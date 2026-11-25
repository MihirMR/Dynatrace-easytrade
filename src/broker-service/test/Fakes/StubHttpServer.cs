using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.DTO;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
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
        /// <summary><c>GET /v1/flags/portfolio-insights-enabled</c>.</summary>
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
        /// <see cref="Refuse"/> or the stub stops.
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
    /// Only the portfolio insights flag and the latest prices follow the configured
    /// <see cref="StubMode"/>; every other path answers 404. In Respond and Hold, every other
    /// flag id answers 404. While the flag route refuses, every flag id at the flag address is
    /// refused, and OpenFeature's client resolves a failed read to the caller's default as it
    /// does a 404. Either way problem-pattern reads resolve to their defaults, so problem-pattern
    /// behaviour stays at its defaults (Guardrails directive 1).
    /// </remarks>
    public sealed class StubHttpServer : IAsyncDisposable
    {
        public const string HttpListenerName = "http";
        public const string GrpcListenerName = "grpc";

        /// <summary>Path the broker requests for the portfolio insights flag.</summary>
        public const string FlagPath = "/v1/flags/" + Constants.PortfolioInsightsEnabled;

        /// <summary>Path the broker requests for the latest prices.</summary>
        public const string LatestPricesPath = "/v1/prices/latest";

        private const string HttpScheme = "http://";
        private const string GrpcContentType = "application/grpc";
        private const string GrpcStatusUnimplemented = "12";

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
        /// Whether a client aborted a held request since start or the last clear. Requests the
        /// stub drops itself, when their route enters <see cref="StubMode.Refuse"/> or the stub
        /// stops, do not count.
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
            catch
            {
                await server.DisposeAsync();
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

        /// <summary>Candles the latest-prices route returns; empty by default.</summary>
        public void SetLatestPrices(IEnumerable<Price> prices)
        {
            ArgumentNullException.ThrowIfNull(prices);
            Price[] copy = [.. prices];
            lock (_gate)
            {
                _latestPrices = copy;
            }
        }

        /// <summary>Recorded requests whose path equals <paramref name="path"/>.</summary>
        public int Count(string path)
        {
            ArgumentNullException.ThrowIfNull(path);
            return _requests.Count(request => IsPath(request, path));
        }

        /// <summary>Held requests to <paramref name="path"/> that their client aborted.</summary>
        public int AbortedCount(string path)
        {
            ArgumentNullException.ThrowIfNull(path);
            lock (_gate)
            {
                return _abortCounts.GetValueOrDefault(path);
            }
        }

        /// <summary>
        /// Clears the recorded requests, the abort counts and <see cref="ClientAborted"/>; waits
        /// already pending stay registered.
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
        /// and clears the recordings.
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
        /// Completes once a client has aborted a held request since start or the last clear,
        /// at once when one already has. On expiry a <see cref="TimeoutException"/> names the
        /// held paths.
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
        /// every listener and frees the ports refused routes hold. Calling it again does nothing.
        /// </summary>
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 1)
            {
                return;
            }

            await _shutdown.CancelAsync();
            // A transition in progress finishes first; with held requests released it is brief.
            await _transitions.WaitAsync();
            try
            {
                await _flagListener.StopAsync();
                await _latestPricesListener.StopAsync();
                if (_grpcApp is not null && _grpcAppStarted)
                {
                    await _grpcApp.StopAsync();
                }
            }
            finally
            {
                await _flagListener.DisposeAsync();
                await _latestPricesListener.DisposeAsync();
                if (_grpcApp is not null)
                {
                    await _grpcApp.DisposeAsync();
                }
                _shutdown.Dispose();
                _transitions.Release();
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
            // An explicit URL overrides ASPNETCORE_URLS and ASPNETCORE_HTTP_PORTS of the test run;
            // port 0 asks for a free port.
            builder.WebHost.UseUrls($"{HttpScheme}{IPAddress.Loopback}:{port}");
            builder.WebHost.ConfigureKestrel(options =>
                options.ConfigureEndpointDefaults(listen => listen.Protocols = protocols)
            );
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

        private async Task HandleRouteAsync(
            HttpContext context,
            RouteListener listener,
            CancellationToken closingToken
        )
        {
            StubRecordedRequest request = Record(HttpListenerName, context);
            if (HttpMethods.IsGet(request.Method) && IsPath(request, listener.Path))
            {
                await ServeAsync(context, listener.Route, request.Path, closingToken);
                return;
            }
            // Every other flag id, every other pricing route and anything else.
            context.Response.StatusCode = StatusCodes.Status404NotFound;
        }

        private Task HandleGrpcAsync(HttpContext context)
        {
            Record(GrpcListenerName, context);
            // Trailers-only reply: Grpc.Net.Client reads grpc-status from the response headers and
            // raises RpcException(Unimplemented), which the broker wraps in DbException.
            context.Response.StatusCode = StatusCodes.Status200OK;
            context.Response.ContentType = GrpcContentType;
            context.Response.Headers["grpc-status"] = GrpcStatusUnimplemented;
            context.Response.Headers["grpc-message"] = "stub";
            return Task.CompletedTask;
        }

        private async Task ServeAsync(
            HttpContext context,
            StubRoute route,
            string path,
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
                    await HoldAsync(context, path, closingToken);
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

        // closingToken is cancelled when the listener closes or the stub stops.
        private async Task HoldAsync(
            HttpContext context,
            string path,
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
            RecordClientAbort(path);
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

        private StubRecordedRequest Record(string listener, HttpContext context)
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
            lock (_gate)
            {
                _requests.Enqueue(request);
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
            return request;
        }

        private void RecordClientAbort(string path)
        {
            TaskCompletionSource[] waiters;
            lock (_gate)
            {
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
        }

        // Called with _gate held.
        private string DescribeHeldPaths()
        {
            List<string> held = [];
            if (_flagRoute.Mode == StubMode.Hold)
            {
                held.Add(FlagPath);
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

            // The one path that follows the route's settings; every other path answers 404.
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

            public async ValueTask DisposeAsync()
            {
                await DisposeAppAsync();
                _placeholder?.Dispose();
                _placeholder = null;
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
