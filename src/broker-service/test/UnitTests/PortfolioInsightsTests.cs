using System.Collections;
using System.Globalization;
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
using Microsoft.Extensions.Logging;
// System.Diagnostics.Metrics also declares an Instrument type, so only the factory and the
// listener are imported.
using IMeterFactory = System.Diagnostics.Metrics.IMeterFactory;
using MeterListener = System.Diagnostics.Metrics.MeterListener;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public sealed class PortfolioInsightsTests : IDisposable
    {
        private const string InsightsLogPrefix = "Portfolio insights for account";
        private const string LowName = "Low instrument";
        private const string MidName = "Mid instrument";
        private const string HighName = "High instrument";

        // The calculation metric as the contract names it, stated here rather than read from
        // PortfolioInsightsMetrics, so a renamed meter, instrument or unit fails the metric test.
        private const string MeterName = "EasyTrade.BrokerService";
        private const string CalculationDurationName =
            "easytrade.broker.portfolio.calculation.duration";
        private const string SecondsUnit = "s";

        // The success statuses exactly as long-trade settlement persists them, kept apart from
        // the calculator's own constants so a drift there fails instead of passing.
        private const string SettledLongBuyStatus = "Long buy transaction finished!";
        private const string SettledLongSellStatus = "Long sell transaction finished!";

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

        // xUnit creates one instance per test and disposes it afterwards, so every test gets its
        // own meter factory and listens only to the meters it created.
        private readonly ServiceProvider _services = new ServiceCollection()
            .AddMetrics()
            .BuildServiceProvider();

        private RecordingLogger<PortfolioInsightsService>? _logger;

        // Public, not private: xUnit passes them to public theories, and a public method cannot
        // take a parameter of a less accessible type.
        public enum EdgeInput
        {
            SingleHolding,
            ZeroPrice,
            NegativeClose,
            ZeroInvested,
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

        public enum CostBasisHistory
        {
            BuysOnly,
            BuyThenSell,
            OpeningLot,
            ZeroCostBasis,
            SellOutThenRebuy,
            SellBeforeAnyUnits,
        }

        public enum ServiceScenario
        {
            UnknownAccount,
            NoPositiveHoldingPricingUnreachable,
            ZeroQuantityHoldingExcluded,
            InstrumentWithoutCandle,
            PricingThrows,
            PricingEmptyWithHoldings,
            PricingListFailsWhileRead,
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

        public void Dispose()
        {
            _services.Dispose();
        }

        [Fact]
        public void CalculateInsights_NoHoldings_ShouldReturnZeroTotalsAndNullRisk()
        {
            // Arrange
            // Zero-quantity rows are no holdings, so the calculator path sees no position at all.
            IReadOnlyList<HoldingPosition> positions = PortfolioInsightsCalculator.BuildPositions(
                [Holding(LowInstrumentId, 0)],
                NoNames,
                [],
                LatestPriceSelector.Select([Candle(LowInstrumentId, 10)])
            );

            // Act
            PortfolioInsightsDTO[] results =
            [
                PortfolioInsightsCalculator.Calculate(positions),
                PortfolioInsightsCalculator.Empty(),
            ];

            // Assert
            (decimal, decimal, decimal, decimal, int, AllocationDTO?, string?) empty = (
                0,
                0,
                0,
                0,
                0,
                null,
                null
            );
            Assert.Equal(
                [empty, empty],
                results.Select(insights =>
                    (
                        insights.TotalValue,
                        insights.TotalInvested,
                        insights.UnrealizedPnl,
                        insights.UnrealizedPnlPercent,
                        insights.Allocations.Count(),
                        insights.LargestPosition,
                        insights.RiskLevel
                    )
                )
            );
        }

        [Theory]
        [InlineData(EdgeInput.SingleHolding)]
        [InlineData(EdgeInput.ZeroPrice)]
        [InlineData(EdgeInput.NegativeClose)]
        [InlineData(EdgeInput.ZeroInvested)]
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
                edgeCase.Trades,
                LatestPriceSelector.Select(edgeCase.Candles)
            );
            PortfolioInsightsDTO insights = PortfolioInsightsCalculator.Calculate(positions);

            // Assert
            Assert.Equal(
                edgeCase.Totals,
                (
                    insights.TotalValue,
                    insights.TotalInvested,
                    insights.UnrealizedPnl,
                    insights.UnrealizedPnlPercent
                )
            );
            Assert.Equal(
                edgeCase.Allocations,
                insights.Allocations.Select(allocation =>
                    (allocation.InstrumentId, allocation.Value, allocation.Percent)
                )
            );
            Assert.Equal(edgeCase.LargestId, insights.LargestPosition?.InstrumentId);
            Assert.Equal(edgeCase.RiskLevel, insights.RiskLevel);
        }

        // The first value is the largest share; every row's values sum to exactly 100, so the
        // largest position's percent is that value without rounding.
        [Theory]
        [InlineData("LOW", "24.99", "24.99", "24.99", "24.99", "0.04")]
        [InlineData("MEDIUM", "25", "25", "25", "25")]
        [InlineData("MEDIUM", "25.01", "24.99", "24.99", "24.99", "0.02")]
        [InlineData("MEDIUM", "49.99", "49.99", "0.02")]
        [InlineData("MEDIUM", "50", "50")]
        [InlineData("HIGH", "50.01", "49.99")]
        public void CalculateInsights_LargestShareAtBoundary_ShouldClassifyRisk(
            string expectedRisk,
            params string[] values
        )
        {
            // Arrange
            decimal share = decimal.Parse(values[0], CultureInfo.InvariantCulture);
            HoldingPosition[] positions =
            [
                .. values.Select(
                    (text, index) =>
                        ValuedPosition(
                            new Guid($"00000000-0000-0000-0000-{index + 1:D12}"),
                            decimal.Parse(text, CultureInfo.InvariantCulture)
                        )
                ),
            ];

            // Act
            PortfolioInsightsDTO insights = PortfolioInsightsCalculator.Calculate(positions);
            string riskForShare = PortfolioInsightsCalculator.RiskLevelFor(share);

            // Assert
            Assert.Equal(
                (share, expectedRisk, expectedRisk),
                (insights.LargestPosition?.Percent, insights.RiskLevel, riskForShare)
            );
        }

        [Theory]
        [InlineData(CostBasisHistory.BuysOnly)]
        [InlineData(CostBasisHistory.BuyThenSell)]
        [InlineData(CostBasisHistory.OpeningLot)]
        [InlineData(CostBasisHistory.ZeroCostBasis)]
        [InlineData(CostBasisHistory.SellOutThenRebuy)]
        [InlineData(CostBasisHistory.SellBeforeAnyUnits)]
        public void CalculateCostBasis_Trades_ShouldMatchRule(CostBasisHistory history)
        {
            // Arrange
            CostBasisCase costBasisCase = BuildCostBasisCase(history);

            // Act
            decimal costBasis = PortfolioInsightsCalculator.CalculateCostBasis(
                costBasisCase.Quantity,
                costBasisCase.Close,
                costBasisCase.Trades
            );
            HoldingPosition position = Assert.Single(
                PortfolioInsightsCalculator.BuildPositions(
                    [Holding(LowInstrumentId, costBasisCase.Quantity)],
                    NoNames,
                    costBasisCase.Trades,
                    LatestPriceSelector.Select([Candle(LowInstrumentId, costBasisCase.Close)])
                )
            );

            // Assert
            Assert.Equal(
                costBasisCase.Expected,
                (
                    costBasis,
                    position.CostBasis,
                    position.Value,
                    position.Value - position.CostBasis,
                    position.PnlPercent
                )
            );
        }

        [Fact]
        public void CalculateCostBasis_SoldOutWithoutQuantity_ShouldReturnZero()
        {
            // Arrange
            // A quantity of 0 is no holding; the replay ends with no units left.
            Trade[] trades =
            [
                QuickTrade(LowInstrumentId, "buy", 3, 10, Time),
                QuickTrade(LowInstrumentId, "sell", 3, 12, Time.AddMinutes(1)),
            ];

            // Act
            decimal costBasis = PortfolioInsightsCalculator.CalculateCostBasis(0, 25, trades);

            // Assert
            Assert.Equal(0, costBasis);
        }

        [Theory]
        [InlineData("buy", true, true, "Instant Buy done.", true)]
        [InlineData("sell", true, true, "Instant Sell done.", true)]
        // Settlement sets TransactionHappened in memory only, so settled long rows read it false.
        [InlineData("longbuy", true, false, SettledLongBuyStatus, true)]
        [InlineData("longbuy", true, true, SettledLongBuyStatus, true)]
        [InlineData("longsell", true, false, SettledLongSellStatus, true)]
        [InlineData("longsell", true, true, SettledLongSellStatus, true)]
        [InlineData("buy", true, false, "Instant Buy done.", false)]
        [InlineData("sell", true, false, "Instant Sell done.", false)]
        // Long rows below are ignored whatever TransactionHappened says: open, including an open
        // row that already carries the success status, then expired, failed, a status differing
        // only in case and the other direction's success status.
        [InlineData("longbuy", false, false, "LongBuy registered.", false)]
        [InlineData("longbuy", false, true, "LongBuy registered.", false)]
        [InlineData("longbuy", false, false, SettledLongBuyStatus, false)]
        [InlineData("longbuy", false, true, SettledLongBuyStatus, false)]
        [InlineData("longbuy", true, false, "Time is up: trade failed", false)]
        [InlineData("longbuy", true, true, "Time is up: trade failed", false)]
        [InlineData("longbuy", true, false, "Not enough money to buy stocks! Trade failed!", false)]
        [InlineData("longbuy", true, true, "Not enough money to buy stocks! Trade failed!", false)]
        [InlineData("longbuy", true, false, "long buy transaction finished!", false)]
        [InlineData("longbuy", true, true, "long buy transaction finished!", false)]
        [InlineData("longbuy", true, false, SettledLongSellStatus, false)]
        [InlineData("longsell", false, false, "LongSell registered.", false)]
        [InlineData("longsell", false, true, "LongSell registered.", false)]
        [InlineData("longsell", false, false, SettledLongSellStatus, false)]
        [InlineData("longsell", false, true, SettledLongSellStatus, false)]
        [InlineData("longsell", true, false, "Time is up: trade failed", false)]
        [InlineData("longsell", true, true, "Time is up: trade failed", false)]
        [InlineData("longsell", true, false, "Not enough stocks to sell! Trade failed!", false)]
        [InlineData("longsell", true, true, "Not enough stocks to sell! Trade failed!", false)]
        [InlineData("longsell", true, false, "long sell transaction finished!", false)]
        [InlineData("longsell", true, true, "long sell transaction finished!", false)]
        [InlineData("longsell", true, false, SettledLongBuyStatus, false)]
        [InlineData("hold", true, true, "Instant Hold done.", false)]
        public void IsExecuted_PersistedTradeShapes_ShouldMatchRule(
            string direction,
            bool tradeClosed,
            bool transactionHappened,
            string status,
            bool expected
        )
        {
            // Arrange
            Trade trade = new(
                LowReplayId,
                AccountId,
                LowInstrumentId,
                direction,
                1,
                10,
                Time,
                Time.AddHours(1),
                tradeClosed,
                transactionHappened,
                status
            );

            // Act
            bool executed = PortfolioInsightsCalculator.IsExecuted(trade);

            // Assert
            Assert.Equal(expected, executed);
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
        [InlineData(ServiceScenario.UnknownAccount)]
        [InlineData(ServiceScenario.NoPositiveHoldingPricingUnreachable)]
        [InlineData(ServiceScenario.ZeroQuantityHoldingExcluded)]
        [InlineData(ServiceScenario.InstrumentWithoutCandle)]
        [InlineData(ServiceScenario.PricingThrows)]
        [InlineData(ServiceScenario.PricingEmptyWithHoldings)]
        [InlineData(ServiceScenario.PricingListFailsWhileRead)]
        [InlineData(ServiceScenario.NullCandleInPriceList)]
        [InlineData(ServiceScenario.ZeroAndNegativeCloses)]
        public async Task GetInsights_Scenario_ShouldMatchContract(ServiceScenario scenario)
        {
            // Arrange
            ServiceCase serviceCase = BuildServiceCase(scenario);
            PortfolioInsightsService service = BuildService(
                serviceCase.Balances,
                Catalog(),
                serviceCase.Holdings,
                serviceCase.Trades,
                serviceCase.Pricing.Object
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
                    insights?.TotalInvested,
                    insights?.LargestPosition?.InstrumentId,
                    insights?.RiskLevel,
                    _logger!.Sink.ByLevel(LogLevel.Warning).Count
                )
            );
            Assert.Equal(
                serviceCase.Allocations,
                insights?.Allocations.Select(allocation =>
                    (allocation.InstrumentId, allocation.Name, allocation.Value, allocation.Percent)
                ) ?? []
            );
            // A latest-price fetch is a call to pricing-service, so its count is a side effect
            // the contract fixes rather than an internal call (tests.md): one per computed
            // result, and none before the account and its holdings are known.
            serviceCase.Pricing.Verify(
                connector => connector.GetLatestPrices(),
                Times.Exactly(serviceCase.PriceCalls)
            );
        }

        [Fact]
        public async Task GetInsights_Computed_ShouldRecordCalculationDuration()
        {
            // Arrange
            PortfolioInsightsService service = BuildComputedService();
            using MetricCapture capture = new(_services.GetRequiredService<IMeterFactory>());

            // Act
            _ = await service.GetInsightsAsync(AccountId);

            // Assert: one untagged measurement on the published meter, in seconds, and the same
            // duration the insights line logs in whole milliseconds.
            RecordedMeasurement measurement = Assert.Single(capture.Measurements);
            LogEntry? computed = _logger!.Entries.FirstOrDefault(logged =>
                logged.GetField("{OriginalFormat}") is string format
                && format.StartsWith(InsightsLogPrefix, StringComparison.Ordinal)
            );
            Assert.Equal(
                (MeterName, CalculationDurationName, SecondsUnit, 0, true, true),
                (
                    measurement.Meter,
                    measurement.Name,
                    measurement.Unit,
                    measurement.Tags.Length,
                    measurement.Value > 0,
                    computed?.GetField("durationMs") is long durationMs
                        && Math.Abs(durationMs - (measurement.Value * 1000)) < 1
                )
            );
        }

        [Fact]
        public async Task GetInsights_Computed_ShouldLogNamedFields()
        {
            // Arrange
            PortfolioInsightsService service = BuildComputedService();

            // Act
            PortfolioInsightsDTO insights = await service.GetInsightsAsync(AccountId);

            // Assert
            LogEntry entry = Assert.Single(
                _logger!.Entries,
                logged =>
                    logged.GetField("{OriginalFormat}") is string format
                    && format.StartsWith(InsightsLogPrefix, StringComparison.Ordinal)
            );
            // Without an ambient Activity, traceId may be null, so only its presence is asserted.
            (object?, object?, object?, object?, bool, bool) expected = (
                AccountId,
                2,
                insights.TotalValue,
                insights.RiskLevel,
                true,
                true
            );
            Assert.Equal(
                expected,
                (
                    entry.GetField("accountId"),
                    entry.GetField("holdingCount"),
                    entry.GetField("totalValue"),
                    entry.GetField("riskLevel"),
                    entry.GetField("durationMs") is long durationMs && durationMs >= 0,
                    entry.HasField("traceId")
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
            PortfolioInsightsService service = BuildPositionsService(
                StubPositionsReads(positionsCase)
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
            PortfolioInsightsService service = BuildPositionsService(mocks);

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
            PortfolioInsightsService service = BuildPositionsService(mocks);

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
            PortfolioInsightsService service = BuildPositionsService(StrictPositionsMocks());

            // Act and Assert
            await Assert.ThrowsAsync<ArgumentNullException>(
                "selectedPrices",
                () => service.GetHoldingPositionsAsync(AccountId, null!)
            );
        }

        // Rows without trades cost every holding as an opening lot at its close, so their total
        // invested equals their total value.
        private static EdgeCase BuildEdgeCase(EdgeInput edgeInput)
        {
            switch (edgeInput)
            {
                case EdgeInput.SingleHolding:
                    return new EdgeCase(
                        [Holding(LowInstrumentId, 4)],
                        [Candle(LowInstrumentId, 25)],
                        [],
                        [(LowInstrumentId, 100, 100)],
                        (100, 100, 0, 0),
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskHigh
                    );
                case EdgeInput.ZeroPrice:
                    // The low holding cost 5 * 4 = 20 and is now worth 5 * 0 = 0; mid is 2 * 10.
                    return new EdgeCase(
                        [Holding(LowInstrumentId, 5), Holding(MidInstrumentId, 2)],
                        [Candle(LowInstrumentId, 0), Candle(MidInstrumentId, 10)],
                        [QuickTrade(LowInstrumentId, "buy", 5, 4, Time)],
                        [(MidInstrumentId, 20, 100), (LowInstrumentId, 0, 0)],
                        (20, 40, -20, -50),
                        MidInstrumentId,
                        PortfolioInsightsCalculator.RiskHigh
                    );
                case EdgeInput.NegativeClose:
                    // The low holding cost 2 * 5 = 10 and is now worth 2 * -5 = -10; mid is 1 * 30.
                    // Percents follow the signed values: 30 / 20 and -10 / 20 of the total.
                    return new EdgeCase(
                        [Holding(LowInstrumentId, 2), Holding(MidInstrumentId, 1)],
                        [Candle(LowInstrumentId, -5), Candle(MidInstrumentId, 30)],
                        [QuickTrade(LowInstrumentId, "buy", 2, 5, Time)],
                        [(MidInstrumentId, 30, 150), (LowInstrumentId, -10, -50)],
                        (20, 40, -20, -50),
                        MidInstrumentId,
                        PortfolioInsightsCalculator.RiskHigh
                    );
                case EdgeInput.ZeroInvested:
                    // Bought at 0, so the total invested is 0 and both P/L figures are 0 although
                    // the value is 5 * 10 = 50.
                    return new EdgeCase(
                        [Holding(LowInstrumentId, 5)],
                        [Candle(LowInstrumentId, 10)],
                        [QuickTrade(LowInstrumentId, "buy", 5, 0, Time)],
                        [(LowInstrumentId, 50, 100)],
                        (50, 0, 0, 0),
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskHigh
                    );
                case EdgeInput.ZeroTotalFromOffsettingSignedValues:
                    // The higher id is seeded first and holds the larger value.
                    return new EdgeCase(
                        [Holding(MidInstrumentId, 1), Holding(LowInstrumentId, 1)],
                        [Candle(MidInstrumentId, 30), Candle(LowInstrumentId, -30)],
                        [],
                        [(MidInstrumentId, 30, 0), (LowInstrumentId, -30, 0)],
                        (0, 0, 0, 0),
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
                        [],
                        [
                            (MidInstrumentId, 30, 0),
                            (LowInstrumentId, -10, 0),
                            (HighInstrumentId, -20, 0),
                        ],
                        (0, 0, 0, 0),
                        LowInstrumentId,
                        PortfolioInsightsCalculator.RiskLow
                    );
                case EdgeInput.ZeroTotalFromZeroPrices:
                    return new EdgeCase(
                        [Holding(MidInstrumentId, 3), Holding(LowInstrumentId, 4)],
                        [Candle(MidInstrumentId, 0), Candle(LowInstrumentId, 0)],
                        [],
                        [(LowInstrumentId, 0, 0), (MidInstrumentId, 0, 0)],
                        (0, 0, 0, 0),
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
                        [],
                        [
                            (LowInstrumentId, 40, 40),
                            (MidInstrumentId, 40, 40),
                            (HighInstrumentId, 20, 20),
                        ],
                        (100, 100, 0, 0),
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

        private static CostBasisCase BuildCostBasisCase(CostBasisHistory history)
        {
            switch (history)
            {
                case CostBasisHistory.BuysOnly:
                    // 10 * 100 + 5 * 130 = 1,650 for 15 units, worth 15 * 132 = 1,980.
                    return new CostBasisCase(
                        15,
                        132,
                        [
                            QuickTrade(LowInstrumentId, "buy", 10, 100, Time),
                            QuickTrade(LowInstrumentId, "buy", 5, 130, Time.AddMinutes(1)),
                        ],
                        (1650, 1650, 1980, 330, 20)
                    );
                case CostBasisHistory.BuyThenSell:
                    // 3,000 for 20 units; selling 5 removes them at the average cost of 150,
                    // whatever their sale price, leaving 2,250 = 15 * 150.
                    return new CostBasisCase(
                        15,
                        180,
                        [
                            QuickTrade(LowInstrumentId, "buy", 10, 100, Time),
                            QuickTrade(LowInstrumentId, "buy", 10, 200, Time.AddMinutes(1)),
                            QuickTrade(LowInstrumentId, "sell", 5, 170, Time.AddMinutes(2)),
                        ],
                        (2250, 2250, 2700, 450, 20)
                    );
                case CostBasisHistory.OpeningLot:
                    // 10 seeded units predate the retained trades and cost 10 * 110 = 1,100 at
                    // the latest close; the buy adds 5 * 100 = 500. Worth 15 * 110 = 1,650.
                    return new CostBasisCase(
                        15,
                        110,
                        [QuickTrade(LowInstrumentId, "buy", 5, 100, Time)],
                        (1600, 1600, 1650, 50, 3.125M)
                    );
                case CostBasisHistory.ZeroCostBasis:
                    // Bought at 0, so the P/L percent is 0 rather than a division by zero.
                    return new CostBasisCase(
                        5,
                        10,
                        [QuickTrade(LowInstrumentId, "buy", 5, 0, Time)],
                        (0, 0, 50, 50, 0)
                    );
                case CostBasisHistory.SellOutThenRebuy:
                    // The trades explain all 5 units. Selling the whole lot of 10 zeroes its
                    // cost, so only the rebuy of 5 * 60 = 300 remains. Worth 5 * 72 = 360.
                    return new CostBasisCase(
                        5,
                        72,
                        [
                            QuickTrade(LowInstrumentId, "buy", 10, 100, Time),
                            QuickTrade(LowInstrumentId, "sell", 10, 120, Time.AddMinutes(1)),
                            QuickTrade(LowInstrumentId, "buy", 5, 60, Time.AddMinutes(2)),
                        ],
                        (300, 300, 360, 60, 20)
                    );
                case CostBasisHistory.SellBeforeAnyUnits:
                    // No opening lot: max(0, 2 - 5 + 3) = 0. The first sale finds no units and
                    // changes nothing; the buy makes 100 for 5, so 2 units cost 40. Worth 60.
                    return new CostBasisCase(
                        2,
                        30,
                        [
                            QuickTrade(LowInstrumentId, "sell", 3, 50, Time),
                            QuickTrade(LowInstrumentId, "buy", 5, 20, Time.AddMinutes(1)),
                        ],
                        (40, 40, 60, 20, 50)
                    );
                default:
                    throw new ArgumentOutOfRangeException(nameof(history), history, null);
            }
        }

        private static ServiceCase BuildServiceCase(ServiceScenario scenario)
        {
            switch (scenario)
            {
                case ServiceScenario.UnknownAccount:
                    // No balance row: the account check fails before any other read.
                    return new ServiceCase(
                        [],
                        [Holding(LowInstrumentId, 2)],
                        [],
                        PricingFrom(Candle(LowInstrumentId, 10)),
                        new ServiceOutcome(
                            typeof(BalanceNotFoundException),
                            null,
                            null,
                            null,
                            null,
                            0
                        ),
                        [],
                        0
                    );
                case ServiceScenario.NoPositiveHoldingPricingUnreachable:
                    // The empty result needs no price, so unreachable pricing cannot fail it.
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 0)],
                        [],
                        UnreachablePricing(),
                        new ServiceOutcome(null, 0, 0, null, null, 0),
                        [],
                        0
                    );
                case ServiceScenario.ZeroQuantityHoldingExcluded:
                    // Low cost 5 * 8 = 40 and is worth 5 * 10 = 50; the zero-quantity mid row is
                    // no holding although it has a price.
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(MidInstrumentId, 0), Holding(LowInstrumentId, 5)],
                        [QuickTrade(LowInstrumentId, "buy", 5, 8, Time)],
                        PricingFrom(Candle(LowInstrumentId, 10), Candle(MidInstrumentId, 20)),
                        new ServiceOutcome(
                            null,
                            50,
                            40,
                            LowInstrumentId,
                            PortfolioInsightsCalculator.RiskHigh,
                            0
                        ),
                        [(LowInstrumentId, LowName, 50, 100)],
                        1
                    );
                case ServiceScenario.InstrumentWithoutCandle:
                    // Mid's only candle is older than the newest timestamp, so the latest-price
                    // list has none for it: it is valued at 0 with a Warning.
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2), Holding(MidInstrumentId, 3)],
                        [],
                        PricingFrom(
                            Candle(LowInstrumentId, 10),
                            new Price(MidInstrumentId, Time.AddMinutes(-1), 20, 20, 20, 20)
                        ),
                        new ServiceOutcome(
                            null,
                            20,
                            20,
                            LowInstrumentId,
                            PortfolioInsightsCalculator.RiskHigh,
                            1
                        ),
                        [(LowInstrumentId, LowName, 20, 100), (MidInstrumentId, MidName, 0, 0)],
                        1
                    );
                case ServiceScenario.PricingThrows:
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2)],
                        [],
                        UnreachablePricing(),
                        new ServiceOutcome(
                            typeof(PricingUnavailableException),
                            null,
                            null,
                            null,
                            null,
                            0
                        ),
                        [],
                        1
                    );
                case ServiceScenario.PricingEmptyWithHoldings:
                    // The connector answers a non-200 from pricing with an empty list.
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2)],
                        [],
                        PricingFrom(),
                        new ServiceOutcome(
                            typeof(PricingUnavailableException),
                            null,
                            null,
                            null,
                            null,
                            0
                        ),
                        [],
                        1
                    );
                case ServiceScenario.PricingListFailsWhileRead:
                {
                    // The fetch itself succeeds; its lazy list fails when it is enumerated.
                    IEnumerable<Price> candles = Enumerable
                        .Range(0, 1)
                        .Select<int, Price>(_ =>
                            throw new HttpRequestException("Connection reset")
                        );
                    Mock<IPriceServiceConnector> connector = new(MockBehavior.Strict);
                    connector.Setup(prices => prices.GetLatestPrices()).ReturnsAsync(candles);
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2)],
                        [],
                        connector,
                        new ServiceOutcome(
                            typeof(PricingUnavailableException),
                            null,
                            null,
                            null,
                            null,
                            0
                        ),
                        [],
                        1
                    );
                }
                case ServiceScenario.NullCandleInPriceList:
                {
                    // A malformed pricing response that deserialized to a null candle.
                    IEnumerable<Price> candles = [Candle(LowInstrumentId, 10), null!];
                    Mock<IPriceServiceConnector> connector = new(MockBehavior.Strict);
                    connector.Setup(prices => prices.GetLatestPrices()).ReturnsAsync(candles);
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2)],
                        [],
                        connector,
                        new ServiceOutcome(
                            typeof(PricingUnavailableException),
                            null,
                            null,
                            null,
                            null,
                            0
                        ),
                        [],
                        1
                    );
                }
                case ServiceScenario.ZeroAndNegativeCloses:
                    // Zero and negative closes are valid prices: values 2 * 0 and 3 * -5. The
                    // zero value is the highest, so it is the largest position, at 0 percent.
                    return new ServiceCase(
                        FundedAccount(),
                        [Holding(LowInstrumentId, 2), Holding(MidInstrumentId, 3)],
                        [],
                        PricingFrom(Candle(LowInstrumentId, 0), Candle(MidInstrumentId, -5)),
                        new ServiceOutcome(
                            null,
                            -15,
                            -15,
                            LowInstrumentId,
                            PortfolioInsightsCalculator.RiskLow,
                            0
                        ),
                        [(LowInstrumentId, LowName, 0, 0), (MidInstrumentId, MidName, -15, 100)],
                        1
                    );
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
        }

        private PortfolioInsightsService BuildService(
            Balance[] balances,
            Instrument[] instruments,
            OwnedInstrument[] owned,
            Trade[] trades,
            IPriceServiceConnector prices
        )
        {
            _logger = new RecordingLogger<PortfolioInsightsService>();
            return new PortfolioInsightsService(
                new FakeBalanceRepository([.. balances], []),
                new FakeInstrumentRepository([.. instruments], [.. owned]),
                new FakeTradeRepository([.. trades]),
                prices,
                new PortfolioInsightsMetrics(_services.GetRequiredService<IMeterFactory>()),
                _logger
            );
        }

        private PortfolioInsightsService BuildService(
            Balance[] balances,
            Instrument[] instruments,
            OwnedInstrument[] owned,
            Trade[] trades,
            Price[] prices
        )
        {
            return BuildService(
                balances,
                instruments,
                owned,
                trades,
                new FakePriceServiceConnector([.. prices])
            );
        }

        // Low is worth 2 * 30 = 60 and mid 4 * 10 = 40 of a total of 100.
        private PortfolioInsightsService BuildComputedService()
        {
            return BuildService(
                FundedAccount(),
                Catalog(),
                [Holding(LowInstrumentId, 2), Holding(MidInstrumentId, 4)],
                [],
                [Candle(LowInstrumentId, 30), Candle(MidInstrumentId, 10)]
            );
        }

        // A strict mock answering from a FakePriceServiceConnector, so the fake's newest-timestamp
        // rule decides the list while the mock counts the fetches.
        private static Mock<IPriceServiceConnector> PricingFrom(params Price[] candles)
        {
            FakePriceServiceConnector fake = new([.. candles]);
            Mock<IPriceServiceConnector> pricing = new(MockBehavior.Strict);
            pricing
                .Setup(connector => connector.GetLatestPrices())
                .Returns(() => fake.GetLatestPrices());
            return pricing;
        }

        // An unreachable pricing service: the fetch fails as an HTTP transport failure does.
        private static Mock<IPriceServiceConnector> UnreachablePricing()
        {
            Mock<IPriceServiceConnector> pricing = new(MockBehavior.Strict);
            pricing
                .Setup(connector => connector.GetLatestPrices())
                .ThrowsAsync(new HttpRequestException("Connection refused"));
            return pricing;
        }

        private static Balance[] FundedAccount()
        {
            return [new Balance(AccountId, 1000)];
        }

        // The low id is listed twice: the first name names the allocation, and the duplicate
        // must not fail the request.
        private static Instrument[] Catalog()
        {
            return
            [
                new Instrument(LowInstrumentId, Guid.Empty, "LOW", LowName, string.Empty),
                new Instrument(MidInstrumentId, Guid.Empty, "MID", MidName, string.Empty),
                new Instrument(HighInstrumentId, Guid.Empty, "HIGH", HighName, string.Empty),
                new Instrument(LowInstrumentId, Guid.Empty, "LOW2", "Duplicate low", string.Empty),
            ];
        }

        // A priced position whose cost basis equals its value, as an opening lot's does.
        private static HoldingPosition ValuedPosition(Guid instrumentId, decimal value)
        {
            return new HoldingPosition(instrumentId, string.Empty, 1, value, true, value, value, 0);
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

        private PortfolioInsightsService BuildPositionsService(PositionsMocks mocks)
        {
            return new PortfolioInsightsService(
                mocks.Balance.Object,
                mocks.Instruments.Object,
                mocks.Trades.Object,
                mocks.Prices.Object,
                new PortfolioInsightsMetrics(_services.GetRequiredService<IMeterFactory>()),
                new RecordingLogger<PortfolioInsightsService>()
            );
        }

        private sealed record EdgeCase(
            OwnedInstrument[] Holdings,
            Price[] Candles,
            Trade[] Trades,
            (Guid InstrumentId, decimal Value, decimal Percent)[] Allocations,
            (decimal Value, decimal Invested, decimal Pnl, decimal PnlPercent) Totals,
            Guid LargestId,
            string RiskLevel
        );

        // One holding of the low instrument costed from its trades at its latest close. Expected
        // holds the direct cost basis, then the position's cost basis, value, P/L and P/L percent.
        private sealed record CostBasisCase(
            decimal Quantity,
            decimal Close,
            Trade[] Trades,
            (
                decimal CostBasis,
                decimal PositionCostBasis,
                decimal Value,
                decimal Pnl,
                decimal PnlPercent
            ) Expected
        );

        // Allocations are expected in result order; PriceCalls counts latest-price fetches.
        private sealed record ServiceCase(
            Balance[] Balances,
            OwnedInstrument[] Holdings,
            Trade[] Trades,
            Mock<IPriceServiceConnector> Pricing,
            ServiceOutcome Expected,
            (Guid InstrumentId, string Name, decimal Value, decimal Percent)[] Allocations,
            int PriceCalls
        );

        // The error type of a failed call or the figures of a computed result, with the number
        // of Warning lines logged for holdings without a latest price.
        private sealed record ServiceOutcome(
            Type? ErrorType,
            decimal? TotalValue,
            decimal? TotalInvested,
            Guid? LargestId,
            string? RiskLevel,
            int MissingPriceWarnings
        );

        private sealed record RecordedMeasurement(
            string Meter,
            string Name,
            string? Unit,
            double Value,
            KeyValuePair<string, object?>[] Tags
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

        /// <summary>
        /// Collects the measurements of the meters one <see cref="IMeterFactory"/> created, so
        /// instruments of test classes running at the same time are never seen.
        /// </summary>
        private sealed class MetricCapture : IDisposable
        {
            private readonly MeterListener _listener = new();
            private readonly Lock _gate = new();
            private readonly List<RecordedMeasurement> _measurements = [];

            public MetricCapture(IMeterFactory factory)
            {
                _listener.InstrumentPublished = (instrument, listener) =>
                {
                    if (ReferenceEquals(instrument.Meter.Scope, factory))
                    {
                        listener.EnableMeasurementEvents(instrument);
                    }
                };
                _listener.SetMeasurementEventCallback<double>(
                    (instrument, value, tags, _) =>
                        Add(instrument.Meter.Name, instrument.Name, instrument.Unit, value, tags)
                );
                _listener.SetMeasurementEventCallback<long>(
                    (instrument, value, tags, _) =>
                        Add(instrument.Meter.Name, instrument.Name, instrument.Unit, value, tags)
                );
                _listener.Start();
            }

            public IReadOnlyList<RecordedMeasurement> Measurements
            {
                get
                {
                    lock (_gate)
                    {
                        return _measurements.ToArray();
                    }
                }
            }

            public void Dispose()
            {
                _listener.Dispose();
            }

            private void Add(
                string meter,
                string name,
                string? unit,
                double value,
                ReadOnlySpan<KeyValuePair<string, object?>> tags
            )
            {
                RecordedMeasurement measurement = new(meter, name, unit, value, tags.ToArray());
                lock (_gate)
                {
                    _measurements.Add(measurement);
                }
            }
        }

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
