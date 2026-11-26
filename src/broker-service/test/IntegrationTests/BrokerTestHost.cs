using System.Net;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;
using EasyTrade.BrokerService.Connectors;
using EasyTrade.BrokerService.Entities.Alerts.Controllers;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.Controllers;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Products.Repository;
using EasyTrade.BrokerService.Entities.Trades.Repository;
using EasyTrade.BrokerService.Entities.Trades.Scheduler;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Middleware.CreditCardValidation;
using EasyTrade.BrokerService.ProblemPatterns.HighCpuUsage;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OpenFeature;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>How a <see cref="BrokerTestHost"/> composes the broker.</summary>
    public enum BrokerHostMode
    {
        /// <summary>
        /// The real Portfolio Insights controllers, filters and services over in-memory fakes,
        /// with the flag read from <see cref="BrokerTestHost.Flag"/> and no hosted service, so
        /// tests drive evaluation through <see cref="BrokerTestHost.RunCycleAsync"/>.
        /// </summary>
        Composed,

        /// <summary>
        /// The shipped <c>AddBrokerServiceDependencyGroup()</c> registrations, both hosted
        /// services included, and Program.cs's middleware in its order, the problem-pattern
        /// middleware included, with the flag and pricing services served by a
        /// <see cref="StubHttpServer"/>. Only the db-adapter repositories are fakes, unless
        /// <see cref="BrokerTestHostOptions.KeepRealRepositories"/> is set.
        /// </summary>
        ProductionRegistrations,
    }

    /// <summary>Settings a test applies through the factories' <c>configure</c> callback.</summary>
    public sealed class BrokerTestHostOptions
    {
        /// <summary>
        /// Composed mode only: registered as <see cref="IPriceServiceConnector"/> instead of
        /// <see cref="BrokerTestHost.Prices"/>, for example a mock that throws.
        /// </summary>
        public IPriceServiceConnector? PriceServiceConnectorOverride { get; set; }

        /// <summary>
        /// Production-registration mode only: keeps the gRPC repositories the composition root
        /// registers, so they dial the stub's gRPC listener, which the stub must then have.
        /// </summary>
        public bool KeepRealRepositories { get; set; }

        /// <summary>
        /// Applied after every other registration, so it can replace any of them. The host's
        /// fakes are also registered under their own concrete types, so a replacement can
        /// resolve them, for example
        /// <c>services.AddSingleton&lt;IBalanceRepository&gt;(sp =&gt;
        /// sp.GetRequiredService&lt;FakeBalanceRepository&gt;())</c>.
        /// </summary>
        public Action<IServiceCollection>? ConfigureServices { get; set; }

        /// <summary>In-memory configuration keys merged over the host's defaults.</summary>
        public Dictionary<string, string?> Configuration { get; } =
            new(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The broker on real Kestrel at a free loopback port, built for the integration tests. It
    /// is the only place in this folder that builds a <see cref="WebApplication"/>. Each host
    /// owns fresh fakes, a recording log sink and an <see cref="HttpClient"/> bound to it, and
    /// releases its port on <see cref="StopAsync"/> or <see cref="DisposeAsync"/>.
    /// </summary>
    /// <remarks>
    /// Configuration holds only in-memory keys, so neither <c>appsettings.json</c> nor a
    /// developer's environment variables reach the host. The only logging provider is a
    /// <see cref="RecordingLoggerProvider"/>; while it is enabled, ASP.NET Core hosting starts
    /// the request <c>Activity</c> that the outbound clients propagate. No
    /// <c>ActivityListener</c> is registered: one would make <see cref="HttpClient"/> start root
    /// activities outside requests and send trace headers the evaluator must not send.
    /// </remarks>
    public sealed class BrokerTestHost : IAsyncDisposable
    {
        /// <summary>The exact body of the Portfolio Insights gate's 403.</summary>
        public const string FeatureDisabledBody = "{\"error\":\"feature_disabled\"}";

        /// <summary>
        /// The Debug line <see cref="AlertEvaluationService"/> logs when the flag is off or
        /// unreadable; a copy of its private message, kept identical to it.
        /// </summary>
        public const string AlertEvaluationSkippedMessage =
            "Alert evaluation skipped: portfolio insights flag disabled or unreadable";

        /// <summary>
        /// Start of the summary line of every completed or failed evaluation cycle.
        /// </summary>
        public const string AlertCycleFinishedPrefix = "Alert evaluation cycle finished";

        // LongTradeSchedulerService prefixes both with a Unix-ms timestamp.
        private const string LongTradeFinishedText = "TradeLogic finished.";
        private const string LongTradeErrorText = "Error running tradeLogic";

        // An explicit IP, because Kestrel binds a dynamic port only for an IP address.
        private const string LoopbackUrl = "http://127.0.0.1:0";

        // DbAdapterConnector requires an address and builds its channel lazily; with the fake
        // repositories registered nothing resolves the connector, so this port is never dialled.
        private const string PlaceholderDbAdapterAddress = "127.0.0.1:1";

        // Longer than any test, so the scheduler's startup cycle is the only one a test sees.
        private const string StartupOnlyIntervalSeconds = "3600";

        private const int MaxListedEntries = 50;

        // Bounds teardown so a stuck hosted service cannot hang the run, yet stays longer than
        // the 5 s a startup test allows StopAsync, so that test still detects a slow stop.
        private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(10);

        // Every broker request answers within the gate's 2 s flag deadline plus processing; a
        // hung request fails the test instead of waiting for HttpClient's 100 s default.
        private static readonly TimeSpan ClientTimeout = TimeSpan.FromSeconds(30);

        private static readonly string AlertEvaluationCategory =
            typeof(AlertEvaluationService).FullName ?? nameof(AlertEvaluationService);

        private static readonly string LongTradeSchedulerCategory =
            typeof(LongTradeSchedulerService).FullName ?? nameof(LongTradeSchedulerService);

        private readonly RecordingLoggerProvider _loggerProvider = new();
        private readonly SwitchableFeatureFlagServiceConnector? _flag;
        private readonly WebApplication _app;
        private readonly HttpClient _client;
        private TaskCompletionSource? _stopCompletion;
        private int _disposed;

        private BrokerTestHost(
            BrokerHostMode mode,
            BrokerTestHostOptions options,
            StubHttpServer? stub
        )
        {
            Mode = mode;
            _flag =
                mode == BrokerHostMode.Composed
                    ? new SwitchableFeatureFlagServiceConnector()
                    : null;
            _app = BuildApp(options, stub);
            _client = new HttpClient { Timeout = ClientTimeout };
        }

        public BrokerHostMode Mode { get; }

        /// <summary>Client whose base address is the host's bound address.</summary>
        public HttpClient Client => _client;

        /// <summary>
        /// The bound address with a trailing slash, for example <c>http://127.0.0.1:54321/</c>.
        /// </summary>
        public Uri BaseAddress =>
            _client.BaseAddress ?? throw new InvalidOperationException("The host has not started.");

        public IServiceProvider Services => _app.Services;

        /// <summary>
        /// Every log line of the host: categories under <c>EasyTrade</c> from Debug, the
        /// framework at the shipped levels. It stays readable after the host is disposed.
        /// </summary>
        public RecordingLogSink Logs => _loggerProvider.Sink;

        public FakeInstrumentRepository Instruments { get; } = new();

        public FakeTradeRepository Trades { get; } = new();

        public FakeBalanceRepository Balances { get; } = new();

        public FakePriceServiceConnector Prices { get; } = new();

        public FakeProductRepository Products { get; } = new();

        public FakeAlertRepository Alerts { get; } = new();

        /// <summary>
        /// The flag-service connector of a composed host, disabled at start. A
        /// production-registration host reads the flag from its <see cref="StubHttpServer"/>
        /// instead, so there this throws <see cref="InvalidOperationException"/>.
        /// </summary>
        public SwitchableFeatureFlagServiceConnector Flag =>
            _flag
            ?? throw new InvalidOperationException(
                "A production-registration host reads the flag from its StubHttpServer."
            );

        /// <summary>
        /// Starts a composed host: the controllers, <see cref="PortfolioInsightsFeatureGate"/>,
        /// the real insights, alert and evaluation services, and
        /// <see cref="PortfolioInsightsFeature"/> over a real <see cref="PluginProvider"/> on
        /// <see cref="Flag"/>, with the fakes as repositories and no hosted service.
        /// </summary>
        public static async Task<BrokerTestHost> StartComposedAsync(
            Action<BrokerTestHostOptions>? configure = null
        )
        {
            BrokerTestHostOptions options = CreateOptions(configure);
            if (options.KeepRealRepositories)
            {
                throw new ArgumentException(
                    "KeepRealRepositories applies to production-registration hosts only.",
                    nameof(configure)
                );
            }

            BrokerTestHost host = new(BrokerHostMode.Composed, options, null);
            await host.StartServerAsync();
            return host;
        }

        /// <summary>
        /// Starts a host with the shipped composition root, both hosted services included,
        /// whose flag and pricing addresses are those of <paramref name="stub"/> and whose alert
        /// interval is 3,600 s, so the startup cycle is the only one during a test.
        /// </summary>
        /// <remarks>
        /// The caller owns <paramref name="stub"/>; declaring it first with <c>await using</c>
        /// disposes the host before the stub. Start the stub with the flag answering
        /// <c>enabled: false</c>, so the startup cycle takes the deterministic skip path, and
        /// switch it on after <see cref="WaitForStartupLinesAsync"/>. The long-trade scheduler
        /// requests <c>/v1/prices/latest</c> at start and every 60 s after, so a test clears the
        /// stub's recordings after that wait and finishes well inside the 60 s.
        /// </remarks>
        public static async Task<BrokerTestHost> StartProductionAsync(
            StubHttpServer stub,
            Action<BrokerTestHostOptions>? configure = null
        )
        {
            ArgumentNullException.ThrowIfNull(stub);
            BrokerTestHostOptions options = CreateOptions(configure);
            if (options.PriceServiceConnectorOverride is not null)
            {
                throw new ArgumentException(
                    "PriceServiceConnectorOverride applies to composed hosts only; a "
                        + "production-registration host prices through the stub.",
                    nameof(configure)
                );
            }

            BrokerTestHost host = new(BrokerHostMode.ProductionRegistrations, options, stub);
            await host.StartServerAsync();
            return host;
        }

        /// <summary>
        /// Runs one alert evaluation cycle with an evaluator from a new service scope.
        /// </summary>
        public async Task<AlertEvaluationResult> RunCycleAsync(
            CancellationToken cancellationToken = default
        )
        {
            await using AsyncServiceScope scope = Services.CreateAsyncScope();
            IAlertEvaluationService evaluator =
                scope.ServiceProvider.GetRequiredService<IAlertEvaluationService>();
            return await evaluator.RunCycleAsync(cancellationToken);
        }

        /// <summary>
        /// Resolves an evaluator in a new service scope, so several can run at once, each in
        /// its own scope. The caller disposes <paramref name="scope"/> once its cycle ended.
        /// </summary>
        public IAlertEvaluationService CreateEvaluator(out AsyncServiceScope scope)
        {
            scope = Services.CreateAsyncScope();
            try
            {
                return scope.ServiceProvider.GetRequiredService<IAlertEvaluationService>();
            }
            catch
            {
                scope.Dispose();
                throw;
            }
        }

        /// <summary>
        /// Waits until both schedulers have finished their startup run: the alert evaluator's
        /// summary or flag-disabled skip line, and the long-trade scheduler's finished or error
        /// line. Production-registration hosts only.
        /// </summary>
        /// <exception cref="TimeoutException">
        /// Either line is missing after <paramref name="timeout"/>; the message lists the
        /// recorded entries.
        /// </exception>
        public async Task WaitForStartupLinesAsync(TimeSpan timeout)
        {
            if (Mode != BrokerHostMode.ProductionRegistrations)
            {
                throw new InvalidOperationException(
                    "Only a production-registration host runs the schedulers."
                );
            }

            Task<LogEntry> alertLine = Logs.WaitForAsync(
                IsAlertStartupLine,
                timeout,
                "alert evaluation summary or flag-disabled skip line"
            );
            Task<LogEntry> longTradeLine = Logs.WaitForAsync(
                IsLongTradeStartupLine,
                timeout,
                "long-trade scheduler finished or error line"
            );
            try
            {
                await Task.WhenAll(alertLine, longTradeLine);
            }
            catch (TimeoutException exception)
            {
                throw new TimeoutException(
                    $"{exception.Message} Recorded entries:{Environment.NewLine}"
                        + DescribeEntries(),
                    exception
                );
            }
        }

        /// <summary>
        /// Stops the host and its hosted services and releases its port. Every call returns
        /// the task of the first.
        /// </summary>
        public Task StopAsync()
        {
            TaskCompletionSource created = new(TaskCreationOptions.RunContinuationsAsynchronously);
            TaskCompletionSource? existing = Interlocked.CompareExchange(
                ref _stopCompletion,
                created,
                null
            );
            if (existing is not null)
            {
                return existing.Task;
            }

            // Completes the source in every case, so the discarded task never faults.
            _ = CompleteStopAsync(created);
            return created.Task;
        }

        /// <summary>
        /// Disposes the client, stops the host unless it already stopped, and disposes it. A
        /// stop failure that an earlier <see cref="StopAsync"/> call already reported is not
        /// raised again; calling it twice does nothing.
        /// </summary>
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 1)
            {
                return;
            }

            List<Exception> failures = [];
            bool stopRequested = Volatile.Read(ref _stopCompletion) is not null;
            // First, so no pooled connection keeps Kestrel's graceful shutdown waiting.
            _client.Dispose();
            try
            {
                await StopAsync();
            }
            catch (Exception exception)
            {
                if (!stopRequested)
                {
                    failures.Add(exception);
                }
            }

            try
            {
                await _app.DisposeAsync();
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }

            if (failures.Count == 1)
            {
                ExceptionDispatchInfo.Throw(failures[0]);
            }
            if (failures.Count > 1)
            {
                throw new AggregateException(
                    "The broker host could not release all it held.",
                    failures
                );
            }
        }

        /// <summary>
        /// Sends <paramref name="rawJson"/> exactly as given, so a threshold travels as the
        /// literal JSON token the test wrote; <c>null</c> sends no body. Each header is added
        /// unvalidated, as a <c>traceparent</c> needs.
        /// </summary>
        /// <exception cref="ArgumentException">A header is not a request header.</exception>
        public static async Task<HttpResponseMessage> SendJsonAsync(
            HttpClient client,
            HttpMethod method,
            string path,
            string? rawJson,
            IEnumerable<KeyValuePair<string, string>>? headers = null
        )
        {
            ArgumentNullException.ThrowIfNull(client);
            ArgumentNullException.ThrowIfNull(method);
            ArgumentNullException.ThrowIfNull(path);
            using HttpRequestMessage request = new(method, path);
            if (rawJson is not null)
            {
                request.Content = new StringContent(rawJson, Encoding.UTF8, "application/json");
            }
            if (headers is not null)
            {
                foreach (KeyValuePair<string, string> header in headers)
                {
                    if (!request.Headers.TryAddWithoutValidation(header.Key, header.Value))
                    {
                        throw new ArgumentException(
                            $"[{header.Key}] cannot be sent as a request header.",
                            nameof(headers)
                        );
                    }
                }
            }
            return await client.SendAsync(request);
        }

        /// <summary>The response body parsed as JSON, detached from its document.</summary>
        /// <exception cref="JsonException">The body is not JSON; the message holds it.</exception>
        public static async Task<JsonElement> ReadJsonAsync(HttpResponseMessage response)
        {
            ArgumentNullException.ThrowIfNull(response);
            string body = await response.Content.ReadAsStringAsync();
            return ParseJson(response.StatusCode, body);
        }

        /// <summary>
        /// Asserts the gate's answer: 403, media type <c>application/json</c> and a body equal
        /// to <see cref="FeatureDisabledBody"/>.
        /// </summary>
        public static async Task AssertFeatureDisabledAsync(HttpResponseMessage response)
        {
            ArgumentNullException.ThrowIfNull(response);
            string body = await response.Content.ReadAsStringAsync();
            AssertStatus(response, HttpStatusCode.Forbidden, body);
            Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
            Assert.Equal(FeatureDisabledBody, body);
        }

        /// <summary>
        /// Asserts <paramref name="expected"/> and an <c>ErrorResponse</c> body: a
        /// <c>statusCode</c> equal to it and a non-empty <c>message</c>.
        /// </summary>
        public static async Task AssertErrorResponseAsync(
            HttpResponseMessage response,
            HttpStatusCode expected
        )
        {
            ArgumentNullException.ThrowIfNull(response);
            string body = await response.Content.ReadAsStringAsync();
            AssertStatus(response, expected, body);
            JsonElement error = ParseJson(response.StatusCode, body);
            Assert.Equal(JsonValueKind.Object, error.ValueKind);
            Assert.True(
                error.TryGetProperty("statusCode", out JsonElement statusCode)
                    && (statusCode.ValueKind == JsonValueKind.Number),
                $"No numeric statusCode in the error body [{body}]."
            );
            Assert.Equal((int)expected, statusCode.GetInt32());
            Assert.True(
                error.TryGetProperty("message", out JsonElement message)
                    && (message.ValueKind == JsonValueKind.String)
                    && !string.IsNullOrWhiteSpace(message.GetString()),
                $"No non-empty message in the error body [{body}]."
            );
        }

        private static BrokerTestHostOptions CreateOptions(Action<BrokerTestHostOptions>? configure)
        {
            BrokerTestHostOptions options = new();
            configure?.Invoke(options);
            return options;
        }

        private static void AssertStatus(
            HttpResponseMessage response,
            HttpStatusCode expected,
            string body
        )
        {
            Assert.True(
                response.StatusCode == expected,
                $"Expected {(int)expected} {expected}, got {(int)response.StatusCode} "
                    + $"{response.StatusCode} with body [{body}]."
            );
        }

        private static JsonElement ParseJson(HttpStatusCode status, string body)
        {
            try
            {
                using JsonDocument document = JsonDocument.Parse(body);
                return document.RootElement.Clone();
            }
            catch (JsonException exception)
            {
                throw new JsonException(
                    $"The {(int)status} response body is not JSON: [{body}].",
                    exception
                );
            }
        }

        private static bool IsAlertStartupLine(LogEntry entry)
        {
            return string.Equals(entry.Category, AlertEvaluationCategory, StringComparison.Ordinal)
                && (
                    entry.Message.StartsWith(AlertCycleFinishedPrefix, StringComparison.Ordinal)
                    || string.Equals(
                        entry.Message,
                        AlertEvaluationSkippedMessage,
                        StringComparison.Ordinal
                    )
                );
        }

        private static bool IsLongTradeStartupLine(LogEntry entry)
        {
            return string.Equals(
                    entry.Category,
                    LongTradeSchedulerCategory,
                    StringComparison.Ordinal
                )
                && (
                    entry.Message.Contains(LongTradeFinishedText, StringComparison.Ordinal)
                    || entry.Message.Contains(LongTradeErrorText, StringComparison.Ordinal)
                );
        }

        private async Task StartServerAsync()
        {
            try
            {
                await _app.StartAsync();
                // Kestrel replaces the configured port 0 with the bound port once started.
                string address =
                    _app.Urls.FirstOrDefault()
                    ?? throw new InvalidOperationException("Kestrel reported no bound address.");
                _client.BaseAddress = new Uri(address.TrimEnd('/') + "/", UriKind.Absolute);
            }
            catch (Exception startException)
            {
                try
                {
                    await DisposeAsync();
                }
                catch (Exception cleanupException)
                {
                    throw new AggregateException(
                        "The broker host failed to start, and releasing it failed too.",
                        startException,
                        cleanupException
                    );
                }
                throw;
            }
        }

        private async Task CompleteStopAsync(TaskCompletionSource completion)
        {
            try
            {
                await _app.StopAsync();
                completion.SetResult();
            }
            catch (Exception exception)
            {
                completion.SetException(exception);
            }
        }

        private WebApplication BuildApp(BrokerTestHostOptions options, StubHttpServer? stub)
        {
            WebApplicationBuilder builder = WebApplication.CreateBuilder(
                new WebApplicationOptions
                {
                    // Fixed, so ValidateOnBuild and developer pages never follow the machine.
                    EnvironmentName = Environments.Production,
                    ContentRootPath = AppContext.BaseDirectory,
                }
            );

            builder.Configuration.Sources.Clear();
            builder.Configuration.AddInMemoryCollection(BuildConfiguration(options, stub));

            builder.Logging.ClearProviders();
            builder.Logging.AddProvider(_loggerProvider);
            builder.Logging.AddFilter<RecordingLoggerProvider>("EasyTrade", LogLevel.Debug);
            // The shipped appsettings.json levels. Critical stays enabled for
            // Microsoft.AspNetCore.Hosting.Diagnostics, which is what makes hosting start the
            // request Activity, so these must never be raised above Critical.
            builder.Logging.AddFilter<RecordingLoggerProvider>(
                "Microsoft.AspNetCore",
                LogLevel.Warning
            );
            builder.Logging.AddFilter<RecordingLoggerProvider>(
                "System.Net.Http.HttpClient",
                LogLevel.Warning
            );

            builder.Services.Configure<HostOptions>(hostOptions =>
                hostOptions.ShutdownTimeout = ShutdownTimeout
            );
            // The entry assembly is the test host, so the broker's controllers are added
            // explicitly. Controllers are activated per request, so one whose services a
            // composed host lacks is harmless until it is called.
            builder
                .Services.AddControllers()
                .AddApplicationPart(typeof(PortfolioController).Assembly);

            if (Mode == BrokerHostMode.Composed)
            {
                AddComposedServices(builder.Services, options);
            }
            else
            {
                AddProductionServices(builder.Services, options);
            }
            options.ConfigureServices?.Invoke(builder.Services);

            WebApplication app = builder.Build();
            if (Mode == BrokerHostMode.ProductionRegistrations)
            {
                // Program.cs's middleware, in its order. As there, the automatic routing runs
                // before all of it, so a request meets the problem-pattern middleware, which read
                // their own flags from the stub's flag service, after the route is matched.
                app.UseHttpsRedirection();
                app.UseAuthorization();
                app.UseMiddleware<HighCpuUsageMiddleware>();
                app.UseMiddleware<CreditCardValidationMiddleware>();
            }
            // No health checks, and in composed mode no middleware: the tests reach the
            // controllers only.
            app.MapControllers();
            app.Urls.Add(LoopbackUrl);
            return app;
        }

        private static Dictionary<string, string?> BuildConfiguration(
            BrokerTestHostOptions options,
            StubHttpServer? stub
        )
        {
            Dictionary<string, string?> values = new(StringComparer.OrdinalIgnoreCase);
            if (stub is not null)
            {
                // The connectors append "/v1/" and "/" themselves, so no trailing slash.
                values[Constants.FeatureFlagServiceAddress] =
                    stub.FeatureFlagServiceAddress.TrimEnd('/');
                values[Constants.PricingServiceAddress] = stub.PricingServiceAddress.TrimEnd('/');
                values[Constants.AlertEvaluationIntervalSeconds] = StartupOnlyIntervalSeconds;
                values[Constants.DbAdapterAddress] = options.KeepRealRepositories
                    ? stub.GrpcAddress
                    : PlaceholderDbAdapterAddress;
            }
            foreach (KeyValuePair<string, string?> pair in options.Configuration)
            {
                values[pair.Key] = pair.Value;
            }

            if (stub is not null && values.GetValueOrDefault(Constants.DbAdapterAddress) is null)
            {
                throw new ArgumentException(
                    "KeepRealRepositories needs a DB_ADAPTER_ADDRESS: start the StubHttpServer "
                        + "with its gRPC listener.",
                    nameof(options)
                );
            }
            return values;
        }

        private void AddComposedServices(IServiceCollection services, BrokerTestHostOptions options)
        {
            AddFakeInstances(services);
            AddFakeRepositories(services);
            services.AddSingleton<IPriceServiceConnector>(
                options.PriceServiceConnectorOverride ?? Prices
            );
            services.AddSingleton(Flag);
            services.AddSingleton<IFeatureFlagServiceConnector>(Flag);
            // The real provider over the switchable connector, so every flag read crosses the
            // same token-forwarding path as in production.
            services.AddSingleton<FeatureProvider, PluginProvider>();
            services.AddSingleton<IPortfolioInsightsFeature, PortfolioInsightsFeature>();
            services.AddTransient<PortfolioInsightsFeatureGate>();
            services.AddSingleton<PortfolioInsightsMetrics>();
            services.AddTransient<IPortfolioService, PortfolioService>();
            services.AddTransient<IPortfolioInsightsService, PortfolioInsightsService>();
            services.AddTransient<IAlertService, AlertService>();
            services.AddTransient<IAlertEvaluationService, AlertEvaluationService>();
            services.TryAddEnumerable(
                ServiceDescriptor.Singleton<
                    MatcherPolicy,
                    AlertController.NotificationsMatcherPolicy
                >()
            );
        }

        // Program.cs's registrations without CORS, health checks and console logger, so the
        // shipped composition root, both hosted services and the middleware BuildApp adds run as
        // they do in production.
        private void AddProductionServices(
            IServiceCollection services,
            BrokerTestHostOptions options
        )
        {
            services.AddSingleton<IDbAdapterConnector, DbAdapterConnector>();
            services.AddMemoryCache();
            services.AddBrokerServiceDependencyGroup();
            services.AddTransient<HighCpuUsageMiddleware>();
            services.AddHttpClient();
            AddFakeInstances(services);
            if (!options.KeepRealRepositories)
            {
                // Registered after the composition root, so these win.
                AddFakeRepositories(services);
            }
        }

        private void AddFakeInstances(IServiceCollection services)
        {
            services.AddSingleton(Instruments);
            services.AddSingleton(Trades);
            services.AddSingleton(Balances);
            services.AddSingleton(Prices);
            services.AddSingleton(Products);
            services.AddSingleton(Alerts);
        }

        private void AddFakeRepositories(IServiceCollection services)
        {
            services.AddSingleton<IInstrumentRepository>(Instruments);
            services.AddSingleton<ITradeRepository>(Trades);
            services.AddSingleton<IBalanceRepository>(Balances);
            services.AddSingleton<IProductRepository>(Products);
            services.AddSingleton<IAlertRepository>(Alerts);
        }

        private string DescribeEntries()
        {
            IReadOnlyList<LogEntry> entries = Logs.Entries;
            if (entries.Count == 0)
            {
                return "(none)";
            }

            IEnumerable<string> lines = entries
                .TakeLast(MaxListedEntries)
                .Select(entry => $"[{entry.Level}] {entry.Category}: {entry.Message}");
            string header =
                entries.Count > MaxListedEntries
                    ? $"(last {MaxListedEntries} of {entries.Count}){Environment.NewLine}"
                    : string.Empty;
            return header + string.Join(Environment.NewLine, lines);
        }
    }
}
