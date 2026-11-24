namespace EasyTrade.BrokerService.Helpers.FeatureFlags
{
    public interface IPortfolioInsightsFeature
    {
        /// <summary>
        /// Reads the portfolio-insights-enabled flag fresh, without caching. Returns true only
        /// when the flag service reports the flag enabled; returns false when it is disabled,
        /// unknown or unreadable, or when the read deadline expires. Cancellation of
        /// <paramref name="cancellationToken"/> propagates as OperationCanceledException.
        /// </summary>
        Task<bool> IsEnabledAsync(CancellationToken cancellationToken);
    }
}
