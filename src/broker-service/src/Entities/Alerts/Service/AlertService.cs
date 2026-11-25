using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;

namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// Alert CRUD rules behind the six <c>/v1/alerts</c> endpoints. Every write goes through
    /// db-adapter by <see cref="IAlertRepository"/>; account, instrument and holding checks are
    /// read-only. This class is the only place where a repository miss (<c>null</c> or
    /// <c>false</c>) becomes an <see cref="AlertNotFoundException"/>. Each audit line is written
    /// only after its db-adapter call has returned successfully, so a failed write logs none.
    /// </summary>
    public class AlertService(
        IAlertRepository alertRepository,
        IBalanceRepository balanceRepository,
        IInstrumentRepository instrumentRepository,
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
        private const string AcknowledgedTemplate =
            "Alert [{alertId}] of account [{accountId}] acknowledged";
        private const string AlertsListedTemplate =
            "Listed [{count}] alerts for account [{accountId}]";
        private const string NotificationsListedTemplate =
            "Listed [{count}] notifications for account [{accountId}]";

        // Every log call below is guarded by IsEnabled, so arguments are neither boxed nor
        // computed while the level is off (CA1873).

        /// <inheritdoc/>
        public async Task<AlertDTO> CreateAlertAsync(CreateAlertDTO request)
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

            await EnsureAccountExistsAsync(accountId);

            _ =
                await instrumentRepository.GetInstrumentAsync(instrumentId)
                ?? throw new InstrumentNotFoundException(instrumentId);

            // A TARGET_PRICE alert watches the price alone and never reads holdings.
            if (type == AlertType.PROFIT_LOSS)
            {
                await EnsureHoldingAsync(accountId, instrumentId);
            }

            Alert alert = await alertRepository.CreateAsync(
                accountId,
                type,
                instrumentId,
                direction,
                threshold
            );

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
        public async Task<IEnumerable<AlertDTO>> GetAlertsAsync(Guid accountId)
        {
            await EnsureAccountExistsAsync(accountId);

            IReadOnlyList<Alert> alerts = await alertRepository.ListAsync(
                accountId,
                false,
                false,
                false
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
            bool unacknowledgedOnly
        )
        {
            await EnsureAccountExistsAsync(accountId);

            // db-adapter decides membership: a triggered alert stays listed after a disable.
            IReadOnlyList<Alert> alerts = await alertRepository.ListAsync(
                accountId,
                false,
                true,
                unacknowledgedOnly
            );

            List<AlertDTO> results =
            [
                .. alerts
                    .OrderByDescending(alert => alert.TriggeredAt)
                    .ThenByDescending(alert => alert.Id.ToString(), StringComparer.Ordinal)
                    .Select(AlertMapper.ToDto),
            ];

            if (logger.IsEnabled(LogLevel.Debug))
            {
                logger.LogDebug(NotificationsListedTemplate, results.Count, accountId);
            }

            return results;
        }

        /// <inheritdoc/>
        public async Task<AlertDTO> UpdateEnabledAsync(Guid id, UpdateAlertDTO request)
        {
            ArgumentNullException.ThrowIfNull(request);

            if (request.Enabled is not bool enabled)
            {
                throw new InvalidAlertException("Field enabled is required");
            }

            // The reply is the snapshot db-adapter read inside the update's own transaction, so
            // it is returned as is: a second read could show another PATCH or a later trigger.
            Alert alert =
                await alertRepository.UpdateEnabledAsync(id, enabled)
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
        public async Task DeleteAlertAsync(Guid id)
        {
            // Read first only so that the audit line can name the owning account.
            Alert alert = await GetAlertOrThrowAsync(id);

            // false here means a concurrent delete removed the alert after the read.
            if (!await alertRepository.DeleteAsync(id))
            {
                throw new AlertNotFoundException(id);
            }

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(DeletedTemplate, alert.Id, alert.AccountId);
            }
        }

        /// <inheritdoc/>
        public async Task AcknowledgeAlertAsync(Guid id)
        {
            Alert alert = await GetAlertOrThrowAsync(id);

            // The repository reports false only for an unknown id. Acknowledging an arming that
            // has not triggered returns true and changes nothing, which is still a 204.
            if (!await alertRepository.AcknowledgeAsync(id))
            {
                throw new AlertNotFoundException(id);
            }

            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(AcknowledgedTemplate, alert.Id, alert.AccountId);
            }
        }

        // An account is known when it has a balance row, the existing broker account check.
        private async Task EnsureAccountExistsAsync(Guid accountId)
        {
            _ =
                await balanceRepository.GetBalanceOfAccountAsync(accountId)
                ?? throw new BalanceNotFoundException(accountId);
        }

        private async Task EnsureHoldingAsync(Guid accountId, Guid instrumentId)
        {
            List<OwnedInstrument> owned =
                await instrumentRepository.GetOwnedInstrumentsOfAccountAsync(accountId);
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

        private async Task<Alert> GetAlertOrThrowAsync(Guid id)
        {
            return await alertRepository.GetAlertAsync(id) ?? throw new AlertNotFoundException(id);
        }
    }
}
