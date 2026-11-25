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
                // Rechecked because a provider can complete successfully after the caller
                // cancelled. Only the caller's token is checked: a read that succeeded as the
                // deadline expired still answers.
                cancellationToken.ThrowIfCancellationRequested();
                return result.Value;
            }
            catch (Exception exception)
            {
                // Caller cancellation propagates; every other failure means disabled.
                cancellationToken.ThrowIfCancellationRequested();
                string reason =
                    exception is OperationCanceledException ? "timeout" : exception.GetType().Name;
                // The exception is deliberately not attached: transport and parser errors can
                // carry endpoint and response details. Only the bounded reason is recorded.
                _logger.LogWarning(
                    "Portfolio insights flag unreadable, treating as disabled: reason [{reason}]",
                    reason
                );
                return false;
            }
        }
    }
}
