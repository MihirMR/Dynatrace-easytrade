using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>
    /// Fail-closed gating of the Portfolio Insights endpoints and of alert evaluation, on the
    /// broker's shipped registrations: the real flag connector, plugin provider, feature, gate
    /// and price connector reach a <see cref="StubHttpServer"/> over sockets, and only the
    /// db-adapter repositories are fakes. Each test ends well inside the long-trade scheduler's
    /// 60 s period, so the stub records only the requests the test itself causes.
    /// </summary>
    [Collection(BrokerHostCollection.Name)]
    public class FlagOutageTests
    {
        private const decimal LatestClose = 110m;
        private const decimal HeldQuantity = 10m;
        private const decimal AlertThreshold = 100m;
        private const string UnreadableWarningPrefix =
            "Portfolio insights flag unreadable, treating as disabled";
        private const string TimeoutReason = "timeout";

        // Not JSON, so a request that reached model binding would answer 400.
        private const string MalformedJson = "{\"accountId\": ";

        private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan ClientAbortTimeout = TimeSpan.FromSeconds(5);

        // The fixed ceiling within which every gated request must answer 403 during an outage,
        // a literal independent of the feature's read deadline, so a longer deadline fails.
        private static readonly TimeSpan GateAnswerLimit = TimeSpan.FromSeconds(3);

        private readonly Guid _accountId = Guid.NewGuid();
        private readonly Guid _instrumentId = Guid.NewGuid();

        [Theory]
        [InlineData(StubMode.Refuse)]
        [InlineData(StubMode.Hold)]
        public async Task FlagOutage_EnabledThenFailureThenRecovered_ShouldGateAndResume(
            StubMode failureMode
        )
        {
            await using StubHttpServer stub = await StartStubAsync();
            await using BrokerTestHost host = await StartHostAsync(stub);

            // Enabled: the endpoints answer, and a cycle lists, prices and triggers.
            await AssertInsightsAvailableAsync(host);
            Guid alertId = await CreateAlertAsync(host);
            stub.ClearRecordings();
            host.Alerts.ResetCalls();
            AlertEvaluationResult enabledCycle = await host.RunCycleAsync();
            AssertTriggeredOnce(enabledCycle, host, alertId, 1);
            AssertLatestPricesRequestedOnce(stub);

            // Failure: the flag cannot be read, so every decision is disabled.
            stub.ClearRecordings();
            host.Alerts.ResetCalls();
            int warningsBefore = UnreadableWarnings(host).Count;
            await stub.SetModeAsync(StubRoute.Flag, failureMode);

            await AssertGatedAsync(() => GetInsightsAsync(host));
            if (failureMode == StubMode.Hold)
            {
                // The deadline aborts the held request itself, not only the wait for it.
                await stub.WaitForClientAbortAsync(ClientAbortTimeout);
                Assert.True(stub.AbortedCount(StubHttpServer.FlagPath) >= 1);
            }
            await AssertGatedAsync(() => PostAlertAsync(host));
            AlertEvaluationResult disabledCycle = await host.RunCycleAsync();

            Assert.Equal(AlertEvaluationOutcome.FlagDisabled, disabledCycle.Outcome);
            Assert.Equal(0, host.Alerts.ListCallCount);
            Assert.Equal(0, host.Alerts.CallCount(FakeAlertRepositoryMethod.Create));
            Assert.Empty(host.Alerts.TriggerCalls);
            Assert.Equal(0, stub.Count(StubHttpServer.LatestPricesPath));
            // A refused connect never reaches the stub; a held read does, once per decision.
            int expectedFlagRequests = failureMode == StubMode.Hold ? 3 : 0;
            Assert.Equal(expectedFlagRequests, stub.Count(StubHttpServer.FlagPath));
            List<LogEntry> warnings = [.. UnreadableWarnings(host).Skip(warningsBefore)];
            Assert.Equal(3, warnings.Count);
            string[] allowedReasons = AllowedUnreadableReasons(failureMode);
            Assert.All(
                warnings,
                warning =>
                    Assert.Contains(
                        Assert.IsType<string>(warning.GetField("reason")),
                        allowedReasons
                    )
            );

            // Recovered: nothing is cached, so the next request reads the flag afresh.
            await stub.SetModeAsync(StubRoute.Flag, StubMode.Respond);
            stub.ClearRecordings();
            await AssertInsightsAvailableAsync(host);
            Assert.Equal(1, stub.Count(StubHttpServer.FlagPath));
            JsonElement rearmed = await RearmAsync(host, alertId);
            Assert.Equal(2, rearmed.GetProperty("armingRevision").GetInt32());
            stub.ClearRecordings();
            host.Alerts.ResetCalls();
            AlertEvaluationResult recoveredCycle = await host.RunCycleAsync();
            AssertTriggeredOnce(recoveredCycle, host, alertId, 2);
            AssertLatestPricesRequestedOnce(stub);
        }

        [Theory]
        [InlineData(404)]
        [InlineData(500)]
        public async Task FlagOutage_Non200_ShouldReturn403(int status)
        {
            await using StubHttpServer stub = await StartStubAsync();
            await using BrokerTestHost host = await StartHostAsync(stub);
            stub.SetStatus(StubRoute.Flag, (HttpStatusCode)status);

            await AssertGatedAsync(() => GetInsightsAsync(host));
            await AssertGatedAsync(() => PostAlertAsync(host));
            AlertEvaluationResult cycle = await host.RunCycleAsync();

            Assert.Equal(AlertEvaluationOutcome.FlagDisabled, cycle.Outcome);
            Assert.Equal(0, host.Alerts.ListCallCount);
            Assert.Equal(0, host.Alerts.CallCount(FakeAlertRepositoryMethod.Create));
            Assert.Equal(3, stub.Count(StubHttpServer.FlagPath));
            Assert.Equal(0, stub.Count(StubHttpServer.LatestPricesPath));
            // A non-200 takes the connector's not-found path, so the provider returns its
            // default false: the connector's Warning per read, and no unreadable-flag Warning.
            string notFound = $"Flag with id [{Constants.PortfolioInsightsEnabled}] not found";
            Assert.Equal(
                3,
                host.Logs.ByCategory<FeatureFlagServiceConnector>()
                    .Count(entry =>
                        (entry.Level == LogLevel.Warning)
                        && string.Equals(entry.Message, notFound, StringComparison.Ordinal)
                    )
            );
            Assert.Empty(UnreadableWarnings(host));
        }

        [Fact]
        public async Task FlagToggle_DisabledAfterEnabled_ShouldApplyOnNextRequest()
        {
            await using StubHttpServer stub = await StartStubAsync();
            await using BrokerTestHost host = await StartHostAsync(stub);

            await AssertInsightsAvailableAsync(host);
            Assert.Equal(1, stub.Count(StubHttpServer.FlagPath));

            // A toggle, not an outage: the flag service answers enabled: false.
            stub.SetFlagEnabled(false);
            await AssertGatedAsync(() => GetInsightsAsync(host));
            // One fresh read per broker request; no cache served the earlier true.
            Assert.Equal(2, stub.Count(StubHttpServer.FlagPath));
            Assert.Equal(1, stub.Count(StubHttpServer.LatestPricesPath));

            AlertEvaluationResult cycle = await host.RunCycleAsync();

            Assert.Equal(AlertEvaluationOutcome.FlagDisabled, cycle.Outcome);
            Assert.Equal(3, stub.Count(StubHttpServer.FlagPath));
            Assert.Equal(0, host.Alerts.ListCallCount);
            Assert.Equal(1, stub.Count(StubHttpServer.LatestPricesPath));
            Assert.Empty(UnreadableWarnings(host));
        }

        /// <summary>
        /// The whole flag service fails before the host has served any request, so the
        /// problem-pattern middleware's flag cache is empty: had the gate's decision waited for
        /// MVC, that middleware would read its own flags from the failed service first, each read
        /// unbounded when held. Every gated endpoint still answers the exact 403 within the
        /// ceiling, with an unbindable request where it takes one, and the middleware never reads.
        /// </summary>
        [Theory]
        [InlineData(StubMode.Hold)]
        [InlineData(StubMode.Refuse)]
        public async Task FlagOutage_ColdLegacyCacheFlagServiceDown_ShouldReturn403WithinCeiling(
            StubMode failureMode
        )
        {
            await using StubHttpServer stub = await StartStubAsync();
            await using BrokerTestHost host = await StartHostAsync(stub);
            await stub.SetModeAsync(StubRoute.Flag, failureMode);
            GatedRequest[] requests = GatedRequests();

            foreach ((HttpMethod method, string path, string? body, _) in requests)
            {
                Exception? failure = await Record.ExceptionAsync(
                    () =>
                        AssertGatedAsync(
                            () => BrokerTestHost.SendJsonAsync(host.Client, method, path, body)
                        )
                );
                Assert.True(failure is null, $"{method} {path}: {failure?.Message}");
            }

            // One portfolio insights read per request, which a refused connect never delivers,
            // and no problem-pattern read: the middleware never ran for a disabled request.
            int expectedFlagReads = failureMode == StubMode.Hold ? requests.Length : 0;
            Assert.Equal(expectedFlagReads, stub.Count(StubHttpServer.FlagPath));
            Assert.All(
                FlagReads(stub),
                request => Assert.Equal(StubHttpServer.FlagPath, request.Path)
            );
            Assert.All(
                Enum.GetValues<FakeAlertRepositoryMethod>(),
                method => Assert.Equal(0, host.Alerts.CallCount(method))
            );

            // Recovered: an enabled request passes routing and meets the problem-pattern
            // middleware, which now read their flags for the first time.
            await stub.SetModeAsync(StubRoute.Flag, StubMode.Respond);
            stub.ClearRecordings();
            await AssertInsightsAvailableAsync(host);
            // A path that matches no route keeps its 404 and reads no portfolio insights flag.
            using HttpResponseMessage unmatched = await host.Client.GetAsync(
                "v1/portfolio/insights/not-a-guid"
            );
            Assert.Equal(HttpStatusCode.NotFound, unmatched.StatusCode);
            Assert.Equal(1, stub.Count(StubHttpServer.FlagPath));
            Assert.Equal(1, stub.Count(StubHttpServer.FlagPathPrefix + Constants.HighCpuUsage));
            Assert.Equal(
                1,
                stub.Count(StubHttpServer.FlagPathPrefix + Constants.CreditCardValidation)
            );
        }

        /// <summary>
        /// The flag service answers disabled before the host has served any request. Each gated
        /// endpoint's 403 is the result the gate set as a resource filter, which MVC executed for
        /// that action before model binding, from the decision taken while the request was
        /// routed: one flag read per request, and none by the problem-pattern middleware, which
        /// the short-circuited request never met.
        /// </summary>
        [Fact]
        public async Task FlagDisabled_GatedRequests_ShouldBeAnsweredByGateResourceFilter()
        {
            ResultProbe probe = new();
            await using StubHttpServer stub = await StartStubAsync();
            await using BrokerTestHost host = await StartHostAsync(
                stub,
                services => services.Configure<MvcOptions>(mvc => mvc.Filters.Add(probe))
            );
            stub.SetFlagEnabled(false);
            GatedRequest[] requests = GatedRequests();

            foreach ((HttpMethod method, string path, string? body, _) in requests)
            {
                using HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                    host.Client,
                    method,
                    path,
                    body
                );
                await BrokerTestHost.AssertFeatureDisabledAsync(response);
            }

            IReadOnlyList<ProbedResult> results = probe.Results;
            Assert.Equal(requests.Select(request => request.Action), results.Select(r => r.Action));
            Assert.All(
                results,
                result =>
                {
                    JsonResult forbidden = Assert.IsType<JsonResult>(result.Result);
                    Assert.Equal((int)HttpStatusCode.Forbidden, forbidden.StatusCode);
                    Assert.Equal(new FeatureDisabledResponse("feature_disabled"), forbidden.Value);
                    // The gate ran in the action's filter pipeline, and nothing was bound.
                    Assert.True(result.GateInPipeline);
                    Assert.Equal(0, result.ModelStateEntries);
                }
            );
            Assert.Equal(requests.Length, stub.Count(StubHttpServer.FlagPath));
            Assert.All(
                FlagReads(stub),
                request => Assert.Equal(StubHttpServer.FlagPath, request.Path)
            );
            Assert.All(
                Enum.GetValues<FakeAlertRepositoryMethod>(),
                method => Assert.Equal(0, host.Alerts.CallCount(method))
            );
        }

        // On Windows a refused connect is reported only after its SYN retries, about 2 s on
        // loopback, so the deadline usually expires first; on Linux the refusal comes at once.
        private static string[] AllowedUnreadableReasons(StubMode failureMode)
        {
            return failureMode == StubMode.Refuse
                ? [TimeoutReason, nameof(HttpRequestException)]
                : [TimeoutReason];
        }

        // Every request the stub recorded at the flag address, whatever the flag id.
        private static IEnumerable<StubRecordedRequest> FlagReads(StubHttpServer stub)
        {
            return stub.Requests.Where(request =>
                request.Path.StartsWith(StubHttpServer.FlagPathPrefix, StringComparison.Ordinal)
            );
        }

        private static IReadOnlyList<LogEntry> UnreadableWarnings(BrokerTestHost host)
        {
            return
            [
                .. host
                    .Logs.ByCategory<PortfolioInsightsFeature>()
                    .Where(entry =>
                        (entry.Level == LogLevel.Warning)
                        && entry.Message.StartsWith(
                            UnreadableWarningPrefix,
                            StringComparison.Ordinal
                        )
                    ),
            ];
        }

        // Asserts the gate's 403 body and that it answered within the fixed 3 s ceiling.
        private static async Task AssertGatedAsync(Func<Task<HttpResponseMessage>> send)
        {
            Stopwatch stopwatch = Stopwatch.StartNew();
            using HttpResponseMessage response = await send();
            stopwatch.Stop();
            await BrokerTestHost.AssertFeatureDisabledAsync(response);
            Assert.True(
                stopwatch.Elapsed < GateAnswerLimit,
                $"The gate answered after {stopwatch.Elapsed}, not within {GateAnswerLimit}."
            );
        }

        private static void AssertTriggeredOnce(
            AlertEvaluationResult result,
            BrokerTestHost host,
            Guid alertId,
            int armingRevision
        )
        {
            Assert.Equal(AlertEvaluationOutcome.Completed, result.Outcome);
            Assert.Equal(1, result.Triggered);
            Assert.True(host.Alerts.ListCallCount >= 1);
            AlertTriggerCall trigger = Assert.Single(host.Alerts.TriggerCalls);
            Assert.Equal(alertId, trigger.Id);
            Assert.Equal(armingRevision, trigger.ArmingRevision);
            Assert.Equal(LatestClose, trigger.TriggerValue);
            Assert.True(trigger.Result);
        }

        private static void AssertLatestPricesRequestedOnce(StubHttpServer stub)
        {
            StubRecordedRequest request = Assert.Single(
                stub.Requests,
                recorded =>
                    string.Equals(
                        recorded.Path,
                        StubHttpServer.LatestPricesPath,
                        StringComparison.Ordinal
                    )
            );
            Assert.Equal(HttpMethod.Get.Method, request.Method);
        }

        // Asserts the status, naming the body on a mismatch, and parses the body.
        private static async Task<JsonElement> ReadSuccessAsync(
            HttpResponseMessage response,
            HttpStatusCode expected
        )
        {
            string body = await response.Content.ReadAsStringAsync();
            Assert.True(
                response.StatusCode == expected,
                $"Expected {(int)expected} {expected}, got {(int)response.StatusCode} "
                    + $"{response.StatusCode} with body [{body}]."
            );
            return await BrokerTestHost.ReadJsonAsync(response);
        }

        private static async Task<JsonElement> RearmAsync(BrokerTestHost host, Guid alertId)
        {
            using HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                host.Client,
                HttpMethod.Patch,
                $"v1/alerts/{alertId}",
                "{\"enabled\": true}"
            );
            JsonElement alert = await ReadSuccessAsync(response, HttpStatusCode.OK);
            Assert.True(alert.GetProperty("enabled").GetBoolean());
            Assert.Equal(JsonValueKind.Null, alert.GetProperty("triggeredAt").ValueKind);
            return alert;
        }

        private async Task<StubHttpServer> StartStubAsync()
        {
            StubHttpServer stub = await StubHttpServer.StartAsync();
            // Off at start, so the startup cycle takes the deterministic flag-disabled skip.
            stub.SetFlagEnabled(false);
            stub.SetLatestPrices(
                [new Price(_instrumentId, DateTimeOffset.UtcNow, 100m, 115m, 95m, LatestClose)]
            );
            return stub;
        }

        private async Task<BrokerTestHost> StartHostAsync(
            StubHttpServer stub,
            Action<IServiceCollection>? configureServices = null
        )
        {
            BrokerTestHost host = await BrokerTestHost.StartProductionAsync(
                stub,
                options => options.ConfigureServices = configureServices
            );
            try
            {
                await host.WaitForStartupLinesAsync(StartupTimeout);
                // Seeded once both schedulers' startup runs have ended: the in-memory fakes are
                // not thread-safe, and neither scheduler runs again within a test.
                host.Balances.AddBalance(new Balance(_accountId, 1000m));
                host.Instruments.AddInstrument(
                    new Instrument(
                        _instrumentId,
                        Guid.NewGuid(),
                        "FLAG",
                        "Flag outage instrument",
                        "Instrument priced by the stub"
                    )
                );
                host.Instruments.AddOwned(
                    new OwnedInstrument(_accountId, _instrumentId, HeldQuantity)
                );
                stub.ClearRecordings();
                host.Alerts.ResetCalls();
                stub.SetFlagEnabled(true);
                return host;
            }
            catch
            {
                await host.DisposeAsync();
                throw;
            }
        }

        // One request to each gated endpoint, with an unbindable body or query where it takes
        // one, and the action that serves it.
        private GatedRequest[] GatedRequests()
        {
            Guid alertId = Guid.NewGuid();
            return
            [
                new(
                    HttpMethod.Get,
                    $"v1/portfolio/insights/{_accountId}",
                    null,
                    "GetPortfolioInsights"
                ),
                new(HttpMethod.Post, "v1/alerts", MalformedJson, "CreateAlert"),
                new(HttpMethod.Get, "v1/alerts", null, "GetAlerts"),
                new(
                    HttpMethod.Get,
                    "v1/alerts/notifications?accountId=not-a-guid",
                    null,
                    "GetNotifications"
                ),
                new(HttpMethod.Patch, $"v1/alerts/{alertId}", MalformedJson, "UpdateAlert"),
                new(HttpMethod.Delete, $"v1/alerts/{alertId}", null, "DeleteAlert"),
                new(HttpMethod.Post, $"v1/alerts/{alertId}/acknowledge", null, "AcknowledgeAlert"),
            ];
        }

        private Task<HttpResponseMessage> GetInsightsAsync(BrokerTestHost host)
        {
            return host.Client.GetAsync($"v1/portfolio/insights/{_accountId}");
        }

        private Task<HttpResponseMessage> PostAlertAsync(BrokerTestHost host)
        {
            string body = JsonSerializer.Serialize(
                new
                {
                    accountId = _accountId,
                    type = "TARGET_PRICE",
                    instrumentId = _instrumentId,
                    direction = "ABOVE",
                    threshold = AlertThreshold,
                }
            );
            return BrokerTestHost.SendJsonAsync(host.Client, HttpMethod.Post, "v1/alerts", body);
        }

        private async Task AssertInsightsAvailableAsync(BrokerTestHost host)
        {
            using HttpResponseMessage response = await GetInsightsAsync(host);
            JsonElement insights = await ReadSuccessAsync(response, HttpStatusCode.OK);
            // Valued through the real price connector at the stub's close.
            Assert.Equal(
                HeldQuantity * LatestClose,
                insights.GetProperty("totalValue").GetDecimal()
            );
        }

        private async Task<Guid> CreateAlertAsync(BrokerTestHost host)
        {
            using HttpResponseMessage response = await PostAlertAsync(host);
            JsonElement alert = await ReadSuccessAsync(response, HttpStatusCode.Created);
            Assert.Equal(1, alert.GetProperty("armingRevision").GetInt32());
            return alert.GetProperty("id").GetGuid();
        }

        /// <summary>A request to one gated endpoint and the action that serves it.</summary>
        private sealed record GatedRequest(
            HttpMethod Method,
            string Path,
            string? Body,
            string Action
        );

        /// <summary>
        /// What <see cref="ResultProbe"/> saw for one result: the action, the result, whether
        /// the gate was among the action's filters, and how many model state entries binding
        /// had made by then.
        /// </summary>
        private sealed record ProbedResult(
            string? Action,
            IActionResult? Result,
            bool GateInPipeline,
            int ModelStateEntries
        );

        /// <summary>
        /// A global MVC filter that records every result MVC executes, the one a resource
        /// filter short-circuits with included, and passes it on unchanged.
        /// </summary>
        private sealed class ResultProbe : IAsyncAlwaysRunResultFilter
        {
            private readonly ConcurrentQueue<ProbedResult> _results = new();

            public IReadOnlyList<ProbedResult> Results => [.. _results];

            public Task OnResultExecutionAsync(
                ResultExecutingContext context,
                ResultExecutionDelegate next
            )
            {
                _results.Enqueue(
                    new ProbedResult(
                        (context.ActionDescriptor as ControllerActionDescriptor)?.ActionName,
                        context.Result,
                        context.Filters.OfType<PortfolioInsightsFeatureGate>().Any(),
                        context.ModelState.Count
                    )
                );
                return next();
            }
        }
    }
}
