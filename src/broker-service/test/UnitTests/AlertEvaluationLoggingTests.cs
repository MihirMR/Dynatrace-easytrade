using System.Collections.Concurrent;
using System.Diagnostics.Metrics;
using System.Text;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// How the evaluator's log emission interacts with its trigger accounting and with a console
    /// provider that writes one record in several separate writes.
    /// </summary>
    public class AlertEvaluationLoggingTests
    {
        // Every crossed alert is ABOVE this threshold and observes CrossingValue.
        private const decimal Threshold = 10m;
        private const decimal CrossingValue = 20m;

        // The named field only the trigger record carries.
        private const string TriggerValueField = "triggerValue";

        // The named field every trigger, skip and per-alert failure record carries.
        private const string AlertIdField = "alertId";

        // The stable marker the cycle summary record starts with.
        private const string CycleFinishedPrefix = "Alert evaluation cycle finished";

        // The start of the Debug record a cycle ended by shutdown logs instead of the summary.
        private const string CycleCancelledPrefix = "Alert evaluation cycle cancelled";

        private static readonly DateTimeOffset PriceTime = FakeAlertRepository.BaseTime;

        // Bounds every wait, so a broken evaluator fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(10);

        /// <summary>The per-alert record every worker emits at the same moment.</summary>
        public enum ConcurrentRecord
        {
            Trigger,
            Skip,
            Failure,
        }

        [Theory]
        [InlineData(AlertType.TARGET_PRICE)]
        [InlineData(AlertType.PROFIT_LOSS)]
        public async Task RunCycle_TriggerLogThrows_ShouldCountCommittedTriggersAndNoFailure(
            AlertType type
        )
        {
            // Arrange
            const int alertCount = 3;
            using EvaluationHarness harness = new();
            harness.SeedCrossedAlerts(type, alertCount);
            HookedLogger logger = new(entry =>
            {
                if (entry.HasField(TriggerValueField))
                {
                    throw new InvalidOperationException("The log provider failed on purpose.");
                }
            });
            AlertEvaluationService service = harness.CreateService(logger);

            // Act
            AlertEvaluationResult result = await service
                .RunCycleAsync(CancellationToken.None)
                .WaitAsync(WaitBound);

            // Assert
            TriggerAccounting expected = new(
                AlertEvaluationOutcome.Completed,
                CommittedTriggers: alertCount,
                ResultTriggered: alertCount,
                ResultFailed: 0,
                TriggeredMetric: alertCount,
                FailedMeasurements: 0
            );
            TriggerAccounting actual = new(
                result.Outcome,
                harness.Repository.TriggerCalls.Count(call => call.Result == true),
                result.Triggered,
                result.Failed,
                harness.Capture.Sum(PortfolioInsightsMetrics.TriggeredName, type),
                harness.Capture.Count(PortfolioInsightsMetrics.EvaluationFailedName)
            );
            Assert.Equal(expected, actual);
        }

        [Theory]
        [InlineData(AlertType.TARGET_PRICE)]
        [InlineData(AlertType.PROFIT_LOSS)]
        public async Task RunCycle_TriggerLogThrowsOnShutdown_ShouldCancelWithTriggerCounted(
            AlertType type
        )
        {
            // Arrange: shutdown arrives inside the committed trigger's log call, which then
            // fails, so the evaluator sees the throw while the cycle's token is cancelled.
            using EvaluationHarness harness = new();
            using CancellationTokenSource shutdown = new();
            harness.SeedCrossedAlerts(type, 1);
            ConcurrentQueue<string> messages = new();
            HookedLogger logger = new(entry =>
            {
                messages.Enqueue(entry.Message);
                if (entry.HasField(TriggerValueField))
                {
                    shutdown.Cancel();
                    throw new InvalidOperationException("The log provider failed on purpose.");
                }
            });
            AlertEvaluationService service = harness.CreateService(logger);

            // Act
            AlertEvaluationResult result = await service
                .RunCycleAsync(shutdown.Token)
                .WaitAsync(WaitBound);

            // Assert
            ShutdownAccounting expected = new(
                new TriggerAccounting(
                    AlertEvaluationOutcome.Cancelled,
                    CommittedTriggers: 1,
                    ResultTriggered: 1,
                    ResultFailed: 0,
                    TriggeredMetric: 1,
                    FailedMeasurements: 0
                ),
                SummaryRecords: 0,
                CancelledRecords: 1,
                DurationMeasurements: 0
            );
            ShutdownAccounting actual = new(
                new TriggerAccounting(
                    result.Outcome,
                    harness.Repository.TriggerCalls.Count(call => call.Result == true),
                    result.Triggered,
                    result.Failed,
                    harness.Capture.Sum(PortfolioInsightsMetrics.TriggeredName, type),
                    harness.Capture.Count(PortfolioInsightsMetrics.EvaluationFailedName)
                ),
                messages.Count(message =>
                    message.StartsWith(CycleFinishedPrefix, StringComparison.Ordinal)
                ),
                messages.Count(message =>
                    message.StartsWith(CycleCancelledPrefix, StringComparison.Ordinal)
                ),
                harness.Capture.Count(PortfolioInsightsMetrics.EvaluationDurationName)
            );
            Assert.Equal(expected, actual);
        }

        [Theory]
        [InlineData(AlertType.TARGET_PRICE)]
        [InlineData(AlertType.PROFIT_LOSS)]
        public async Task RunCycle_TriggerLogged_ShouldAlreadyHaveCountedTrigger(AlertType type)
        {
            // Arrange
            using EvaluationHarness harness = new();
            harness.SeedCrossedAlerts(type, 1);
            ConcurrentQueue<long> triggeredAtLogTime = new();
            HookedLogger logger = new(entry =>
            {
                if (entry.HasField(TriggerValueField))
                {
                    triggeredAtLogTime.Enqueue(
                        harness.Capture.Sum(PortfolioInsightsMetrics.TriggeredName, type)
                    );
                }
            });
            AlertEvaluationService service = harness.CreateService(logger);

            // Act
            await service.RunCycleAsync(CancellationToken.None).WaitAsync(WaitBound);

            // Assert
            long[] expected = [1];
            Assert.Equal(expected, triggeredAtLogTime.ToArray());
        }

        [Theory]
        [InlineData(ConcurrentRecord.Trigger)]
        [InlineData(ConcurrentRecord.Skip)]
        [InlineData(ConcurrentRecord.Failure)]
        public async Task RunCycle_WorkersLogAtOnce_ShouldWriteWholeLinesOneAtATime(
            ConcurrentRecord record
        )
        {
            // Arrange
            int workers = AlertEvaluationService.MaxAccountConcurrency;
            using EvaluationHarness harness = new();
            StartingGate gate = new(workers);
            if (record == ConcurrentRecord.Trigger)
            {
                harness.SeedCrossedAlerts(AlertType.TARGET_PRICE, workers);
                // Every worker returns from its committed write at the same moment, then logs.
                harness.Repository.AfterTrigger = (_, _, _) => gate.ArriveAndWaitAsync();
            }
            else
            {
                harness.SeedCrossedAlerts(AlertType.PROFIT_LOSS, workers);
                // Every worker's positions load returns at the same moment: empty, so its alert
                // is skipped as no_holding, or throwing, so its alert is a per-alert failure.
                harness.PositionsLoader = async _ =>
                {
                    await gate.ArriveAndWaitAsync();
                    if (record == ConcurrentRecord.Failure)
                    {
                        throw new InvalidOperationException(
                            "The positions load failed on purpose."
                        );
                    }
                    return [];
                };
            }
            SplitWriteConsoleLogger logger = new();
            AlertEvaluationService service = harness.CreateService(logger);

            // Act
            await service.RunCycleAsync(CancellationToken.None).WaitAsync(WaitBound);

            // Assert
            RenderedOutput expected = new(
                GateOpened: true,
                MaxConcurrentLogCalls: 1,
                AlertRecords: workers,
                Lines: logger.RecordedLines()
            );
            RenderedOutput actual = new(
                gate.Opened,
                logger.MaxConcurrentLogCalls,
                logger.AlertRecordCount,
                logger.WrittenLines()
            );
            Assert.Equal(expected, actual);
        }

        /// <summary>The trigger accounting a cycle leaves behind.</summary>
        private sealed record TriggerAccounting(
            AlertEvaluationOutcome Outcome,
            int CommittedTriggers,
            int ResultTriggered,
            int ResultFailed,
            long TriggeredMetric,
            int FailedMeasurements
        );

        /// <summary>
        /// The trigger accounting of a cycle ended by shutdown, with the summary and cancelled
        /// records it logged and the evaluation durations it recorded.
        /// </summary>
        private sealed record ShutdownAccounting(
            TriggerAccounting Triggers,
            int SummaryRecords,
            int CancelledRecords,
            int DurationMeasurements
        );

        /// <summary>
        /// What a split-write console provider rendered: whether the workers were released
        /// together, the most Log calls that ran at once, the per-alert record count, and the
        /// rendered lines in ordinal order.
        /// </summary>
        private sealed record RenderedOutput(
            bool GateOpened,
            int MaxConcurrentLogCalls,
            int AlertRecords,
            string Lines
        );

        /// <summary>
        /// Holds each arriving caller until <paramref name="participants"/> callers have arrived,
        /// then releases them all at once. Every wait is bounded by <see cref="WaitBound"/>.
        /// </summary>
        private sealed class StartingGate(int participants)
        {
            private readonly TaskCompletionSource _opened = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            private int _arrived;

            public bool Opened => _opened.Task.IsCompletedSuccessfully;

            public Task ArriveAndWaitAsync()
            {
                if (Interlocked.Increment(ref _arrived) == participants)
                {
                    _opened.TrySetResult();
                }
                return _opened.Task.WaitAsync(WaitBound);
            }
        }

        /// <summary>
        /// Writes like the console provider: the prefix, the message and the terminator of one
        /// record are separate writes to one shared output, each atomic on its own as a
        /// synchronized console writer's are, and the thread spins between them. It counts the
        /// Log calls running at once and keeps each record's whole line for comparison.
        /// </summary>
        private sealed class SplitWriteConsoleLogger : ILogger<AlertEvaluationService>
        {
            private const string CallerName = nameof(AlertEvaluationService);
            private const int SpinsBetweenWrites = 20;

            private readonly Lock _outputLock = new();
            private readonly StringBuilder _output = new();
            private readonly ConcurrentQueue<string> _records = new();
            private int _sequence;
            private int _activeCalls;
            private int _maxActiveCalls;
            private int _alertRecords;

            public int MaxConcurrentLogCalls => Volatile.Read(ref _maxActiveCalls);

            public int AlertRecordCount => Volatile.Read(ref _alertRecords);

            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                return null;
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                return logLevel != LogLevel.None;
            }

            public void Log<TState>(
                LogLevel logLevel,
                EventId eventId,
                TState state,
                Exception? exception,
                Func<TState, Exception?, string> formatter
            )
            {
                int active = Interlocked.Increment(ref _activeCalls);
                try
                {
                    RaiseMaxActiveCalls(active);
                    string prefix = $"[{Interlocked.Increment(ref _sequence)} | {logLevel}]";
                    string message = $" {formatter(state, exception)}";
                    string terminator = $" | {CallerName}";
                    _records.Enqueue(prefix + message + terminator);
                    if (
                        state is IEnumerable<KeyValuePair<string, object?>> pairs
                        && pairs.Any(pair => pair.Key == AlertIdField)
                    )
                    {
                        Interlocked.Increment(ref _alertRecords);
                    }

                    Write(prefix);
                    SpinBetweenWrites();
                    Write(message);
                    SpinBetweenWrites();
                    Write(terminator + "\n");
                }
                finally
                {
                    Interlocked.Decrement(ref _activeCalls);
                }
            }

            /// <summary>Each record's whole line, in ordinal order.</summary>
            public string RecordedLines()
            {
                return Sorted(_records);
            }

            /// <summary>The lines the shared output holds, in ordinal order.</summary>
            public string WrittenLines()
            {
                string written;
                lock (_outputLock)
                {
                    written = _output.ToString();
                }
                return Sorted(written.Split('\n', StringSplitOptions.RemoveEmptyEntries));
            }

            private static string Sorted(IEnumerable<string> lines)
            {
                return string.Join('\n', lines.Order(StringComparer.Ordinal));
            }

            // Widens the gap between two writes, as the provider's cursor handling does, by
            // spinning and yielding rather than sleeping.
            private static void SpinBetweenWrites()
            {
                SpinWait spinner = default;
                for (int spin = 0; spin < SpinsBetweenWrites; spin++)
                {
                    spinner.SpinOnce(sleep1Threshold: -1);
                }
            }

            private void Write(string text)
            {
                lock (_outputLock)
                {
                    _output.Append(text);
                }
            }

            private void RaiseMaxActiveCalls(int active)
            {
                int seen = Volatile.Read(ref _maxActiveCalls);
                while (active > seen)
                {
                    int previous = Interlocked.CompareExchange(ref _maxActiveCalls, active, seen);
                    if (previous == seen)
                    {
                        return;
                    }
                    seen = previous;
                }
            }
        }

        /// <summary>
        /// Hands each record to a hook as a <see cref="LogEntry"/>. A hook that throws fails the
        /// logging call, as a faulty log provider would.
        /// </summary>
        private sealed class HookedLogger(Action<LogEntry> hook) : ILogger<AlertEvaluationService>
        {
            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                return null;
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                return logLevel != LogLevel.None;
            }

            public void Log<TState>(
                LogLevel logLevel,
                EventId eventId,
                TState state,
                Exception? exception,
                Func<TState, Exception?, string> formatter
            )
            {
                KeyValuePair<string, object?>[] fields = state
                    is IEnumerable<KeyValuePair<string, object?>> pairs
                    ? [.. pairs]
                    : [];
                hook(
                    new LogEntry(
                        nameof(AlertEvaluationService),
                        logLevel,
                        eventId,
                        formatter(state, exception),
                        fields,
                        exception
                    )
                );
            }
        }

        /// <summary>
        /// Collects the counter and histogram measurements of the meters one
        /// <see cref="IMeterFactory"/> created, so instruments of other tests running at the same
        /// time are never seen.
        /// </summary>
        private sealed class MetricCapture : IDisposable
        {
            private readonly MeterListener _listener = new();
            private readonly ConcurrentQueue<CounterMeasurement> _measurements = new();

            // Histograms record doubles; only the instrument of each recording is kept.
            private readonly ConcurrentQueue<string> _histogramRecordings = new();

            public MetricCapture(IMeterFactory factory)
            {
                _listener.InstrumentPublished = (instrument, listener) =>
                {
                    if (ReferenceEquals(instrument.Meter.Scope, factory))
                    {
                        listener.EnableMeasurementEvents(instrument);
                    }
                };
                _listener.SetMeasurementEventCallback<long>(
                    (instrument, value, tags, _) =>
                        _measurements.Enqueue(
                            new CounterMeasurement(instrument.Name, value, AlertTypeOf(tags))
                        )
                );
                _listener.SetMeasurementEventCallback<double>(
                    (instrument, _, _, _) => _histogramRecordings.Enqueue(instrument.Name)
                );
                _listener.Start();
            }

            /// <summary>Sum of the measurements of one instrument tagged with one type.</summary>
            public long Sum(string instrumentName, AlertType type)
            {
                string tag = type.ToString();
                return _measurements
                    .Where(measurement =>
                        measurement.Instrument == instrumentName && measurement.AlertType == tag
                    )
                    .Sum(measurement => measurement.Value);
            }

            /// <summary>Number of measurements of one instrument, whatever their tags.</summary>
            public int Count(string instrumentName)
            {
                return _measurements.Count(measurement => measurement.Instrument == instrumentName)
                    + _histogramRecordings.Count(recorded => recorded == instrumentName);
            }

            public void Dispose()
            {
                _listener.Dispose();
            }

            private static string? AlertTypeOf(ReadOnlySpan<KeyValuePair<string, object?>> tags)
            {
                foreach (KeyValuePair<string, object?> tag in tags)
                {
                    if (tag.Key == PortfolioInsightsMetrics.AlertTypeTag)
                    {
                        return tag.Value as string;
                    }
                }
                return null;
            }

            private sealed record CounterMeasurement(
                string Instrument,
                long Value,
                string? AlertType
            );
        }

        /// <summary>
        /// Builds the real evaluator over in-memory fakes, an enabled flag and metrics from a
        /// factory of its own, and seeds alerts that every cycle finds crossed.
        /// </summary>
        private sealed class EvaluationHarness : IDisposable
        {
            private readonly ServiceProvider _provider;
            private readonly Dictionary<Guid, IReadOnlyList<HoldingPosition>> _positions = [];
            private readonly FakePriceServiceConnector _prices = new();
            private readonly Mock<IPortfolioInsightsService> _insights = new(MockBehavior.Strict);
            private readonly Mock<IPortfolioInsightsFeature> _feature = new(MockBehavior.Strict);
            private readonly PortfolioInsightsMetrics _metrics;

            public EvaluationHarness()
            {
                _provider = new ServiceCollection().AddMetrics().BuildServiceProvider();
                IMeterFactory factory = _provider.GetRequiredService<IMeterFactory>();
                Capture = new MetricCapture(factory);
                _metrics = new PortfolioInsightsMetrics(factory);
                PositionsLoader = LoadSeededPositions;
                _feature
                    .Setup(feature => feature.IsEnabledAsync(It.IsAny<CancellationToken>()))
                    .ReturnsAsync(true);
                _insights
                    .Setup(insights =>
                        insights.GetHoldingPositionsAsync(
                            It.IsAny<Guid>(),
                            It.IsAny<IReadOnlyDictionary<Guid, Price>>()
                        )
                    )
                    .Returns(
                        (Guid accountId, IReadOnlyDictionary<Guid, Price> _) =>
                            PositionsLoader(accountId)
                    );
            }

            public FakeAlertRepository Repository { get; } = new();

            public MetricCapture Capture { get; }

            /// <summary>
            /// Loads one account's positions for the evaluator; by default the seeded positions.
            /// </summary>
            public Func<Guid, Task<IReadOnlyList<HoldingPosition>>> PositionsLoader { get; set; }

            /// <summary>
            /// Seeds <paramref name="count"/> armed <see cref="AlertDirection.ABOVE"/> alerts of
            /// <paramref name="type"/>, each on its own account and instrument so each is its own
            /// work item, with a price and a holding that cross every one of them.
            /// </summary>
            public void SeedCrossedAlerts(AlertType type, int count)
            {
                for (int index = 0; index < count; index++)
                {
                    Guid accountId = Guid.NewGuid();
                    Guid instrumentId = Guid.NewGuid();
                    Repository.Seed(
                        new Alert(
                            Guid.NewGuid(),
                            accountId,
                            instrumentId,
                            type,
                            AlertDirection.ABOVE,
                            Threshold,
                            Enabled: true,
                            ArmingRevision: 1,
                            TriggeredAt: null,
                            TriggerValue: null,
                            Acknowledged: false,
                            CreatedAt: FakeAlertRepository.BaseTime.AddMinutes(index)
                        )
                    );
                    _prices.AddPrice(
                        new Price(
                            instrumentId,
                            PriceTime,
                            CrossingValue,
                            CrossingValue,
                            CrossingValue,
                            CrossingValue
                        )
                    );
                    _positions[accountId] =
                    [
                        new HoldingPosition(
                            instrumentId,
                            string.Empty,
                            Quantity: 1m,
                            LatestPrice: CrossingValue,
                            HasPrice: true,
                            Value: CrossingValue,
                            CostBasis: Threshold,
                            PnlPercent: CrossingValue
                        ),
                    ];
                }
            }

            public AlertEvaluationService CreateService(ILogger<AlertEvaluationService> logger)
            {
                return new AlertEvaluationService(
                    Repository,
                    _prices,
                    _insights.Object,
                    _feature.Object,
                    _metrics,
                    logger
                );
            }

            public void Dispose()
            {
                Capture.Dispose();
                _provider.Dispose();
            }

            private Task<IReadOnlyList<HoldingPosition>> LoadSeededPositions(Guid accountId)
            {
                return Task.FromResult(_positions.GetValueOrDefault(accountId) ?? []);
            }
        }
    }
}
