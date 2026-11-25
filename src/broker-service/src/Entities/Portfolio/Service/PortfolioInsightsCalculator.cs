using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Trades;

namespace EasyTrade.BrokerService.Entities.Portfolio.Service
{
    /// <summary>
    /// The single implementation of the portfolio insights rules: holding selection, executed
    /// trades, average cost basis, P/L percent, risk level and the aggregate result. It is pure,
    /// so the insights endpoint, alert creation and alert evaluation all share it.
    /// </summary>
    public static class PortfolioInsightsCalculator
    {
        public const string RiskLow = "LOW";
        public const string RiskMedium = "MEDIUM";
        public const string RiskHigh = "HIGH";

        // Must stay byte-identical to the statuses LongTradeService writes on settlement.
        public const string LongBuyFinishedStatus = "Long buy transaction finished!";
        public const string LongSellFinishedStatus = "Long sell transaction finished!";

        // Trade directions as persisted: ActionType.ToString().ToLower().
        private const string BuyDirection = "buy";
        private const string SellDirection = "sell";
        private const string LongBuyDirection = "longbuy";
        private const string LongSellDirection = "longsell";

        /// <summary>
        /// Keeps the owned-instrument rows with a positive quantity, in input order, one
        /// position per row.
        /// </summary>
        /// <param name="owned">The account's owned-instrument rows.</param>
        /// <returns>The rows that count as holdings.</returns>
        public static IReadOnlyList<OwnedInstrument> SelectHoldings(
            IEnumerable<OwnedInstrument> owned
        )
        {
            ArgumentNullException.ThrowIfNull(owned);

            return [.. owned.Where(instrument => instrument.Quantity > 0)];
        }

        /// <summary>
        /// Returns whether a persisted trade moved instruments: a quick trade by
        /// <see cref="Trade.TransactionHappened"/>, a long trade by being closed with its exact
        /// success status. Every other row, and any unknown direction, is not executed.
        /// </summary>
        /// <param name="trade">A trade as read back from storage.</param>
        /// <returns><c>true</c> when the trade's quantity changed the holding.</returns>
        public static bool IsExecuted(Trade trade)
        {
            ArgumentNullException.ThrowIfNull(trade);

            // A long trade's TransactionHappened is set only in memory at settlement and is never
            // persisted, so settled long trades read back false; their status is the record.
            return trade.Direction switch
            {
                BuyDirection or SellDirection => trade.TransactionHappened,
                LongBuyDirection => trade.TradeClosed
                    && string.Equals(trade.Status, LongBuyFinishedStatus, StringComparison.Ordinal),
                LongSellDirection => trade.TradeClosed
                    && string.Equals(
                        trade.Status,
                        LongSellFinishedStatus,
                        StringComparison.Ordinal
                    ),
                _ => false,
            };
        }

        /// <summary>
        /// Average-cost basis of a holding, replaying its executed trades in
        /// <see cref="Trade.TimestampOpen"/> order, then by <see cref="Trade.Id"/>.
        /// </summary>
        /// <remarks>
        /// Quantity not explained by the retained trades (seed data, purged rows) forms an
        /// opening lot costed at <paramref name="latestPrice"/>, so it carries no unrealized P/L.
        /// Fees are excluded and prices are used as delivered, signed and unrounded.
        /// </remarks>
        /// <param name="quantity">The holding's current quantity.</param>
        /// <param name="latestPrice">The holding's latest close; 0 when it has no candle.</param>
        /// <param name="instrumentTrades">The account's trades of this instrument only.</param>
        /// <returns>The cost basis of <paramref name="quantity"/> units.</returns>
        public static decimal CalculateCostBasis(
            decimal quantity,
            decimal latestPrice,
            IEnumerable<Trade> instrumentTrades
        )
        {
            ArgumentNullException.ThrowIfNull(instrumentTrades);

            List<Trade> executed =
            [
                .. instrumentTrades
                    .Where(IsExecuted)
                    .OrderBy(trade => trade.TimestampOpen)
                    .ThenBy(trade => trade.Id),
            ];

            decimal bought = 0;
            decimal sold = 0;
            foreach (Trade trade in executed)
            {
                if (IsBuy(trade))
                {
                    bought += trade.Quantity;
                }
                else
                {
                    sold += trade.Quantity;
                }
            }

            decimal units = Math.Max(0, quantity - bought + sold);
            decimal cost = units * latestPrice;
            foreach (Trade trade in executed)
            {
                if (IsBuy(trade))
                {
                    units += trade.Quantity;
                    cost += trade.Quantity * trade.EntryPrice;
                }
                else if (units > 0)
                {
                    // Selling the whole lot zeroes the cost directly, leaving no decimal residue.
                    if (trade.Quantity >= units)
                    {
                        units = 0;
                        cost = 0;
                    }
                    else
                    {
                        cost -= (cost / units) * trade.Quantity;
                        units -= trade.Quantity;
                    }
                }
            }

            if (units <= 0)
            {
                return quantity * latestPrice;
            }

            return units == quantity ? cost : (cost / units) * quantity;
        }

        /// <summary>
        /// P/L of a value against its cost basis, in percent; 0 when the cost basis is 0.
        /// </summary>
        /// <param name="value">The current value.</param>
        /// <param name="costBasis">The cost basis.</param>
        /// <returns>The unrounded P/L percent.</returns>
        public static decimal PnlPercent(decimal value, decimal costBasis)
        {
            if (costBasis == 0)
            {
                return 0;
            }

            return ((value - costBasis) / costBasis) * 100;
        }

