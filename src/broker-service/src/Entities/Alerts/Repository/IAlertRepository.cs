namespace EasyTrade.BrokerService.Entities.Alerts.Repository
{
    /// <summary>
    /// Persistence port for alerts, served by db-adapter. Every member reports a failed call as
    /// <see cref="EasyTrade.BrokerService.ExceptionHandling.Exceptions.DbException"/>; a missing
    /// alert is reported as <c>null</c> or <c>false</c>, never as an exception.
    /// </summary>
    public interface IAlertRepository
    {
        /// <summary>
        /// Creates an armed alert: <c>Enabled = true</c>, <c>ArmingRevision = 1</c>, no trigger
        /// and not acknowledged. db-adapter generates <see cref="Alert.Id"/> and
        /// <see cref="Alert.CreatedAt"/>.
        /// </summary>
        Task<Alert> CreateAsync(
            Guid accountId,
            AlertType type,
            Guid instrumentId,
            AlertDirection direction,
            decimal threshold
        );

        /// <summary>
        /// Lists alerts. A <c>null</c> <paramref name="accountId"/> lists every account.
        /// <paramref name="armedOnly"/> keeps <c>Enabled</c> alerts whose current arming has not
        /// triggered; <paramref name="triggeredOnly"/> keeps triggered alerts, ordered by
        /// <see cref="Alert.TriggeredAt"/> descending; otherwise the order is
        /// <see cref="Alert.CreatedAt"/> descending, then <see cref="Alert.Id"/> descending.
        /// <paramref name="unacknowledgedOnly"/> keeps alerts that are not acknowledged.
        /// <paramref name="cancellationToken"/> reaches the gRPC call.
        /// </summary>
        Task<IReadOnlyList<Alert>> ListAsync(
            Guid? accountId,
            bool armedOnly,
            bool triggeredOnly,
            bool unacknowledgedOnly,
            CancellationToken cancellationToken = default
        );

        /// <summary>Reads one alert; <c>null</c> when it does not exist.</summary>
        Task<Alert?> GetAlertAsync(Guid id);

        /// <summary>
        /// <c>true</c> re-arms the alert: it clears the trigger fields and the acknowledgement and
        /// increments <see cref="Alert.ArmingRevision"/>. <c>false</c> sets only
        /// <c>Enabled = false</c> and keeps any trigger data. Returns the snapshot this update
        /// wrote, or <c>null</c> when the alert does not exist.
        /// </summary>
        Task<Alert?> UpdateEnabledAsync(Guid id, bool enabled);

        /// <summary>
        /// Deletes the alert and its notification; <c>false</c> when it does not exist.
        /// </summary>
        Task<bool> DeleteAsync(Guid id);

        /// <summary>
        /// Acknowledges the notification of the current arming when that arming has triggered.
        /// Returns <c>true</c> whenever the alert exists, including the no-op on an arming that
        /// has not triggered, and <c>false</c> when it does not exist.
        /// </summary>
        Task<bool> AcknowledgeAsync(Guid id);

        /// <summary>
        /// The single conditional write that records a trigger: it succeeds only for the alert
        /// <paramref name="id"/> at <paramref name="armingRevision"/> while it is enabled and its
        /// arming has not triggered. Returns db-adapter's <c>triggered</c> flag. <c>false</c> is a
        /// normal outcome, not an error: another evaluator won, or the alert was disabled,
        /// deleted or re-armed meanwhile. <paramref name="triggerValue"/> is already rounded and
        /// validated by the caller. <paramref name="cancellationToken"/> reaches the gRPC call.
        /// </summary>
        Task<bool> TriggerAsync(
            Guid id,
            int armingRevision,
            decimal triggerValue,
            CancellationToken cancellationToken = default
        );
    }
}
