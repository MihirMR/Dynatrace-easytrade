using EasyTrade.BrokerService.Connectors;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.DbAdapter.Common.Grpc;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;

namespace EasyTrade.BrokerService.Entities.Alerts.Repository
{
    /// <summary>
    /// <see cref="IAlertRepository"/> over db-adapter's <c>AlertService</c> on the shared
    /// db-adapter channel. The four calls that may miss an alert use
    /// <see cref="GrpcHelper.ExecuteOrNullAsync{T}"/> and report the miss as a value, because
    /// <see cref="GrpcHelper.ExecuteAsync{T}"/> wraps a NotFound status in a <c>DbException</c>
    /// like any other failure.
    /// </summary>
    public class AlertRepository(IDbAdapterConnector connector)
        : DbAdapterRepository<AlertGrpc.AlertService.AlertServiceClient>(
            connector,
            channel => new(channel)
        ),
            IAlertRepository
    {
        /// <summary>
        /// Budget of each evaluator call, <see cref="ListAsync"/> and <see cref="TriggerAsync"/>,
        /// sent as the gRPC deadline of that call when it starts.
        /// </summary>
        /// <remarks>
        /// The host token stops these calls only at shutdown, so without a bound a db-adapter that
        /// accepts a call but never answers would hold the cycle, and every later tick, while the
        /// host runs. 10 s is far above a healthy list or conditional write and below the default
        /// interval. Expiry fails the call with <c>DeadlineExceeded</c>, which
        /// <see cref="GrpcHelper.ExecuteAsync{T}"/> wraps in a <c>DbException</c> while the host
        /// token is still live: a failure, never a cancellation. A trigger that db-adapter
        /// committed but answered too late stays committed; its arming no longer matches the
        /// conditional write, so no second notification follows.
        /// </remarks>
        public static readonly TimeSpan EvaluatorCallTimeout = TimeSpan.FromSeconds(10);

        public async Task<Alert> CreateAsync(
            Guid accountId,
            AlertType type,
            Guid instrumentId,
            AlertDirection direction,
            decimal threshold
        )
        {
            AlertGrpc.CreateAlertRequest request = AlertMapper.ToCreateRequest(
                accountId,
                type,
                instrumentId,
                direction,
                threshold
            );
            return await GrpcHelper.ExecuteAsync(
                async () => AlertMapper.FromProto(await GetClient().CreateAlertAsync(request))
            );
        }

        public async Task<IReadOnlyList<Alert>> ListAsync(
            Guid? accountId,
            bool armedOnly,
            bool triggeredOnly,
            bool unacknowledgedOnly,
            CancellationToken cancellationToken = default
        )
        {
            // An empty account id lists the alerts of every account.
            AlertGrpc.ListAlertsRequest request = new()
            {
                AccountId = accountId?.ToString() ?? string.Empty,
                ArmedOnly = armedOnly,
                TriggeredOnly = triggeredOnly,
                UnacknowledgedOnly = unacknowledgedOnly,
            };
            List<Alert> alerts = await GrpcHelper.ExecuteAsync(
                async () =>
                    AlertMapper.FromProto(
                        (
                            await GetClient()
                                .ListAlertsAsync(
                                    request,
                                    deadline: DateTime.UtcNow.Add(EvaluatorCallTimeout),
                                    cancellationToken: cancellationToken
                                )
                        ).Alerts
                    )
            );
            return alerts;
        }

        public async Task<Alert?> GetAlertAsync(Guid id)
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            return await GrpcHelper.ExecuteOrNullAsync(
                async () => AlertMapper.FromProto(await GetClient().GetAlertAsync(request))
            );
        }

        public async Task<Alert?> UpdateEnabledAsync(Guid id, bool enabled)
        {
            AlertGrpc.UpdateAlertEnabledRequest request = new()
            {
                Id = id.ToString(),
                Enabled = enabled,
            };
            // The reply is the row as this update wrote it, read inside db-adapter's transaction,
            // so it is returned as is and never re-read.
            return await GrpcHelper.ExecuteOrNullAsync(
                async () =>
                    AlertMapper.FromProto(await GetClient().UpdateAlertEnabledAsync(request))
            );
        }

        public async Task<bool> DeleteAsync(Guid id)
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            BatchResponse? response = await GrpcHelper.ExecuteOrNullAsync(
                async () => await GetClient().DeleteAlertAsync(request)
            );
            return response is not null;
        }

        public async Task<bool> AcknowledgeAsync(Guid id)
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            // An existing alert whose arming has not triggered answers with affected = 0; it is
            // still found, so only a NotFound status reports a miss.
            BatchResponse? response = await GrpcHelper.ExecuteOrNullAsync(
                async () => await GetClient().AcknowledgeAlertAsync(request)
            );
            return response is not null;
        }

        public async Task<bool> TriggerAsync(
            Guid id,
            int armingRevision,
            decimal triggerValue,
            CancellationToken cancellationToken = default
        )
        {
            AlertGrpc.TriggerAlertRequest request = new()
            {
                Id = id.ToString(),
                ArmingRevision = armingRevision,
                TriggerValue = AlertNumber.ToWire(triggerValue),
            };
            AlertGrpc.TriggerAlertResponse response = await GrpcHelper.ExecuteAsync(
                async () =>
                    await GetClient()
                        .TriggerAlertAsync(
                            request,
                            deadline: DateTime.UtcNow.Add(EvaluatorCallTimeout),
                            cancellationToken: cancellationToken
                        )
            );
            return response.Triggered;
        }
    }
}
