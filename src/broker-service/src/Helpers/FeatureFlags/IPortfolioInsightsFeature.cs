namespace EasyTrade.BrokerService.Helpers.FeatureFlags
{
    public interface IPortfolioInsightsFeature
    {
        /// <summary>
        /// Reads the portfolio-insights-enabled flag fresh, without caching. Returns true only
        /// when the flag service answers with the flag of exactly that id, enabled; returns false
        /// when it is disabled, unknown or unreadable, when the answer carries another id or none,
        /// or when the read deadline expires, even for a read that completes as it expires.
        /// Cancellation of <paramref name="cancellationToken"/> propagates as
        /// OperationCanceledException.
        /// </summary>
        Task<bool> IsEnabledAsync(CancellationToken cancellationToken);
    }
}
