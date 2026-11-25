using System.Net;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Trades;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>
    /// One notification per arming, end to end over HTTP: alerts are created, re-armed and read
    /// through the real controller, feature gate and alert service, and evaluated by the real
    /// evaluator, with <see cref="FakeAlertRepository"/> standing in for db-adapter's conditional
    /// trigger write. Cycles run only when a test runs them, so no timer decides any order; the
    /// re-arm race is ordered by a barrier, a completion source and the fake's list hook, and
    /// every wait is bounded.
    /// </summary>
    [Collection(BrokerHostCollection.Name)]
    public class AlertEvaluationFlowTests
    {
        private const string TargetPrice = "TARGET_PRICE";
        private const string ProfitLoss = "PROFIT_LOSS";
        private const string TargetPriceThreshold = "100";
        private const string ProfitLossThreshold = "5";

        private const decimal AccountBalance = 1000m;

        // One executed buy of 10 units at 100: a cost basis of 1000 and no opening lot, so a
        // PROFIT_LOSS alert observes (10 x close - 1000) / 1000 x 100 percent.
        private const decimal HeldQuantity = 10m;
        private const decimal EntryPrice = 100m;

        // A close of 90 crosses neither alert (price 90, P/L -10 %); 110 crosses both (price 110
        // above 100, P/L 10 % above 5).
        private const decimal UncrossedClose = 90m;
        private const decimal CrossedClose = 110m;
        private const decimal CrossedPnlPercent = 10m;

        private static readonly DateTimeOffset T0 = new(2025, 6, 2, 9, 0, 0, TimeSpan.Zero);

        // Bounds every wait, so a broken ordering fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(10);

        [Theory]
        [InlineData(TargetPrice)]
        [InlineData(ProfitLoss)]
        public async Task EvaluationFlow_CreateCrossRepeatRearm_ShouldNotifyOncePerArming(
            string type
        )
        {
            // Arrange
            (string threshold, decimal expectedTriggerValue) = type switch
            {
                TargetPrice => (TargetPriceThreshold, CrossedClose),
                ProfitLoss => (ProfitLossThreshold, CrossedPnlPercent),
                _ => throw new ArgumentOutOfRangeException(nameof(type), type, "Unknown type."),
            };
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            FlowFixture fixture = SeedHeldInstrument(host);

            // Act and assert 1: created armed and evaluated below its threshold, so nothing
            // triggers.
            Guid alertId = await CreateAlertAsync(host, fixture, type, threshold);
            Assert.Equal(
                Completed(alertCount: 1, triggered: 0),
                Summarize(await host.RunCycleAsync())
            );
            Assert.Empty(await GetNotificationsAsync(host, fixture));

            // 2: the price moves across the threshold.
            AddCandles(host, fixture, T0.AddMinutes(1), CrossedClose);

            // 3: the crossing triggers the first arming once.
            Assert.Equal(
                Completed(alertCount: 1, triggered: 1),
                Summarize(await host.RunCycleAsync())
            );
            string firstTriggeredAt = AssertSingleNotification(
                await GetNotificationsAsync(host, fixture),
                alertId,
                armingRevision: 1,
                expectedTriggerValue
            );

            // 4: the same price evaluated again: the triggered alert has left the armed set, so
            // the notification and its trigger time stay as they were.
            Assert.Equal(
                Completed(alertCount: 0, triggered: 0),
                Summarize(await host.RunCycleAsync())
            );
            string repeatedTriggeredAt = AssertSingleNotification(
                await GetNotificationsAsync(host, fixture),
                alertId,
                armingRevision: 1,
                expectedTriggerValue
            );
            Assert.Equal(firstTriggeredAt, repeatedTriggeredAt);

            // 5: re-arming clears the trigger and with it the notification.
            AssertRearmed(await RearmAsync(host, alertId), alertId, armingRevision: 2);
            Assert.Empty(await GetNotificationsAsync(host, fixture));

            // 6: the price is still across, so the second arming triggers once.
            Assert.Equal(
                Completed(alertCount: 1, triggered: 1),
                Summarize(await host.RunCycleAsync())
            );
            AssertSingleNotification(
                await GetNotificationsAsync(host, fixture),
                alertId,
                armingRevision: 2,
                expectedTriggerValue
            );
            AssertTriggerWrites(host, alertId, "rev 1 True, rev 2 True");
        }

        [Fact]
        public async Task EvaluationFlow_RearmRace_ShouldNotifyOncePerArming()
        {
            // Arrange: the price already crosses the TARGET_PRICE alert.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            FlowFixture fixture = SeedHeldInstrument(host);
            AddCandles(host, fixture, T0.AddMinutes(1), CrossedClose);
            Guid alertId = await CreateAlertAsync(host, fixture, TargetPrice, TargetPriceThreshold);
            // So the hook's ordinals count from evaluator A's listing, whatever the create path
            // read.
            host.Alerts.ResetCalls();

            // Listing 1 (cycle A) and listing 2 (cycle B) both hold the revision-1 snapshot at the
            // barrier before either triggers; B then waits until the test has re-armed the alert
            // through HTTP. Later listings, the fresh cycle's and the notification read's, pass
            // straight through.
            using Barrier listed = new(3);
            TaskCompletionSource firstListEntered = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            TaskCompletionSource releaseB = new(TaskCreationOptions.RunContinuationsAsynchronously);
            host.Alerts.BeforeListReturns = async (ordinal, _) =>
            {
                // The barrier blocks the listing thread, which is a pool thread because each
                // cycle starts through Task.Run.
                if (ordinal == 1)
                {
                    firstListEntered.TrySetResult();
                    SignalAndWaitBounded(listed);
                }
                else if (ordinal == 2)
                {
                    SignalAndWaitBounded(listed);
                    await releaseB.Task.WaitAsync(WaitBound);
                }
            };

            IAlertEvaluationService evaluatorA = host.CreateEvaluator(out AsyncServiceScope scopeA);
            IAlertEvaluationService evaluatorB = host.CreateEvaluator(out AsyncServiceScope scopeB);
            Task<AlertEvaluationResult>? cycleA = null;
            Task<AlertEvaluationResult>? cycleB = null;
            try
            {
                // Act: B starts only once A holds listing 1, so A is the cycle that wins.
                cycleA = Task.Run(() => evaluatorA.RunCycleAsync(CancellationToken.None));
                await firstListEntered.Task.WaitAsync(WaitBound);
                cycleB = Task.Run(() => evaluatorB.RunCycleAsync(CancellationToken.None));
                await Task.Run(() => SignalAndWaitBounded(listed));
                AlertEvaluationResult resultA = await cycleA.WaitAsync(WaitBound);
                JsonElement rearmed = await RearmAsync(host, alertId);
                releaseB.TrySetResult();
                AlertEvaluationResult resultB = await cycleB.WaitAsync(WaitBound);
                AlertEvaluationResult resultFresh = await host.RunCycleAsync();
                IReadOnlyList<JsonElement> notifications = await GetNotificationsAsync(
                    host,
                    fixture
                );

                // Assert: B's write carries the stale revision 1 and fails the revision
                // predicate, so only the fresh cycle notifies for revision 2.
                Assert.Equal(Completed(alertCount: 1, triggered: 1), Summarize(resultA));
                AssertRearmed(rearmed, alertId, armingRevision: 2);
                Assert.Equal(Completed(alertCount: 1, triggered: 0), Summarize(resultB));
                Assert.Equal(Completed(alertCount: 1, triggered: 1), Summarize(resultFresh));
                AssertSingleNotification(notifications, alertId, armingRevision: 2, CrossedClose);
                AssertTriggerWrites(host, alertId, "rev 1 True, rev 1 False, rev 2 True");
            }
            finally
            {
                // An assertion that ends the test early can leave B held at the hook; releasing
                // it and letting both cycles end keeps them from outliving their scopes and the
                // barrier.
                releaseB.TrySetResult();
                await WhenEndedAsync(cycleA, cycleB);
                await scopeB.DisposeAsync();
                await scopeA.DisposeAsync();
            }
        }

        private static FlowFixture SeedHeldInstrument(BrokerTestHost host)
        {
            Guid accountId = Guid.NewGuid();
            Guid instrumentId = Guid.NewGuid();
            host.Balances.AddBalance(new Balance(accountId, AccountBalance));
            host.Instruments.AddInstrument(
                    new Instrument(instrumentId, Guid.NewGuid(), "C1", "Alpha", "d")
                )
                .AddOwned(new OwnedInstrument(accountId, instrumentId, HeldQuantity));
            host.Trades.Add(
                new Trade(
                    Guid.NewGuid(),
                    accountId,
                    instrumentId,
                    "buy",
                    HeldQuantity,
                    EntryPrice,
                    T0,
                    T0,
                    true,
                    true,
                    "Instant Buy done."
                )
            );
            FlowFixture fixture = new(accountId, instrumentId);
            AddCandles(host, fixture, T0, UncrossedClose);
            return fixture;
        }

        // The fake pricing connector serves only the candles at the newest timestamp, so every
        // instrument of the fixture gets a candle at each new time; one left behind would be
        // skipped as no_price.
        private static void AddCandles(
            BrokerTestHost host,
            FlowFixture fixture,
            DateTimeOffset timestamp,
            decimal close
        )
        {
            host.Prices.AddPrice(
                new Price(fixture.InstrumentId, timestamp, close, close, close, close)
            );
        }

        private static async Task<Guid> CreateAlertAsync(
            BrokerTestHost host,
            FlowFixture fixture,
            string type,
            string threshold
        )
        {
            // The threshold goes out as the literal JSON number token, as a client sends it.
            string body = $$"""
                {
                  "accountId": "{{fixture.AccountId}}",
                  "type": "{{type}}",
                  "instrumentId": "{{fixture.InstrumentId}}",
                  "direction": "ABOVE",
                  "threshold": {{threshold}}
                }
                """;
            using HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                host.Client,
                HttpMethod.Post,
                "v1/alerts",
                body
            );
            JsonElement alert = await ReadJsonAsync(response, HttpStatusCode.Created);
            Assert.True(alert.GetProperty("enabled").GetBoolean());
            Assert.Equal(1, alert.GetProperty("armingRevision").GetInt32());
            Assert.Equal(JsonValueKind.Null, alert.GetProperty("triggeredAt").ValueKind);
            return alert.GetProperty("id").GetGuid();
        }

        private static async Task<JsonElement> RearmAsync(BrokerTestHost host, Guid alertId)
        {
            using HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                host.Client,
                HttpMethod.Patch,
                $"v1/alerts/{alertId}",
                """{"enabled": true}"""
            );
            return await ReadJsonAsync(response, HttpStatusCode.OK);
        }

        private static async Task<IReadOnlyList<JsonElement>> GetNotificationsAsync(
            BrokerTestHost host,
            FlowFixture fixture
        )
        {
            using HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                host.Client,
                HttpMethod.Get,
                $"v1/alerts/notifications?accountId={fixture.AccountId}&unacknowledged=true",
                null
            );
            JsonElement body = await ReadJsonAsync(response, HttpStatusCode.OK);
            JsonElement results = body.GetProperty("results");
            Assert.Equal(JsonValueKind.Array, results.ValueKind);
            return [.. results.EnumerateArray()];
        }

        // Asserts the status with the body in the failure message, then parses the body.
        private static async Task<JsonElement> ReadJsonAsync(
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

        // Asserts the one notification of the given arming and returns its triggeredAt text.
        private static string AssertSingleNotification(
            IReadOnlyList<JsonElement> notifications,
            Guid alertId,
            int armingRevision,
            decimal triggerValue
        )
        {
            JsonElement notification = Assert.Single(notifications);
            Assert.Equal(alertId, notification.GetProperty("id").GetGuid());
            Assert.Equal(armingRevision, notification.GetProperty("armingRevision").GetInt32());
            Assert.Equal(triggerValue, notification.GetProperty("triggerValue").GetDecimal());
            string? triggeredAt = notification.GetProperty("triggeredAt").GetString();
            Assert.NotNull(triggeredAt);
            return triggeredAt;
        }

        private static void AssertRearmed(JsonElement alert, Guid alertId, int armingRevision)
        {
            Assert.Equal(alertId, alert.GetProperty("id").GetGuid());
            Assert.True(alert.GetProperty("enabled").GetBoolean());
            Assert.Equal(armingRevision, alert.GetProperty("armingRevision").GetInt32());
            Assert.Equal(JsonValueKind.Null, alert.GetProperty("triggeredAt").ValueKind);
            Assert.Equal(JsonValueKind.Null, alert.GetProperty("triggerValue").ValueKind);
        }

        // Every trigger write of the alert as its revision and decision, in the order the store
        // recorded them.
        private static void AssertTriggerWrites(
            BrokerTestHost host,
            Guid alertId,
            string expectedWrites
        )
        {
            IReadOnlyList<AlertTriggerCall> writes = host.Alerts.TriggerCalls;
            Assert.All(writes, write => Assert.Equal(alertId, write.Id));
            Assert.Equal(
                expectedWrites,
                string.Join(
                    ", ",
                    writes.Select(write => $"rev {write.ArmingRevision} {write.Result}")
                )
            );
        }

        private static CycleSummary Completed(int alertCount, int triggered)
        {
            return new CycleSummary(AlertEvaluationOutcome.Completed, alertCount, triggered, 0, 0);
        }

        // The result without its duration, so whole outcomes compare in one assertion.
        private static CycleSummary Summarize(AlertEvaluationResult result)
        {
            return new CycleSummary(
                result.Outcome,
                result.AlertCount,
                result.Triggered,
                result.Failed,
                result.Skipped
            );
        }

        // Signals the barrier and waits for every party, failing rather than blocking past the
        // bound.
        private static void SignalAndWaitBounded(Barrier barrier)
        {
            if (!barrier.SignalAndWait(WaitBound))
            {
                throw new TimeoutException(
                    $"Not all {barrier.ParticipantCount} barrier parties arrived in {WaitBound}."
                );
            }
        }

        // Waits, bounded, for the started cycles to end. Their failures are not raised here: on
        // the normal path the result checks have already observed them, and on an early exit
        // the assertion that ended the test is the failure to report.
        private static async Task WhenEndedAsync(params Task?[] cycles)
        {
            Task[] started = [.. cycles.OfType<Task>()];
            await Task.WhenAll(started)
                .WaitAsync(WaitBound)
                .ConfigureAwait(
                    ConfigureAwaitOptions.SuppressThrowing
                        | ConfigureAwaitOptions.ContinueOnCapturedContext
                );
        }

        private sealed record FlowFixture(Guid AccountId, Guid InstrumentId);

        private sealed record CycleSummary(
            AlertEvaluationOutcome Outcome,
            int AlertCount,
            int Triggered,
            int Failed,
            int Skipped
        );
    }
}
