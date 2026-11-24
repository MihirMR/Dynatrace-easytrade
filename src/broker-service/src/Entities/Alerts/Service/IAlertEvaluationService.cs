namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    public interface IAlertEvaluationService
    {
        /// <summary>
        /// Runs one alert evaluation cycle: a single portfolio insights flag check, a single
        /// listing of the armed alerts of every account, a single latest-price fetch, then the
        /// evaluation of each armed alert, recording each crossing through the conditional
        /// trigger write.
        /// </summary>
        /// <param name="cancellationToken">
        /// Cancels the cycle between alerts and in the db-adapter calls, normally on host
        /// shutdown. Triggers committed before the cancellation stay committed.
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
