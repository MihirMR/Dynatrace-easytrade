using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using Grpc.Core;

namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// Alert CRUD rules behind the six <c>/v1/alerts</c> endpoints. Every write goes through
    /// db-adapter by <see cref="IAlertRepository"/>; account, instrument and holding checks are
    /// read-only. This class is the only place where a repository miss (<c>null</c> or
    /// <c>false</c>) becomes an <see cref="AlertNotFoundException"/>. It also answers a create
    /// that db-adapter rejects as NotFound, because a reference was removed between the checks
    /// and the insert, with a 404 <see cref="BalanceNotFoundException"/> naming both the account
    /// and the instrument. Each audit line is written only after its db-adapter call has returned
    /// successfully, so a failed write logs none. The checks read through existing repositories
    /// that set no deadline and take no token, so each is awaited within
    /// <see cref="AlertRepository.CallTimeout"/> on the injected <see cref="TimeProvider"/>'s
    /// clock and only until the request's token is cancelled.
    /// </summary>
    public class AlertService(
        IAlertRepository alertRepository,
        IBalanceRepository balanceRepository,
        IInstrumentRepository instrumentRepository,
        TimeProvider timeProvider,
        ILogger<AlertService> logger
    ) : IAlertService
    {
        private const string CreatedTemplate =
            "Alert [{alertId}] created for account [{accountId}] type [{type}] "
            + "instrument [{instrumentId}] direction [{direction}] threshold [{threshold}]";
        private const string EnabledChangedTemplate =
            "Alert [{alertId}] of account [{accountId}] enabled [{enabled}] "
            + "revision [{armingRevision}]";
        private const string DeletedTemplate = "Alert [{alertId}] of account [{accountId}] deleted";
        private const string AcknowledgeAcceptedTemplate =
            "Alert [{alertId}] of account [{accountId}] acknowledgement request accepted";
        private const string AlertsListedTemplate =
            "Listed [{count}] alerts for account [{accountId}]";
        private const string NotificationsListedTemplate =
            "Listed [{count}] notifications for account [{accountId}]";

        // Every log call below is guarded by IsEnabled, so arguments are neither boxed nor
        // computed while the level is off (CA1873).

        /// <inheritdoc/>
        public async Task<AlertDTO> CreateAlertAsync(
            CreateAlertDTO request,
            CancellationToken cancellationToken = default
        )
        {
            ArgumentNullException.ThrowIfNull(request);

            // Field rules first, in this order: a malformed request never reaches a 404.
            if (request.AccountId is not Guid accountId)
            {
                throw new InvalidAlertException("Field accountId is required");
            }

            if (request.InstrumentId is not Guid instrumentId)
            {
                throw new InvalidAlertException("Field instrumentId is required");
            }

            if (!AlertMapper.TryParseType(request.Type, out AlertType type))
            {
                throw new InvalidAlertException("Field type must be TARGET_PRICE or PROFIT_LOSS");
            }

            if (!AlertMapper.TryParseDirection(request.Direction, out AlertDirection direction))
            {
                throw new InvalidAlertException("Field direction must be ABOVE or BELOW");
            }

            if (request.Threshold is not decimal threshold)
            {
                throw new InvalidAlertException("Field threshold is required");
            }

            if (!AlertNumber.IsInThresholdDomain(threshold))
            {
                throw new InvalidAlertException(
                    "Field threshold must have at most 10 integer and 8 fractional digits"
                );
            }

            if (!AlertNumber.IsValidThreshold(type, threshold))
            {
                throw new InvalidAlertException(
                    "Field threshold must be greater than 0 for TARGET_PRICE alerts"
                );
            }

            await EnsureAccountExistsAsync(accountId, cancellationToken);

            _ =
                await BoundedReadAsync(
                    instrumentRepository.GetInstrumentAsync(instrumentId),
                    nameof(IInstrumentRepository.GetInstrumentAsync),
                    cancellationToken
                ) ?? throw new InstrumentNotFoundException(instrumentId);

            // A TARGET_PRICE alert watches the price alone and never reads holdings.
            if (type == AlertType.PROFIT_LOSS)
            {
                await EnsureHoldingAsync(accountId, instrumentId, cancellationToken);
            }

            Alert alert;
            try
            {
                alert = await alertRepository.CreateAsync(
                    accountId,
                    type,
                    instrumentId,
                    direction,
                    threshold,
                    cancellationToken
                );
            }
            catch (DbException exception)
                when (exception.InnerException is RpcException { StatusCode: StatusCode.NotFound })
            {
                // db-adapter answers the create with NotFound only when a foreign key names no
                // row, so a reference was removed after the checks above passed. Its reply does
                // not say which one, so the 404 names both ids, with no further read. The account
                // exception carries it because accounts are the reference that can disappear;
                // instruments are seeded reference data with no delete path. Every other failure
                // stays the DbException thrown (503), and no audit line is written.
                throw new BalanceNotFoundException(
                    $"Account {accountId} or instrument {instrumentId} not found"
                );
            }

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(
                    CreatedTemplate,
                    alert.Id,
                    alert.AccountId,
                    AlertMapper.ToName(alert.Type),
                    alert.InstrumentId,
                    AlertMapper.ToName(alert.Direction),
                    alert.Threshold
                );
            }

            return AlertMapper.ToDto(alert);
        }

        /// <inheritdoc/>
        public async Task<IEnumerable<AlertDTO>> GetAlertsAsync(
            Guid accountId,
            CancellationToken cancellationToken = default
        )
        {
            await EnsureAccountExistsAsync(accountId, cancellationToken);

            IReadOnlyList<Alert> alerts = await alertRepository.ListAsync(
                accountId,
                false,
                false,
                false,
                cancellationToken
            );

            // Ordered here rather than trusted from SQL, so the order is the same on both
            // dialects; SQL Server does not order uniqueidentifier values by their text.
            List<AlertDTO> results =
            [
                .. alerts
                    .OrderByDescending(alert => alert.CreatedAt)
                    .ThenByDescending(alert => alert.Id.ToString(), StringComparer.Ordinal)
                    .Select(AlertMapper.ToDto),
            ];

            if (logger.IsEnabled(LogLevel.Debug))
            {
                logger.LogDebug(AlertsListedTemplate, results.Count, accountId);
            }

            return results;
        }

        /// <inheritdoc/>
        public async Task<IEnumerable<AlertDTO>> GetNotificationsAsync(
            Guid accountId,
            bool unacknowledgedOnly,
            CancellationToken cancellationToken = default
        )
        {
            await EnsureAccountExistsAsync(accountId, cancellationToken);

            // db-adapter decides membership: a triggered alert stays listed after a disable.
            IReadOnlyList<Alert> alerts = await alertRepository.ListAsync(
                accountId,
                false,
                true,
                unacknowledgedOnly,
                cancellationToken
            );

            // db-adapter returns triggered alerts newest trigger first, which is the contract
            // order, so they are kept as listed; ties have no contracted order.
            List<AlertDTO> results = [.. alerts.Select(AlertMapper.ToDto)];

            if (logger.IsEnabled(LogLevel.Debug))
            {
                logger.LogDebug(NotificationsListedTemplate, results.Count, accountId);
            }

            return results;
        }

        /// <inheritdoc/>
        public async Task<AlertDTO> UpdateEnabledAsync(
            Guid id,
            UpdateAlertDTO request,
            CancellationToken cancellationToken = default
        )
        {
            ArgumentNullException.ThrowIfNull(request);

            if (request.Enabled is not bool enabled)
            {
                throw new InvalidAlertException("Field enabled is required");
            }

            // The reply is the snapshot db-adapter read inside the update's own transaction, so
            // it is returned as is: a second read could show another PATCH or a later trigger.
            Alert alert =
                await alertRepository.UpdateEnabledAsync(id, enabled, cancellationToken)
                ?? throw new AlertNotFoundException(id);

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(
                    EnabledChangedTemplate,
                    alert.Id,
                    alert.AccountId,
                    alert.Enabled,
                    alert.ArmingRevision
                );
            }

            return AlertMapper.ToDto(alert);
        }

        /// <inheritdoc/>
        public async Task DeleteAlertAsync(Guid id, CancellationToken cancellationToken = default)
        {
            // Read first only so that the audit line can name the owning account.
            Alert alert = await GetAlertOrThrowAsync(id, cancellationToken);

            // false here means a concurrent delete removed the alert after the read.
            if (!await alertRepository.DeleteAsync(id, cancellationToken))
            {
                throw new AlertNotFoundException(id);
            }

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(DeletedTemplate, alert.Id, alert.AccountId);
            }
        }

        /// <inheritdoc/>
        public async Task AcknowledgeAlertAsync(
            Guid id,
            CancellationToken cancellationToken = default
        )
        {
            Alert alert = await GetAlertOrThrowAsync(id, cancellationToken);

            // The repository reports only whether the alert exists: false for an unknown id, true
            // otherwise. db-adapter acknowledges the current arming only if it has triggered at
            // the moment of this write, so the broker cannot tell an acknowledgement from the
            // no-op on an untriggered arming, which is still a 204; the read above can be stale
            // by then. The audit line therefore records that the request was accepted, never
            // that a notification was acknowledged.
            if (!await alertRepository.AcknowledgeAsync(id, cancellationToken))
            {
                throw new AlertNotFoundException(id);
            }

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(AcknowledgeAcceptedTemplate, alert.Id, alert.AccountId);
            }
        }

        // An account is known when it has a balance row, the existing broker account check.
        private async Task EnsureAccountExistsAsync(
            Guid accountId,
            CancellationToken cancellationToken
        )
        {
            _ =
                await BoundedReadAsync(
                    balanceRepository.GetBalanceOfAccountAsync(accountId),
                    nameof(IBalanceRepository.GetBalanceOfAccountAsync),
                    cancellationToken
                ) ?? throw new BalanceNotFoundException(accountId);
        }

        private async Task EnsureHoldingAsync(
            Guid accountId,
            Guid instrumentId,
            CancellationToken cancellationToken
        )
        {
            List<OwnedInstrument> owned = await BoundedReadAsync(
                instrumentRepository.GetOwnedInstrumentsOfAccountAsync(accountId),
                nameof(IInstrumentRepository.GetOwnedInstrumentsOfAccountAsync),
                cancellationToken
            );
            IReadOnlyList<OwnedInstrument> holdings = PortfolioInsightsCalculator.SelectHoldings(
                owned
            );
            if (!holdings.Any(holding => holding.InstrumentId == instrumentId))
            {
                throw new InvalidAlertException(
                    "PROFIT_LOSS alerts require a holding of the instrument"
                );
            }
        }

        private async Task<Alert> GetAlertOrThrowAsync(Guid id, CancellationToken cancellationToken)
        {
            return await alertRepository.GetAlertAsync(id, cancellationToken)
                ?? throw new AlertNotFoundException(id);
        }

        // A check's read through an existing repository, which sets no gRPC deadline and takes no
        // token: no reply within the call budget, or a cancelled request, fails it with a
        // DbException (503) before any alert call is made.
        private Task<T> BoundedReadAsync<T>(
            Task<T> call,
            string operation,
            CancellationToken cancellationToken
        )
        {
            return AlertRepository.BoundExistingReadAsync(
                call,
                operation,
                timeProvider,
                cancellationToken
            );
        }
    }
}