        /// <summary>
        /// Risk level from the largest position's unrounded share of the total value:
        /// <see cref="RiskLow"/> below 25, <see cref="RiskMedium"/> from 25 up to and including
        /// 50, <see cref="RiskHigh"/> above 50.
        /// </summary>
        /// <param name="largestPercent">The largest position's percent of the total value.</param>
        /// <returns>The risk level wire value.</returns>
        public static string RiskLevelFor(decimal largestPercent)
        {
            return largestPercent switch
            {
                < 25 => RiskLow,
                <= 50 => RiskMedium,
                _ => RiskHigh,
            };
        }

        /// <summary>
        /// Values each positive-quantity holding at its selected candle's close and costs it from
        /// its own executed trades. A holding without a candle is valued at a price of 0.
        /// </summary>
        /// <param name="holdings">The account's owned-instrument rows.</param>
        /// <param name="names">Instrument names by id; a missing name becomes empty.</param>
        /// <param name="trades">The account's trades of every instrument.</param>
        /// <param name="selectedPrices">
        /// One candle per instrument, as chosen by <see cref="LatestPriceSelector.Select"/>.
        /// </param>
        /// <returns>One position per selected holding, in holding order.</returns>
        public static IReadOnlyList<HoldingPosition> BuildPositions(
            IEnumerable<OwnedInstrument> holdings,
            IReadOnlyDictionary<Guid, string> names,
            IEnumerable<Trade> trades,
            IReadOnlyDictionary<Guid, Price> selectedPrices
        )
        {
            ArgumentNullException.ThrowIfNull(holdings);
            ArgumentNullException.ThrowIfNull(names);
            ArgumentNullException.ThrowIfNull(trades);
            ArgumentNullException.ThrowIfNull(selectedPrices);

            ILookup<Guid, Trade> tradesByInstrument = trades.ToLookup(trade => trade.InstrumentId);
            List<HoldingPosition> positions = [];
            foreach (OwnedInstrument holding in SelectHoldings(holdings))
            {
                Guid instrumentId = holding.InstrumentId;
                string name = names.TryGetValue(instrumentId, out string? knownName)
                    ? knownName
                    : string.Empty;

                decimal latestPrice = 0;
                bool hasPrice = false;
                if (selectedPrices.TryGetValue(instrumentId, out Price? candle))
                {
                    latestPrice = candle.Close;
                    hasPrice = true;
                }

                decimal value = holding.Quantity * latestPrice;
                decimal costBasis = CalculateCostBasis(
                    holding.Quantity,
                    latestPrice,
                    tradesByInstrument[instrumentId]
                );
                positions.Add(
                    new HoldingPosition(
                        instrumentId,
                        name,
                        holding.Quantity,
                        latestPrice,
                        hasPrice,
                        value,
                        costBasis,
                        PnlPercent(value, costBasis)
                    )
                );
            }
            return positions;
        }

        /// <summary>
        /// Aggregates positions into the insights result: totals, allocations ordered by value
        /// descending then by the lowercase instrument id string ordinally, the largest position
        /// and its risk level. Nothing is rounded, and every division is guarded against zero.
        /// </summary>
        /// <param name="positions">The account's positions; empty for no holdings.</param>
        /// <returns>
        /// The insights result; with no positions it has zero totals, no allocations and a null
        /// largest position and risk level.
        /// </returns>
        public static PortfolioInsightsDTO Calculate(IReadOnlyList<HoldingPosition> positions)
        {
            ArgumentNullException.ThrowIfNull(positions);

            decimal totalValue = positions.Sum(position => position.Value);
            decimal totalInvested = positions.Sum(position => position.CostBasis);
            decimal unrealizedPnl = totalInvested == 0 ? 0 : totalValue - totalInvested;
            decimal unrealizedPnlPercent =
                totalInvested == 0 ? 0 : (unrealizedPnl / totalInvested) * 100;

            List<AllocationDTO> allocations =
            [
                .. positions
                    .Select(position => new AllocationDTO(
                        position.InstrumentId,
                        position.Name,
                        position.Quantity,
                        position.Value,
                        totalValue == 0 ? 0 : (position.Value / totalValue) * 100
                    ))
                    .OrderByDescending(allocation => allocation.Value)
                    .ThenBy(
                        allocation => allocation.InstrumentId.ToString(),
                        StringComparer.Ordinal
                    ),
            ];

            AllocationDTO? largestPosition = allocations.Count == 0 ? null : allocations[0];
            string? riskLevel = largestPosition is null
                ? null
                : RiskLevelFor(largestPosition.Percent);

            return new PortfolioInsightsDTO(
                totalValue,
                totalInvested,
                unrealizedPnl,
                unrealizedPnlPercent,
                allocations,
                largestPosition,
                riskLevel
            );
        }

        /// <summary>
        /// The result for an account without holdings.
        /// </summary>
        /// <returns>A new result with zero totals and no allocations.</returns>
        public static PortfolioInsightsDTO Empty()
        {
            return Calculate([]);
        }

        private static bool IsBuy(Trade trade)
        {
            return trade.Direction is BuyDirection or LongBuyDirection;
        }
    }
}
