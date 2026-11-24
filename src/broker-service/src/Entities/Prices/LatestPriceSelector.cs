namespace EasyTrade.BrokerService.Entities.Prices
{
    /// <summary>
    /// Reduces a latest-price list to one candle per instrument. The latest-price query can
    /// return several candles with the same newest timestamp for one instrument, so this is
    /// the single place that decides which candle prices an instrument.
    /// </summary>
    public static class LatestPriceSelector
    {
        /// <summary>
        /// Selects one candle per instrument: the greatest <see cref="Price.Timestamp"/> wins,
        /// ties go to the greater <see cref="Price.Close"/>, then the greater
        /// <see cref="Price.Open"/>, and a full tie keeps the first candle encountered.
        /// Callers price an instrument with the selected candle's <see cref="Price.Close"/>.
        /// </summary>
        /// <param name="prices">The list returned by one latest-price fetch.</param>
        /// <returns>The selected candle per instrument id; empty for an empty list.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="prices"/> is null.</exception>
        public static IReadOnlyDictionary<Guid, Price> Select(IEnumerable<Price> prices)
        {
            ArgumentNullException.ThrowIfNull(prices);

            Dictionary<Guid, Price> selected = new();
            foreach (Price candidate in prices)
            {
                if (
                    !selected.TryGetValue(candidate.InstrumentId, out Price? current)
                    || IsPreferred(candidate, current)
                )
                {
                    selected[candidate.InstrumentId] = candidate;
                }
            }
            return selected;
        }

        private static bool IsPreferred(Price candidate, Price current)
        {
            // DateTimeOffset compares UTC instants, so equal instants in different offsets tie.
            int byTimestamp = candidate.Timestamp.CompareTo(current.Timestamp);
            if (byTimestamp != 0)
            {
                return byTimestamp > 0;
            }

            int byClose = candidate.Close.CompareTo(current.Close);
            if (byClose != 0)
            {
                return byClose > 0;
            }

            return candidate.Open > current.Open;
        }
    }
}
