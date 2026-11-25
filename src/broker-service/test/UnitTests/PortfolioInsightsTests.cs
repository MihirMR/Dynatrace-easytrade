using System.Collections;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;
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
