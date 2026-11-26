using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using OpenFeature;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.Helpers.FeatureFlags
{
    /// <summary>
    /// The only reader of the portfolio-insights-enabled flag. It evaluates the registered
    /// <see cref="FeatureProvider"/> directly on every call instead of going through the
    /// problem-pattern plugin manager, whose cache could keep serving an enabled value after the
    /// flag was switched off or the flag service became unreachable.
    /// </summary>
    public class PortfolioInsightsFeature(
        FeatureProvider provider,
        ILogger<PortfolioInsightsFeature> logger
    ) : IPortfolioInsightsFeature
    {
        public static readonly TimeSpan ReadDeadline = TimeSpan.FromSeconds(2);

        private readonly FeatureProvider _provider = provider;
        private readonly ILogger _logger = logger;

        public async Task<bool> IsEnabledAsync(CancellationToken cancellationToken)
        {
            // Checked first because WaitAsync returns an already completed provider result even
            // for a cancelled token, which would turn a cancelled caller into a flag value.
            cancellationToken.ThrowIfCancellationRequested();
            using CancellationTokenSource deadline =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(ReadDeadline);
            try
            {
                // The token aborts the provider's HTTP request; WaitAsync also bounds a provider
                // that ignores it.
                ResolutionDetails<bool> result = await _provider
                    .ResolveBooleanValueAsync(
                        Constants.PortfolioInsightsEnabled,
                        false,
                        null,
                        deadline.Token
                    )
                    .WaitAsync(deadline.Token);
                // WaitAsync hands back a provider result that completed whatever its token says,
                // so both tokens are rechecked before the result is accepted. The caller's comes
                // first, so a cancelled caller still gets its cancellation rather than a value.
                cancellationToken.ThrowIfCancellationRequested();
                // A read that completed as or after the deadline expired is not accepted: the
                // decision stays bounded by the deadline and fails closed.
                if (deadline.IsCancellationRequested)
                {
                    LogUnreadable("timeout");
                    return false;
                }
                string? answeredId = result.FlagMetadata?.GetString(
                    PluginProvider.FlagIdMetadataKey
                );
                // No answered flag: the service gave a non-200, the connector already logged it,
                // and the provider fell back to the default of disabled.
                if (answeredId is null)
                {
                    return false;
                }
                // Only an answer for the requested flag decides; one for another flag, or for no
                // id at all, means disabled whatever its enabled field says. The comparison is
                // ordinal, as the flag service matches ids.
                if (answeredId != Constants.PortfolioInsightsEnabled)
                {
                    LogUnreadable("unexpected_flag_id");
                    return false;
                }
                return result.Value;
            }
            catch (Exception exception)
            {
                // Caller cancellation propagates; every other failure means disabled.
                cancellationToken.ThrowIfCancellationRequested();
                string reason =
                    exception is OperationCanceledException ? "timeout" : exception.GetType().Name;
                LogUnreadable(reason);
                return false;
            }
        }

        // The exception is deliberately never attached: transport and parser errors can carry
        // endpoint and response details. Only the bounded reason is recorded.
        private void LogUnreadable(string reason)
        {
            _logger.LogWarning(
                "Portfolio insights flag unreadable, treating as disabled: reason [{reason}]",
                reason
            );
        }
    }
}
