using System.Collections;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;
using EasyTrade.BrokerService.Entities.Trades.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;
// System.Diagnostics.Metrics also declares an Instrument type, so only the factory is imported.
using IMeterFactory = System.Diagnostics.Metrics.IMeterFactory;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class PortfolioInsightsTests
    {
        private static readonly Guid AccountId = new("a0000000-0000-4000-8000-000000000001");

        // Their canonical lowercase strings sort ordinally in declaration order.
        private static readonly Guid LowInstrumentId = new("00000000-0000-0000-0000-00000000000a");
        private static readonly Guid MidInstrumentId = new("00000000-0000-0000-0000-00000000000b");
        private static readonly Guid HighInstrumentId = new("00000000-0000-0000-0000-00000000000c");

        // Trade ids that differ only in their last byte, so Guid comparison orders them
        // unambiguously in declaration order.
        private static readonly Guid LowReplayId = new("d0000000-0000-4000-8000-000000000001");
        private static readonly Guid MidReplayId = new("d0000000-0000-4000-8000-000000000002");
        private static readonly Guid HighReplayId = new("d0000000-0000-4000-8000-000000000003");

        private static readonly DateTimeOffset Time = new(2025, 1, 1, 12, 0, 0, TimeSpan.Zero);

        private static readonly IReadOnlyDictionary<Guid, string> NoNames =
            new Dictionary<Guid, string>();
        private static readonly IReadOnlyDictionary<Guid, Price> NoPrices =
            new Dictionary<Guid, Price>();

        // Public, not private: xUnit passes them to public theories, and a public method cannot
        // take a parameter of a less accessible type.
        public enum EdgeInput
        {
            ZeroTotalFromOffsettingSignedValues,
            ZeroTotalWithLowestIdBetweenSignedValues,
            ZeroTotalFromZeroPrices,
            TiedLargestValue,
        }

        public enum NoPositiveHolding
        {
            NoRows,
            ZeroQuantityOnly,
        }

        public enum ServiceScenario
        {
            NullCandleInPriceList,
            ZeroAndNegativeCloses,
        }

        public enum ReplayOrder
        {
            OpenTimeOutranksInputAndId,
            IdBreaksOpenTimeTie,
        }

        public enum PositionsScenario
        {
            AllHoldingsPriced,
            OneHoldingUnpriced,
            NoPositiveQuantity,
        }

        public enum PositionsFailure
        {
            HoldingsRead,
            TradesRead,
        }

        [Theory]
        [InlineData(EdgeInput.ZeroTotalFromOffsettingSignedValues)]
        [InlineData(EdgeInput.ZeroTotalWithLowestIdBetweenSignedValues)]
        [InlineData(EdgeInput.ZeroTotalFromZeroPrices)]
        [InlineData(EdgeInput.TiedLargestValue)]
        public void CalculateInsights_EdgeInput_ShouldMatchContract(EdgeInput edgeInput)
        {
            // Arrange
            EdgeCase edgeCase = BuildEdgeCase(edgeInput);

            // Act
            IReadOnlyList<HoldingPosition> positions = PortfolioInsightsCalculator.BuildPositions(
                edgeCase.Holdings,
                NoNames,
                [],
                LatestPriceSelector.Select(edgeCase.Candles)
            );
            PortfolioInsightsDTO insights = PortfolioInsightsCalculator.Calculate(positions);

            // Assert
            Assert.Equal(edgeCase.TotalValue, insights.TotalValue);
            Assert.Equal(
                edgeCase.Allocations,
                insights.Allocations.Select(allocation =>
                    (allocation.InstrumentId, allocation.Value, allocation.Percent)
                )
            );
            Assert.Equal(edgeCase.LargestId, insights.LargestPosition?.InstrumentId);
            Assert.Equal(edgeCase.RiskLevel, insights.RiskLevel);
        }

        [Theory]
        [InlineData(NoPositiveHolding.NoRows)]
        [InlineData(NoPositiveHolding.ZeroQuantityOnly)]
        public void BuildPositions_NoPositiveHolding_ShouldNotEnumerateTrades(
            NoPositiveHolding noPositiveHolding
        )
        {
            // Arrange
            OwnedInstrument[] holdings = BuildHoldings(noPositiveHolding);

            // Act
            IReadOnlyList<HoldingPosition> positions = PortfolioInsightsCalculator.BuildPositions(
                holdings,
                NoNames,
                new UnreadableTrades(),
                NoPrices
            );

            // Assert
            Assert.Empty(positions);
        }

        [Fact]
        public void BuildPositions_DuplicateHoldingRows_ShouldCostEachRowFromInstrumentTrades()
        {
            // Arrange
            // The low instrument replays buy 6 at 100, sell 3, buy 3 at 130 once ordered by open
            // time; its open long buy is not executed. The list is out of time order and
            // interleaved with the mid instrument's trade.
            Trade lateBuy = QuickTrade(LowInstrumentId, "buy", 3, 130, Time.AddMinutes(2));
            Trade sell = QuickTrade(LowInstrumentId, "sell", 3, 120, Time.AddMinutes(1));
            Trade openLongBuy = new(
                AccountId,
                LowInstrumentId,
                "longbuy",
                7,
                90,
                Time.AddSeconds(90),
                Time.AddHours(1),
                false,
                false,
                "LongBuy registered."
            );
            Trade earlyBuy = QuickTrade(LowInstrumentId, "buy", 6, 100, Time);
            Trade midBuy = QuickTrade(MidInstrumentId, "buy", 3, 50, Time);
            Dictionary<Guid, Trade[]> instrumentTrades = new()
            {
                [LowInstrumentId] = [lateBuy, sell, openLongBuy, earlyBuy],
                [MidInstrumentId] = [midBuy],
            };
            Trade[] trades = [lateBuy, midBuy, sell, openLongBuy, earlyBuy];
            OwnedInstrument[] holdings =
            [
                Holding(LowInstrumentId, 10),
                Holding(MidInstrumentId, 3),
                Holding(LowInstrumentId, 4),
            ];
            IReadOnlyDictionary<Guid, Price> prices = LatestPriceSelector.Select(
                [Candle(LowInstrumentId, 110), Candle(MidInstrumentId, 60)]
            );

            // Act
            IReadOnlyList<HoldingPosition> positions = PortfolioInsightsCalculator.BuildPositions(
                holdings,
                NoNames,
                trades,
                prices
            );

            // Assert
            // 10 units: Q0 = 10 - 9 + 3 = 4 at 110 is 440; the buy makes 1,040 for 10; the sell
            // removes 312, leaving 728 for 7; the last buy makes 1,118 for 10.
            // 4 units: Q0 = 0; 600 for 6; 300 for 3; 690 for 6, so 690 / 6 * 4 = 460.
            // 3 mid units: Q0 = 0 and one buy of 3 at 50, so 150.
            (Guid, decimal, decimal)[] expected =
            [
                (LowInstrumentId, 10, 1118),
                (MidInstrumentId, 3, 150),
                (LowInstrumentId, 4, 460),
            ];
            Assert.Equal(
                expected,
                positions.Select(position =>
                    (position.InstrumentId, position.Quantity, position.CostBasis)
                )
            );
            Assert.Equal(
                positions.Select(position =>
                    PortfolioInsightsCalculator.CalculateCostBasis(
                        position.Quantity,
                        position.LatestPrice,
                        instrumentTrades[position.InstrumentId]
                    )
                ),
                positions.Select(position => position.CostBasis)
            );
        }

        [Theory]
        [InlineData(ReplayOrder.OpenTimeOutranksInputAndId)]
        [InlineData(ReplayOrder.IdBreaksOpenTimeTie)]
        public void CalculateCostBasis_ShuffledHistory_ShouldReplayByOpenTimeThenId(
            ReplayOrder replayOrder
        )
        {
            // Arrange
            // Each history replays as buy 10 at 100, sell 5, buy 10 at 200. The 15 units equal
            // 20 bought less 5 sold, so there is no opening lot.
            Trade[] trades = BuildReplayHistory(replayOrder);

            // Act
            decimal costBasis = PortfolioInsightsCalculator.CalculateCostBasis(15, 150, trades);

            // Assert
            // 1,000 for 10; the sale removes 500, leaving 500 for 5; the buy makes 2,500 for 15.
            Assert.Equal(2500, costBasis);
        }

        [Theory]
        [InlineData(ServiceScenario.NullCandleInPriceList)]
        [InlineData(ServiceScenario.ZeroAndNegativeCloses)]
        public async Task GetInsights_Scenario_ShouldMatchContract(ServiceScenario scenario)
        {
            // Arrange
            ServiceCase serviceCase = BuildServiceCase(scenario);
            using ServiceProvider services = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            PortfolioInsightsService service = new(
                new FakeBalanceRepository().AddBalance(new Balance(AccountId, 1000)),
                serviceCase.Instruments,
                new FakeTradeRepository(),
                serviceCase.Prices,
                new PortfolioInsightsMetrics(services.GetRequiredService<IMeterFactory>()),
                new RecordingLogger<PortfolioInsightsService>()
            );
            PortfolioInsightsDTO? insights = null;

            // Act
            Exception? error = await Record.ExceptionAsync(
                async () => insights = await service.GetInsightsAsync(AccountId)
            );

            // Assert
            Assert.Equal(
                serviceCase.Expected,
                new ServiceOutcome(
                    error?.GetType(),
                    insights?.TotalValue,
                    insights?.Allocations.Count()
                )
            );
        }

        [Theory]
        [InlineData(PositionsScenario.AllHoldingsPriced)]
        [InlineData(PositionsScenario.OneHoldingUnpriced)]
        [InlineData(PositionsScenario.NoPositiveQuantity)]
        public async Task GetHoldingPositions_Scenario_ShouldValueAtSuppliedPrices(
            PositionsScenario scenario
        )
        {
            // Arrange
            PositionsCase positionsCase = BuildPositionsCase(scenario);
            using ServiceProvider services = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            PortfolioInsightsService service = BuildPositionsService(
                StubPositionsReads(positionsCase),
                services
            );

            // Act
            IReadOnlyList<HoldingPosition> positions = await service.GetHoldingPositionsAsync(
                AccountId,
                positionsCase.Prices
            );

            // Assert
            Assert.Equal(
                positionsCase.Expected,
                positions.Select(position =>
                    (
                        position.InstrumentId,
                        position.Quantity,
                        position.LatestPrice,
                        position.HasPrice,
                        position.Value,
                        position.CostBasis,
                        position.PnlPercent
                    )
                )
            );
        }

        [Fact]
        public async Task GetHoldingPositions_SuppliedPrices_ShouldReadOnlyHoldingsAndTradesOnce()
        {
            // Arrange
            PositionsCase positionsCase = BuildPositionsCase(PositionsScenario.AllHoldingsPriced);
            PositionsMocks mocks = StubPositionsReads(positionsCase);
            using ServiceProvider services = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            PortfolioInsightsService service = BuildPositionsService(mocks, services);

            // Act
            _ = await service.GetHoldingPositionsAsync(AccountId, positionsCase.Prices);

            // Assert
            // The two reads happened once each, and nothing else was called: no balance check,
            // no instrument catalog and no price fetch.
            mocks.Instruments.Verify(
                repository => repository.GetOwnedInstrumentsOfAccountAsync(AccountId),
                Times.Once()
            );
            mocks.Trades.Verify(
                repository => repository.GetAccountTradesAsync(AccountId, false, false),
                Times.Once()
            );
            mocks.Balance.VerifyNoOtherCalls();
            mocks.Instruments.VerifyNoOtherCalls();
            mocks.Trades.VerifyNoOtherCalls();
            mocks.Prices.VerifyNoOtherCalls();
        }

        [Theory]
        [InlineData(PositionsFailure.HoldingsRead)]
        [InlineData(PositionsFailure.TradesRead)]
        public async Task GetHoldingPositions_RepositoryFails_ShouldPropagate(
            PositionsFailure failingRead
        )
        {
            // Arrange
            // GrpcHelper reports every failed db-adapter call as a DbException.
            DbException failure = new("Db Adapter call error");
            PositionsCase positionsCase = BuildPositionsCase(PositionsScenario.AllHoldingsPriced);
            PositionsMocks mocks = StubPositionsReads(positionsCase);
            FailPositionsRead(mocks, failingRead, failure);
            using ServiceProvider services = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            PortfolioInsightsService service = BuildPositionsService(mocks, services);

            // Act
            Exception? error = await Record.ExceptionAsync(
                () => service.GetHoldingPositionsAsync(AccountId, positionsCase.Prices)
            );

            // Assert
            Assert.Same(failure, error);
        }

        [Fact]
        public async Task GetHoldingPositions_NullPrices_ShouldThrowArgumentNullException()
        {
            // Arrange
            // No setups, so any read ahead of the argument check throws a MockException instead.
            using ServiceProvider services = new ServiceCollection()
                .AddMetrics()
                .BuildServiceProvider();
            PortfolioInsightsService service = BuildPositionsService(
                StrictPositionsMocks(),
                services
            );

            // Act and Assert
            await Assert.ThrowsAsync<ArgumentNullException>(
                "selectedPrices",
                () => service.GetHoldingPositionsAsync(AccountId, null!)
            );
        }

        private static EdgeCase BuildEdgeCase(EdgeInput edgeInput)
        {
            switch (edgeInput)
            {
                case EdgeInput.ZeroTotalFromOffsettingSignedValues:
                    // The higher id is seeded first and holds the larger value.
                    return new EdgeCase(
                        [Holding(MidInstrumentId, 1), Holding(LowInstrumentId, 1)],
                        [Candle(MidInstrumentId, 30), Candle(LowInstrumentId, -30)],
                        [(MidInstrumentId, 30, 0), (LowInstrumentId, -30, 0)],
                        0,
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskLow
                    );
                case EdgeInput.ZeroTotalWithLowestIdBetweenSignedValues:
                    // The lowest id is neither the first nor the last allocation.
                    return new EdgeCase(
                        [
                            Holding(HighInstrumentId, 1),
                            Holding(MidInstrumentId, 1),
                            Holding(LowInstrumentId, 1),
                        ],
                        [
                            Candle(HighInstrumentId, -20),
                            Candle(MidInstrumentId, 30),
                            Candle(LowInstrumentId, -10),
                        ],
                        [
                            (MidInstrumentId, 30, 0),
                            (LowInstrumentId, -10, 0),
                            (HighInstrumentId, -20, 0),
                        ],
                        0,
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskLow
                    );
                case EdgeInput.ZeroTotalFromZeroPrices:
                    return new EdgeCase(
                        [Holding(MidInstrumentId, 3), Holding(LowInstrumentId, 4)],
                        [Candle(MidInstrumentId, 0), Candle(LowInstrumentId, 0)],
                        [(LowInstrumentId, 0, 0), (MidInstrumentId, 0, 0)],
                        0,
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskLow
                    );
                case EdgeInput.TiedLargestValue:
                    // Values 20, 40 and 40 of a total of 100; the tie goes to the lower id.
                    return new EdgeCase(
                        [
                            Holding(HighInstrumentId, 2),
                            Holding(MidInstrumentId, 4),
                            Holding(LowInstrumentId, 8),
                        ],
                        [
                            Candle(HighInstrumentId, 10),
                            Candle(MidInstrumentId, 10),
                            Candle(LowInstrumentId, 5),
                        ],
                        [
                            (LowInstrumentId, 40, 40),
                            (MidInstrumentId, 40, 40),
                            (HighInstrumentId, 20, 20),
                        ],
                        100,
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskMedium
                    );
                default:
                    throw new ArgumentOutOfRangeException(nameof(edgeInput), edgeInput, null);
            }
        }

        private static OwnedInstrument[] BuildHoldings(NoPositiveHolding noPositiveHolding)
        {
            switch (noPositiveHolding)
            {
                case NoPositiveHolding.NoRows:
                    return [];
                case NoPositiveHolding.ZeroQuantityOnly:
                    return [Holding(LowInstrumentId, 0), Holding(MidInstrumentId, 0)];
                default:
                    throw new ArgumentOutOfRangeException(
                        nameof(noPositiveHolding),
                        noPositiveHolding,
                        null
                    );
            }
        }

        private static ServiceCase BuildServiceCase(ServiceScenario scenario)
        {
            switch (scenario)
            {
                case ServiceScenario.NullCandleInPriceList:
                {
                    // A malformed pricing response that deserialized to a null candle.
                    IEnumerable<Price> candles = [Candle(LowInstrumentId, 10), null!];
                    Mock<IPriceServiceConnector> connector = new(MockBehavior.Strict);
                    connector.Setup(prices => prices.GetLatestPrices()).ReturnsAsync(candles);
                    return new ServiceCase(
                        Instruments((LowInstrumentId, 2)),
                        connector.Object,
                        new ServiceOutcome(typeof(PricingUnavailableException), null, null)
                    );
                }
                case ServiceScenario.ZeroAndNegativeCloses:
                {
                    // Zero and negative closes are valid prices: values 2 * 0 and 3 * -5.
                    FakePriceServiceConnector connector = new(
                        [Candle(LowInstrumentId, 0), Candle(MidInstrumentId, -5)]
                    );
                    return new ServiceCase(
                        Instruments((LowInstrumentId, 2), (MidInstrumentId, 3)),
                        connector,
                        new ServiceOutcome(null, -15, 2)
                    );
                }
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
        }

        private static FakeInstrumentRepository Instruments(
            params (Guid InstrumentId, decimal Quantity)[] holdings
        )
        {
            FakeInstrumentRepository repository = new();
            foreach ((Guid instrumentId, decimal quantity) in holdings)
            {
                repository
                    .AddInstrument(new Instrument(instrumentId, Guid.Empty, "CODE", "Name", ""))
                    .AddOwned(Holding(instrumentId, quantity));
            }
            return repository;
        }

        private static OwnedInstrument Holding(Guid instrumentId, decimal quantity)
        {
            return new OwnedInstrument(AccountId, instrumentId, quantity, Time);
        }

        private static Price Candle(Guid instrumentId, decimal close)
        {
            return new Price(instrumentId, Time, close, close, close, close);
        }

        private static Trade QuickTrade(
            Guid instrumentId,
            string direction,
            decimal quantity,
            decimal entryPrice,
            DateTimeOffset opened
        )
        {
            return new Trade(
                AccountId,
                instrumentId,
                direction,
                quantity,
                entryPrice,
                opened,
                opened,
                true,
                true,
                "Instant " + direction + " done."
            );
        }

        // One instrument's executed quick trades, listed in input order.
        private static Trade[] BuildReplayHistory(ReplayOrder replayOrder)
        {
            switch (replayOrder)
            {
                case ReplayOrder.OpenTimeOutranksInputAndId:
                    // Ids fall as open times rise, and the sale is listed first. Input order
                    // skips the sale and gives 3,000 for 20, so 2,250; id order gives 2,000.
                    return
                    [
                        IdentifiedTrade(MidReplayId, "sell", 5, 160, Time.AddMinutes(1)),
                        IdentifiedTrade(HighReplayId, "buy", 10, 100, Time),
                        IdentifiedTrade(LowReplayId, "buy", 10, 200, Time.AddMinutes(2)),
                    ];
                case ReplayOrder.IdBreaksOpenTimeTie:
                    // The sale and the buy at 200 open together, and the sale's lower id replays
                    // it first. Open time alone keeps input order for the tie, so the sale comes
                    // last and removes 750 of 3,000 for 20, leaving 2,250.
                    return
                    [
                        IdentifiedTrade(HighReplayId, "buy", 10, 200, Time.AddMinutes(1)),
                        IdentifiedTrade(MidReplayId, "sell", 5, 160, Time.AddMinutes(1)),
                        IdentifiedTrade(LowReplayId, "buy", 10, 100, Time),
                    ];
                default:
                    throw new ArgumentOutOfRangeException(nameof(replayOrder), replayOrder, null);
            }
        }

        // An executed quick trade of the low instrument with a fixed id.
        private static Trade IdentifiedTrade(
            Guid id,
            string direction,
            decimal quantity,
            decimal entryPrice,
            DateTimeOffset opened
        )
        {
            return new Trade(
                id,
                AccountId,
                LowInstrumentId,
                direction,
                quantity,
                entryPrice,
                opened,
                opened,
                true,
                true,
                "Instant " + direction + " done."
            );
        }

        // Holdings are listed with the lower value and the higher id first, so neither a value
        // nor an id order of the result passes for holding order.
        private static PositionsCase BuildPositionsCase(PositionsScenario scenario)
        {
            // Every trade is executed. The high instrument was bought and sold out, and its trades
            // would change the low cost basis if they were replayed against it.
            Trade[] trades =
            [
                QuickTrade(LowInstrumentId, "buy", 4, 50, Time),
                QuickTrade(HighInstrumentId, "buy", 3, 40, Time),
                QuickTrade(MidInstrumentId, "buy", 2, 30, Time.AddMinutes(1)),
                QuickTrade(HighInstrumentId, "sell", 3, 45, Time.AddMinutes(2)),
            ];
            // Each close differs from its candle's open, high and low and from every entry price,
            // so only the supplied closes give the expected figures.
            Price lowCandle = new(LowInstrumentId, Time, 70, 90, 60, 80);
            Price midCandle = new(MidInstrumentId, Time, 20, 25, 10, 15);
            Price highCandle = new(HighInstrumentId, Time, 40, 50, 35, 47);
            Dictionary<Guid, Price> allPrices = new()
            {
                [LowInstrumentId] = lowCandle,
                [MidInstrumentId] = midCandle,
                [HighInstrumentId] = highCandle,
            };
            switch (scenario)
            {
                case PositionsScenario.AllHoldingsPriced:
                    // Mid: Q0 = max(0, 2 - 2 + 0) = 0; the buy of 2 at 30 costs 60; value
                    // 2 * 15 = 30; P/L (30 - 60) / 60 * 100 = -50.
                    // Low: Q0 = max(0, 4 - 4 + 0) = 0; the buy of 4 at 50 costs 200; value
                    // 4 * 80 = 320; P/L (320 - 200) / 200 * 100 = 60.
                    // The zero-quantity high row is no holding, though it has trades and a price.
                    return new PositionsCase(
                        [
                            Holding(MidInstrumentId, 2),
                            Holding(HighInstrumentId, 0),
                            Holding(LowInstrumentId, 4),
                        ],
                        trades,
                        allPrices,
                        [
                            (MidInstrumentId, 2, 15, true, 30, 60, -50),
                            (LowInstrumentId, 4, 80, true, 320, 200, 60),
                        ]
                    );
                case PositionsScenario.OneHoldingUnpriced:
                    // Mid has no supplied price, so p = 0 and value 0; Q0 = 0 and the buy of 2 at
                    // 30 still costs 60; P/L (0 - 60) / 60 * 100 = -100. Low is as above.
                    return new PositionsCase(
                        [Holding(MidInstrumentId, 2), Holding(LowInstrumentId, 4)],
                        trades,
                        new Dictionary<Guid, Price> { [LowInstrumentId] = lowCandle },
                        [
                            (MidInstrumentId, 2, 0, false, 0, 60, -100),
                            (LowInstrumentId, 4, 80, true, 320, 200, 60),
                        ]
                    );
                case PositionsScenario.NoPositiveQuantity:
                    // Zero-quantity rows only, though both instruments have trades and prices.
                    return new PositionsCase(
                        [Holding(MidInstrumentId, 0), Holding(LowInstrumentId, 0)],
                        trades,
                        allPrices,
                        []
                    );
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
        }

        // Strict mocks without setups: any call throws, and Moq records it all the same, so
        // verification also sees a call whose failure the service swallowed.
        private static PositionsMocks StrictPositionsMocks()
        {
            return new PositionsMocks(
                new Mock<IBalanceRepository>(MockBehavior.Strict),
                new Mock<IInstrumentRepository>(MockBehavior.Strict),
                new Mock<ITradeRepository>(MockBehavior.Strict),
                new Mock<IPriceServiceConnector>(MockBehavior.Strict)
            );
        }

        // Strict mocks that answer only the holdings and trades reads of the positions path.
        private static PositionsMocks StubPositionsReads(PositionsCase positionsCase)
        {
            PositionsMocks mocks = StrictPositionsMocks();
            mocks
                .Instruments.Setup(repository =>
                    repository.GetOwnedInstrumentsOfAccountAsync(AccountId)
                )
                .ReturnsAsync(positionsCase.Holdings.ToList());
            mocks
                .Trades.Setup(repository =>
                    repository.GetAccountTradesAsync(AccountId, false, false)
                )
                .ReturnsAsync(positionsCase.Trades.ToList());
            return mocks;
        }

        // Replaces one stubbed read with one whose task faults with the given exception.
        private static void FailPositionsRead(
            PositionsMocks mocks,
            PositionsFailure failingRead,
            Exception failure
        )
        {
            switch (failingRead)
            {
                case PositionsFailure.HoldingsRead:
                    mocks
                        .Instruments.Setup(repository =>
                            repository.GetOwnedInstrumentsOfAccountAsync(AccountId)
                        )
                        .ThrowsAsync(failure);
                    return;
                case PositionsFailure.TradesRead:
                    mocks
                        .Trades.Setup(repository =>
                            repository.GetAccountTradesAsync(AccountId, false, false)
                        )
                        .ThrowsAsync(failure);
                    return;
                default:
                    throw new ArgumentOutOfRangeException(nameof(failingRead), failingRead, null);
            }
        }

        private static PortfolioInsightsService BuildPositionsService(
            PositionsMocks mocks,
            ServiceProvider services
        )
        {
            return new PortfolioInsightsService(
                mocks.Balance.Object,
                mocks.Instruments.Object,
                mocks.Trades.Object,
                mocks.Prices.Object,
                new PortfolioInsightsMetrics(services.GetRequiredService<IMeterFactory>()),
                new RecordingLogger<PortfolioInsightsService>()
            );
        }

        private sealed record EdgeCase(
            OwnedInstrument[] Holdings,
            Price[] Candles,
            (Guid InstrumentId, decimal Value, decimal Percent)[] Allocations,
            decimal TotalValue,
            Guid LargestId,
            string RiskLevel
        );

        private sealed record ServiceCase(
            FakeInstrumentRepository Instruments,
            IPriceServiceConnector Prices,
            ServiceOutcome Expected
        );

        // The error type of a failed call, or the figures of a computed result.
        private sealed record ServiceOutcome(
            Type? ErrorType,
            decimal? TotalValue,
            int? AllocationCount
        );

        // The figures expected per position, in holding order; the name is not compared.
        private sealed record PositionsCase(
            OwnedInstrument[] Holdings,
            Trade[] Trades,
            IReadOnlyDictionary<Guid, Price> Prices,
            (
                Guid InstrumentId,
                decimal Quantity,
                decimal LatestPrice,
                bool HasPrice,
                decimal Value,
                decimal CostBasis,
                decimal PnlPercent
            )[] Expected
        );

        private sealed record PositionsMocks(
            Mock<IBalanceRepository> Balance,
            Mock<IInstrumentRepository> Instruments,
            Mock<ITradeRepository> Trades,
            Mock<IPriceServiceConnector> Prices
        );

        // Fails the test as soon as anything enumerates the trades.
        private sealed class UnreadableTrades : IEnumerable<Trade>
        {
            public IEnumerator<Trade> GetEnumerator()
            {
                throw new InvalidOperationException("The trades must not be enumerated.");
            }

            IEnumerator IEnumerable.GetEnumerator()
            {
                return GetEnumerator();
            }
        }
    }
}
