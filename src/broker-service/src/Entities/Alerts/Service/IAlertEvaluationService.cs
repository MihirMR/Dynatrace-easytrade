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
        /// armed alert is evaluated. Only a crossing whose rounded observed value lies in the
        /// trigger-value domain reaches the single conditional trigger write, which alone decides
        /// whether the alert notifies; any other crossing is a per-alert failure
        /// (<c>trigger_value_out_of_range</c>) and is never written. A trigger is counted, in
        /// <see cref="AlertEvaluationResult.Triggered"/> and
        /// <c>easytrade.broker.alerts.triggered</c>, only when the write is observed to return
        /// <c>triggered = true</c>; a write db-adapter committed but whose reply cancellation or
        /// the per-call deadline cut off stays committed and uncounted.
        /// </summary>
        /// <param name="cancellationToken">
        /// Cancels the cycle, normally on host shutdown. It is observed in the flag read and the
        /// db-adapter calls, after each call that takes no token (the price fetch and the
        /// positions load), and between alerts. Triggers db-adapter committed stay committed
        /// after the cancellation, but each is counted only when its <c>triggered = true</c> reply
        /// returned first; one whose reply the cancellation cut off is not counted, and its
        /// arming no longer matches the conditional write, so no second notification follows.
        /// The cancelled cycle records no duration and logs no summary.
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
