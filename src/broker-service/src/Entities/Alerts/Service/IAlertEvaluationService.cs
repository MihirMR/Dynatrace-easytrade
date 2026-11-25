namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    public interface IAlertEvaluationService
    {
        /// <summary>
        /// Runs one alert evaluation cycle. One portfolio insights flag read starts it; when the
        /// flag is off or unreadable, no alert is listed, no price is fetched and no metric is
        /// recorded (<see cref="AlertEvaluationOutcome.FlagDisabled"/>). Otherwise the armed
        /// alerts of every account are listed once: a failed listing ends the cycle
        /// <see cref="AlertEvaluationOutcome.Failed"/> and an empty armed set ends it
        /// <see cref="AlertEvaluationOutcome.Completed"/>, both without pricing. Otherwise the
        /// latest prices are fetched once, and a failed or empty fetch ends the cycle
        /// <see cref="AlertEvaluationOutcome.Failed"/> with no alert evaluated. Otherwise every
        /// armed alert is evaluated, and each crossing is recorded by the single conditional
        /// trigger write, which alone decides whether it notifies.
        /// </summary>
        /// <param name="cancellationToken">
        /// Cancels the cycle, normally on host shutdown. It is observed in the flag read and the
        /// db-adapter calls, after each call that takes no token (the price fetch and the
        /// positions load), and between alerts. Triggers committed before the cancellation stay
        /// committed and counted; the cancelled cycle records no duration and logs no summary.
        /// </param>
        /// <returns>
        /// The cycle result, whose outcome is <see cref="AlertEvaluationOutcome.FlagDisabled"/>,
        /// <see cref="AlertEvaluationOutcome.Completed"/>,
        /// <see cref="AlertEvaluationOutcome.Failed"/> or
        /// <see cref="AlertEvaluationOutcome.Cancelled"/>. Cancellation of
        /// <paramref name="cancellationToken"/> is reported as
        /// <see cref="AlertEvaluationOutcome.Cancelled"/> and never thrown.
        /// </returns>
        Task<AlertEvaluationResult> RunCycleAsync(CancellationToken cancellationToken);
    }
}
