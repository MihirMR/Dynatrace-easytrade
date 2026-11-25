using System.Collections;
using System.Collections.Concurrent;
using System.Diagnostics.Metrics;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Host shutdown during one evaluation cycle. Each case cancels the cycle's token from inside
    /// the call it targets, so the point of cancellation is exact and nothing waits on time. A
    /// cancelled cycle ends <see cref="AlertEvaluationOutcome.Cancelled"/> with the Debug
    /// cancelled line only: no summary line, no duration, no failure for the cancellation, and
    /// every trigger committed before it still counted. The uncancelled flag-disabled cycle is
    /// covered beside its cancelled counterpart.
    /// </summary>
    public class AlertEvaluationCancellationTests
    {
        private const string CycleFinishedPrefix = "Alert evaluation cycle finished";
        private const string CycleCancelledPrefix = "Alert evaluation cycle cancelled";
        private const string CycleFailedPrefix = "Alert evaluation cycle failed";
        private const string AlertFailedText = "evaluation failed";
        private const string FlagSkippedMessage =
            "Alert evaluation skipped: portfolio insights flag disabled or unreadable";

        // Bounds every cycle, so a cycle that never ends fails its test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(10);

        // A cycle cancelled before any call returned data: only the cancelled line is left.
        private static readonly CycleEffects CancelledWithoutWork = new(
            AlertEvaluationOutcome.Cancelled,
            AlertCount: 0,
            Triggered: 0,
            Failed: 0,
            ListCalls: 0,
            PriceFetches: 0,
            PriceListReads: 0,
            PositionReads: 0,
            TriggerWrites: 0,
            SummaryLines: 0,
            CancelledLines: 1,
            FlagSkippedLines: 0,
            DurationMeasurements: 0,
            TriggeredMetric: 0,
            FailedMetric: 0
        );

        public enum CycleFailure
        {
            ListThrows,
            PricesThrow,
            PricesEmpty,
        }

        // Each path reaches the cycle summary from a different point of the cycle.
        public enum SummaryPath
        {
            EmptyArmedSet,
            ListFails,
            PricesFail,
            AllAlertsEvaluated,
        }

        public enum PriceCancellation
        {
            WhenFetchReturns,
            WhileListRead,
        }

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public async Task RunCycle_CancelledWhileFlagRead_ShouldReturnCancelledWithoutListing(
            bool flagValue
        )
        {
            // Arrange
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            harness.ReadFlag = _ =>
            {
                harness.Shutdown.Cancel();
                return Task.FromResult(flagValue);
            };

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(CancelledWithoutWork, effects);
        }

        [Fact]
        public async Task RunCycle_FlagDisabled_ShouldLogSkipWithoutListingPricingOrMetrics()
        {
            // Arrange
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            harness.ReadFlag = _ => Task.FromResult(false);

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    Outcome = AlertEvaluationOutcome.FlagDisabled,
                    CancelledLines = 0,
                    FlagSkippedLines = 1,
                },
                effects
            );
        }

        [Fact]
        public async Task RunCycle_CancelledWhileFlagSkipEnablementChecked_ShouldReturnCancelled()
        {
            // Arrange: the flag reads false after its token check passed, and the shutdown lands
            // inside the Debug enablement check of the skip line, standing in for one during
            // that check or the log-gate wait before it.
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            harness.ReadFlag = _ => Task.FromResult(false);
            harness.Logger.CancelWhenChecked = level => level == LogLevel.Debug;

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(CancelledWithoutWork, effects);
        }

        [Theory]
        [InlineData(0)]
        [InlineData(2)]
        public async Task RunCycle_CancelledAfterListReturns_ShouldReturnCancelledWithListedCount(
            int armedCount
        )
        {
            // Arrange
            using CycleHarness harness = new();
            for (int index = 0; index < armedCount; index++)
            {
                harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            }
            harness.Alerts.BeforeListReturns = (_, _) =>
            {
                harness.Shutdown.Cancel();
                return Task.CompletedTask;
            };

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = armedCount,
                    ListCalls = 1,
                },
                effects
            );
        }

        [Theory]
        [InlineData(CycleFailure.ListThrows)]
        [InlineData(CycleFailure.PricesThrow)]
        [InlineData(CycleFailure.PricesEmpty)]
        public async Task RunCycle_CancelledWhileCycleFailureLogged_ShouldReturnCancelled(
            CycleFailure failure
        )
        {
            // Arrange
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            harness.Logger.CancelWhen = (level, message) =>
                level == LogLevel.Error
                && message.StartsWith(CycleFailedPrefix, StringComparison.Ordinal);
            CycleEffects expected;
            switch (failure)
            {
                case CycleFailure.ListThrows:
                    harness.Alerts.ThrowOnNext(
                        FakeAlertRepositoryMethod.List,
                        new DbException("Db Adapter call error: unavailable")
                    );
                    expected = CancelledWithoutWork with { ListCalls = 1 };
                    break;

                case CycleFailure.PricesThrow:
                    harness.FetchPrices = () =>
                        Task.FromException<IEnumerable<Price>>(
                            new HttpRequestException("Pricing service unreachable")
                        );
                    expected = CancelledWithoutWork with
                    {
                        AlertCount = 1,
                        ListCalls = 1,
                        PriceFetches = 1,
                    };
                    break;

                case CycleFailure.PricesEmpty:
                    harness.PriceList = new TrackedPrices([]);
                    expected = CancelledWithoutWork with
                    {
                        AlertCount = 1,
                        ListCalls = 1,
                        PriceFetches = 1,
                        PriceListReads = 1,
                    };
                    break;

                default:
                    throw new ArgumentOutOfRangeException(nameof(failure), failure, null);
            }

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(expected, effects);
        }

        [Theory]
        [InlineData(SummaryPath.EmptyArmedSet)]
        [InlineData(SummaryPath.ListFails)]
        [InlineData(SummaryPath.PricesFail)]
        [InlineData(SummaryPath.AllAlertsEvaluated)]
        public async Task RunCycle_CancelledWhileSummaryEnablementChecked_ShouldReturnCancelled(
            SummaryPath path
        )
        {
            // Arrange: on these paths the summary makes the only Information enablement check,
            // so cancelling inside it lands after every earlier token check passed, standing in
            // for a shutdown during that check or the log-gate wait before it.
            using CycleHarness harness = new();
            harness.Logger.CancelWhenChecked = level => level == LogLevel.Information;
            CycleEffects expected;
            switch (path)
            {
                case SummaryPath.EmptyArmedSet:
                    expected = CancelledWithoutWork with { ListCalls = 1 };
                    break;

                case SummaryPath.ListFails:
                    harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
                    harness.Alerts.ThrowOnNext(
                        FakeAlertRepositoryMethod.List,
                        new DbException("Db Adapter call error: unavailable")
                    );
                    expected = CancelledWithoutWork with { ListCalls = 1 };
                    break;

                case SummaryPath.PricesFail:
                    harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
                    harness.FetchPrices = () =>
                        Task.FromException<IEnumerable<Price>>(
                            new HttpRequestException("Pricing service unreachable")
                        );
                    expected = CancelledWithoutWork with
                    {
                        AlertCount = 1,
                        ListCalls = 1,
                        PriceFetches = 1,
                    };
                    break;

                case SummaryPath.AllAlertsEvaluated:
                    // A close of 11 does not cross ABOVE 20, so no trigger line checks the level.
                    harness.SeedArmed(AlertType.TARGET_PRICE, 20m);
                    expected = CancelledWithoutWork with
                    {
                        AlertCount = 1,
                        ListCalls = 1,
                        PriceFetches = 1,
                        PriceListReads = 1,
                    };
                    break;

                default:
                    throw new ArgumentOutOfRangeException(nameof(path), path, null);
            }

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(expected, effects);
        }

        [Theory]
        [InlineData(PriceCancellation.WhenFetchReturns, 0)]
        [InlineData(PriceCancellation.WhileListRead, 1)]
        public async Task RunCycle_CancelledDuringPriceFetch_ShouldReturnCancelledBeforeAnyAlert(
            PriceCancellation point,
            int expectedListReads
        )
        {
            // Arrange
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            if (point == PriceCancellation.WhenFetchReturns)
            {
                harness.FetchPrices = () =>
                {
                    harness.Shutdown.Cancel();
                    return Task.FromResult<IEnumerable<Price>>(harness.PriceList);
                };
            }
            else
            {
                harness.PriceList = new TrackedPrices(harness.Candles, harness.Shutdown.Cancel);
            }

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = 1,
                    ListCalls = 1,
                    PriceFetches = 1,
                    PriceListReads = expectedListReads,
                },
                effects
            );
        }

        [Fact]
        public async Task RunCycle_CancelledDuringPositionsFailure_ShouldStopBeforeNextAlert()
        {
            // Arrange: one account whose positions read fails, so each of its three alerts
            // would be one failure; shutdown arrives while the first failure is logged.
            using CycleHarness harness = new();
            for (int index = 0; index < 3; index++)
            {
                harness.SeedArmed(AlertType.PROFIT_LOSS, 5m);
            }
            harness.ReadPositions = (_, _) =>
                Task.FromException<IReadOnlyList<HoldingPosition>>(
                    new DbException("Db Adapter call error: unavailable")
                );
            harness.Logger.CancelWhen = (level, message) =>
                level == LogLevel.Error
                && message.Contains(AlertFailedText, StringComparison.Ordinal);

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = 3,
                    Failed = 1,
                    ListCalls = 1,
                    PriceFetches = 1,
                    PriceListReads = 1,
                    PositionReads = 1,
                    FailedMetric = 1,
                },
                effects
            );
        }

        [Fact]
        public async Task RunCycle_CancelledBeforeProfitLossItemStarts_ShouldNotReadPositions()
        {
            // Arrange: the loop takes the target-price items first, one per worker, and holds
            // each worker at its committed trigger, so the one P/L item waits undispatched.
            // Cancellation callbacks run in reverse registration order, so the shutdown runs the
            // release registered below before the loop's own callback: the cycle token is
            // already cancelled while the loop has not seen it. Only one worker is released, and
            // only once every worker has parked, so it resumes inline in that callback, passes
            // the loop's own check and starts the P/L item with the cancelled token. Only the
            // item's entry check then keeps the tokenless positions read from starting.
            using CycleHarness harness = new();
            int held = AlertEvaluationService.MaxAccountConcurrency;
            for (int index = 0; index < held; index++)
            {
                harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            }
            harness.SeedArmed(AlertType.PROFIT_LOSS, 5m);
            TriggerHolds holds = new(held);
            harness.Alerts.AfterTrigger = (_, _, _) => holds.Hold();

            // Act
            Task<CycleEffects> cycle = holds.Observe(harness.RunAsync);
            await holds.AllParked.WaitAsync(WaitBound);
            TaskCompletionSource[] parked = holds.Parked();
            using (harness.Shutdown.Token.Register(parked[0].SetResult))
            {
                // Cancelled off the test's synchronization context, which would otherwise keep
                // the released worker from resuming inline.
                await Task.Run(harness.Shutdown.Cancel).WaitAsync(WaitBound);
            }
            foreach (TaskCompletionSource hold in parked.Skip(1))
            {
                hold.SetResult();
            }
            CycleEffects effects = await cycle;

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = held + 1,
                    Triggered = held,
                    ListCalls = 1,
                    PriceFetches = 1,
                    PriceListReads = 1,
                    TriggerWrites = held,
                    TriggeredMetric = held,
                },
                effects
            );
        }

        [Fact]
        public async Task RunCycle_CancelledAfterCommittedTrigger_ShouldKeepTriggerCounted()
        {
            // Arrange: two crossing alerts of one account run in order; shutdown arrives once
            // the first trigger is committed and before its write returns.
            using CycleHarness harness = new();
            Guid secondInstrumentId = Guid.NewGuid();
            harness.SeedArmed(AlertType.PROFIT_LOSS, 5m);
            harness.SeedArmed(AlertType.PROFIT_LOSS, 5m, secondInstrumentId);
            harness.ReadPositions = (_, _) =>
                Task.FromResult<IReadOnlyList<HoldingPosition>>(
                    [CrossingPosition(harness.InstrumentId), CrossingPosition(secondInstrumentId)]
                );
            harness.Alerts.AfterTrigger = (_, _, _) =>
            {
                harness.Shutdown.Cancel();
                return Task.CompletedTask;
            };

            // Act
            CycleEffects effects = await harness.RunAsync();

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = 2,
                    Triggered = 1,
                    ListCalls = 1,
                    PriceFetches = 1,
                    PriceListReads = 1,
                    PositionReads = 1,
                    TriggerWrites = 1,
                    TriggeredMetric = 1,
                },
                effects
            );
        }

        [Fact]
        public async Task RunCycle_CancelledAfterLastAlertEvaluated_ShouldReturnCancelled()
        {
            // Arrange: the only alert's trigger is held until the cycle is parked on its
            // parallel loop, so the loop's continuation is always posted to the context, which
            // cancels after every alert was evaluated and before the cycle finishes.
            using CycleHarness harness = new();
            harness.SeedArmed(AlertType.TARGET_PRICE, 10m);
            TaskCompletionSource triggerGate = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            harness.Alerts.AfterTrigger = (_, _, _) => triggerGate.Task;

            // Act
            CycleEffects effects = await harness.RunUnderContextAsync(
                new CancelOnPostContext(harness.Shutdown),
                triggerGate
            );

            // Assert
            Assert.Equal(
                CancelledWithoutWork with
                {
                    AlertCount = 1,
                    Triggered = 1,
                    ListCalls = 1,
                    PriceFetches = 1,
                    PriceListReads = 1,
                    TriggerWrites = 1,
                    TriggeredMetric = 1,
                },
                effects
            );
        }

        // A held position whose P/L of 10 % crosses an ABOVE 5 threshold.
        private static HoldingPosition CrossingPosition(Guid instrumentId)
        {
            return new HoldingPosition(
                instrumentId,
                string.Empty,
                Quantity: 1m,
                LatestPrice: 11m,
                HasPrice: true,
                Value: 11m,
                CostBasis: 10m,
                PnlPercent: 10m
            );
        }

        /// <summary>
        /// Everything one cycle leaves observable, compared as one value per case.
        /// </summary>
        private sealed record CycleEffects(
            AlertEvaluationOutcome Outcome,
            int AlertCount,
            int Triggered,
            int Failed,
            int ListCalls,
            int PriceFetches,
            int PriceListReads,
            int PositionReads,
            int TriggerWrites,
            int SummaryLines,
            int CancelledLines,
            int FlagSkippedLines,
            int DurationMeasurements,
            double TriggeredMetric,
            double FailedMetric
        );

        /// <summary>
        /// A price list read only when enumerated, as a lazy sequence from the price connector
        /// would be. It counts its reads and can run an action as each read starts.
        /// </summary>
        private sealed class TrackedPrices(IReadOnlyList<Price> candles, Action? onRead = null)
            : IEnumerable<Price>
        {
            private int _reads;

            public int Reads => Volatile.Read(ref _reads);

            public IEnumerator<Price> GetEnumerator()
            {
                Interlocked.Increment(ref _reads);
                onRead?.Invoke();
                return candles.GetEnumerator();
            }

            IEnumerator IEnumerable.GetEnumerator()
            {
                return GetEnumerator();
            }
        }

        /// <summary>
        /// Records every call into the shared sink, then cancels the cycle when
        /// <see cref="CancelWhen"/> matches it, so a shutdown lands inside that exact log call.
        /// <see cref="CancelWhenChecked"/> does the same for an enablement check.
        /// </summary>
        private sealed class CancellingLogger(
            ILogger<AlertEvaluationService> inner,
            CancellationTokenSource shutdown
        ) : ILogger<AlertEvaluationService>
        {
            public Func<LogLevel, string, bool>? CancelWhen { get; set; }

            /// <summary>
            /// Cancels the cycle inside every <see cref="IsEnabled"/> call whose level it
            /// matches, after the inner logger answered.
            /// </summary>
            public Func<LogLevel, bool>? CancelWhenChecked { get; set; }

            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                return inner.BeginScope(state);
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                bool enabled = inner.IsEnabled(logLevel);
                Func<LogLevel, bool>? cancelWhenChecked = CancelWhenChecked;
                if (cancelWhenChecked is not null && cancelWhenChecked(logLevel))
                {
                    shutdown.Cancel();
                }
                return enabled;
            }

            public void Log<TState>(
                LogLevel logLevel,
                EventId eventId,
                TState state,
                Exception? exception,
                Func<TState, Exception?, string> formatter
            )
            {
                inner.Log(logLevel, eventId, state, exception, formatter);
                Func<LogLevel, string, bool>? cancelWhen = CancelWhen;
                if (cancelWhen is not null && cancelWhen(logLevel, formatter(state, exception)))
                {
                    shutdown.Cancel();
                }
            }
        }

        /// <summary>
        /// Captures the measurements of instruments created through one meter factory, so
        /// tests running in parallel never see each other's measurements.
        /// </summary>
        private sealed class MetricCapture : IDisposable
        {
            private readonly MeterListener _listener = new();
            private readonly ConcurrentQueue<Measurement> _measurements = new();

            public MetricCapture(IMeterFactory meterFactory)
            {
                _listener.InstrumentPublished = (instrument, listener) =>
                {
                    if (ReferenceEquals(instrument.Meter.Scope, meterFactory))
                    {
                        listener.EnableMeasurementEvents(instrument);
                    }
                };
                _listener.SetMeasurementEventCallback<double>(
                    (instrument, value, _, _) =>
                        _measurements.Enqueue(new Measurement(instrument.Name, value))
                );
                _listener.SetMeasurementEventCallback<long>(
                    (instrument, value, _, _) =>
                        _measurements.Enqueue(new Measurement(instrument.Name, value))
                );
                _listener.Start();
            }

            public int Count(string instrumentName)
            {
                return _measurements.Count(measurement => measurement.Instrument == instrumentName);
            }

            public double Sum(string instrumentName)
            {
                return _measurements
                    .Where(measurement => measurement.Instrument == instrumentName)
                    .Sum(measurement => measurement.Value);
            }

            public void Dispose()
            {
                _listener.Dispose();
            }

            private readonly record struct Measurement(string Instrument, double Value);
        }

        /// <summary>
        /// Cancels the cycle as an awaited continuation is posted to it, then runs that
        /// continuation on the thread pool, so the shutdown lands after the awaited operation
        /// finished and before the code after the await runs.
        /// </summary>
        private sealed class CancelOnPostContext(CancellationTokenSource shutdown)
            : SynchronizationContext
        {
            public override void Post(SendOrPostCallback d, object? state)
            {
                shutdown.Cancel();
                ThreadPool.QueueUserWorkItem(d.Invoke, state);
            }
        }

        /// <summary>
        /// Holds every trigger write that reaches <see cref="Hold"/> on a hold of its own, and
        /// completes <see cref="AllParked"/> once that many loop workers have parked: each
        /// worker's thread-pool work item has returned, so the whole await chain above its hold
        /// is registered and releasing the hold resumes that worker inline. A return is seen as
        /// the worker's thread leaving the execution context the loop captured at its start,
        /// which <see cref="Observe"/> marks.
        /// </summary>
        private sealed class TriggerHolds
        {
            private readonly object _marker = new();
            private readonly int _expected;
            private readonly AsyncLocal<object?> _context;
            private readonly ConcurrentQueue<TaskCompletionSource> _holds = new();
            private readonly ConcurrentDictionary<int, int> _unparked = new();
            private readonly TaskCompletionSource _allParked = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            private int _parked;

            public TriggerHolds(int expected)
            {
                _expected = expected;
                _context = new AsyncLocal<object?>(OnContextChanged);
            }

            public Task AllParked => _allParked.Task;

            /// <summary>Starts <paramref name="start"/> under the marked context.</summary>
            public Task<T> Observe<T>(Func<Task<T>> start)
            {
                _context.Value = _marker;
                try
                {
                    return start();
                }
                finally
                {
                    _context.Value = null;
                }
            }

            public Task Hold()
            {
                TaskCompletionSource hold = new();
                _holds.Enqueue(hold);
                _unparked.AddOrUpdate(
                    Environment.CurrentManagedThreadId,
                    1,
                    (_, count) => count + 1
                );
                return hold.Task;
            }

            /// <summary>The holds in the order the workers reached them.</summary>
            public TaskCompletionSource[] Parked()
            {
                return [.. _holds];
            }

            // Runs on the thread whose context changed, so each thread's count is only ever
            // changed by that thread.
            private void OnContextChanged(AsyncLocalValueChangedArgs<object?> change)
            {
                int thread = Environment.CurrentManagedThreadId;
                if (
                    change.ThreadContextChanged
                    && ReferenceEquals(change.PreviousValue, _marker)
                    && change.CurrentValue is null
                    && _unparked.TryGetValue(thread, out int count)
                    && count > 0
                )
                {
                    _unparked[thread] = count - 1;
                    if (Interlocked.Increment(ref _parked) == _expected)
                    {
                        _allParked.TrySetResult();
                    }
                }
            }
        }

        /// <summary>
        /// One <see cref="AlertEvaluationService"/> over the alert fake, strict mocks of the
        /// flag, pricing and positions reads, a recording logger and a metric capture. The
        /// delegates decide what each mocked call does, so a case can cancel
        /// <see cref="Shutdown"/> from inside the call it targets.
        /// </summary>
        private sealed class CycleHarness : IDisposable
        {
            private readonly Mock<IPortfolioInsightsFeature> _feature = new(MockBehavior.Strict);
            private readonly Mock<IPriceServiceConnector> _prices = new(MockBehavior.Strict);
            private readonly Mock<IPortfolioInsightsService> _insights = new(MockBehavior.Strict);
            private readonly ServiceProvider _provider;
            private readonly MetricCapture _metrics;
            private readonly AlertEvaluationService _service;

            public CycleHarness()
            {
                Candles =
                [
                    new Price(InstrumentId, FakeAlertRepository.BaseTime, 11m, 11m, 11m, 11m),
                ];
                PriceList = new TrackedPrices(Candles);
                ReadFlag = _ => Task.FromResult(true);
                FetchPrices = () => Task.FromResult<IEnumerable<Price>>(PriceList);
                ReadPositions = (_, _) => Task.FromResult<IReadOnlyList<HoldingPosition>>([]);
                Logger = new CancellingLogger(
                    new RecordingLogger<AlertEvaluationService>(Sink),
                    Shutdown
                );

                _feature
                    .Setup(feature => feature.IsEnabledAsync(It.IsAny<CancellationToken>()))
                    .Returns((CancellationToken token) => ReadFlag(token));
                _prices
                    .Setup(connector => connector.GetLatestPrices())
                    .Returns(() => FetchPrices());
                _insights
                    .Setup(service =>
                        service.GetHoldingPositionsAsync(
                            It.IsAny<Guid>(),
                            It.IsAny<IReadOnlyDictionary<Guid, Price>>()
                        )
                    )
                    .Returns(
                        (Guid accountId, IReadOnlyDictionary<Guid, Price> selected) =>
                            ReadPositions(accountId, selected)
                    );

                _provider = new ServiceCollection().AddMetrics().BuildServiceProvider();
                IMeterFactory meterFactory = _provider.GetRequiredService<IMeterFactory>();
                _metrics = new MetricCapture(meterFactory);
                _service = new AlertEvaluationService(
                    Alerts,
                    _prices.Object,
                    _insights.Object,
                    _feature.Object,
                    new PortfolioInsightsMetrics(meterFactory),
                    Logger
                );
            }

            public Guid AccountId { get; } = Guid.NewGuid();

            public Guid InstrumentId { get; } = Guid.NewGuid();

            /// <summary>One candle of <see cref="InstrumentId"/> with a close of 11.</summary>
            public IReadOnlyList<Price> Candles { get; }

            public FakeAlertRepository Alerts { get; } = new();

            public CancellationTokenSource Shutdown { get; } = new();

            public RecordingLogSink Sink { get; } = new();

            public CancellingLogger Logger { get; }

            /// <summary>What <c>IsEnabledAsync</c> returns; true by default.</summary>
            public Func<CancellationToken, Task<bool>> ReadFlag { get; set; }

            /// <summary>The list the default <see cref="FetchPrices"/> returns.</summary>
            public TrackedPrices PriceList { get; set; }

            /// <summary>
            /// What <c>GetLatestPrices</c> returns; <see cref="PriceList"/> by default.
            /// </summary>
            public Func<Task<IEnumerable<Price>>> FetchPrices { get; set; }

            /// <summary>
            /// What <c>GetHoldingPositionsAsync</c> returns; no positions by default.
            /// </summary>
            public Func<
                Guid,
                IReadOnlyDictionary<Guid, Price>,
                Task<IReadOnlyList<HoldingPosition>>
            > ReadPositions { get; set; }

            /// <summary>Seeds one armed ABOVE alert of <see cref="AccountId"/>.</summary>
            public void SeedArmed(AlertType type, decimal threshold, Guid? instrumentId = null)
            {
                Alerts.Seed(
                    new Alert(
                        Guid.NewGuid(),
                        AccountId,
                        instrumentId ?? InstrumentId,
                        type,
                        AlertDirection.ABOVE,
                        threshold,
                        Enabled: true,
                        ArmingRevision: 1,
                        TriggeredAt: null,
                        TriggerValue: null,
                        Acknowledged: false,
                        CreatedAt: FakeAlertRepository.BaseTime
                    )
                );
            }

            /// <summary>
            /// Runs one cycle on the <see cref="Shutdown"/> token and collects its effects.
            /// </summary>
            public Task<CycleEffects> RunAsync()
            {
                return CollectAsync(_service.RunCycleAsync(Shutdown.Token));
            }

            /// <summary>
            /// Starts one cycle while <paramref name="context"/> is current, so the first await
            /// at which the cycle yields posts its continuation there, then opens
            /// <paramref name="gate"/> and collects the cycle's effects.
            /// </summary>
            public Task<CycleEffects> RunUnderContextAsync(
                SynchronizationContext context,
                TaskCompletionSource gate
            )
            {
                SynchronizationContext? previous = SynchronizationContext.Current;
                SynchronizationContext.SetSynchronizationContext(context);
                Task<AlertEvaluationResult> cycle;
                try
                {
                    cycle = _service.RunCycleAsync(Shutdown.Token);
                }
                finally
                {
                    SynchronizationContext.SetSynchronizationContext(previous);
                }
                gate.SetResult();
                return CollectAsync(cycle);
            }

            public void Dispose()
            {
                _metrics.Dispose();
                _provider.Dispose();
                Shutdown.Dispose();
            }

            private async Task<CycleEffects> CollectAsync(Task<AlertEvaluationResult> cycle)
            {
                AlertEvaluationResult result = await cycle.WaitAsync(WaitBound);
                return new CycleEffects(
                    result.Outcome,
                    result.AlertCount,
                    result.Triggered,
                    result.Failed,
                    Alerts.ListCallCount,
                    CountCalls(_prices, nameof(IPriceServiceConnector.GetLatestPrices)),
                    PriceList.Reads,
                    CountCalls(
                        _insights,
                        nameof(IPortfolioInsightsService.GetHoldingPositionsAsync)
                    ),
                    Alerts.TriggerCalls.Count,
                    Sink.WithMessageStartingWith(CycleFinishedPrefix).Count,
                    Sink.WithMessageStartingWith(CycleCancelledPrefix).Count,
                    Sink.ByLevel(LogLevel.Debug)
                        .Count(entry =>
                            string.Equals(
                                entry.Message,
                                FlagSkippedMessage,
                                StringComparison.Ordinal
                            )
                        ),
                    _metrics.Count(PortfolioInsightsMetrics.EvaluationDurationName),
                    _metrics.Sum(PortfolioInsightsMetrics.TriggeredName),
                    _metrics.Sum(PortfolioInsightsMetrics.EvaluationFailedName)
                );
            }

            private static int CountCalls<T>(Mock<T> mock, string methodName)
                where T : class
            {
                return mock.Invocations.Count(invocation => invocation.Method.Name == methodName);
            }
        }
    }
}
