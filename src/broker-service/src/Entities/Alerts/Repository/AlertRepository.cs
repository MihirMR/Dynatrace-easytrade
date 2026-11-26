using System.Globalization;
using EasyTrade.BrokerService.Connectors;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
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
        /// Budget of every db-adapter <c>AlertService</c> call this repository makes, sent as the
        /// gRPC deadline of that call when it starts. <see cref="BoundExistingReadAsync{T}"/> and
        /// <see cref="WithinCallTimeoutAsync{T}"/> apply the same budget to the reads the insights
        /// endpoint and the alert endpoints' checks make through the existing repositories, and
        /// to the insights latest-price fetch, which set no deadline of their own.
        /// </summary>
        /// <remarks>
        /// Each call also carries its caller's token. The evaluator's calls,
        /// <see cref="ListAsync"/> and <see cref="TriggerAsync"/>, carry the host token, which
        /// cancels only at shutdown. The calls of the six REST endpoints, made through the alert
        /// service and including <see cref="ListAsync"/> for <c>GET /v1/alerts</c> and
        /// <c>GET /v1/alerts/notifications</c>, carry the request's abort token, which cancels
        /// when the caller disconnects. Without the bound, a db-adapter that accepts a call but
        /// never answers would hold an evaluation cycle, and every later tick, for as long as the
        /// host runs, and hold a request for as long as its caller waits. 10 s is far above a
        /// healthy call and below the default evaluation interval. Expiry fails the call with
        /// <c>DeadlineExceeded</c>, which <see cref="GrpcHelper.ExecuteAsync{T}"/> and
        /// <see cref="GrpcHelper.ExecuteOrNullAsync{T}"/> wrap in a <c>DbException</c> while the
        /// caller's token is still live: a 503 on the REST endpoints and a failure in the
        /// evaluator, never a cancellation and never a missing alert. A write that db-adapter
        /// committed but answered too late stays committed and is not retried; for a trigger, its
        /// arming no longer matches the conditional write, so no second notification follows.
        /// </remarks>
        public static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(10);

        /// <summary>
        /// Awaits <paramref name="call"/>, a db-adapter read made through an existing repository,
        /// for at most <see cref="CallTimeout"/> on <paramref name="timeProvider"/>'s clock, and
        /// stops waiting as soon as <paramref name="cancellationToken"/> is cancelled.
        /// </summary>
        /// <remarks>
        /// The bound gives up the wait, not the call: the existing call sets no deadline and
        /// takes no token, so it runs on until db-adapter answers or its connection fails. Its
        /// result is discarded and its eventual fault is observed, so it never surfaces as an
        /// unobserved task exception.
        /// </remarks>
        /// <param name="call">The read in flight.</param>
        /// <param name="operation">
        /// The repository method's name, for example
        /// <c>nameof(IBalanceRepository.GetBalanceOfAccountAsync)</c>. It must be an
        /// identifier, so the exception filter logs it as the failed db-adapter call.
        /// </param>
        /// <param name="timeProvider">The clock that times the bound.</param>
        /// <param name="cancellationToken">
        /// The caller's token, such as a request's abort token.
        /// </param>
        /// <returns>The read's own result.</returns>
        /// <exception cref="DbException">
        /// The read did not answer within <see cref="CallTimeout"/>, with the
        /// <see cref="TimeoutException"/> as its inner exception, or
        /// <paramref name="cancellationToken"/> was cancelled first, with the
        /// <see cref="OperationCanceledException"/> as its inner exception. Its message starts
        /// with <c>Db Adapter call error in "operation" method: </c>, as <c>GrpcHelper</c>'s
        /// does, so it answers 503 like any failed db-adapter call. Any exception the read
        /// throws itself, a <c>DbException</c> from <c>GrpcHelper</c> included, propagates
        /// unchanged.
        /// </exception>
        public static async Task<T> BoundExistingReadAsync<T>(
            Task<T> call,
            string operation,
            TimeProvider timeProvider,
            CancellationToken cancellationToken = default
        )
        {
            ArgumentNullException.ThrowIfNull(call);
            ArgumentException.ThrowIfNullOrWhiteSpace(operation);
            ArgumentNullException.ThrowIfNull(timeProvider);

            try
            {
                return await call.WaitAsync(CallTimeout, timeProvider, cancellationToken);
            }
            catch (Exception exception) when (WaitGaveUp(call, exception, cancellationToken))
            {
                ObserveAbandoned(call);
                string seconds = CallTimeout.TotalSeconds.ToString(CultureInfo.InvariantCulture);
                string reason =
                    exception is TimeoutException
                        ? $"no reply within {seconds} s"
                        : "the caller cancelled before a reply";
                throw new DbException(
                    $"Db Adapter call error in \"{operation}\" method: {reason}",
                    exception
                );
            }
        }

        /// <summary>
        /// Awaits <paramref name="call"/> for at most <see cref="CallTimeout"/> on
        /// <paramref name="timeProvider"/>'s clock, for a caller that maps the expiry to an error
        /// of its own, such as the insights latest-price fetch. Like
        /// <see cref="BoundExistingReadAsync{T}"/>, it gives up the wait, not the call, and
        /// observes the abandoned call's eventual fault.
        /// </summary>
        /// <param name="call">The call in flight.</param>
        /// <param name="timeProvider">The clock that times the bound.</param>
        /// <returns>The call's own result.</returns>
        /// <exception cref="TimeoutException">
        /// The call did not answer within <see cref="CallTimeout"/>. Any exception the call
        /// throws itself propagates unchanged.
        /// </exception>
        public static async Task<T> WithinCallTimeoutAsync<T>(
            Task<T> call,
            TimeProvider timeProvider
        )
        {
            ArgumentNullException.ThrowIfNull(call);
            ArgumentNullException.ThrowIfNull(timeProvider);

            try
            {
                return await call.WaitAsync(CallTimeout, timeProvider);
            }
            catch (Exception exception) when (WaitGaveUp(call, exception, CancellationToken.None))
            {
                ObserveAbandoned(call);
                throw;
            }
        }

        public async Task<Alert> CreateAsync(
            Guid accountId,
            AlertType type,
            Guid instrumentId,
            AlertDirection direction,
            decimal threshold,
            CancellationToken cancellationToken = default
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
                async () =>
                    AlertMapper.FromProto(
                        await GetClient()
                            .CreateAlertAsync(
                                request,
                                deadline: DateTime.UtcNow.Add(CallTimeout),
                                cancellationToken: cancellationToken
                            )
                    )
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
                                    deadline: DateTime.UtcNow.Add(CallTimeout),
                                    cancellationToken: cancellationToken
                                )
                        ).Alerts
                    )
            );
            return alerts;
        }

        public async Task<Alert?> GetAlertAsync(
            Guid id,
            CancellationToken cancellationToken = default
        )
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            return await GrpcHelper.ExecuteOrNullAsync(
                async () =>
                    AlertMapper.FromProto(
                        await GetClient()
                            .GetAlertAsync(
                                request,
                                deadline: DateTime.UtcNow.Add(CallTimeout),
                                cancellationToken: cancellationToken
                            )
                    )
            );
        }

        public async Task<Alert?> UpdateEnabledAsync(
            Guid id,
            bool enabled,
            CancellationToken cancellationToken = default
        )
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
                    AlertMapper.FromProto(
                        await GetClient()
                            .UpdateAlertEnabledAsync(
                                request,
                                deadline: DateTime.UtcNow.Add(CallTimeout),
                                cancellationToken: cancellationToken
                            )
                    )
            );
        }

        public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            BatchResponse? response = await GrpcHelper.ExecuteOrNullAsync(
                async () =>
                    await GetClient()
                        .DeleteAlertAsync(
                            request,
                            deadline: DateTime.UtcNow.Add(CallTimeout),
                            cancellationToken: cancellationToken
                        )
            );
            return response is not null;
        }

        public async Task<bool> AcknowledgeAsync(
            Guid id,
            CancellationToken cancellationToken = default
        )
        {
            AlertGrpc.AlertIdRequest request = new() { Id = id.ToString() };
            // An existing alert whose arming has not triggered answers with affected = 0; it is
            // still found, so only a NotFound status reports a miss.
            BatchResponse? response = await GrpcHelper.ExecuteOrNullAsync(
                async () =>
                    await GetClient()
                        .AcknowledgeAlertAsync(
                            request,
                            deadline: DateTime.UtcNow.Add(CallTimeout),
                            cancellationToken: cancellationToken
                        )
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
                            deadline: DateTime.UtcNow.Add(CallTimeout),
                            cancellationToken: cancellationToken
                        )
            );
            return response.Triggered;
        }

        // The wait, not the call, ended in the exception: a TimeoutException the call did not
        // throw itself, or the cancellation of the caller's token, which the call never sees.
        private static bool WaitGaveUp(
            Task call,
            Exception exception,
            CancellationToken cancellationToken
        )
        {
            return exception switch
            {
                TimeoutException => call.Exception?.InnerExceptions.Contains(exception) != true,
                OperationCanceledException cancelled => cancellationToken.IsCancellationRequested
                    && (cancelled.CancellationToken == cancellationToken),
                _ => false,
            };
        }

        // The abandoned call ends later; reading its fault then marks it observed.
        private static void ObserveAbandoned(Task call)
        {
            _ = call.ContinueWith(
                static abandoned => _ = abandoned.Exception,
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted
                    | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default
            );
        }
    }
}
