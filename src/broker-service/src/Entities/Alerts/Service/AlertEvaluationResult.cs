namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// How one alert evaluation cycle ended.
    /// </summary>
    public enum AlertEvaluationOutcome
    {
        /// <summary>
        /// The portfolio insights flag was off or unreadable, so the cycle loaded no alerts,
        /// fetched no prices and recorded no metrics.
        /// </summary>
        FlagDisabled,

        /// <summary>
        /// Every armed alert was evaluated, including the case of an empty armed set.
        /// </summary>
        Completed,

        /// <summary>
        /// The cycle failed as a whole: listing alerts failed, or fetching prices failed or
        /// returned no prices while armed alerts existed. No alert was evaluated.
        /// </summary>
        Failed,

        /// <summary>
        /// The cycle's token was cancelled, normally by host shutdown. Triggers committed before
        /// the cancellation stay committed.
        /// </summary>
        Cancelled,
    }

    /// <summary>
    /// Outcome and counts of one alert evaluation cycle.
    /// </summary>
    /// <param name="Outcome">How the cycle ended.</param>
    /// <param name="AlertCount">
    /// The number of armed alerts listed this cycle; 0 when listing failed or the flag was off.
    /// </param>
    /// <param name="Triggered">
    /// The number of <c>TriggerAlert</c> calls that returned <c>triggered = true</c>.
    /// </param>
    /// <param name="Failed">
    /// The number of per-alert failures. Cycle-level failures and cancellation are never counted
    /// here.
    /// </param>
    /// <param name="Skipped">
    /// The number of alerts skipped as <c>no_holding</c> or <c>no_price</c>.
    /// </param>
    /// <param name="Duration">
    /// The measured cycle time for <see cref="AlertEvaluationOutcome.Completed"/> and
    /// <see cref="AlertEvaluationOutcome.Failed"/>; <see cref="TimeSpan.Zero"/> for
    /// <see cref="AlertEvaluationOutcome.FlagDisabled"/> and
    /// <see cref="AlertEvaluationOutcome.Cancelled"/>.
    /// </param>
    public record AlertEvaluationResult(
        AlertEvaluationOutcome Outcome,
        int AlertCount,
        int Triggered,
        int Failed,
        int Skipped,
        TimeSpan Duration
    );
}
