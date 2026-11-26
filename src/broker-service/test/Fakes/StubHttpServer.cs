using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Runtime.ExceptionServices;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.DTO;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using Google.Protobuf;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Primitives;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>Stub route whose behaviour a test controls.</summary>
    public enum StubRoute
    {
        /// <summary>
        /// <c>GET /v1/flags/portfolio-insights-enabled</c>; in <see cref="StubMode.Hold"/>, every
        /// <c>GET /v1/flags/{id}</c>.
        /// </summary>
        Flag,

        /// <summary><c>GET /v1/prices/latest</c>.</summary>
        LatestPrices,
    }

    /// <summary>How a controlled stub route answers.</summary>
    public enum StubMode
    {
        /// <summary>Answers with the configured status, and with a body for 200.</summary>
        Respond,

        /// <summary>
        /// Refuses every connection: the route's listener is closed and its port held by a socket
        /// that never listens, so the OS refuses each connect and nothing reaches or is recorded
        /// by the stub. The client gets an <see cref="HttpRequestException"/> whose inner
        /// <see cref="SocketException"/> has <see cref="SocketError.ConnectionRefused"/>.
        /// </summary>
        /// <remarks>
        /// A test tells a refusal from a reset by <see cref="StubHttpServer.Count(string)"/>
        /// staying 0 for the route's path. On Windows the client's connect reports the refusal
        /// only after its SYN retries, about 2 s on loopback; on Linux it reports it at once, so a
        /// caller with a deadline of about 2 s sees its deadline first on Windows.
        /// The held port is never handed to a socket that asks for a free port, and on Windows no
        /// other socket can bind it. On Linux a socket that binds that exact port with address
        /// reuse, which .NET sets on every TCP bind there, can still listen on it and take the
        /// route's connects; while it listens the stub cannot listen again, so leaving Refuse
        /// throws <see cref="InvalidOperationException"/>.
        /// </remarks>
        Refuse,

        /// <summary>
        /// Keeps the request open until the client aborts it, the route enters
        /// <see cref="Refuse"/> or the stub stops. On the flag route it holds the read of every
        /// flag id, the problem-pattern ids included, as a hung flag service would.
        /// </summary>
        Hold,
    }

    /// <summary>
    /// One request the stub received. <see cref="Listener"/> is <c>"http"</c> or <c>"grpc"</c>;
    /// <see cref="Headers"/> is case-insensitive, with repeated values joined by commas.
    /// </summary>
    public sealed record StubRecordedRequest(
        string Listener,
        string Method,
        string Path,
        string QueryString,
        IReadOnlyDictionary<string, string> Headers,
        DateTimeOffset ReceivedAt
    );

    /// <summary>
    /// In-process Kestrel listeners that stand in for feature-flag-service and pricing-service,
    /// each on its own loopback port, and, optionally, for db-adapter's gRPC endpoint, so the
    /// broker's real connectors run over sockets. Every request that reaches a listener is
    /// recorded before it is answered.
    /// </summary>
    /// <remarks>
    /// While an HTTP listener listens, its route in <see cref="StubMode.Respond"/>, only a GET of
    /// that route's path, the portfolio insights flag or the latest prices, gets the configured
    /// answer; every other request answers 404, including every other flag id at the flag
    /// address and every other pricing route at the pricing address. In
    /// <see cref="StubMode.Hold"/> the pricing route holds only the latest prices, while the flag
    /// route holds every <c>GET /v1/flags/{id}</c>: a whole hung flag service, whose
    /// problem-pattern reads hang until their client gives up. While a route is in
    /// <see cref="StubMode.Refuse"/>, its connects are refused and get no HTTP response, and
    /// nothing is recorded: every flag id at the flag address is refused, and OpenFeature's
    /// client resolves the failed read to the caller's default as it does a 404. In Respond and
    /// Refuse, problem-pattern reads therefore resolve to their defaults, so problem-pattern
    /// behaviour stays at its defaults (Guardrails directive 1).
    /// The gRPC listener has no mode and serves HTTP/2 only: it records every HTTP/2 request,
    /// whatever its path or method, and answers HTTP 200 with a trailers-only <c>grpc-status</c>
    /// 12 (Unimplemented), which Grpc.Net.Client raises as RpcException(Unimplemented). The one
    /// exception is opt-in: a method path given a reply through <see cref="SetGrpcReply"/> has
    /// its request message read to the end, then is answered with that one message and
    /// <c>grpc-status</c> 0 in the trailers, until <see cref="ResetAsync"/>. Kestrel answers an
    /// HTTP/1.1 request on the listener with 400 before the stub sees it, so it is not recorded.
    /// </remarks>
    public sealed class StubHttpServer : IAsyncDisposable
    {
        public const string HttpListenerName = "http";
        public const string GrpcListenerName = "grpc";

        /// <summary>Path of every flag read; the flag id follows it.</summary>
        public const string FlagPathPrefix = "/v1/flags/";

        /// <summary>Path the broker requests for the portfolio insights flag.</summary>
        public const string FlagPath = FlagPathPrefix + Constants.PortfolioInsightsEnabled;

        /// <summary>Path the broker requests for the latest prices.</summary>
        public const string LatestPricesPath = "/v1/prices/latest";

        private const string HttpScheme = "http://";
        private const string GrpcContentType = "application/grpc";
        private const string GrpcStatusHeader = "grpc-status";
        private const string GrpcStatusOk = "0";
        private const string GrpcStatusUnimplemented = "12";

        // gRPC length-prefixed framing: a 1-byte compression flag, then a 4-byte big-endian length.
        private const int GrpcMessagePrefixLength = 5;

        private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(5);
        private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);
        private static readonly RouteSettings DefaultRoute = new(
            StubMode.Respond,
            HttpStatusCode.OK
        );

        private readonly Lock _gate = new();

        // Serialises listener transitions; route settings stay under _gate. Never disposed: it
        // allocates no wait handle, and a transition still waiting must observe the disposal.
        private readonly SemaphoreSlim _transitions = new(1, 1);
        private readonly CancellationTokenSource _shutdown = new();
        private readonly CancellationToken _shutdownToken;
        private readonly ConcurrentQueue<StubRecordedRequest> _requests = new();
        private readonly Dictionary<string, int> _abortCounts = new(StringComparer.Ordinal);
        private readonly List<RequestWaiter> _requestWaiters = [];
        private readonly List<TaskCompletionSource> _abortWaiters = [];

        // Framed reply per gRPC method path, under _gate; a path without one answers status 12.
        private readonly Dictionary<string, byte[]> _grpcReplies = new(StringComparer.Ordinal);
        private readonly RouteListener _flagListener = new(StubRoute.Flag, FlagPath);
        private readonly RouteListener _latestPricesListener = new(
            StubRoute.LatestPrices,
            LatestPricesPath
        );
        private readonly WebApplication? _grpcApp;

        private RouteSettings _flagRoute = DefaultRoute;
        private RouteSettings _latestPricesRoute = DefaultRoute;
        private bool _flagEnabled;
        private IReadOnlyList<Price> _latestPrices = [];
        private bool _clientAborted;

        // Advanced by every clear and reset. A client abort counts only for a request recorded
        // in the current generation, so a request held across a clear or reset leaves no trace.
        private long _recordingGeneration;
        private bool _grpcAppStarted;
        private int _disposed;

        private StubHttpServer(bool enableGrpcListener)
        {
            _shutdownToken = _shutdown.Token;
            if (enableGrpcListener)
            {
                // Grpc.Net.Client over http:// speaks prior-knowledge HTTP/2, which Kestrel serves
                // only on an endpoint limited to HTTP/2.
                _grpcApp = BuildApp(HttpProtocols.Http2, 0);
                _grpcApp.Run(HandleGrpcAsync);
            }
        }

        /// <summary>
        /// Address for <c>FEATURE_FLAG_SERVICE_ADDRESS</c>, for example
        /// <c>http://127.0.0.1:5123</c>, with no trailing slash. It never changes, whatever the
        /// flag route's mode.
        /// </summary>
        public string FeatureFlagServiceAddress => _flagListener.Address;

        /// <summary>
        /// Address for <c>PRICING_SERVICE_ADDRESS</c>, for example <c>http://127.0.0.1:5125</c>,
        /// with no trailing slash. It never changes, whatever the latest-prices route's mode.
        /// </summary>
        public string PricingServiceAddress => _latestPricesListener.Address;

        /// <summary>
        /// Address for <c>DB_ADAPTER_ADDRESS</c>, for example <c>127.0.0.1:5124</c>, without a
        /// scheme because the connector adds <c>http://</c>; null when the gRPC listener is off.
        /// </summary>
        public string? GrpcAddress { get; private set; }

        /// <summary>Requests received since start or the last clear, in arrival order.</summary>
        public IReadOnlyList<StubRecordedRequest> Requests => _requests.ToArray();

        /// <summary>
        /// Whether a client aborted a held request recorded since start or the last clear or
        /// reset. A request held across a clear or reset and aborted later does not count, nor
        /// do requests the stub drops itself, when their route enters
        /// <see cref="StubMode.Refuse"/> or the stub stops.
        /// </summary>
        public bool ClientAborted
        {
            get
            {
                lock (_gate)
                {
                    return _clientAborted;
                }
            }
        }

        /// <summary>
        /// Starts the feature-flag and pricing listeners and, when
        /// <paramref name="enableGrpcListener"/> is set, the gRPC listener, each on its own free
        /// loopback port.
        /// </summary>
        /// <exception cref="AggregateException">
        /// Starting failed and releasing what had started failed too; it holds the start failure
        /// first, then the cleanup failure. A start failure whose cleanup succeeds is rethrown as
        /// it was raised.
        /// </exception>
        public static async Task<StubHttpServer> StartAsync(
            bool enableGrpcListener = false,
            CancellationToken cancellationToken = default
        )
        {
            StubHttpServer server = new(enableGrpcListener);
            try
            {
                await server.OpenAsync(server._flagListener, cancellationToken);
                await server.OpenAsync(server._latestPricesListener, cancellationToken);
                if (server._grpcApp is not null)
                {
                    // Kestrel replaces port 0 with the bound port in Urls once started.
                    await server._grpcApp.StartAsync(cancellationToken);
                    server._grpcAppStarted = true;
                    string grpcUrl = server._grpcApp.Urls.First().TrimEnd('/');
                    server.GrpcAddress = grpcUrl.StartsWith(HttpScheme, StringComparison.Ordinal)
                        ? grpcUrl[HttpScheme.Length..]
                        : grpcUrl;
                }
                return server;
            }
            catch (Exception startException)
            {
                try
                {
                    await server.DisposeAsync();
                }
                catch (Exception cleanupException)
                {
                    // Neither hides the other: the start failure is the cause, the cleanup
                    // failure names what may still be held.
                    throw new AggregateException(
                        "The stub failed to start, and releasing what it had started failed too.",
                        startException,
                        cleanupException
                    );
                }
                throw;
            }
        }

        /// <summary>
        /// Sets how the route answers, <see cref="StubMode.Respond"/> by default, and completes
        /// once the route's listener matches the mode.
        /// </summary>
        /// <remarks>
        /// Entering <see cref="StubMode.Refuse"/> drops the route's held requests, which do not
        /// count as client aborts, closes the route's listener and holds its port with a socket
        /// that never listens, so the OS refuses each connect. Nothing then reaches or is
        /// recorded by the stub, and the client gets an <see cref="HttpRequestException"/> whose
        /// inner <see cref="SocketException"/> has <see cref="SocketError.ConnectionRefused"/>.
        /// On Windows the client's connect reports the refusal only after its SYN retries, about
        /// 2 s on loopback; on Linux at once, so a caller with a deadline of about 2 s sees its
        /// deadline first on Windows. Leaving Refuse listens on the same port again, so the
        /// route's address never changes. Refuse to Refuse, and Respond to Hold either way,
        /// leave the listener as it is.
        /// </remarks>
        /// <exception cref="InvalidOperationException">
        /// The route's port could not be held, or listened on again; the listener stays closed.
        /// On Linux, leaving Refuse throws it while another socket listens on the held port, as
        /// <see cref="StubMode.Refuse"/> describes.
        /// </exception>
        public async Task SetModeAsync(
            StubRoute route,
            StubMode mode,
            CancellationToken cancellationToken = default
        )
        {
            if (!Enum.IsDefined(mode))
            {
                throw new ArgumentOutOfRangeException(nameof(mode), mode, "Unknown stub mode.");
            }
            RouteListener listener = GetListener(route);
            await _transitions.WaitAsync(cancellationToken);
            try
            {
                ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) == 1, this);
                await TransitionAsync(listener, mode, cancellationToken);
            }
            finally
            {
                _transitions.Release();
            }
        }

        /// <summary>
        /// Status the route answers with in <see cref="StubMode.Respond"/>; 200 by default. Only
        /// 200 carries a body.
        /// </summary>
        public void SetStatus(StubRoute route, HttpStatusCode status)
        {
            int code = (int)status;
            if (code is < 100 or > 599)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(status),
                    status,
                    "Not an HTTP status."
                );
            }
            UpdateRoute(route, settings => settings with { Status = status });
        }

        /// <summary>Portfolio insights flag value; false by default, as in production.</summary>
        public void SetFlagEnabled(bool enabled)
        {
            lock (_gate)
            {
                _flagEnabled = enabled;
            }
        }

        /// <summary>
        /// Candles the latest-prices route returns; empty by default. Each candle's fields,
        /// <see cref="Price.Id"/> included, are copied when this is called, so later changes to
        /// the source candles or to <paramref name="prices"/> do not change the reply.
        /// </summary>
        /// <exception cref="ArgumentException">
        /// An element of <paramref name="prices"/> is null; the candles set before stay in place.
        /// </exception>
        public void SetLatestPrices(IEnumerable<Price> prices)
        {
            ArgumentNullException.ThrowIfNull(prices);
            List<Price> copy = [];
            foreach (Price price in prices)
            {
                if (price is null)
                {
                    throw new ArgumentException("A candle is null.", nameof(prices));
                }
                copy.Add(CopyPrice(price));
            }
            lock (_gate)
            {
                _latestPrices = copy;
            }
        }

        /// <summary>
        /// Answers every later gRPC call to <paramref name="methodPath"/>, the request path
        /// <c>/package.Service/Method</c>, for example
        /// <c>/easytrade.dbadapter.alert.AlertService/ListAlerts</c>, with
        /// <paramref name="message"/> and <c>grpc-status</c> 0 instead of status 12. The message
        /// is serialized when this is called, so later changes to it do not change the reply; a
        /// later call for the same path replaces it. Every other path keeps status 12, and
        /// <see cref="ResetAsync"/> removes every configured reply.
        /// </summary>
        /// <exception cref="ArgumentException">
        /// <paramref name="methodPath"/> is empty or does not start with <c>/</c>, so no call
        /// could match it.
        /// </exception>
        /// <exception cref="InvalidOperationException">
        /// The stub was started without its gRPC listener.
        /// </exception>
        public void SetGrpcReply(string methodPath, IMessage message)
        {
            ArgumentException.ThrowIfNullOrEmpty(methodPath);
            ArgumentNullException.ThrowIfNull(message);
            if (!methodPath.StartsWith('/'))
            {
                throw new ArgumentException(
                    $"The gRPC method path [{methodPath}] does not start with '/'.",
                    nameof(methodPath)
                );
            }
            if (_grpcApp is null)
            {
                throw new InvalidOperationException(
                    "The stub was started without its gRPC listener."
                );
            }
            byte[] frame = FrameGrpcMessage(message.ToByteArray());
            lock (_gate)
            {
                _grpcReplies[methodPath] = frame;
            }
        }

        /// <summary>Recorded requests whose path equals <paramref name="path"/>.</summary>
        public int Count(string path)
        {
            ArgumentNullException.ThrowIfNull(path);
            return _requests.Count(request => IsPath(request, path));
        }

        /// <summary>
        /// Held requests to <paramref name="path"/>, recorded since start or the last clear or
        /// reset, that their client aborted.
        /// </summary>
        public int AbortedCount(string path)
        {
            ArgumentNullException.ThrowIfNull(path);
            lock (_gate)
            {
                return _abortCounts.GetValueOrDefault(path);
            }
        }

        /// <summary>
        /// Clears the recorded requests, the abort counts and <see cref="ClientAborted"/>, and
        /// discards the later client abort of every request recorded before the clear, one still
        /// held included. Waits already pending stay registered; a pending abort wait completes
        /// only on the abort of a request recorded after the clear.
        /// </summary>
        public void ClearRecordings()
        {
            lock (_gate)
            {
                ClearRecordingsLocked();
            }
        }

        /// <summary>
        /// Listens again on the port of every refused route, puts every route back to
        /// <see cref="StubMode.Respond"/> with 200, the flag to false and the prices to empty,
        /// removes every reply <see cref="SetGrpcReply"/> configured, so every gRPC call answers
        /// status 12 again, and clears the recordings as <see cref="ClearRecordings"/> does. A
        /// held request stays held, because leaving Hold keeps its listener open, and its
        /// client's later abort is discarded.
        /// </summary>
        /// <exception cref="InvalidOperationException">
        /// A refused route's port could not be listened on again; its listener stays closed.
        /// </exception>
        public async Task ResetAsync()
        {
            await _transitions.WaitAsync();
            try
            {
                ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) == 1, this);
                await TransitionAsync(_flagListener, StubMode.Respond, CancellationToken.None);
                await TransitionAsync(
                    _latestPricesListener,
                    StubMode.Respond,
                    CancellationToken.None
                );
                lock (_gate)
                {
                    _flagRoute = DefaultRoute;
                    _latestPricesRoute = DefaultRoute;
                    _flagEnabled = false;
                    _latestPrices = [];
                    _grpcReplies.Clear();
                    ClearRecordingsLocked();
                }
            }
            finally
            {
                _transitions.Release();
            }
        }

        /// <summary>
        /// Returns the first recorded request to <paramref name="path"/>, or waits for the next
        /// one. <paramref name="timeout"/> bounds the wait; on expiry a
        /// <see cref="TimeoutException"/> names the path.
        /// </summary>
        public async Task<StubRecordedRequest> WaitForRequestAsync(string path, TimeSpan timeout)
        {
            ArgumentNullException.ThrowIfNull(path);
            // Waits are always bounded, so an infinite or negative timeout is a test bug.
            ArgumentOutOfRangeException.ThrowIfLessThan(timeout, TimeSpan.Zero);
            RequestWaiter waiter;
            lock (_gate)
            {
                foreach (StubRecordedRequest request in _requests)
                {
                    if (IsPath(request, path))
                    {
                        return request;
                    }
                }
                waiter = new RequestWaiter(path);
                _requestWaiters.Add(waiter);
            }

            try
            {
                return await waiter.Completion.Task.WaitAsync(timeout);
            }
            catch (TimeoutException exception)
            {
                lock (_gate)
                {
                    _requestWaiters.Remove(waiter);
                }
                throw new TimeoutException(
                    $"No request to [{path}] reached the stub within {timeout}.",
                    exception
                );
            }
        }

        /// <summary>
        /// Completes once a client has aborted a held request recorded since start or the last
        /// clear or reset, at once when one already has. A wait still pending at a clear or reset
        /// stays registered and completes only on the abort of a request recorded after it. On
        /// expiry a <see cref="TimeoutException"/> names the held paths.
        /// </summary>
        public async Task WaitForClientAbortAsync(TimeSpan timeout)
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(timeout, TimeSpan.Zero);
            TaskCompletionSource waiter;
            lock (_gate)
            {
                if (_clientAborted)
                {
                    return;
                }
                waiter = new TaskCompletionSource(
                    TaskCreationOptions.RunContinuationsAsynchronously
                );
                _abortWaiters.Add(waiter);
            }

            try
            {
                await waiter.Task.WaitAsync(timeout);
            }
            catch (TimeoutException exception)
            {
                string heldPaths;
                lock (_gate)
                {
                    _abortWaiters.Remove(waiter);
                    heldPaths = DescribeHeldPaths();
                }
                throw new TimeoutException(
                    $"No held request to [{heldPaths}] was aborted by its client within {timeout}.",
                    exception
                );
            }
        }

        /// <summary>
        /// Releases held requests first, so no listener waits for them, then stops and disposes
        /// every listener and frees the ports refused routes hold. Every step is attempted even
        /// when an earlier one fails, so one listener's failure leaves no other listener or port
        /// behind. The transition lock is always released, so a transition waiting for it, or
        /// started later, throws <see cref="ObjectDisposedException"/>. Calling it again does
        /// nothing, even after a failure.
        /// </summary>
        /// <exception cref="AggregateException">
        /// Several steps failed; it holds their failures in step order. A single failure is
        /// rethrown as it was raised. Either is thrown only once every step has been attempted.
        /// </exception>
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 1)
            {
                return;
            }

            List<Exception> failures = [];
            await AttemptAsync(failures, _shutdown.CancelAsync);
            // A transition in progress finishes first; with held requests released it is brief.
            await _transitions.WaitAsync();
            try
            {
                await AttemptAsync(failures, _flagListener.StopAsync);
                await AttemptAsync(failures, _latestPricesListener.StopAsync);
                WebApplication? grpcApp = _grpcApp;
                if (grpcApp is not null && _grpcAppStarted)
                {
                    await AttemptAsync(failures, () => grpcApp.StopAsync());
                }
                await AttemptAsync(failures, () => _flagListener.DisposeAsync().AsTask());
                await AttemptAsync(failures, () => _latestPricesListener.DisposeAsync().AsTask());
                if (grpcApp is not null)
                {
                    await AttemptAsync(failures, () => grpcApp.DisposeAsync().AsTask());
                }
                try
                {
                    _shutdown.Dispose();
                }
                catch (Exception exception)
                {
                    failures.Add(exception);
                }
            }
            finally
            {
                _transitions.Release();
            }

            if (failures.Count == 1)
            {
                ExceptionDispatchInfo.Throw(failures[0]);
            }
            if (failures.Count > 1)
            {
                throw new AggregateException("The stub could not release all it held.", failures);
            }
        }

        // Runs one teardown step and records its failure, so the steps after it still run.
        private static async Task AttemptAsync(List<Exception> failures, Func<Task> step)
        {
            try
            {
                await step();
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }

        private static WebApplication BuildApp(HttpProtocols protocols, int port)
        {
            WebApplicationBuilder builder = WebApplication.CreateSlimBuilder(
                new WebApplicationOptions
                {
                    EnvironmentName = "Testing",
                    ContentRootPath = AppContext.BaseDirectory,
                }
            );
            // Kestrel binds hosting URLs (ASPNETCORE_URLS, ASPNETCORE_HTTP_PORTS) instead of
            // explicit endpoints only when preferHostingUrls is true; this overrides an
            // ASPNETCORE_PREFERHOSTINGURLS of the test run.
            builder.WebHost.PreferHostingUrls(false);
            builder.WebHost.ConfigureKestrel(options =>
            {
                // Replaces the slim builder's loader for the "Kestrel" configuration section with
                // an empty one, so no endpoint, endpoint default or certificate configured there,
                // for example by a Kestrel__Endpoints__* variable, is bound or applied.
                options.Configure();
                // The only endpoint, on loopback alone and with the listener's protocols; port 0
                // asks for a free port.
                options.Listen(IPAddress.Loopback, port, listen => listen.Protocols = protocols);
            });
            // The stub logs nothing, so its lines never mix with the broker host's recorded logs.
            builder.Logging.ClearProviders();
            builder.Services.Configure<HostOptions>(options =>
                options.ShutdownTimeout = ShutdownTimeout
            );
            return builder.Build();
        }

        private static bool IsPath(StubRecordedRequest request, string path)
        {
            return string.Equals(request.Path, path, StringComparison.Ordinal);
        }

        // The stub's own copy: Price has public setters, and the reply serializes what is stored.
        private static Price CopyPrice(Price price)
        {
            return new Price(
                price.InstrumentId,
                price.Timestamp,
                price.Open,
                price.High,
                price.Low,
                price.Close
            )
            {
                Id = price.Id,
            };
        }

        private static byte[] FrameGrpcMessage(byte[] payload)
        {
            byte[] frame = new byte[GrpcMessagePrefixLength + payload.Length];
            // frame[0] stays 0: the message is not compressed.
            BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(1, 4), (uint)payload.Length);
            payload.CopyTo(frame, GrpcMessagePrefixLength);
            return frame;
        }

        private async Task HandleRouteAsync(
            HttpContext context,
            RouteListener listener,
            CancellationToken closingToken
        )
        {
            (StubRecordedRequest request, long generation) = Record(HttpListenerName, context);
            if (HttpMethods.IsGet(request.Method) && IsPath(request, listener.Path))
            {
                await ServeAsync(context, listener.Route, request.Path, generation, closingToken);
                return;
            }
            if (IsHeldFlagRead(listener.Route, request))
            {
                // A hung flag service hangs every flag read, not only the portfolio insights one.
                await HoldAsync(context, request.Path, generation, closingToken);
                return;
            }
            // Every other flag id, every other pricing route and anything else.
            context.Response.StatusCode = StatusCodes.Status404NotFound;
        }

        // A GET of /v1/flags/{id} for any other id while the flag route is in Hold.
        private bool IsHeldFlagRead(StubRoute route, StubRecordedRequest request)
        {
            if (
                (route != StubRoute.Flag)
                || !HttpMethods.IsGet(request.Method)
                || !request.Path.StartsWith(FlagPathPrefix, StringComparison.Ordinal)
                || (request.Path.Length == FlagPathPrefix.Length)
                || (request.Path.IndexOf('/', FlagPathPrefix.Length) >= 0)
            )
            {
                return false;
            }
            lock (_gate)
            {
                return _flagRoute.Mode == StubMode.Hold;
            }
        }

        private async Task HandleGrpcAsync(HttpContext context)
        {
            (StubRecordedRequest request, _) = Record(GrpcListenerName, context);
            byte[]? frame;
            lock (_gate)
            {
                frame = _grpcReplies.GetValueOrDefault(request.Path);
            }
            context.Response.StatusCode = StatusCodes.Status200OK;
            context.Response.ContentType = GrpcContentType;
            if (frame is null)
            {
                // Trailers-only reply: Grpc.Net.Client reads grpc-status from the response headers
                // and raises RpcException(Unimplemented), which the broker wraps in DbException.
                context.Response.Headers[GrpcStatusHeader] = GrpcStatusUnimplemented;
                context.Response.Headers["grpc-message"] = "stub";
                return;
            }
            // A unary call's success: the request message is read to its end, then one message
            // goes out and the status follows it in the trailers, which every HTTP/2 response
            // supports and Grpc.Net.Client reads once the message is read.
            await context.Request.Body.CopyToAsync(Stream.Null, context.RequestAborted);
            await context.Response.Body.WriteAsync(frame, context.RequestAborted);
            context.Response.AppendTrailer(GrpcStatusHeader, GrpcStatusOk);
        }

        private async Task ServeAsync(
            HttpContext context,
            StubRoute route,
            string path,
            long generation,
            CancellationToken closingToken
        )
        {
            RouteSettings settings;
            bool flagEnabled;
            IReadOnlyList<Price> latestPrices;
            lock (_gate)
            {
                settings = route == StubRoute.Flag ? _flagRoute : _latestPricesRoute;
                flagEnabled = _flagEnabled;
                latestPrices = _latestPrices;
            }

            switch (settings.Mode)
            {
                case StubMode.Refuse:
                    // Only a request the route's listener took in while closing gets here. It is
                    // dropped, as the listener's held requests are.
                    context.Abort();
                    return;
                case StubMode.Hold:
                    await HoldAsync(context, path, generation, closingToken);
                    return;
            }

            context.Response.StatusCode = (int)settings.Status;
            if (settings.Status != HttpStatusCode.OK)
            {
                return;
            }
            if (route == StubRoute.Flag)
            {
                Flag flag = new(
                    Constants.PortfolioInsightsEnabled,
                    flagEnabled,
                    "Portfolio insights",
                    "Simulated Portfolio Insights demo feature.",
                    true,
                    "feature"
                );
                await context.Response.WriteAsJsonAsync(flag, WebJson, context.RequestAborted);
                return;
            }
            await context.Response.WriteAsJsonAsync(
                new PricesResultDto(latestPrices),
                WebJson,
                context.RequestAborted
            );
        }

        // generation is the recording generation Record put the request in; closingToken is
        // cancelled when the listener closes or the stub stops.
        private async Task HoldAsync(
            HttpContext context,
            string path,
            long generation,
            CancellationToken closingToken
        )
        {
            using CancellationTokenSource released =
                CancellationTokenSource.CreateLinkedTokenSource(
                    context.RequestAborted,
                    closingToken
                );
            await Task.Delay(Timeout.Infinite, released.Token)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);

            if (closingToken.IsCancellationRequested)
            {
                // Dropped rather than answered, so a client still waiting sees the service go
                // away instead of an empty 200; the stub's own drop is not a client abort.
                context.Abort();
                return;
            }
            RecordClientAbort(path, generation);
        }

        // Listens on the listener's port, or on a free port the first time.
        private Task OpenAsync(RouteListener listener, CancellationToken cancellationToken)
        {
            return listener.OpenAsync(
                (port, closingToken) =>
                {
                    WebApplication app = BuildApp(HttpProtocols.Http1, port);
                    app.Run(context => HandleRouteAsync(context, listener, closingToken));
                    return app;
                },
                _shutdownToken,
                cancellationToken
            );
        }

        // Called with _transitions held.
        private async Task TransitionAsync(
            RouteListener listener,
            StubMode mode,
            CancellationToken cancellationToken
        )
        {
            // Set before the listener changes: a request the closing listener still takes in is
            // dropped, and the reopened listener answers in the new mode from its first request.
            UpdateRoute(listener.Route, settings => settings with { Mode = mode });
            if (mode == StubMode.Refuse)
            {
                await listener.CloseAsync();
                return;
            }
            if (listener.IsListening)
            {
                return;
            }
            try
            {
                await OpenAsync(listener, cancellationToken);
            }
            catch
            {
                // The listener stayed closed, so the route still refuses.
                UpdateRoute(listener.Route, settings => settings with { Mode = StubMode.Refuse });
                throw;
            }
        }

        private RouteListener GetListener(StubRoute route)
        {
            return route switch
            {
                StubRoute.Flag => _flagListener,
                StubRoute.LatestPrices => _latestPricesListener,
                _ => throw new ArgumentOutOfRangeException(
                    nameof(route),
                    route,
                    "Unknown stub route."
                ),
            };
        }

        // Also returns the request's recording generation, read under the lock that enqueues it,
        // so a clear or reset comes either before both or after both.
        private (StubRecordedRequest Request, long Generation) Record(
            string listener,
            HttpContext context
        )
        {
            Dictionary<string, string> headers = new(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, StringValues> header in context.Request.Headers)
            {
                headers[header.Key] = string.Join(",", header.Value.ToArray());
            }
            StubRecordedRequest request = new(
                listener,
                context.Request.Method,
                context.Request.Path.Value ?? string.Empty,
                context.Request.QueryString.Value ?? string.Empty,
                headers.AsReadOnly(),
                DateTimeOffset.UtcNow
            );

            List<RequestWaiter> matched = [];
            long generation;
            lock (_gate)
            {
                _requests.Enqueue(request);
                generation = _recordingGeneration;
                _requestWaiters.RemoveAll(waiter =>
                {
                    if (!IsPath(request, waiter.Path))
                    {
                        return false;
                    }
                    matched.Add(waiter);
                    return true;
                });
            }
            // Completed outside the lock so no continuation runs while the stub state is held.
            foreach (RequestWaiter waiter in matched)
            {
                waiter.Completion.TrySetResult(request);
            }
            return (request, generation);
        }

        // generation is the one Record returned for the held request.
        private void RecordClientAbort(string path, long generation)
        {
            TaskCompletionSource[] waiters;
            lock (_gate)
            {
                if (generation != _recordingGeneration)
                {
                    // Recorded before the last clear or reset: no current recording holds the
                    // request, so its abort sets nothing and completes no wait.
                    return;
                }
                _clientAborted = true;
                _abortCounts[path] = _abortCounts.GetValueOrDefault(path) + 1;
                waiters = [.. _abortWaiters];
                _abortWaiters.Clear();
            }
            foreach (TaskCompletionSource waiter in waiters)
            {
                waiter.TrySetResult();
            }
        }

        private void UpdateRoute(StubRoute route, Func<RouteSettings, RouteSettings> update)
        {
            lock (_gate)
            {
                switch (route)
                {
                    case StubRoute.Flag:
                        _flagRoute = update(_flagRoute);
                        break;
                    case StubRoute.LatestPrices:
                        _latestPricesRoute = update(_latestPricesRoute);
                        break;
                    default:
                        throw new ArgumentOutOfRangeException(
                            nameof(route),
                            route,
                            "Unknown stub route."
                        );
                }
            }
        }

        // Called with _gate held.
        private void ClearRecordingsLocked()
        {
            _requests.Clear();
            _abortCounts.Clear();
            _clientAborted = false;
            // Every request recorded so far, held ones included, now belongs to a past generation.
            _recordingGeneration++;
        }

        // Called with _gate held.
        private string DescribeHeldPaths()
        {
            List<string> held = [];
            if (_flagRoute.Mode == StubMode.Hold)
            {
                held.Add(FlagPathPrefix + "{id}");
            }
            if (_latestPricesRoute.Mode == StubMode.Hold)
            {
                held.Add(LatestPricesPath);
            }
            return held.Count == 0 ? "no route in Hold mode" : string.Join(", ", held);
        }

        private readonly record struct RouteSettings(StubMode Mode, HttpStatusCode Status);

        // One route's listener: the port it keeps for the stub's lifetime and either its running
        // app with that app's closing token or, while the route refuses, the socket holding the
        // port. StartAsync, transitions and DisposeAsync change it, one at a time.
        private sealed class RouteListener(StubRoute route, string path) : IAsyncDisposable
        {
            private (WebApplication App, CancellationTokenSource Closing)? _running;
            private Socket? _placeholder;
            private int _port;

            public StubRoute Route { get; } = route;

            // The one path whose GET follows the route's settings; while the listener listens,
            // every other request answers 404.
            public string Path { get; } = path;

            public string Address { get; private set; } = string.Empty;

            public bool IsListening => _running is not null;

            // Listens on the kept port, or on a free port the first time. createApp builds the
            // app for a port and the closing token its handlers watch.
            public async Task OpenAsync(
                Func<int, CancellationToken, WebApplication> createApp,
                CancellationToken shutdownToken,
                CancellationToken cancellationToken
            )
            {
                if (_running is not null)
                {
                    return;
                }
                _placeholder?.Dispose();
                _placeholder = null;
                // Linked to the stub's shutdown, so disposal drops held requests as closing does.
                CancellationTokenSource closing = CancellationTokenSource.CreateLinkedTokenSource(
                    shutdownToken
                );
                WebApplication? app = null;
                try
                {
                    app = createApp(_port, closing.Token);
                    await app.StartAsync(cancellationToken);
                    if (_port == 0)
                    {
                        // Kestrel replaces port 0 with the bound port in Urls once started.
                        _port = new Uri(app.Urls.First()).Port;
                        Address = $"{HttpScheme}{IPAddress.Loopback}:{_port}";
                    }
                    _running = (app, closing);
                }
                catch (Exception exception) when (exception is IOException or SocketException)
                {
                    throw new InvalidOperationException(
                        $"The stub could not listen on {IPAddress.Loopback}:{_port}.",
                        exception
                    );
                }
                finally
                {
                    if (_running is null)
                    {
                        if (app is not null)
                        {
                            await app.DisposeAsync();
                        }
                        closing.Dispose();
                    }
                }
            }

            // Drops held requests, stops and disposes the app, then binds a socket to the port and
            // never listens on it, so the OS refuses every connect. No socket asking for a free
            // port gets it, and on Windows no other socket can bind it; on Linux a socket binding
            // it with address reuse, as .NET does there, can still listen on it and take the
            // connects, and OpenAsync then fails until that socket closes.
            public async Task CloseAsync()
            {
                try
                {
                    await StopAsync();
                }
                finally
                {
                    await DisposeAppAsync();
                }
                _placeholder ??= HoldPort(_port);
            }

            // Drops held requests, then stops the app; nothing to do while closed.
            public async Task StopAsync()
            {
                if (_running is not { } running)
                {
                    return;
                }
                await running.Closing.CancelAsync();
                await running.App.StopAsync();
            }

            // Frees the held port even when the app's disposal fails.
            public async ValueTask DisposeAsync()
            {
                try
                {
                    await DisposeAppAsync();
                }
                finally
                {
                    _placeholder?.Dispose();
                    _placeholder = null;
                }
            }

            private static Socket HoldPort(int port)
            {
                Socket socket = new(
                    AddressFamily.InterNetwork,
                    SocketType.Stream,
                    ProtocolType.Tcp
                );
                try
                {
                    socket.Bind(new IPEndPoint(IPAddress.Loopback, port));
                    return socket;
                }
                catch (SocketException exception)
                {
                    socket.Dispose();
                    throw new InvalidOperationException(
                        $"The stub could not hold {IPAddress.Loopback}:{port} for refusal.",
                        exception
                    );
                }
            }

            private async Task DisposeAppAsync()
            {
                if (_running is not { } running)
                {
                    return;
                }
                _running = null;
                try
                {
                    await running.App.DisposeAsync();
                }
                finally
                {
                    running.Closing.Dispose();
                }
            }
        }

        private sealed class RequestWaiter(string path)
        {
            public string Path { get; } = path;

            public TaskCompletionSource<StubRecordedRequest> Completion { get; } =
                new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
    }
}
