using EasyTrade.BrokerService.Entities.Alerts.DTO;

namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// Alert rules behind the six <c>/v1/alerts</c> endpoints. Members return alerts as
    /// <see cref="AlertDTO"/> values; wrapping a list in the <c>{"results": [...]}</c> envelope is
    /// the controller's job. Operations by alert id take only the id and perform no ownership
    /// check. A failed db-adapter call throws
    /// <see cref="ExceptionHandling.Exceptions.DbException"/> (503) from every member, except a
    /// create that db-adapter rejects as NotFound because a reference was removed between the
    /// checks and the insert: <see cref="CreateAlertAsync"/> answers it with a 404
    /// <see cref="ExceptionHandling.Exceptions.BalanceNotFoundException"/> naming both ids.
    /// Every member takes the request's abort token as <c>cancellationToken</c> and passes it to
    /// every <see cref="Repository.IAlertRepository"/> call it makes, so a caller that disconnects
    /// cancels the alert call in flight. The account, instrument and holding checks read through
    /// existing repositories that take no token, so each check is awaited for at most
    /// <see cref="Repository.AlertRepository.CallTimeout"/> and abandoned as soon as the token
    /// cancels. Cancellation and a check left unanswered, like every failed db-adapter call,
    /// surface as that <c>DbException</c>.
    /// </summary>
    public interface IAlertService
    {
        /// <summary>
        /// Serves <c>POST /v1/alerts</c>. Checks run in order and the first failure answers:
        /// required fields, exact type and direction names and the threshold domain (a
        /// <c>TARGET_PRICE</c> threshold must be positive); the account; the instrument; and,
        /// for <c>PROFIT_LOSS</c>, a holding of the instrument with a positive quantity. When
        /// db-adapter rejects the create as NotFound, a reference was removed between these
        /// checks and the insert; db-adapter does not say which one, so the 404 names both ids
        /// and nothing is read again.
        /// </summary>
        /// <returns>
        /// The created alert: enabled, arming revision 1, no trigger data and not acknowledged.
        /// </returns>
        /// <exception cref="ExceptionHandling.Exceptions.InvalidAlertException">
        /// 400: a field is missing or invalid, or a <c>PROFIT_LOSS</c> alert names an instrument
        /// the account does not hold.
        /// </exception>
        /// <exception cref="ExceptionHandling.Exceptions.BalanceNotFoundException">
        /// 404: the account is unknown, or a reference was removed between the checks and the
        /// insert, with the message <c>Account {accountId} or instrument {instrumentId} not
        /// found</c>.
        /// </exception>
        /// <exception cref="ExceptionHandling.Exceptions.InstrumentNotFoundException">
        /// 404: the instrument is unknown.
        /// </exception>
        Task<AlertDTO> CreateAlertAsync(
            CreateAlertDTO request,
            CancellationToken cancellationToken = default
        );

        /// <summary>
        /// Serves <c>GET /v1/alerts?accountId=</c>: every alert of the account, newest first
        /// (<c>createdAt</c> descending, then <c>id</c> descending); empty when it has none.
        /// </summary>
        /// <exception cref="ExceptionHandling.Exceptions.BalanceNotFoundException">
        /// 404: the account is unknown.
        /// </exception>
        Task<IEnumerable<AlertDTO>> GetAlertsAsync(
            Guid accountId,
            CancellationToken cancellationToken = default
        );

        /// <summary>
        /// Serves <c>GET /v1/alerts/notifications?accountId=&amp;unacknowledged=</c>: the alerts
        /// of the account whose current arming has triggered, ordered by <c>triggeredAt</c>
        /// descending. <paramref name="unacknowledgedOnly"/> keeps only those not acknowledged.
        /// </summary>
        /// <exception cref="ExceptionHandling.Exceptions.BalanceNotFoundException">
        /// 404: the account is unknown.
        /// </exception>
        Task<IEnumerable<AlertDTO>> GetNotificationsAsync(
            Guid accountId,
            bool unacknowledgedOnly,
            CancellationToken cancellationToken = default
        );

        /// <summary>
        /// Serves <c>PATCH /v1/alerts/{id}</c>. <c>true</c> re-arms the alert whatever its state:
        /// it is enabled, its trigger data and acknowledgement are cleared and its arming
        /// revision increases. <c>false</c> only disables it and keeps any trigger data.
        /// </summary>
        /// <returns>The alert as this update wrote it.</returns>
        /// <exception cref="ExceptionHandling.Exceptions.InvalidAlertException">
        /// 400: <c>enabled</c> is missing or <c>null</c>.
        /// </exception>
        /// <exception cref="ExceptionHandling.Exceptions.AlertNotFoundException">
        /// 404: the alert is unknown or was deleted.
        /// </exception>
        Task<AlertDTO> UpdateEnabledAsync(
            Guid id,
            UpdateAlertDTO request,
            CancellationToken cancellationToken = default
        );

        /// <summary>
        /// Serves <c>DELETE /v1/alerts/{id}</c>: removes the alert together with its
        /// notification.
        /// </summary>
        /// <exception cref="ExceptionHandling.Exceptions.AlertNotFoundException">
        /// 404: the alert is unknown or was deleted.
        /// </exception>
        Task DeleteAlertAsync(Guid id, CancellationToken cancellationToken = default);

        /// <summary>
        /// Serves <c>POST /v1/alerts/{id}/acknowledge</c>: acknowledges the notification of the
        /// alert's current arming. When that arming has not triggered, nothing changes, so a
        /// future trigger is never acknowledged in advance.
        /// </summary>
        /// <exception cref="ExceptionHandling.Exceptions.AlertNotFoundException">
        /// 404: the alert is unknown or was deleted.
        /// </exception>
        Task AcknowledgeAlertAsync(Guid id, CancellationToken cancellationToken = default);
    }
}
