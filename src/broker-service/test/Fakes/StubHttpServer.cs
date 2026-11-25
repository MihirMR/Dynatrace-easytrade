using System.Collections.Concurrent;
using System.Net;
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

        /// <summary>Drops the connection without a response.</summary>
        Refuse,

        /// <summary>Keeps the request open until the client aborts it or the stub stops.</summary>
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
    /// In-process Kestrel server that stands in for feature-flag-service, pricing-service and,
    /// optionally, db-adapter's gRPC endpoint, so the broker's real connectors run over sockets.
    /// Every request is recorded before it is answered.
    /// </summary>
    /// <remarks>
    /// Only the portfolio insights flag and the latest prices follow the configured
    /// <see cref="StubMode"/>. Every other flag id answers 404 in every mode, so problem-pattern
    /// reads always resolve to their defaults and problem-pattern behaviour never changes.
    /// </remarks>
    public sealed class StubHttpServer : IAsyncDisposable
    {
        public const string HttpListenerName = "http";
        public const string GrpcListenerName = "grpc";

        /// <summary>Path the broker requests for the portfolio insights flag.</summary>
        public const string FlagPath = "/v1/flags/" + Constants.PortfolioInsightsEnabled;

        /// <summary>Path the broker requests for the latest prices.</summary>
        public const string LatestPricesPath = "/v1/prices/latest";

        private const string LoopbackUrl = "http://127.0.0.1:0";
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
        private readonly CancellationTokenSource _shutdown = new();
        private readonly CancellationToken _shutdownToken;
        private readonly ConcurrentQueue<StubRecordedRequest> _requests = new();
        private readonly Dictionary<string, int> _abortCounts = new(StringComparer.Ordinal);
        private readonly List<RequestWaiter> _requestWaiters = [];
        private readonly List<TaskCompletionSource> _abortWaiters = [];
        private readonly WebApplication _httpApp;
        private readonly WebApplication? _grpcApp;
        private readonly List<WebApplication> _startedApps = [];

        private RouteSettings _flagRoute = DefaultRoute;
        private RouteSettings _latestPricesRoute = DefaultRoute;
        private bool _flagEnabled;
        private IReadOnlyList<Price> _latestPrices = [];
        private bool _clientAborted;
        private int _disposed;

        private StubHttpServer(bool enableGrpcListener)
        {
            _shutdownToken = _shutdown.Token;
            _httpApp = BuildApp(HttpProtocols.Http1);
            _httpApp.Run(HandleHttpAsync);
            if (enableGrpcListener)
            {
                // Grpc.Net.Client over http:// speaks prior-knowledge HTTP/2, which Kestrel serves
                // only on an endpoint limited to HTTP/2.
                _grpcApp = BuildApp(HttpProtocols.Http2);
                _grpcApp.Run(HandleGrpcAsync);
            }
        }

        /// <summary>
        /// Address for <c>FEATURE_FLAG_SERVICE_ADDRESS</c> and <c>PRICING_SERVICE_ADDRESS</c>,
        /// for example <c>http://127.0.0.1:5123</c>, with no trailing slash.
        /// </summary>
        public string BaseAddress { get; private set; } = string.Empty;

        /// <summary>
        /// Address for <c>DB_ADAPTER_ADDRESS</c>, for example <c>127.0.0.1:5124</c>, without a
        /// scheme because the connector adds <c>http://</c>; null when the gRPC listener is off.
        /// </summary>
        public string? GrpcAddress { get; private set; }

        /// <summary>Requests received since start or the last clear, in arrival order.</summary>
        public IReadOnlyList<StubRecordedRequest> Requests => _requests.ToArray();

        /// <summary>
        /// Whether a client aborted a held request since start or the last clear. Requests
        /// released by the stub's own shutdown do not count.
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
        /// Starts the HTTP listener and, when <paramref name="enableGrpcListener"/> is set, the
        /// gRPC listener, each on its own free loopback port.
        /// </summary>
        public static async Task<StubHttpServer> StartAsync(
            bool enableGrpcListener = false,
            CancellationToken cancellationToken = default
        )
        {
            StubHttpServer server = new(enableGrpcListener);
            try
            {
                // Kestrel replaces port 0 with the bound port in Urls once started.
                await server._httpApp.StartAsync(cancellationToken);
                server._startedApps.Add(server._httpApp);
                server.BaseAddress = server._httpApp.Urls.First().TrimEnd('/');
                if (server._grpcApp is not null)
                {
                    await server._grpcApp.StartAsync(cancellationToken);
                    server._startedApps.Add(server._grpcApp);
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

        /// <summary>How the route answers; <see cref="StubMode.Respond"/> by default.</summary>
        public void SetMode(StubRoute route, StubMode mode)
        {
            if (!Enum.IsDefined(mode))
            {
                throw new ArgumentOutOfRangeException(nameof(mode), mode, "Unknown stub mode.");
            }
            UpdateRoute(route, settings => settings with { Mode = mode });
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
        /// Puts every route back to <see cref="StubMode.Respond"/> with 200, the flag to false and
        /// the prices to empty, and clears the recordings.
        /// </summary>
        public void Reset()
        {
            lock (_gate)
            {
                _flagRoute = DefaultRoute;
                _latestPricesRoute = DefaultRoute;
                _flagEnabled = false;
                _latestPrices = [];
                ClearRecordingsLocked();
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
        /// Releases held requests first, so neither listener waits for them, then stops and
        /// disposes both listeners. Calling it again does nothing.
        /// </summary>
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 1)
            {
                return;
            }

            await _shutdown.CancelAsync();
            try
            {
                foreach (WebApplication app in _startedApps)
                {
                    await app.StopAsync();
                }
            }
            finally
            {
                await _httpApp.DisposeAsync();
                if (_grpcApp is not null)
                {
                    await _grpcApp.DisposeAsync();
                }
                _shutdown.Dispose();
            }
        }

        private static WebApplication BuildApp(HttpProtocols protocols)
        {
            WebApplicationBuilder builder = WebApplication.CreateSlimBuilder(
                new WebApplicationOptions
                {
                    EnvironmentName = "Testing",
                    ContentRootPath = AppContext.BaseDirectory,
                }
            );
            // An explicit URL overrides ASPNETCORE_URLS and ASPNETCORE_HTTP_PORTS of the test run.
            builder.WebHost.UseUrls(LoopbackUrl);
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

        private async Task HandleHttpAsync(HttpContext context)
        {
            StubRecordedRequest request = Record(HttpListenerName, context);
            if (HttpMethods.IsGet(request.Method))
            {
                if (IsPath(request, FlagPath))
                {
                    await ServeAsync(context, StubRoute.Flag, request.Path);
                    return;
                }
                if (IsPath(request, LatestPricesPath))
                {
                    await ServeAsync(context, StubRoute.LatestPrices, request.Path);
                    return;
                }
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

        private async Task ServeAsync(HttpContext context, StubRoute route, string path)
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
                    context.Abort();
                    return;
                case StubMode.Hold:
                    await HoldAsync(context, path);
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

        private async Task HoldAsync(HttpContext context, string path)
        {
            using CancellationTokenSource released =
                CancellationTokenSource.CreateLinkedTokenSource(
                    context.RequestAborted,
                    _shutdownToken
                );
            await Task.Delay(Timeout.Infinite, released.Token)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);

            if (_shutdownToken.IsCancellationRequested)
            {
                // Dropped rather than answered, so a client still waiting sees the service go
                // away instead of an empty 200.
                context.Abort();
                return;
            }
            RecordClientAbort(path);
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

        private sealed class RequestWaiter(string path)
        {
            public string Path { get; } = path;

            public TaskCompletionSource<StubRecordedRequest> Completion { get; } =
                new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
    }
}
