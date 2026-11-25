using EasyTrade.BrokerService.Entities.Prices;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class LatestPriceSelectorTests
    {
        private static readonly Guid FirstInstrumentId = new(
            "c0000000-0000-4000-8000-000000000001"
        );
        private static readonly Guid SecondInstrumentId = new(
            "c0000000-0000-4000-8000-000000000002"
        );
        private static readonly DateTimeOffset Time = new(2025, 1, 1, 12, 0, 0, TimeSpan.Zero);

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum SelectorCase
        {
            NewerTimestampWins,
            TiedTimestampGreaterClose,
            TiedTimestampAndCloseGreaterOpen,
            FullTieKeepsFirst,
            Empty,
        }

        [Theory]
        [InlineData(SelectorCase.NewerTimestampWins)]
        [InlineData(SelectorCase.TiedTimestampGreaterClose)]
        [InlineData(SelectorCase.TiedTimestampAndCloseGreaterOpen)]
        [InlineData(SelectorCase.FullTieKeepsFirst)]
        [InlineData(SelectorCase.Empty)]
        public void Select_Candles_ShouldApplyTieRule(SelectorCase selectorCase)
        {
            // Arrange
            (Price[] candles, Price[] winners) = BuildCase(selectorCase);

            // Act
            IReadOnlyDictionary<Guid, Price> selected = LatestPriceSelector.Select(candles);

            // Assert
            Assert.Equal(winners.Length, selected.Count);
            foreach (Price winner in winners)
            {
                Assert.Same(winner, selected[winner.InstrumentId]);
            }
        }

        [Fact]
        public void Select_NullCandles_ShouldThrowArgumentNullException()
        {
            // Arrange
            IEnumerable<Price> candles = null!;

            // Act & Assert
            Assert.Throws<ArgumentNullException>(
                "prices",
                () => LatestPriceSelector.Select(candles)
            );
        }

        // Every non-empty case holds two instruments. Where the rule ranks the candles, they arrive
        // in opposite orders, so each instrument gets its own winner and the winner does not depend
        // on input order. In the full tie nothing ranks them, so the first candle encountered wins.
        private static (Price[] Candles, Price[] Winners) BuildCase(SelectorCase selectorCase)
        {
            switch (selectorCase)
            {
                case SelectorCase.NewerTimestampWins:
                {
                    // The newer candle wins although its close is lower.
                    DateTimeOffset later = Time.AddMinutes(1);
                    Price firstOlder = Candle(FirstInstrumentId, Time, open: 9, close: 10);
                    Price firstNewer = Candle(FirstInstrumentId, later, open: 2, close: 8);
                    Price secondNewer = Candle(SecondInstrumentId, later, open: 1, close: 3);
                    Price secondOlder = Candle(SecondInstrumentId, Time, open: 8, close: 9);
                    return (
                        [firstOlder, firstNewer, secondNewer, secondOlder],
                        [firstNewer, secondNewer]
                    );
                }
                case SelectorCase.TiedTimestampGreaterClose:
                {
                    // The greater close wins although its open is lower.
                    Price firstLowClose = Candle(FirstInstrumentId, Time, open: 9, close: 5);
                    Price firstHighClose = Candle(FirstInstrumentId, Time, open: 1, close: 7);
                    Price secondHighClose = Candle(SecondInstrumentId, Time, open: 1, close: 7);
                    Price secondLowClose = Candle(SecondInstrumentId, Time, open: 9, close: 5);
                    return (
                        [firstLowClose, firstHighClose, secondHighClose, secondLowClose],
                        [firstHighClose, secondHighClose]
                    );
                }
                case SelectorCase.TiedTimestampAndCloseGreaterOpen:
                {
                    Price firstLowOpen = Candle(FirstInstrumentId, Time, open: 3, close: 6);
                    Price firstHighOpen = Candle(FirstInstrumentId, Time, open: 4, close: 6);
                    Price secondHighOpen = Candle(SecondInstrumentId, Time, open: 4, close: 6);
                    Price secondLowOpen = Candle(SecondInstrumentId, Time, open: 3, close: 6);
                    return (
                        [firstLowOpen, firstHighOpen, secondHighOpen, secondLowOpen],
                        [firstHighOpen, secondHighOpen]
                    );
                }
                case SelectorCase.FullTieKeepsFirst:
                {
                    // Distinct instances with equal timestamp, open and close.
                    Price firstEarlier = Candle(FirstInstrumentId, Time, open: 4, close: 6);
                    Price firstLater = Candle(FirstInstrumentId, Time, open: 4, close: 6);
                    Price secondEarlier = Candle(SecondInstrumentId, Time, open: 4, close: 6);
                    Price secondLater = Candle(SecondInstrumentId, Time, open: 4, close: 6);
                    return (
                        [firstEarlier, firstLater, secondEarlier, secondLater],
                        [firstEarlier, secondEarlier]
                    );
                }
                case SelectorCase.Empty:
                    return ([], []);
                default:
                    throw new ArgumentOutOfRangeException(nameof(selectorCase), selectorCase, null);
            }
        }

        private static Price Candle(
            Guid instrumentId,
            DateTimeOffset timestamp,
            decimal open,
            decimal close
        )
        {
            return new Price(
                instrumentId,
                timestamp,
                open,
                Math.Max(open, close),
                Math.Min(open, close),
                close
            );
        }
    }
}
