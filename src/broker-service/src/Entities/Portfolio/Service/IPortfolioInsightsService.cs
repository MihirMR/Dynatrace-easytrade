using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Prices;

namespace EasyTrade.BrokerService.Entities.Portfolio.Service
{
    /// <summary>
    /// Values an account's holdings from the existing holdings, trade and pricing data access.
    /// It serves both the portfolio insights endpoint and the alert evaluator, so both apply
    /// the same holding selection, cost basis and valuation rules.
    /// </summary>
    public interface IPortfolioInsightsService
    {
        /// <summary>
        /// Computes the portfolio insights of one account from its positive-quantity holdings,
        /// its executed trades and a single latest-price fetch.
        /// </summary>
        /// <param name="accountId">The account whose holdings are valued.</param>
        /// <returns>
        /// The insights. An account without a positive holding gets zero totals, no
        /// allocations and a null largest position and risk level, and no price is fetched.
        /// </returns>
        /// <remarks>
        /// Throws <c>BalanceNotFoundException</c> for an unknown account (404),
        /// <c>PricingUnavailableException</c> when the price fetch fails or returns no candle
        /// while the account holds instruments (503), and <c>DbException</c> when a db-adapter
        /// call fails (503).
        /// </remarks>
        Task<PortfolioInsightsDTO> GetInsightsAsync(Guid accountId);

        /// <summary>
        /// Values the positive-quantity holdings of one account at prices the caller has
        /// already selected, so an evaluation cycle fetches prices once for every account.
        /// </summary>
        /// <param name="accountId">The account whose holdings are valued.</param>
        /// <param name="selectedPrices">
        /// One candle per instrument id, as <c>LatestPriceSelector.Select</c> returns. A holding
        /// whose instrument has no entry is valued at 0 with
        /// <see cref="HoldingPosition.HasPrice"/> false.
        /// </param>
        /// <returns>One position per positive-quantity holding; empty without holdings.</returns>
        /// <remarks>
        /// Neither checks the account's balance nor fetches prices. Repository failures
        /// propagate to the caller.
        /// </remarks>
        Task<IReadOnlyList<HoldingPosition>> GetHoldingPositionsAsync(
            Guid accountId,
            IReadOnlyDictionary<Guid, Price> selectedPrices
        );
    }
}
