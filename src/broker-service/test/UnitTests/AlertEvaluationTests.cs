using System.Threading.Channels;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;
using EasyTrade.BrokerService.Entities.Trades.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Test.Fakes;
using Grpc.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
// System.Diagnostics.Metrics also declares an Instrument type, so only the types used are imported.
using IMeterFactory = System.Diagnostics.Metrics.IMeterFactory;
using MeterListener = System.Diagnostics.Metrics.MeterListener;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Cycle tests of <see cref="AlertEvaluationService"/>, each driving
    /// <see cref="AlertEvaluationService.RunCycleAsync"/> over the in-memory alert store, the
    /// existing repository and pricing fakes, and the real <see cref="PortfolioInsightsService"/>
    /// positions path. They cover the strict crossing rule, one notification per arming under
    /// repetition, racing evaluators and a stale re-arm snapshot, the armed selection, skips,
    /// per-alert and cycle failures, cancellation, the trigger write with its metrics, and the
    /// named log fields. Racing cycles are ordered with barriers and completion sources, and every
    /// wait is bounded. The concurrency case checks the bound on concurrent work: every positions
    /// load is held until the test releases it, one at a time in arrival order, so the loads in
    /// flight are observed at each step without waiting on time. A second concurrency case holds
    /// the loads' own repository reads while a manual clock passes the alert call budget, so no
    /// read beyond the bound may start.
    /// </summary>
    public class AlertEvaluationTests
    {
        private const string CycleFinishedPrefix = "Alert evaluation cycle finished";
        private const string CycleFailedPrefix = "Alert evaluation cycle failed";
        private const string AlertUnit = "{alert}";
        private const string SecondsUnit = "s";
        private const string ReasonNoHolding = "no_holding";
        private const string ReasonNoPrice = "no_price";
        private const string ReasonException = "exception";
        private const string ReasonOutOfRange = "trigger_value_out_of_range";

        // The published metric contract, stated here rather than read from
        // PortfolioInsightsMetrics, so a renamed meter, instrument, tag or outcome fails these
        // tests: a lookup by a renamed instrument finds no measurement.
        private const string MeterName = "EasyTrade.BrokerService";
        private const string EvaluationDurationName = "easytrade.broker.alerts.evaluation.duration";
        private const string TriggeredName = "easytrade.broker.alerts.triggered";
        private const string EvaluationFailedName = "easytrade.broker.alerts.evaluation.failed";
        private const string CycleOutcomeTag = "cycle.outcome";
        private const string AlertTypeTag = "alert.type";
        private const string OutcomeCompleted = "completed";
        private const string OutcomeFailed = "failed";

        // A TARGET_PRICE alert compares the selected close with this threshold; CrossingClose is
        // one step above it, so an ABOVE alert on it is crossed.
        private const decimal PriceThreshold = 10m;
        private const decimal CrossingClose = 10.00000001m;

        // The held position is 10 units bought at 100, a cost basis of 1000, so a PROFIT_LOSS
        // alert observes a P/L % of exactly close - 100 against this threshold.
        private const decimal PnlThreshold = 5m;
        private const decimal HeldQuantity = 10m;
        private const decimal HeldEntryPrice = 100m;

        // 21 integer digits: it crosses any lower threshold, but its rounded value lies outside
        // the trigger-value domain.
        private const decimal OutOfRangeClose = 100_000_000_000_000_000_000m;

        // The plan fixes the evaluator's per-cycle bound on concurrent work at eight. It is
        // stated here rather than read from the evaluator, so a changed bound fails the test.
        private const int AccountBound = 8;

        // Twice the bound plus one, so every release refills the loop to the bound again until
        // the last round, which runs a single load.
        private const int ProfitLossAccounts = (2 * AccountBound) + 1;
        private const int TargetOnlyAccounts = 2;

        // Every alert is ABOVE and crossed: P/L of 20 % and 50 % against 5, and closes of 12
        // and 15 against 11.
        private const decimal EntryPrice = 10m;
        private const decimal FirstClose = 12m;
        private const decimal SecondClose = 15m;
        private const decimal ProfitLossThreshold = 5m;
        private const decimal TargetPriceThreshold = 11m;

        private static readonly DateTimeOffset Time = FakeAlertRepository.BaseTime;

        // Bounds every wait, so a broken evaluator fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(10);

        // The one listing an evaluation cycle makes: the armed alerts of every account.
        private static readonly AlertListCall ArmedListing = new(
            AccountId: null,
            ArmedOnly: true,
            TriggeredOnly: false,
            UnacknowledgedOnly: false
        );

        public enum SelectionScenario
        {
            FlagOff,
            NoArmedAlert,
            DisabledAlert,
            TargetPriceWithoutHolding,
        }

        public enum AlertFailureScenario
        {
            TriggerThrows,
            PositionsThrow,
            TriggerValueOutOfRange,
        }

        public enum CycleFailureScenario
        {
            ListThrows,
            PricesThrow,
            PricesEmpty,
        }

        public enum FailureLogScenario
        {
            TriggerThrowsDbException,
            TriggerValueOutOfRange,
            ListThrowsDbException,
            PricesThrowHttpRequestException,
            PricesEmpty,
        }

        public enum CancellationScenario
        {
            AfterCommittedTrigger,
            DuringDbCall,
        }

        /// <summary>
        /// Type, direction, close and the trigger value the row stores, or null when it must not
        /// trigger. Each type's threshold is observed at it and one step either side: ABOVE
        /// triggers only one step above, BELOW only one step below. A PROFIT_LOSS close c
        /// observes c - 100 against 5. The last row crosses by less than one step and stores the
        /// rounded value, exactly 10.
        /// </summary>
        public static TheoryData<AlertType, AlertDirection, decimal, decimal?> CrossingRows =>
            new()
            {
                { AlertType.TARGET_PRICE, AlertDirection.ABOVE, 10m, null },
                { AlertType.TARGET_PRICE, AlertDirection.ABOVE, 10.00000001m, 10.00000001m },
                { AlertType.TARGET_PRICE, AlertDirection.ABOVE, 9.99999999m, null },
                { AlertType.TARGET_PRICE, AlertDirection.BELOW, 10m, null },
                { AlertType.TARGET_PRICE, AlertDirection.BELOW, 10.00000001m, null },
                { AlertType.TARGET_PRICE, AlertDirection.BELOW, 9.99999999m, 9.99999999m },
                { AlertType.PROFIT_LOSS, AlertDirection.ABOVE, 105m, null },
                { AlertType.PROFIT_LOSS, AlertDirection.ABOVE, 105.00000001m, 5.00000001m },
                { AlertType.PROFIT_LOSS, AlertDirection.ABOVE, 104.99999999m, null },
                { AlertType.PROFIT_LOSS, AlertDirection.BELOW, 105m, null },
                { AlertType.PROFIT_LOSS, AlertDirection.BELOW, 105.00000001m, null },
                { AlertType.PROFIT_LOSS, AlertDirection.BELOW, 104.99999999m, 4.99999999m },
                { AlertType.TARGET_PRICE, AlertDirection.ABOVE, 10.000000001m, 10m },
            };

        [Theory]
        [MemberData(nameof(CrossingRows))]
        public async Task RunCycle_AlertCondition_ShouldTriggerOnlyWhenStrictlyCrossed(
            AlertType type,
            AlertDirection direction,
            decimal close,
            decimal? expectedTriggerValue
        )
        {
            // Arrange
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, close);
            decimal threshold = PriceThreshold;
            if (type == AlertType.PROFIT_LOSS)
            {
                harness.HoldTenBoughtAtHundred(harness.InstrumentA);
                threshold = PnlThreshold;
            }
            Alert alert = harness.SeedAlert(type, direction, harness.InstrumentA, threshold);
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert
            Alert? row = harness.Alerts.Get(alert.Id);
            Assert.Equal(
                new ConditionEffects(
                    Triggered: expectedTriggerValue is null ? 0 : 1,
                    RowTriggered: expectedTriggerValue is not null,
                    StoredTriggerValue: expectedTriggerValue
                ),
                new ConditionEffects(
                    result.Triggered,
                    row?.TriggeredAt is not null,
                    row?.TriggerValue
                )
            );
        }

        [Fact]
        public async Task RunCycle_SamePriceEvaluatedTwice_ShouldTriggerOnce()
        {
            // Arrange
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            Alert alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act: the second cycle sees the same, unchanged price.
            AlertEvaluationResult first = await harness.RunAsync(evaluator);
            DateTimeOffset? triggeredAtAfterFirst = harness.Alerts.Get(alert.Id)?.TriggeredAt;
            AlertEvaluationResult second = await harness.RunAsync(evaluator);
            DateTimeOffset? triggeredAtAfterSecond = harness.Alerts.Get(alert.Id)?.TriggeredAt;

            // Assert
            Assert.Equal(
                new RepeatEffects(
                    FirstTriggered: 1,
                    SecondAlertCount: 0,
                    SecondTriggered: 0,
                    TriggeredAtSet: true,
                    TriggeredAtUnchanged: true
                ),
                new RepeatEffects(
                    first.Triggered,
                    second.AlertCount,
                    second.Triggered,
                    triggeredAtAfterFirst is not null,
                    triggeredAtAfterSecond == triggeredAtAfterFirst
                )
            );
        }

        [Fact]
        public async Task RunCycle_TwoConcurrentEvaluators_ShouldTriggerOnce()
        {
            // Arrange: each listing waits until both evaluators hold the armed snapshot, so both
            // reach the conditional write for the same arming.
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            AlertEvaluationService first = harness.BuildEvaluator();
            AlertEvaluationService second = harness.BuildEvaluator();
            using Barrier listed = new(2);
            harness.Alerts.BeforeListReturns = (_, _) =>
                Task.Run(() => SignalAndWaitBounded(listed));

            // Act
            Task<AlertEvaluationResult> firstCycle = Task.Run(
                () => first.RunCycleAsync(CancellationToken.None)
            );
            Task<AlertEvaluationResult> secondCycle = Task.Run(
                () => second.RunCycleAsync(CancellationToken.None)
            );
            AlertEvaluationResult[] results = await Task.WhenAll(firstCycle, secondCycle)
                .WaitAsync(WaitBound);

            // Assert
            IReadOnlyList<AlertTriggerCall> writes = harness.Alerts.TriggerCalls;
            Assert.Equal(
                new RaceEffects(CombinedTriggered: 1, TriggerWrites: 2, SuccessfulWrites: 1),
                new RaceEffects(
                    results.Sum(result => result.Triggered),
                    writes.Count,
                    writes.Count(write => write.Result == true)
                )
            );
        }

        [Fact]
        public async Task RunCycle_StaleSnapshotAfterRearm_ShouldNotTrigger()
        {
            // Arrange: listing 1 (cycle A) and listing 2 (cycle B) both hold the revision-1
            // snapshot before either triggers; B then waits until the test has re-armed the
            // alert. Listing 3, the fresh cycle's, and listing 4, the notifications read, pass
            // straight through.
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            Alert alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
            AlertEvaluationService cycleAEvaluator = harness.BuildEvaluator();
            AlertEvaluationService cycleBEvaluator = harness.BuildEvaluator();
            AlertEvaluationService freshEvaluator = harness.BuildEvaluator();
            using Barrier listed = new(3);
            TaskCompletionSource firstListEntered = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            TaskCompletionSource releaseB = new(TaskCreationOptions.RunContinuationsAsynchronously);
            harness.Alerts.BeforeListReturns = async (ordinal, _) =>
            {
                if (ordinal == 1)
                {
                    firstListEntered.TrySetResult();
                    await Task.Run(() => SignalAndWaitBounded(listed));
                }
                else if (ordinal == 2)
                {
                    await Task.Run(() => SignalAndWaitBounded(listed));
                    await releaseB.Task.WaitAsync(WaitBound);
                }
            };

            // Act
            Task<AlertEvaluationResult> cycleA = Task.Run(
                () => cycleAEvaluator.RunCycleAsync(CancellationToken.None)
            );
            await firstListEntered.Task.WaitAsync(WaitBound);
            Task<AlertEvaluationResult> cycleB = Task.Run(
                () => cycleBEvaluator.RunCycleAsync(CancellationToken.None)
            );
            await Task.Run(() => SignalAndWaitBounded(listed)).WaitAsync(WaitBound);
            AlertEvaluationResult resultA = await cycleA.WaitAsync(WaitBound);
            Alert? rearmed = await harness.Alerts.UpdateEnabledAsync(alert.Id, true);
            releaseB.TrySetResult();
            AlertEvaluationResult resultB = await cycleB.WaitAsync(WaitBound);
            AlertEvaluationResult resultC = await harness.RunAsync(freshEvaluator);

            // The final notification set, read as the notifications endpoint reads it: the
            // account's alerts whose current arming has triggered, acknowledged or not.
            IReadOnlyList<Alert> notifications = await harness
                .Alerts.ListAsync(
                    alert.AccountId,
                    armedOnly: false,
                    triggeredOnly: true,
                    unacknowledgedOnly: false
                )
                .WaitAsync(WaitBound);
            Alert? notification = notifications.FirstOrDefault();

            // Assert: one notification, this alert's second arming triggered by the fresh cycle,
            // and none left by the stale revision-1 write.
            Assert.Equal(
                new StaleEffects(
                    FirstTriggered: 1,
                    RearmedRevision: 2,
                    RearmedTriggerCleared: true,
                    StaleTriggered: 0,
                    FreshTriggered: 1,
                    TriggerWrites: "rev 1 True, rev 1 False, rev 2 True",
                    NotificationCount: 1,
                    NotificationAlertId: alert.Id,
                    NotificationRevision: 2,
                    NotificationTriggered: true,
                    NotificationTriggerValue: CrossingClose
                ),
                new StaleEffects(
                    resultA.Triggered,
                    rearmed?.ArmingRevision,
                    rearmed is { TriggeredAt: null, TriggerValue: null },
                    resultB.Triggered,
                    resultC.Triggered,
                    DescribeWrites(harness.Alerts.TriggerCalls),
                    notifications.Count,
                    notification?.Id,
                    notification?.ArmingRevision,
                    notification?.TriggeredAt is not null,
                    notification?.TriggerValue
                )
            );
        }

        [Theory]
        [InlineData(SelectionScenario.FlagOff)]
        [InlineData(SelectionScenario.NoArmedAlert)]
        [InlineData(SelectionScenario.DisabledAlert)]
        [InlineData(SelectionScenario.TargetPriceWithoutHolding)]
        public async Task RunCycle_Selection_ShouldEvaluateOnlyArmed(SelectionScenario scenario)
        {
            // Arrange: every row's price crosses its alert, and the account holds nothing.
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            Alert seeded = scenario switch
            {
                SelectionScenario.NoArmedAlert => harness.SeedAlert(
                    AlertType.TARGET_PRICE,
                    AlertDirection.ABOVE,
                    harness.InstrumentA,
                    PriceThreshold,
                    triggeredAt: FakeAlertRepository.BaseTime,
                    triggerValue: CrossingClose
                ),
                SelectionScenario.DisabledAlert => harness.SeedAlert(
                    AlertType.TARGET_PRICE,
                    AlertDirection.ABOVE,
                    harness.InstrumentA,
                    PriceThreshold,
                    enabled: false
                ),
                _ => harness.SeedTargetPriceAlert(harness.InstrumentA),
            };
            AlertEvaluationService evaluator = harness.BuildEvaluator(
                flagEnabled: scenario != SelectionScenario.FlagOff
            );

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert: a cycle past its flag check records its own duration, in seconds.
            string completedOnly = EvaluationDurationName;
            double cycleSeconds = result.Duration.TotalSeconds;
            SelectionEffects expected = scenario switch
            {
                SelectionScenario.FlagOff => new SelectionEffects(
                    AlertEvaluationOutcome.FlagDisabled,
                    AlertCount: 0,
                    Triggered: 0,
                    FlagReads: 1,
                    ListCalls: 0,
                    FirstListing: null,
                    PriceFetches: 0,
                    TriggerWrites: 0,
                    RowUnchanged: true,
                    MeasuredInstruments: string.Empty,
                    DurationSeconds: 0
                ),
                SelectionScenario.NoArmedAlert or SelectionScenario.DisabledAlert =>
                    new SelectionEffects(
                        AlertEvaluationOutcome.Completed,
                        AlertCount: 0,
                        Triggered: 0,
                        FlagReads: 1,
                        ListCalls: 1,
                        FirstListing: ArmedListing,
                        PriceFetches: 0,
                        TriggerWrites: 0,
                        RowUnchanged: true,
                        MeasuredInstruments: completedOnly,
                        DurationSeconds: cycleSeconds
                    ),
                SelectionScenario.TargetPriceWithoutHolding => new SelectionEffects(
                    AlertEvaluationOutcome.Completed,
                    AlertCount: 1,
                    Triggered: 1,
                    FlagReads: 1,
                    ListCalls: 1,
                    FirstListing: ArmedListing,
                    PriceFetches: 1,
                    TriggerWrites: 1,
                    RowUnchanged: false,
                    MeasuredInstruments: Join([completedOnly, TriggeredName]),
                    DurationSeconds: cycleSeconds
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null),
            };
            IReadOnlyList<AlertListCall> listings = harness.Alerts.ListCalls;
            Assert.Equal(
                expected,
                new SelectionEffects(
                    result.Outcome,
                    result.AlertCount,
                    result.Triggered,
                    harness.FlagReads,
                    listings.Count,
                    listings.FirstOrDefault(),
                    harness.PriceCalls.LatestPriceFetches,
                    harness.Alerts.TriggerCalls.Count,
                    harness.Alerts.Get(seeded.Id) == seeded,
                    harness.Measurements.MeasuredInstruments(),
                    harness.Measurements.Sum(EvaluationDurationName)
                )
            );
        }

        [Theory]
        [InlineData(ReasonNoHolding)]
        [InlineData(ReasonNoPrice)]
        public async Task RunCycle_SkipReason_ShouldSkipWithoutFailure(string reason)
        {
            // Arrange
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            Alert alert;
            if (reason == ReasonNoHolding)
            {
                // The account holds A only; B is priced but not held.
                harness.HoldTenBoughtAtHundred(harness.InstrumentA);
                harness.AddCandle(harness.InstrumentB, CrossingClose);
                alert = harness.SeedAlert(
                    AlertType.PROFIT_LOSS,
                    AlertDirection.ABOVE,
                    harness.InstrumentB,
                    PnlThreshold
                );
            }
            else
            {
                // The price list is not empty, but only A has a candle.
                alert = harness.SeedTargetPriceAlert(harness.InstrumentB);
            }
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert
            LogEntry[] warnings =
            [
                .. harness.EvaluatorLogs.Where(entry => entry.Level == LogLevel.Warning),
            ];
            Assert.Equal(
                new SkipEffects(
                    AlertEvaluationOutcome.Completed,
                    Skipped: 1,
                    Failed: 0,
                    Triggered: 0,
                    FailedMeasurements: 0,
                    Warnings: 1,
                    WarningAlertId: alert.Id,
                    WarningReason: reason
                ),
                new SkipEffects(
                    result.Outcome,
                    result.Skipped,
                    result.Failed,
                    result.Triggered,
                    harness.Measurements.Count(EvaluationFailedName),
                    warnings.Length,
                    warnings.FirstOrDefault()?.GetField("alertId"),
                    warnings.FirstOrDefault()?.GetField("reason")
                )
            );
        }

        [Theory]
        [InlineData(AlertFailureScenario.TriggerThrows)]
        [InlineData(AlertFailureScenario.PositionsThrow)]
        [InlineData(AlertFailureScenario.TriggerValueOutOfRange)]
        public async Task RunCycle_AlertFailure_ShouldCountAndContinue(
            AlertFailureScenario scenario
        )
        {
            // Arrange: every row also has one crossed TARGET_PRICE alert on A that must still
            // trigger.
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            IPortfolioInsightsService? insights = null;
            switch (scenario)
            {
                case AlertFailureScenario.TriggerThrows:
                    harness.AddCandle(harness.InstrumentB, CrossingClose);
                    harness.SeedTargetPriceAlert(harness.InstrumentB);
                    harness.Alerts.ThrowOnNext(
                        FakeAlertRepositoryMethod.Trigger,
                        new DbException("x")
                    );
                    break;
                case AlertFailureScenario.PositionsThrow:
                    harness.AddCandle(harness.InstrumentB, CrossingClose);
                    harness.SeedAlert(
                        AlertType.PROFIT_LOSS,
                        AlertDirection.ABOVE,
                        harness.InstrumentA,
                        PnlThreshold
                    );
                    harness.SeedAlert(
                        AlertType.PROFIT_LOSS,
                        AlertDirection.ABOVE,
                        harness.InstrumentB,
                        PnlThreshold
                    );
                    Mock<IPortfolioInsightsService> positions = new(MockBehavior.Strict);
                    positions
                        .Setup(service =>
                            service.GetHoldingPositionsAsync(
                                harness.AccountId,
                                It.IsAny<IReadOnlyDictionary<Guid, Price>>()
                            )
                        )
                        .ThrowsAsync(new DbException("positions unavailable"));
                    insights = positions.Object;
                    break;
                case AlertFailureScenario.TriggerValueOutOfRange:
                    harness.AddCandle(harness.InstrumentB, OutOfRangeClose);
                    harness.SeedAlert(
                        AlertType.TARGET_PRICE,
                        AlertDirection.ABOVE,
                        harness.InstrumentB,
                        1m
                    );
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
            AlertEvaluationService evaluator = harness.BuildEvaluator(insights: insights);

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert: the failed counter on the published meter adds one per failed alert,
            // tagged with its type.
            FailureEffects expected = scenario switch
            {
                AlertFailureScenario.TriggerThrows => new FailureEffects(
                    AlertEvaluationOutcome.Completed,
                    Triggered: 1,
                    Failed: 1,
                    FailedMetricSum: 1,
                    FailedMetricTypes: "TARGET_PRICE",
                    FailedMetricUnits: AlertUnit,
                    FailedMetricMeters: MeterName,
                    FailureReasons: ReasonException
                ),
                AlertFailureScenario.PositionsThrow => new FailureEffects(
                    AlertEvaluationOutcome.Completed,
                    Triggered: 1,
                    Failed: 2,
                    FailedMetricSum: 2,
                    FailedMetricTypes: Join(["PROFIT_LOSS", "PROFIT_LOSS"]),
                    FailedMetricUnits: AlertUnit,
                    FailedMetricMeters: MeterName,
                    FailureReasons: Join([ReasonException, ReasonException])
                ),
                AlertFailureScenario.TriggerValueOutOfRange => new FailureEffects(
                    AlertEvaluationOutcome.Completed,
                    Triggered: 1,
                    Failed: 1,
                    FailedMetricSum: 1,
                    FailedMetricTypes: "TARGET_PRICE",
                    FailedMetricUnits: AlertUnit,
                    FailedMetricMeters: MeterName,
                    FailureReasons: ReasonOutOfRange
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null),
            };
            Assert.Equal(
                expected,
                new FailureEffects(
                    result.Outcome,
                    result.Triggered,
                    result.Failed,
                    harness.Measurements.Sum(EvaluationFailedName),
                    harness.Measurements.TagValues(EvaluationFailedName, AlertTypeTag),
                    harness.Measurements.Units(EvaluationFailedName),
                    harness.Measurements.Meters(EvaluationFailedName),
                    harness.AlertFailureReasons()
                )
            );
        }

        [Theory]
        [InlineData(CycleFailureScenario.ListThrows, 0, "list_failed")]
        [InlineData(CycleFailureScenario.PricesThrow, 1, "prices_failed")]
        [InlineData(CycleFailureScenario.PricesEmpty, 1, "prices_empty")]
        public async Task RunCycle_CycleFailure_ShouldReturnFailedOutcome(
            CycleFailureScenario scenario,
            int expectedAlertCount,
            string expectedReason
        )
        {
            // Arrange: one armed alert that a priced cycle would trigger.
            using CycleHarness harness = new();
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            IPriceServiceConnector? prices = null;
            switch (scenario)
            {
                case CycleFailureScenario.ListThrows:
                    harness.AddCandle(harness.InstrumentA, CrossingClose);
                    harness.Alerts.ThrowOnNext(
                        FakeAlertRepositoryMethod.List,
                        new DbException("list unavailable")
                    );
                    break;
                case CycleFailureScenario.PricesThrow:
                    Mock<IPriceServiceConnector> failing = new(MockBehavior.Strict);
                    failing
                        .Setup(connector => connector.GetLatestPrices())
                        .ThrowsAsync(new HttpRequestException("pricing unreachable"));
                    prices = failing.Object;
                    break;
                case CycleFailureScenario.PricesEmpty:
                    // No candle is added, as pricing answers a non-200 with an empty list.
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
            AlertEvaluationService evaluator = harness.BuildEvaluator(prices: prices);

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert: the failed cycle's duration is recorded on the published meter, in seconds,
            // as the same duration the result returns and the summary line logs.
            Assert.Equal(
                new CycleFailureEffects(
                    AlertEvaluationOutcome.Failed,
                    AlertCount: expectedAlertCount,
                    Triggered: 0,
                    Failed: 0,
                    TriggerWrites: 0,
                    DurationMeasurements: 1,
                    DurationOutcomes: OutcomeFailed,
                    DurationUnits: SecondsUnit,
                    DurationMeters: MeterName,
                    DurationSeconds: result.Duration.TotalSeconds,
                    SummaryDurationMatches: true,
                    FailedMeasurements: 0,
                    CycleFailureReason: expectedReason
                ),
                new CycleFailureEffects(
                    result.Outcome,
                    result.AlertCount,
                    result.Triggered,
                    result.Failed,
                    harness.Alerts.TriggerCalls.Count,
                    harness.Measurements.Count(EvaluationDurationName),
                    harness.Measurements.TagValues(EvaluationDurationName, CycleOutcomeTag),
                    harness.Measurements.Units(EvaluationDurationName),
                    harness.Measurements.Meters(EvaluationDurationName),
                    harness.Measurements.Sum(EvaluationDurationName),
                    harness.SummaryDurationMatches(result.Duration),
                    harness.Measurements.Count(EvaluationFailedName),
                    harness.FirstLineStartingWith(CycleFailedPrefix)?.GetField("reason")
                )
            );
        }

        [Theory]
        [InlineData(
            FailureLogScenario.TriggerThrowsDbException,
            "reason [exception] (DbException: db-adapter call [TriggerAsync] failed with status "
                + "[Unavailable])"
        )]
        [InlineData(
            FailureLogScenario.TriggerValueOutOfRange,
            "reason [trigger_value_out_of_range]"
        )]
        [InlineData(
            FailureLogScenario.ListThrowsDbException,
            "reason [list_failed] (DbException: db-adapter call [ListAsync] failed with status "
                + "[Unavailable])"
        )]
        [InlineData(
            FailureLogScenario.PricesThrowHttpRequestException,
            "reason [prices_failed] (HttpRequestException: Name does not resolve "
                + "(pricing-service:8080))"
        )]
        [InlineData(FailureLogScenario.PricesEmpty, "reason [prices_empty]")]
        public async Task RunCycle_FailureLogged_ShouldRenderExceptionWithoutDriverDetail(
            FailureLogScenario scenario,
            string expectedTail
        )
        {
            // Arrange: one armed alert; a db-adapter failure carries a driver diagnostic that
            // names a database login, as GrpcHelper reports it.
            using CycleHarness harness = new();
            string marker = $"driver-diagnostic-{Guid.NewGuid():N}";
            Alert alert;
            Exception? thrown = null;
            IPriceServiceConnector? prices = null;
            switch (scenario)
            {
                case FailureLogScenario.TriggerThrowsDbException:
                    harness.AddCandle(harness.InstrumentA, CrossingClose);
                    alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
                    thrown = await CaptureDbAdapterFailureAsync("TriggerAsync", marker);
                    harness.Alerts.ThrowOnNext(FakeAlertRepositoryMethod.Trigger, thrown);
                    break;
                case FailureLogScenario.TriggerValueOutOfRange:
                    harness.AddCandle(harness.InstrumentA, OutOfRangeClose);
                    alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
                    break;
                case FailureLogScenario.ListThrowsDbException:
                    alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
                    thrown = await CaptureDbAdapterFailureAsync("ListAsync", marker);
                    harness.Alerts.ThrowOnNext(FakeAlertRepositoryMethod.List, thrown);
                    break;
                case FailureLogScenario.PricesThrowHttpRequestException:
                    alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
                    thrown = new HttpRequestException(
                        "Name does not resolve (pricing-service:8080)"
                    );
                    Mock<IPriceServiceConnector> failing = new(MockBehavior.Strict);
                    failing.Setup(connector => connector.GetLatestPrices()).ThrowsAsync(thrown);
                    prices = failing.Object;
                    break;
                case FailureLogScenario.PricesEmpty:
                    // No candle is added, as pricing answers a non-200 with an empty list.
                    alert = harness.SeedTargetPriceAlert(harness.InstrumentA);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
            AlertEvaluationService evaluator = harness.BuildEvaluator(prices: prices);

            // Act
            _ = await harness.RunAsync(evaluator);

            // Assert: the console logger prints only the message, so the message carries the
            // exception when there is one, never its driver detail; the exception object is
            // still passed to the logger. A failure without an exception keeps its line.
            bool perAlert =
                scenario
                    is FailureLogScenario.TriggerThrowsDbException
                        or FailureLogScenario.TriggerValueOutOfRange;
            string expectedMessage = perAlert
                ? $"Alert [{alert.Id}] of account [{alert.AccountId}] evaluation failed: "
                    + expectedTail
                : $"{CycleFailedPrefix}: {expectedTail}";
            LogEntry error = Assert.Single(
                harness.EvaluatorLogs,
                entry => entry.Level == LogLevel.Error
            );
            Assert.Equal(expectedMessage, error.Message);
            Assert.Same(thrown, error.Exception);
            Assert.Equal(thrown is not null, error.HasField("exception"));
            Assert.All(
                harness.Logs.Entries,
                entry =>
                {
                    Assert.DoesNotContain(marker, entry.Message, StringComparison.Ordinal);
                    Assert.All(
                        entry.State,
                        pair =>
                            Assert.DoesNotContain(
                                marker,
                                pair.Value?.ToString() ?? string.Empty,
                                StringComparison.Ordinal
                            )
                    );
                }
            );
        }

        [Theory]
        [InlineData(FailureLogScenario.TriggerThrowsDbException)]
        [InlineData(FailureLogScenario.ListThrowsDbException)]
        public async Task RunCycle_FailureWithErrorLevelOff_ShouldCountWithoutLogging(
            FailureLogScenario scenario
        )
        {
            // Arrange: one crossed armed alert, and an evaluator logger with Error off.
            using CycleHarness harness = new();
            using ILoggerFactory loggerFactory = LoggerFactory.Create(builder =>
                builder
                    .SetMinimumLevel(LogLevel.Critical)
                    .AddProvider(new RecordingLoggerProvider(harness.Logs))
            );
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            (FakeAlertRepositoryMethod failingMethod, string operation) = scenario switch
            {
                FailureLogScenario.TriggerThrowsDbException => (
                    FakeAlertRepositoryMethod.Trigger,
                    "TriggerAsync"
                ),
                FailureLogScenario.ListThrowsDbException => (
                    FakeAlertRepositoryMethod.List,
                    "ListAsync"
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null),
            };
            harness.Alerts.ThrowOnNext(
                failingMethod,
                await CaptureDbAdapterFailureAsync(operation, "driver-diagnostic")
            );
            AlertEvaluationService evaluator = harness.BuildEvaluator(
                logger: loggerFactory.CreateLogger<AlertEvaluationService>()
            );

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert: the failure keeps its outcome and counts; with Error off no line is written.
            Assert.Equal(
                scenario == FailureLogScenario.TriggerThrowsDbException
                    ? (AlertEvaluationOutcome.Completed, 1, 1d)
                    : (AlertEvaluationOutcome.Failed, 0, 0d),
                (
                    result.Outcome,
                    result.Failed,
                    harness.Measurements.Sum(PortfolioInsightsMetrics.EvaluationFailedName)
                )
            );
            Assert.Empty(harness.EvaluatorLogs);
        }

        // Fails as a db-adapter call fails: GrpcHelper wraps the RPC error, whose detail is the
        // driver's diagnostic, in a DbException naming the repository method.
        private static Task<DbException> CaptureDbAdapterFailureAsync(
            string operation,
            string marker
        )
        {
            RpcException driverError = new(
                new Status(StatusCode.Unavailable, $"login error: Login failed for user '{marker}'")
            );
            return Assert.ThrowsAsync<DbException>(
                () =>
                    GrpcHelper.ExecuteAsync(() => Task.FromException<bool>(driverError), operation)
            );
        }

        [Theory]
        [InlineData(CancellationScenario.AfterCommittedTrigger)]
        [InlineData(CancellationScenario.DuringDbCall)]
        public async Task RunCycle_Cancelled_ShouldNotCountFailure(CancellationScenario scenario)
        {
            // Arrange
            using CycleHarness harness = new();
            using CancellationTokenSource shutdown = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            if (scenario == CancellationScenario.AfterCommittedTrigger)
            {
                // Shutdown lands once a trigger is committed; that write still returns true.
                for (int index = 0; index < 3; index++)
                {
                    harness.SeedTargetPriceAlert(harness.InstrumentA);
                }
                harness.Alerts.AfterTrigger = (_, triggered, _) =>
                {
                    if (triggered)
                    {
                        shutdown.Cancel();
                    }
                    return Task.CompletedTask;
                };
            }
            else
            {
                // Shutdown lands inside the listing, which the fake then fails with a
                // DbException wrapping the OperationCanceledException, as GrpcHelper reports a
                // cancelled gRPC call.
                harness.SeedTargetPriceAlert(harness.InstrumentA);
                harness.Alerts.BeforeListReturns = (_, token) =>
                {
                    shutdown.Cancel();
                    token.ThrowIfCancellationRequested();
                    return Task.CompletedTask;
                };
            }
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator, shutdown.Token);

            // Assert: every committed trigger is counted, in the result and the metric.
            int committed = harness.Alerts.TriggerCalls.Count(write => write.Result == true);
            Assert.Equal(
                new CancellationEffects(
                    AlertEvaluationOutcome.Cancelled,
                    HasCommittedTrigger: scenario == CancellationScenario.AfterCommittedTrigger,
                    ResultCountsCommitted: true,
                    MetricCountsCommitted: true,
                    Failed: 0,
                    FailedMeasurements: 0,
                    DurationMeasurements: 0,
                    SummaryLines: 0,
                    CycleFailureLines: 0
                ),
                new CancellationEffects(
                    result.Outcome,
                    committed >= 1,
                    result.Triggered == committed,
                    harness.Measurements.Sum(TriggeredName) == committed,
                    result.Failed,
                    harness.Measurements.Count(EvaluationFailedName),
                    harness.Measurements.Count(EvaluationDurationName),
                    harness.LinesStartingWith(CycleFinishedPrefix),
                    harness.LinesStartingWith(CycleFailedPrefix)
                )
            );
        }

        [Theory]
        [InlineData(AlertType.TARGET_PRICE, "TARGET_PRICE")]
        [InlineData(AlertType.PROFIT_LOSS, "PROFIT_LOSS")]
        public async Task RunCycle_Triggered_ShouldPassRoundedValueAndRecordMetrics(
            AlertType type,
            string expectedTypeTag
        )
        {
            // Arrange: the observed value has a ninth fractional digit, and the alert is on its
            // third arming, so the write must carry the listed revision.
            using CycleHarness harness = new();
            decimal threshold = PriceThreshold;
            decimal expectedTriggerValue = 10.12345679m;
            if (type == AlertType.PROFIT_LOSS)
            {
                harness.HoldTenBoughtAtHundred(harness.InstrumentA);
                harness.AddCandle(harness.InstrumentA, 105.123456789m);
                threshold = PnlThreshold;
                expectedTriggerValue = 5.12345679m;
            }
            else
            {
                harness.AddCandle(harness.InstrumentA, 10.123456789m);
            }
            Alert alert = harness.SeedAlert(
                type,
                AlertDirection.ABOVE,
                harness.InstrumentA,
                threshold,
                armingRevision: 3
            );
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act
            AlertEvaluationResult result = await harness.RunAsync(evaluator);

            // Assert: both instruments record on the published meter, and the cycle's duration is
            // the one the result returns and the summary line logs, in seconds.
            IReadOnlyList<AlertTriggerCall> writes = harness.Alerts.TriggerCalls;
            Assert.Equal(
                new TriggeredEffects(
                    AlertEvaluationOutcome.Completed,
                    TriggerWrites: 1,
                    Write: new AlertTriggerCall(alert.Id, 3, expectedTriggerValue, true),
                    TriggeredMeasurements: 1,
                    TriggeredSum: 1,
                    TriggeredTypes: expectedTypeTag,
                    TriggeredUnits: AlertUnit,
                    TriggeredMeters: MeterName,
                    DurationMeasurements: 1,
                    DurationOutcomes: OutcomeCompleted,
                    DurationUnits: SecondsUnit,
                    DurationMeters: MeterName,
                    DurationSeconds: result.Duration.TotalSeconds,
                    SummaryDurationMatches: true
                ),
                new TriggeredEffects(
                    result.Outcome,
                    writes.Count,
                    writes.FirstOrDefault(),
                    harness.Measurements.Count(TriggeredName),
                    harness.Measurements.Sum(TriggeredName),
                    harness.Measurements.TagValues(TriggeredName, AlertTypeTag),
                    harness.Measurements.Units(TriggeredName),
                    harness.Measurements.Meters(TriggeredName),
                    harness.Measurements.Count(EvaluationDurationName),
                    harness.Measurements.TagValues(EvaluationDurationName, CycleOutcomeTag),
                    harness.Measurements.Units(EvaluationDurationName),
                    harness.Measurements.Meters(EvaluationDurationName),
                    harness.Measurements.Sum(EvaluationDurationName),
                    harness.SummaryDurationMatches(result.Duration)
                )
            );
        }

        [Fact]
        public async Task RunCycle_Completed_ShouldLogNamedSummaryAndTriggerFields()
        {
            // Arrange: three crossed alerts on A, two out-of-range alerts on B and one alert on
            // an unpriced instrument. Every count differs, so a field bound to the wrong
            // placeholder fails.
            using CycleHarness harness = new();
            harness.AddCandle(harness.InstrumentA, CrossingClose);
            harness.AddCandle(harness.InstrumentB, OutOfRangeClose);
            Alert logged = harness.SeedTargetPriceAlert(harness.InstrumentA);
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            harness.SeedTargetPriceAlert(harness.InstrumentA);
            for (int index = 0; index < 2; index++)
            {
                harness.SeedAlert(
                    AlertType.TARGET_PRICE,
                    AlertDirection.ABOVE,
                    harness.InstrumentB,
                    1m
                );
            }
            harness.SeedTargetPriceAlert(Guid.NewGuid());
            AlertEvaluationService evaluator = harness.BuildEvaluator();

            // Act
            await harness.RunAsync(evaluator);

            // Assert
            LogEntry? summary = harness.FirstLineStartingWith(CycleFinishedPrefix);
            LogEntry? trigger = harness.EvaluatorLogs.FirstOrDefault(entry =>
                entry.HasField("triggerValue") && Equals(entry.GetField("alertId"), logged.Id)
            );
            Assert.Equal(
                new LoggedFields(
                    SummaryLines: 1,
                    Summary: new SummaryFields(
                        LogLevel.Information,
                        Outcome: OutcomeCompleted,
                        AlertCount: 6,
                        TriggeredCount: 3,
                        FailedCount: 2,
                        SkippedCount: 1,
                        HasDurationMs: true
                    ),
                    Trigger: new TriggerFields(
                        LogLevel.Information,
                        AlertId: logged.Id,
                        AccountId: harness.AccountId,
                        Type: "TARGET_PRICE",
                        Direction: "ABOVE",
                        Threshold: PriceThreshold,
                        TriggerValue: CrossingClose,
                        ArmingRevision: 1
                    )
                ),
                new LoggedFields(
                    harness.LinesStartingWith(CycleFinishedPrefix),
                    SummaryFields.Of(summary),
                    TriggerFields.Of(trigger)
                )
            );
        }

        [Fact]
        public async Task RunCycle_ManyProfitLossAccounts_ShouldLoadEachOnceAtMostEightAtATime()
        {
            // Arrange
            using ConcurrencyHarness harness = new();

            // Act: the cycle runs off the test's context. Before each release the loop must have
            // refilled to the bound, or to every account once fewer remain to be started.
            Task<AlertEvaluationResult> cycle = Task.Run(
                () => harness.Service.RunCycleAsync(CancellationToken.None)
            );
            bool completedWhileLoadHeld = false;
            try
            {
                Queue<HeldLoad> held = new();
                for (int released = 0; released < ProfitLossAccounts; released++)
                {
                    int due = Math.Min(ProfitLossAccounts, AccountBound + released);
                    while (held.Count + released < due)
                    {
                        held.Enqueue(await harness.Probe.NextArrivalAsync().WaitAsync(WaitBound));
                    }
                    if (released == ProfitLossAccounts - 1)
                    {
                        completedWhileLoadHeld = cycle.IsCompleted;
                    }
                    held.Dequeue().Release();
                }
            }
            finally
            {
                // Lets through every load the loop did not release, so a failed wait or an
                // unexpected extra load never leaves the cycle parked.
                harness.Probe.ReleaseAll();
            }
            AlertEvaluationResult result = await cycle.WaitAsync(WaitBound);

            // Assert
            ConcurrencyEffects expected = new(
                AlertEvaluationOutcome.Completed,
                AlertCount: harness.SeededAlerts,
                Triggered: harness.SeededAlerts,
                Failed: 0,
                Skipped: 0,
                MaxLoadsInFlight: AccountBound,
                PositionLoads: ProfitLossAccounts,
                ProfitLossAccountsLoadedOnce: ProfitLossAccounts,
                OtherAccountLoads: 0,
                DistinctSelectedPrices: 1,
                SelectedPricesAreSeededCandles: true,
                LatestPriceFetches: 1,
                OtherPricingCalls: 0,
                InsightsReads: 0,
                CycleCompletedWhileLoadHeld: false
            );
            Assert.Equal(expected, harness.Collect(result, completedWhileLoadHeld));
        }

        // The positions reads are existing repository calls that take no token. Held as by a
        // db-adapter that accepted them and stopped, they keep the bound's eight accounts busy
        // however far the clock moves past the alert call budget, so no further read starts and
        // db-adapter never has more than eight accounts' two reads in flight. Released, the
        // cycle completes with every account read once.
        [Fact]
        public async Task RunCycle_PositionsReadsHeld_ShouldStartNoFurtherReadPastCallTimeout()
        {
            // Arrange
            ManualTimeProvider time = new();
            HeldPositionsReads reads = new();
            using ConcurrencyHarness harness = new(reads, time);
            // The loads run unheld, so only the reads hold the cycle.
            harness.Probe.ReleaseAll();
            const int boundReads = 2 * AccountBound;

            // Act: the cycle runs off the test's context.
            Task<AlertEvaluationResult> cycle = Task.Run(
                () => harness.Service.RunCycleAsync(CancellationToken.None)
            );
            int startedPastBudget;
            bool completedPastBudget;
            try
            {
                await reads.WaitForStartedAsync(boundReads).WaitAsync(WaitBound);
                time.Advance(AlertRepository.CallTimeout * 3);
                startedPastBudget = reads.Started;
                completedPastBudget = cycle.IsCompleted;
            }
            finally
            {
                // Lets every read through, so a failed wait never leaves the cycle parked.
                reads.ReleaseAll();
            }
            AlertEvaluationResult result = await cycle.WaitAsync(WaitBound);

            // Assert
            ConcurrencyEffects expected = new(
                AlertEvaluationOutcome.Completed,
                AlertCount: harness.SeededAlerts,
                Triggered: harness.SeededAlerts,
                Failed: 0,
                Skipped: 0,
                MaxLoadsInFlight: AccountBound,
                PositionLoads: ProfitLossAccounts,
                ProfitLossAccountsLoadedOnce: ProfitLossAccounts,
                OtherAccountLoads: 0,
                DistinctSelectedPrices: 1,
                SelectedPricesAreSeededCandles: true,
                LatestPriceFetches: 1,
                OtherPricingCalls: 0,
                InsightsReads: 0,
                CycleCompletedWhileLoadHeld: false
            );
            HeldReadEffects expectedReads = new(
                StartedPastBudget: boundReads,
                MaxUnanswered: boundReads,
                Started: 2 * ProfitLossAccounts,
                AccountsReadOnce: ProfitLossAccounts
            );
            Assert.Equal(
                (expected, expectedReads),
                (harness.Collect(result, completedPastBudget), reads.Collect(startedPastBudget))
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

        // Each trigger write as its revision and decision, in the order the store recorded them.
        private static string DescribeWrites(IReadOnlyList<AlertTriggerCall> writes)
        {
            return string.Join(
                ", ",
                writes.Select(write => $"rev {write.ArmingRevision} {write.Result}")
            );
        }

        // Sorted, so values recorded by parallel workers compare independently of their order.
        private static string Join(IEnumerable<string?> values)
        {
            return string.Join(", ", values.Order(StringComparer.Ordinal));
        }

        private sealed record ConditionEffects(
            int Triggered,
            bool RowTriggered,
            decimal? StoredTriggerValue
        );

        private sealed record RepeatEffects(
            int FirstTriggered,
            int SecondAlertCount,
            int SecondTriggered,
            bool TriggeredAtSet,
            bool TriggeredAtUnchanged
        );

        private sealed record RaceEffects(
            int CombinedTriggered,
            int TriggerWrites,
            int SuccessfulWrites
        );

        private sealed record StaleEffects(
            int FirstTriggered,
            int? RearmedRevision,
            bool RearmedTriggerCleared,
            int StaleTriggered,
            int FreshTriggered,
            string TriggerWrites,
            int NotificationCount,
            Guid? NotificationAlertId,
            int? NotificationRevision,
            bool NotificationTriggered,
            decimal? NotificationTriggerValue
        );

        private sealed record SelectionEffects(
            AlertEvaluationOutcome Outcome,
            int AlertCount,
            int Triggered,
            int FlagReads,
            int ListCalls,
            AlertListCall? FirstListing,
            int PriceFetches,
            int TriggerWrites,
            bool RowUnchanged,
            string MeasuredInstruments,
            double DurationSeconds
        );

        private sealed record SkipEffects(
            AlertEvaluationOutcome Outcome,
            int Skipped,
            int Failed,
            int Triggered,
            int FailedMeasurements,
            int Warnings,
            object? WarningAlertId,
            object? WarningReason
        );

        private sealed record FailureEffects(
            AlertEvaluationOutcome Outcome,
            int Triggered,
            int Failed,
            double FailedMetricSum,
            string FailedMetricTypes,
            string FailedMetricUnits,
            string FailedMetricMeters,
            string FailureReasons
        );

        private sealed record CycleFailureEffects(
            AlertEvaluationOutcome Outcome,
            int AlertCount,
            int Triggered,
            int Failed,
            int TriggerWrites,
            int DurationMeasurements,
            string DurationOutcomes,
            string DurationUnits,
            string DurationMeters,
            double DurationSeconds,
            bool SummaryDurationMatches,
            int FailedMeasurements,
            object? CycleFailureReason
        );

        private sealed record CancellationEffects(
            AlertEvaluationOutcome Outcome,
            bool HasCommittedTrigger,
            bool ResultCountsCommitted,
            bool MetricCountsCommitted,
            int Failed,
            int FailedMeasurements,
            int DurationMeasurements,
            int SummaryLines,
            int CycleFailureLines
        );

        private sealed record TriggeredEffects(
            AlertEvaluationOutcome Outcome,
            int TriggerWrites,
            AlertTriggerCall? Write,
            int TriggeredMeasurements,
            double TriggeredSum,
            string TriggeredTypes,
            string TriggeredUnits,
            string TriggeredMeters,
            int DurationMeasurements,
            string DurationOutcomes,
            string DurationUnits,
            string DurationMeters,
            double DurationSeconds,
            bool SummaryDurationMatches
        );

        private sealed record LoggedFields(
            int SummaryLines,
            SummaryFields? Summary,
            TriggerFields? Trigger
        );

        /// <summary>
        /// The named fields of the cycle summary line; values stay boxed as logged, so a field
        /// logged with another type compares unequal.
        /// </summary>
        private sealed record SummaryFields(
            LogLevel Level,
            object? Outcome,
            object? AlertCount,
            object? TriggeredCount,
            object? FailedCount,
            object? SkippedCount,
            bool HasDurationMs
        )
        {
            public static SummaryFields? Of(LogEntry? entry)
            {
                return entry is null
                    ? null
                    : new SummaryFields(
                        entry.Level,
                        entry.GetField("outcome"),
                        entry.GetField("alertCount"),
                        entry.GetField("triggeredCount"),
                        entry.GetField("failedCount"),
                        entry.GetField("skippedCount"),
                        entry.GetField("durationMs") is long durationMs && durationMs >= 0
                    );
            }
        }

        /// <summary>The named fields of one trigger line, boxed as logged.</summary>
        private sealed record TriggerFields(
            LogLevel Level,
            object? AlertId,
            object? AccountId,
            object? Type,
            object? Direction,
            object? Threshold,
            object? TriggerValue,
            object? ArmingRevision
        )
        {
            public static TriggerFields? Of(LogEntry? entry)
            {
                return entry is null
                    ? null
                    : new TriggerFields(
                        entry.Level,
                        entry.GetField("alertId"),
                        entry.GetField("accountId"),
                        entry.GetField("type"),
                        entry.GetField("direction"),
                        entry.GetField("threshold"),
                        entry.GetField("triggerValue"),
                        entry.GetField("armingRevision")
                    );
            }
        }

        /// <summary>
        /// Everything the cycle leaves observable, compared as one value. Positions loads are
        /// counted per account with PROFIT_LOSS alerts, and separately for any other account;
        /// the price dictionaries the loads received are counted by reference and checked
        /// against the seeded candles; pricing calls other than the latest fetch and full
        /// insights reads, which the evaluator never needs, are counted too.
        /// </summary>
        private sealed record ConcurrencyEffects(
            AlertEvaluationOutcome Outcome,
            int AlertCount,
            int Triggered,
            int Failed,
            int Skipped,
            int MaxLoadsInFlight,
            int PositionLoads,
            int ProfitLossAccountsLoadedOnce,
            int OtherAccountLoads,
            int DistinctSelectedPrices,
            bool SelectedPricesAreSeededCandles,
            int LatestPriceFetches,
            int OtherPricingCalls,
            int InsightsReads,
            bool CycleCompletedWhileLoadHeld
        );

        /// <summary>
        /// The positions path's repository reads, compared as one value: the reads started once
        /// the clock had passed the alert call budget, the most unanswered at once, all reads
        /// started, and the accounts read exactly once by each of the two reads.
        /// </summary>
        private sealed record HeldReadEffects(
            int StartedPastBudget,
            int MaxUnanswered,
            int Started,
            int AccountsReadOnce
        );

        /// <summary>One positions load: its arguments and the release it waits for.</summary>
        private sealed class HeldLoad(Guid accountId, IReadOnlyDictionary<Guid, Price> selected)
        {
            private readonly TaskCompletionSource _release = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            public Guid AccountId { get; } = accountId;

            public IReadOnlyDictionary<Guid, Price> SelectedPrices { get; } = selected;

            public Task Released => _release.Task;

            public void Release()
            {
                _release.TrySetResult();
            }
        }

        /// <summary>
        /// Wraps the real positions service. Each load records its account and the price
        /// dictionary it was given, counts itself in flight, announces its arrival and waits for
        /// its own release before it delegates. It leaves the in-flight count only on exit.
        /// </summary>
        private sealed class HeldPositionsProbe(IPortfolioInsightsService inner)
            : IPortfolioInsightsService
        {
            private readonly Lock _lock = new();
            private readonly List<HeldLoad> _loads = [];
            private readonly Channel<HeldLoad> _arrivals = Channel.CreateUnbounded<HeldLoad>();
            private int _inFlight;
            private int _maxInFlight;
            private int _insightsReads;
            private bool _allReleased;

            /// <summary>The most loads that were between arrival and exit at once.</summary>
            public int MaxInFlight
            {
                get
                {
                    lock (_lock)
                    {
                        return _maxInFlight;
                    }
                }
            }

            /// <summary>Every load in arrival order.</summary>
            public IReadOnlyList<HeldLoad> Loads
            {
                get
                {
                    lock (_lock)
                    {
                        return _loads.ToArray();
                    }
                }
            }

            public int InsightsReads => Volatile.Read(ref _insightsReads);

            /// <summary>The next load to arrive that this method has not returned yet.</summary>
            public Task<HeldLoad> NextArrivalAsync()
            {
                return _arrivals.Reader.ReadAsync().AsTask();
            }

            /// <summary>Releases every held load and lets every later load run unheld.</summary>
            public void ReleaseAll()
            {
                HeldLoad[] loads;
                lock (_lock)
                {
                    _allReleased = true;
                    loads = _loads.ToArray();
                }
                foreach (HeldLoad load in loads)
                {
                    load.Release();
                }
            }

            public Task<PortfolioInsightsDTO> GetInsightsAsync(Guid accountId)
            {
                Interlocked.Increment(ref _insightsReads);
                return inner.GetInsightsAsync(accountId);
            }

            public async Task<IReadOnlyList<HoldingPosition>> GetHoldingPositionsAsync(
                Guid accountId,
                IReadOnlyDictionary<Guid, Price> selectedPrices
            )
            {
                HeldLoad load = new(accountId, selectedPrices);
                bool allReleased;
                lock (_lock)
                {
                    _loads.Add(load);
                    _inFlight++;
                    _maxInFlight = Math.Max(_maxInFlight, _inFlight);
                    allReleased = _allReleased;
                }
                try
                {
                    if (allReleased)
                    {
                        load.Release();
                    }
                    if (!_arrivals.Writer.TryWrite(load))
                    {
                        throw new InvalidOperationException("The arrival channel is closed.");
                    }
                    await load.Released;
                    return await inner.GetHoldingPositionsAsync(accountId, selectedPrices);
                }
                finally
                {
                    lock (_lock)
                    {
                        _inFlight--;
                    }
                }
            }
        }

        /// <summary>
        /// Holds the two repository reads of the positions path, the holdings and the trades of
        /// an account, until <see cref="ReleaseAll"/>, then lets them and every later read through
        /// to the in-memory repositories. A read counts as started when the repository is called
        /// and as unanswered until its task is about to complete.
        /// </summary>
        private sealed class HeldPositionsReads
        {
            private const string HoldingsRead = "holdings";
            private const string TradesRead = "trades";

            private readonly Lock _lock = new();
            private readonly TaskCompletionSource _release = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            private readonly List<(Guid AccountId, string Read)> _started = [];
            private readonly List<(int Count, TaskCompletionSource Signal)> _waiters = [];
            private int _unanswered;
            private int _maxUnanswered;

            /// <summary>The reads started so far.</summary>
            public int Started
            {
                get
                {
                    lock (_lock)
                    {
                        return _started.Count;
                    }
                }
            }

            /// <summary>Completes once <paramref name="count"/> reads have started.</summary>
            public Task WaitForStartedAsync(int count)
            {
                lock (_lock)
                {
                    if (_started.Count >= count)
                    {
                        return Task.CompletedTask;
                    }
                    TaskCompletionSource signal = new(
                        TaskCreationOptions.RunContinuationsAsynchronously
                    );
                    _waiters.Add((count, signal));
                    return signal.Task;
                }
            }

            public void ReleaseAll()
            {
                _release.TrySetResult();
            }

            /// <summary>The holdings reads of <paramref name="inner"/>, held.</summary>
            public IInstrumentRepository Hold(FakeInstrumentRepository inner)
            {
                // Strict, so a read the positions path does not make throws.
                Mock<IInstrumentRepository> held = new(MockBehavior.Strict);
                held.Setup(repository =>
                        repository.GetOwnedInstrumentsOfAccountAsync(It.IsAny<Guid>())
                    )
                    .Returns(
                        (Guid accountId) =>
                            HoldAsync(
                                accountId,
                                HoldingsRead,
                                () => inner.GetOwnedInstrumentsOfAccountAsync(accountId)
                            )
                    );
                return held.Object;
            }

            /// <summary>The executed-trade reads of <paramref name="inner"/>, held.</summary>
            public ITradeRepository Hold(FakeTradeRepository inner)
            {
                Mock<ITradeRepository> held = new(MockBehavior.Strict);
                held.Setup(repository =>
                        repository.GetAccountTradesAsync(It.IsAny<Guid>(), false, false)
                    )
                    .Returns(
                        (Guid accountId, bool onlyOpen, bool onlyLong) =>
                            HoldAsync(
                                accountId,
                                TradesRead,
                                () => inner.GetAccountTradesAsync(accountId, onlyOpen, onlyLong)
                            )
                    );
                return held.Object;
            }

            public HeldReadEffects Collect(int startedPastBudget)
            {
                lock (_lock)
                {
                    return new HeldReadEffects(
                        startedPastBudget,
                        _maxUnanswered,
                        _started.Count,
                        _started
                            .GroupBy(read => read.AccountId)
                            .Count(account =>
                                account.Count(read => read.Read == HoldingsRead) == 1
                                && account.Count(read => read.Read == TradesRead) == 1
                            )
                    );
                }
            }

            private async Task<T> HoldAsync<T>(Guid accountId, string read, Func<Task<T>> answer)
            {
                List<TaskCompletionSource> reached = [];
                lock (_lock)
                {
                    _started.Add((accountId, read));
                    _unanswered++;
                    _maxUnanswered = Math.Max(_maxUnanswered, _unanswered);
                    foreach ((int count, TaskCompletionSource signal) in _waiters)
                    {
                        if (count <= _started.Count)
                        {
                            reached.Add(signal);
                        }
                    }
                    _waiters.RemoveAll(waiter => waiter.Count <= _started.Count);
                }
                foreach (TaskCompletionSource signal in reached)
                {
                    signal.TrySetResult();
                }

                try
                {
                    await _release.Task;
                    return await answer();
                }
                finally
                {
                    lock (_lock)
                    {
                        _unanswered--;
                    }
                }
            }
        }

        /// <summary>
        /// Delegates every member to <see cref="FakePriceServiceConnector"/> and counts the
        /// calls, so a pricing call from the evaluator or from the positions path is seen.
        /// </summary>
        private sealed class CountingPriceServiceConnector(FakePriceServiceConnector inner)
            : IPriceServiceConnector
        {
            private int _latestPriceFetches;
            private int _otherCalls;

            public int LatestPriceFetches => Volatile.Read(ref _latestPriceFetches);

            public int OtherCalls => Volatile.Read(ref _otherCalls);

            public Task<IEnumerable<Price>> GetLatestPrices()
            {
                Interlocked.Increment(ref _latestPriceFetches);
                return inner.GetLatestPrices();
            }

            public Task<IEnumerable<Price>> GetPricesByInstrumentId(Guid id, int count)
            {
                Interlocked.Increment(ref _otherCalls);
                return inner.GetPricesByInstrumentId(id, count);
            }

            public Task<Price?> GetLastPriceByInstrumentId(Guid id)
            {
                Interlocked.Increment(ref _otherCalls);
                return inner.GetLastPriceByInstrumentId(id);
            }

            public Task<IReadOnlyDictionary<Guid, List<Price>>> GetAllPricesAscByTimestamp(
                DateTimeOffset since
            )
            {
                Interlocked.Increment(ref _otherCalls);
                return inner.GetAllPricesAscByTimestamp(since);
            }
        }

        /// <summary>
        /// One <see cref="AlertEvaluationService"/> whose positions come from the real
        /// <see cref="PortfolioInsightsService"/> over in-memory holdings and trades, behind the
        /// probe. Each P/L account holds one unit of two instruments, each bought at
        /// <see cref="EntryPrice"/>, and has one crossed PROFIT_LOSS alert on each; the first
        /// also has a crossed TARGET_PRICE alert. Each target-only account has two crossed
        /// TARGET_PRICE alerts and no holding. Both candles share one timestamp. Given
        /// <see cref="HeldPositionsReads"/>, the positions service reads holdings and trades
        /// through it, and given a clock, it runs on that clock.
        /// </summary>
        private sealed class ConcurrencyHarness : IDisposable
        {
            private readonly ServiceProvider _provider;
            private readonly Guid[] _profitLossAccounts;
            private readonly Price[] _candles = [Candle(FirstClose), Candle(SecondClose)];
            private readonly CountingPriceServiceConnector _prices;
            private readonly FakeAlertRepository _alerts = new();

            public ConcurrencyHarness(
                HeldPositionsReads? heldReads = null,
                TimeProvider? timeProvider = null
            )
            {
                FakeInstrumentRepository instruments = new();
                FakeTradeRepository trades = new();
                _profitLossAccounts =
                [
                    .. Enumerable.Range(0, ProfitLossAccounts).Select(_ => Guid.NewGuid()),
                ];
                foreach (Guid accountId in _profitLossAccounts)
                {
                    foreach (Price candle in _candles)
                    {
                        instruments.AddOwned(
                            new OwnedInstrument(accountId, candle.InstrumentId, 1m, Time)
                        );
                        trades.Add(ExecutedBuy(accountId, candle.InstrumentId));
                        SeedArmed(
                            accountId,
                            candle.InstrumentId,
                            AlertType.PROFIT_LOSS,
                            ProfitLossThreshold
                        );
                    }
                }
                SeedArmed(
                    _profitLossAccounts[0],
                    _candles[0].InstrumentId,
                    AlertType.TARGET_PRICE,
                    TargetPriceThreshold
                );
                for (int index = 0; index < TargetOnlyAccounts; index++)
                {
                    Guid accountId = Guid.NewGuid();
                    foreach (Price candle in _candles)
                    {
                        SeedArmed(
                            accountId,
                            candle.InstrumentId,
                            AlertType.TARGET_PRICE,
                            TargetPriceThreshold
                        );
                    }
                }

                _prices = new CountingPriceServiceConnector(
                    new FakePriceServiceConnector([.. _candles])
                );
                _provider = new ServiceCollection().AddMetrics().BuildServiceProvider();
                PortfolioInsightsMetrics metrics = new(
                    _provider.GetRequiredService<IMeterFactory>()
                );
                // The positions path never reads a balance, so none is seeded.
                Probe = new HeldPositionsProbe(
                    new PortfolioInsightsService(
                        new FakeBalanceRepository(),
                        heldReads?.Hold(instruments) ?? instruments,
                        heldReads?.Hold(trades) ?? trades,
                        _prices,
                        metrics,
                        timeProvider ?? TimeProvider.System,
                        new RecordingLogger<PortfolioInsightsService>()
                    )
                );
                Mock<IPortfolioInsightsFeature> feature = new(MockBehavior.Strict);
                feature
                    .Setup(flag => flag.IsEnabledAsync(It.IsAny<CancellationToken>()))
                    .ReturnsAsync(true);
                Service = new AlertEvaluationService(
                    _alerts,
                    _prices,
                    Probe,
                    feature.Object,
                    metrics,
                    new RecordingLogger<AlertEvaluationService>()
                );
            }

            public AlertEvaluationService Service { get; }

            public HeldPositionsProbe Probe { get; }

            /// <summary>Every armed alert the harness seeded.</summary>
            public int SeededAlerts { get; private set; }

            public ConcurrencyEffects Collect(
                AlertEvaluationResult result,
                bool completedWhileLoadHeld
            )
            {
                IReadOnlyList<HeldLoad> loads = Probe.Loads;
                HashSet<Guid> profitLossAccounts = [.. _profitLossAccounts];
                return new ConcurrencyEffects(
                    result.Outcome,
                    result.AlertCount,
                    result.Triggered,
                    result.Failed,
                    result.Skipped,
                    Probe.MaxInFlight,
                    loads.Count,
                    _profitLossAccounts.Count(account =>
                        loads.Count(load => load.AccountId == account) == 1
                    ),
                    loads.Count(load => !profitLossAccounts.Contains(load.AccountId)),
                    loads
                        .Select(load => load.SelectedPrices)
                        .Distinct(ReferenceEqualityComparer.Instance)
                        .Count(),
                    loads.All(load => HoldsSeededCandles(load.SelectedPrices)),
                    _prices.LatestPriceFetches,
                    _prices.OtherCalls,
                    Probe.InsightsReads,
                    completedWhileLoadHeld
                );
            }

            public void Dispose()
            {
                _provider.Dispose();
            }

            // A candle of a new instrument; the close alone prices it.
            private static Price Candle(decimal close)
            {
                return new Price(Guid.NewGuid(), Time, close, close, close, close);
            }

            // An executed quick buy of one unit, so the holding's cost basis is EntryPrice.
            private static Trade ExecutedBuy(Guid accountId, Guid instrumentId)
            {
                return new Trade(
                    accountId,
                    instrumentId,
                    "buy",
                    1m,
                    EntryPrice,
                    Time,
                    Time,
                    true,
                    true,
                    "Instant buy done."
                );
            }

            private void SeedArmed(
                Guid accountId,
                Guid instrumentId,
                AlertType type,
                decimal threshold
            )
            {
                _alerts.Seed(
                    new Alert(
                        Guid.NewGuid(),
                        accountId,
                        instrumentId,
                        type,
                        AlertDirection.ABOVE,
                        threshold,
                        Enabled: true,
                        ArmingRevision: 1,
                        TriggeredAt: null,
                        TriggerValue: null,
                        Acknowledged: false,
                        CreatedAt: Time
                    )
                );
                SeededAlerts++;
            }

            private bool HoldsSeededCandles(IReadOnlyDictionary<Guid, Price> selected)
            {
                return selected.Count == _candles.Length
                    && _candles.All(candle =>
                        selected.TryGetValue(candle.InstrumentId, out Price? price)
                        && ReferenceEquals(price, candle)
                    );
            }
        }

        /// <summary>
        /// One account with a balance and two instruments, A and B, over the existing in-memory
        /// repository and pricing fakes. Every candle carries <see cref="Time"/>, so the fake
        /// latest-price fetch returns them all. Evaluators built here share one alert store, one
        /// meter factory and one log sink.
        /// </summary>
        private sealed class CycleHarness : IDisposable
        {
            private readonly ServiceProvider _provider = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            private readonly FakeBalanceRepository _balances = new();
            private readonly FakeInstrumentRepository _instruments = new();
            private readonly FakeTradeRepository _trades = new();
            private readonly FakePriceServiceConnector _prices = new();
            private readonly PortfolioInsightsMetrics _metrics;
            private int _flagReads;

            public CycleHarness()
            {
                IMeterFactory meterFactory = _provider.GetRequiredService<IMeterFactory>();
                Measurements = new MetricCapture(meterFactory);
                _metrics = new PortfolioInsightsMetrics(meterFactory);
                PriceCalls = new CountingPriceServiceConnector(_prices);
                _balances.AddBalance(new Balance(AccountId, 10_000m));
            }

            public Guid AccountId { get; } = Guid.NewGuid();

            public Guid InstrumentA { get; } = Guid.NewGuid();

            public Guid InstrumentB { get; } = Guid.NewGuid();

            public FakeAlertRepository Alerts { get; } = new();

            /// <summary>The default pricing of the evaluators built here; counts fetches.</summary>
            public CountingPriceServiceConnector PriceCalls { get; }

            public MetricCapture Measurements { get; }

            public RecordingLogSink Logs { get; } = new();

            /// <summary>Flag reads made by every evaluator built here.</summary>
            public int FlagReads => Volatile.Read(ref _flagReads);

            public IReadOnlyList<LogEntry> EvaluatorLogs =>
                Logs.ByCategory<AlertEvaluationService>();

            /// <summary>
            /// An evaluator over the shared store, metrics and log sink. Pricing defaults to
            /// <see cref="PriceCalls"/>, positions to the real
            /// <see cref="PortfolioInsightsService"/> over the harness fakes and that pricing,
            /// and the evaluator's logger to one recording every level into <see cref="Logs"/>.
            /// </summary>
            public AlertEvaluationService BuildEvaluator(
                bool flagEnabled = true,
                IPriceServiceConnector? prices = null,
                IPortfolioInsightsService? insights = null,
                ILogger<AlertEvaluationService>? logger = null
            )
            {
                IPriceServiceConnector pricing = prices ?? PriceCalls;
                Mock<IPortfolioInsightsFeature> feature = new(MockBehavior.Strict);
                feature
                    .Setup(flag => flag.IsEnabledAsync(It.IsAny<CancellationToken>()))
                    .Returns(() =>
                    {
                        Interlocked.Increment(ref _flagReads);
                        return Task.FromResult(flagEnabled);
                    });
                IPortfolioInsightsService positions =
                    insights
                    ?? new PortfolioInsightsService(
                        _balances,
                        _instruments,
                        _trades,
                        pricing,
                        _metrics,
                        TimeProvider.System,
                        new RecordingLogger<PortfolioInsightsService>(Logs)
                    );
                return new AlertEvaluationService(
                    Alerts,
                    pricing,
                    positions,
                    feature.Object,
                    _metrics,
                    logger ?? new RecordingLogger<AlertEvaluationService>(Logs)
                );
            }

            public void AddCandle(Guid instrumentId, decimal close)
            {
                _prices.AddPrice(new Price(instrumentId, Time, close, close, close, close));
            }

            /// <summary>Holds 10 units of the instrument from one executed buy at 100.</summary>
            public void HoldTenBoughtAtHundred(Guid instrumentId)
            {
                _instruments.AddOwned(
                    new OwnedInstrument(AccountId, instrumentId, HeldQuantity, Time)
                );
                _trades.Add(
                    new Trade(
                        AccountId,
                        instrumentId,
                        "buy",
                        HeldQuantity,
                        HeldEntryPrice,
                        Time,
                        Time,
                        tradeClosed: true,
                        transactionHappened: true,
                        "Instant buy done."
                    )
                );
            }

            /// <summary>Seeds an alert of the account, armed unless told otherwise.</summary>
            public Alert SeedAlert(
                AlertType type,
                AlertDirection direction,
                Guid instrumentId,
                decimal threshold,
                bool enabled = true,
                int armingRevision = 1,
                DateTimeOffset? triggeredAt = null,
                decimal? triggerValue = null
            )
            {
                Alert alert = new(
                    Guid.NewGuid(),
                    AccountId,
                    instrumentId,
                    type,
                    direction,
                    threshold,
                    Enabled: enabled,
                    ArmingRevision: armingRevision,
                    TriggeredAt: triggeredAt,
                    TriggerValue: triggerValue,
                    Acknowledged: false,
                    CreatedAt: Time
                );
                Alerts.Seed(alert);
                return alert;
            }

            /// <summary>
            /// An armed TARGET_PRICE alert ABOVE <see cref="PriceThreshold"/>, which a candle at
            /// <see cref="CrossingClose"/> crosses.
            /// </summary>
            public Alert SeedTargetPriceAlert(Guid instrumentId)
            {
                return SeedAlert(
                    AlertType.TARGET_PRICE,
                    AlertDirection.ABOVE,
                    instrumentId,
                    PriceThreshold
                );
            }

            public Task<AlertEvaluationResult> RunAsync(
                AlertEvaluationService evaluator,
                CancellationToken cancellationToken = default
            )
            {
                return evaluator.RunCycleAsync(cancellationToken).WaitAsync(WaitBound);
            }

            public LogEntry? FirstLineStartingWith(string prefix)
            {
                return EvaluatorLogs.FirstOrDefault(entry =>
                    entry.Message.StartsWith(prefix, StringComparison.Ordinal)
                );
            }

            public int LinesStartingWith(string prefix)
            {
                return EvaluatorLogs.Count(entry =>
                    entry.Message.StartsWith(prefix, StringComparison.Ordinal)
                );
            }

            /// <summary>
            /// Whether the summary line logs <paramref name="duration"/> in whole milliseconds:
            /// its durationMs is a long less than one millisecond away from it.
            /// </summary>
            public bool SummaryDurationMatches(TimeSpan duration)
            {
                return FirstLineStartingWith(CycleFinishedPrefix)?.GetField("durationMs")
                        is long durationMs
                    && Math.Abs(durationMs - duration.TotalMilliseconds) < 1;
            }

            /// <summary>
            /// The reason of every per-alert failure line, sorted. Only those lines carry an
            /// alert id; the cycle failure line does not.
            /// </summary>
            public string AlertFailureReasons()
            {
                return Join(
                    EvaluatorLogs
                        .Where(entry => entry.Level == LogLevel.Error && entry.HasField("alertId"))
                        .Select(entry => entry.GetField("reason")?.ToString())
                );
            }

            public void Dispose()
            {
                Measurements.Dispose();
                _provider.Dispose();
            }
        }

        /// <summary>
        /// Captures every measurement of the instruments one meter factory created, with its
        /// meter name, instrument name, unit and tags, so tests running in parallel never see
        /// each other's measurements. Parallel workers record at once, so every access takes the
        /// lock.
        /// </summary>
        private sealed class MetricCapture : IDisposable
        {
            private readonly Lock _lock = new();
            private readonly List<CapturedMeasurement> _measurements = [];
            private readonly MeterListener _listener = new();

            public MetricCapture(IMeterFactory meterFactory)
            {
                _listener.InstrumentPublished = (instrument, listener) =>
                {
                    if (ReferenceEquals(instrument.Meter.Scope, meterFactory))
                    {
                        listener.EnableMeasurementEvents(instrument);
                    }
                };
                _listener.SetMeasurementEventCallback<long>(
                    (instrument, value, tags, _) =>
                        Record(instrument.Meter.Name, instrument.Name, instrument.Unit, value, tags)
                );
                _listener.SetMeasurementEventCallback<double>(
                    (instrument, value, tags, _) =>
                        Record(instrument.Meter.Name, instrument.Name, instrument.Unit, value, tags)
                );
                _listener.Start();
            }

            public int Count(string instrumentName)
            {
                return Of(instrumentName).Length;
            }

            public double Sum(string instrumentName)
            {
                return Of(instrumentName).Sum(measurement => measurement.Value);
            }

            /// <summary>The tag <paramref name="key"/> of every measurement, sorted.</summary>
            public string TagValues(string instrumentName, string key)
            {
                return Join(
                    Of(instrumentName)
                        .Select(measurement => measurement.Tags.GetValueOrDefault(key)?.ToString())
                );
            }

            /// <summary>The distinct units the instrument's measurements carried.</summary>
            public string Units(string instrumentName)
            {
                return Join(Of(instrumentName).Select(measurement => measurement.Unit).Distinct());
            }

            /// <summary>The distinct meter names the instrument's measurements carried.</summary>
            public string Meters(string instrumentName)
            {
                return Join(Of(instrumentName).Select(measurement => measurement.Meter).Distinct());
            }

            /// <summary>The distinct names of every instrument that recorded anything.</summary>
            public string MeasuredInstruments()
            {
                lock (_lock)
                {
                    return Join(_measurements.Select(measurement => measurement.Name).Distinct());
                }
            }

            public void Dispose()
            {
                _listener.Dispose();
            }

            private CapturedMeasurement[] Of(string instrumentName)
            {
                lock (_lock)
                {
                    return
                    [
                        .. _measurements.Where(measurement => measurement.Name == instrumentName),
                    ];
                }
            }

            private void Record(
                string meter,
                string name,
                string? unit,
                double value,
                ReadOnlySpan<KeyValuePair<string, object?>> tags
            )
            {
                Dictionary<string, object?> copied = new();
                foreach (KeyValuePair<string, object?> tag in tags)
                {
                    copied[tag.Key] = tag.Value;
                }
                lock (_lock)
                {
                    _measurements.Add(new CapturedMeasurement(meter, name, unit, value, copied));
                }
            }

            private sealed record CapturedMeasurement(
                string Meter,
                string Name,
                string? Unit,
                double Value,
                IReadOnlyDictionary<string, object?> Tags
            );
        }
    }
}
