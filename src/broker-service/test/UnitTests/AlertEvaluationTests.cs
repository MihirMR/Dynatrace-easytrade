using System.Threading.Channels;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;
// System.Diagnostics.Metrics also declares an Instrument type, so only the factory is imported.
using IMeterFactory = System.Diagnostics.Metrics.IMeterFactory;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Cycle tests of <see cref="AlertEvaluationService"/>, each driving
    /// <see cref="AlertEvaluationService.RunCycleAsync"/>. The concurrency case checks the bound on
    /// concurrent work and the reuse of per-cycle data through the real
    /// <see cref="PortfolioInsightsService"/> positions path. Every positions load is held until
    /// the test releases it, one at a time in arrival order, so the loads in flight are observed
    /// at each step without waiting on time.
    /// </summary>
    public class AlertEvaluationTests
    {
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
        /// TARGET_PRICE alerts and no holding. Both candles share one timestamp.
        /// </summary>
        private sealed class ConcurrencyHarness : IDisposable
        {
            private readonly ServiceProvider _provider;
            private readonly Guid[] _profitLossAccounts;
            private readonly Price[] _candles = [Candle(FirstClose), Candle(SecondClose)];
            private readonly CountingPriceServiceConnector _prices;
            private readonly FakeAlertRepository _alerts = new();

            public ConcurrencyHarness()
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
                        instruments,
                        trades,
                        _prices,
                        metrics,
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
    }
}
