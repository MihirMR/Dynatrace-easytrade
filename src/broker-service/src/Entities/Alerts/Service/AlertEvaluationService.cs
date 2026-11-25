using System.Diagnostics;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;

namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// Runs one alert evaluation cycle over the armed alerts of every account. One flag read
    /// starts the cycle; when the flag is off or unreadable nothing is listed or priced and no
    /// metric is recorded (<see cref="AlertEvaluationOutcome.FlagDisabled"/>). Otherwise the
    /// armed alerts are listed once: a failed listing ends the cycle
    /// <see cref="AlertEvaluationOutcome.Failed"/> and an empty armed set ends it
    /// <see cref="AlertEvaluationOutcome.Completed"/>, both without pricing. Otherwise the latest
    /// prices are fetched once, and a failed or empty fetch ends the cycle
    /// <see cref="AlertEvaluationOutcome.Failed"/> with no alert evaluated. Otherwise every armed
    /// alert is evaluated, and each crossing is recorded by one conditional trigger write, which
    /// alone decides whether it notifies.
    /// </summary>
    public class AlertEvaluationService(
        IAlertRepository alertRepository,
        IPriceServiceConnector priceServiceConnector,
        IPortfolioInsightsService insightsService,
        IPortfolioInsightsFeature feature,
        PortfolioInsightsMetrics metrics,
        ILogger<AlertEvaluationService> logger
    ) : IAlertEvaluationService
    {
        /// <summary>
        /// The most work items evaluated at once: one per <see cref="AlertType.TARGET_PRICE"/>
        /// alert and one per account with <see cref="AlertType.PROFIT_LOSS"/> alerts. It bounds
        /// concurrent db-adapter load, not the number of alerts or the cycle duration.
        /// </summary>
        public const int MaxAccountConcurrency = 8;

        private const string ReasonListFailed = "list_failed";
        private const string ReasonPricesFailed = "prices_failed";
        private const string ReasonPricesEmpty = "prices_empty";
        private const string ReasonNoHolding = "no_holding";
        private const string ReasonNoPrice = "no_price";
        private const string ReasonException = "exception";
        private const string ReasonTriggerValueOutOfRange = "trigger_value_out_of_range";

        private const string FlagDisabledMessage =
            "Alert evaluation skipped: portfolio insights flag disabled or unreadable";
        private const string CycleFailedTemplate =
            "Alert evaluation cycle failed: reason [{reason}]";
        private const string SkippedTemplate =
            "Alert [{alertId}] of account [{accountId}] skipped: reason [{reason}]";
        private const string AlertFailedTemplate =
            "Alert [{alertId}] of account [{accountId}] evaluation failed: reason [{reason}]";
        private const string TriggeredTemplate =
            "Alert [{alertId}] triggered for account [{accountId}] type [{type}] "
            + "direction [{direction}] threshold [{threshold}] value [{triggerValue}] "
            + "revision [{armingRevision}]";

        // The stack scripts parse this line from its "Alert evaluation cycle finished" marker.
        private const string CycleFinishedTemplate =
            "Alert evaluation cycle finished: alerts [{alertCount}] "
            + "triggered [{triggeredCount}] failed [{failedCount}] skipped [{skippedCount}] "
            + "outcome [{outcome}] duration [{durationMs}] ms";
        private const string CycleCancelledTemplate =
            "Alert evaluation cycle cancelled: alerts [{alertCount}] "
            + "triggered [{triggeredCount}]";

        // Serializes every log record this class emits. The console provider writes one record
        // in several separate writes (prefix, message, padding, terminator), so records that
        // parallel workers emit at once would interleave and split lines. Static, because the
        // console is process-wide and evaluator instances can run at the same time. Only log
        // emission is held under it, never evaluation, db-adapter calls or metrics.
        private static readonly Lock LogGate = new();

        /// <inheritdoc/>
        public async Task<AlertEvaluationResult> RunCycleAsync(CancellationToken cancellationToken)
        {
            try
            {
                bool enabled = await feature.IsEnabledAsync(cancellationToken);
                // A call that returns normally does not report a shutdown it overlapped, so the
                // token is checked after it and before every outcome below is decided.
                cancellationToken.ThrowIfCancellationRequested();
                if (!enabled)
                {
                    return FlagDisabled(cancellationToken);
                }
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                return Cancelled(0, new CycleCounters());
            }

            Stopwatch stopwatch = Stopwatch.StartNew();
            CycleCounters counters = new();
            int alertCount = 0;
            try
            {
                IReadOnlyList<Alert>? armed = await ListArmedAsync(cancellationToken);
                if (armed is null)
                {
                    return Finish(
                        AlertEvaluationOutcome.Failed,
                        alertCount,
                        counters,
                        stopwatch,
                        cancellationToken
                    );
                }

                // Counted first, so a cycle cancelled here still reports the alerts it listed.
                alertCount = armed.Count;
                cancellationToken.ThrowIfCancellationRequested();
                if (alertCount == 0)
                {
                    return Finish(
                        AlertEvaluationOutcome.Completed,
                        alertCount,
                        counters,
                        stopwatch,
                        cancellationToken
                    );
                }

                IReadOnlyDictionary<Guid, Price>? selected = await FetchSelectedPricesAsync(
                    cancellationToken
                );
                if (selected is null)
                {
                    return Finish(
                        AlertEvaluationOutcome.Failed,
                        alertCount,
                        counters,
                        stopwatch,
                        cancellationToken
                    );
                }

                // The cycle's own token goes to every call, not the loop's linked token, so the
                // per-alert filters below and the db-adapter calls observe the same cancellation.
                await Parallel.ForEachAsync(
                    BuildWorkItems(armed),
                    new ParallelOptions
                    {
                        MaxDegreeOfParallelism = MaxAccountConcurrency,
                        CancellationToken = cancellationToken,
                    },
                    (item, _) => EvaluateItemAsync(item, selected, counters, cancellationToken)
                );

                return Finish(
                    AlertEvaluationOutcome.Completed,
                    alertCount,
                    counters,
                    stopwatch,
                    cancellationToken
                );
            }
            // Filtered on the token, not on the exception type: GrpcHelper wraps a cancelled
            // gRPC call in DbException, and Parallel.ForEachAsync throws
            // OperationCanceledException, so any exception seen once the token is cancelled is
            // cancellation.
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                return Cancelled(alertCount, counters);
            }
        }

        private async Task<IReadOnlyList<Alert>?> ListArmedAsync(
            CancellationToken cancellationToken
        )
        {
            try
            {
                return await alertRepository.ListAsync(
                    accountId: null,
                    armedOnly: true,
                    triggeredOnly: false,
                    unacknowledgedOnly: false,
                    cancellationToken: cancellationToken
                );
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                LogCycleFailure(ReasonListFailed, exception);
                return null;
            }
        }

        private async Task<IReadOnlyDictionary<Guid, Price>?> FetchSelectedPricesAsync(
            CancellationToken cancellationToken
        )
        {
            IReadOnlyDictionary<Guid, Price> selected;
            try
            {
                IEnumerable<Price> prices = await priceServiceConnector.GetLatestPrices();
                // The price fetch takes no token, so cancellation is checked once it returns and
                // before the list is read; the filter below lets that cancellation through.
                cancellationToken.ThrowIfCancellationRequested();
                // Inside the try so a price list that cannot be read counts as a failed fetch.
                selected = LatestPriceSelector.Select(prices);
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                LogCycleFailure(ReasonPricesFailed, exception);
                return null;
            }

            // Checked again, because a shutdown can arrive while the list is being read.
            cancellationToken.ThrowIfCancellationRequested();

            // Pricing answers a non-200 response with an empty list.
            if (selected.Count == 0)
            {
                LogCycleFailure(ReasonPricesEmpty, null);
                return null;
            }

            return selected;
        }

        private static List<WorkItem> BuildWorkItems(IReadOnlyList<Alert> armed)
        {
            List<WorkItem> items = [];
            foreach (Alert alert in armed)
            {
                if (alert.Type != AlertType.PROFIT_LOSS)
                {
                    items.Add(new WorkItem(alert.AccountId, [alert], IsProfitLossGroup: false));
                }
            }

            // Grouped so each account's positions are loaded once per cycle.
            foreach (
                IGrouping<Guid, Alert> group in armed
                    .Where(alert => alert.Type == AlertType.PROFIT_LOSS)
                    .GroupBy(alert => alert.AccountId)
            )
            {
                items.Add(new WorkItem(group.Key, [.. group], IsProfitLossGroup: true));
            }

            return items;
        }

        private async ValueTask EvaluateItemAsync(
            WorkItem item,
            IReadOnlyDictionary<Guid, Price> selected,
            CycleCounters counters,
            CancellationToken cancellationToken
        )
        {
            if (!item.IsProfitLossGroup)
            {
                await EvaluateEachAsync(
                    item.Alerts,
                    alert => ObserveTargetPrice(alert, selected),
                    counters,
                    cancellationToken
                );
                return;
            }

            // The positions read takes no token, so it never starts once the cycle is cancelled,
            // and the token is checked again when it returns.
            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyList<HoldingPosition> positions;
            try
            {
                positions = await insightsService.GetHoldingPositionsAsync(
                    item.AccountId,
                    selected
                );
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                foreach (Alert alert in item.Alerts)
                {
                    // The filter is tested once, so a shutdown during this loop is checked here
                    // and stops it before the next alert, as on the normal path.
                    cancellationToken.ThrowIfCancellationRequested();
                    RecordFailure(alert, ReasonException, exception, counters);
                }
                return;
            }

            await EvaluateEachAsync(
                item.Alerts,
                alert => ObserveProfitLoss(alert, positions),
                counters,
                cancellationToken
            );
        }

        private async Task EvaluateEachAsync(
            IReadOnlyList<Alert> alerts,
            Func<Alert, Observation> observe,
            CycleCounters counters,
            CancellationToken cancellationToken
        )
        {
            foreach (Alert alert in alerts)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    Observation observation = observe(alert);
                    if (observation.SkipReason is not null)
                    {
                        Skip(alert, observation.SkipReason, counters);
                        continue;
                    }

                    await EvaluateAlertAsync(alert, observation.Value, counters, cancellationToken);
                }
                // Any exception, a decimal overflow included, fails this alert only.
                catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
                {
                    RecordFailure(alert, ReasonException, exception, counters);
                }
            }
        }

        // Target prices never consult holdings: the alert is evaluated whether or not the
        // account holds the instrument.
        private static Observation ObserveTargetPrice(
            Alert alert,
            IReadOnlyDictionary<Guid, Price> selected
        )
        {
            if (alert.Type != AlertType.TARGET_PRICE)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(alert),
                    alert.Type,
                    "Undefined alert type."
                );
            }

            return selected.TryGetValue(alert.InstrumentId, out Price? price)
                ? Observation.Of(price.Close)
                : Observation.Skipped(ReasonNoPrice);
        }

        private static Observation ObserveProfitLoss(
            Alert alert,
            IReadOnlyList<HoldingPosition> positions
        )
        {
            HoldingPosition? position = positions.FirstOrDefault(candidate =>
                candidate.InstrumentId == alert.InstrumentId
            );
            if (position is null)
            {
                return Observation.Skipped(ReasonNoHolding);
            }

            return position.HasPrice
                ? Observation.Of(position.PnlPercent)
                : Observation.Skipped(ReasonNoPrice);
        }

        private async Task EvaluateAlertAsync(
            Alert alert,
            decimal value,
            CycleCounters counters,
            CancellationToken cancellationToken
        )
        {
            // The unrounded value decides, so equality never triggers and 10.000000001 crosses
            // ABOVE 10 even though it is stored as 10.
            if (!AlertTriggerRule.IsCrossed(alert.Direction, value, alert.Threshold))
            {
                return;
            }

            decimal rounded = AlertNumber.RoundTriggerValue(value);
            if (!AlertNumber.IsValidTriggerValue(rounded))
            {
                RecordFailure(alert, ReasonTriggerValueOutOfRange, null, counters);
                return;
            }

            // The listed revision is passed back so a stale snapshot of a re-armed alert fails
            // the conditional write; false means another evaluator won or the alert changed.
            bool triggered = await alertRepository.TriggerAsync(
                alert.Id,
                alert.ArmingRevision,
                rounded,
                cancellationToken
            );
            if (!triggered)
            {
                return;
            }

            // Counted the moment the write reports the trigger, before any logging, so a slow or
            // failing log provider can neither delay nor drop the count.
            metrics.AddTriggered(alert.Type);
            counters.AddTriggered();

            try
            {
                // Log calls with value-type arguments are guarded by IsEnabled so the arguments
                // are boxed only when the level is on (CA1873); the rendered text is unchanged.
                if (logger.IsEnabled(LogLevel.Information))
                {
                    lock (LogGate)
                    {
                        logger.LogInformation(
                            TriggeredTemplate,
                            alert.Id,
                            alert.AccountId,
                            AlertMapper.ToName(alert.Type),
                            AlertMapper.ToName(alert.Direction),
                            alert.Threshold,
                            rounded,
                            alert.ArmingRevision
                        );
                    }
                }
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                // The trigger is committed and counted, so a failing log provider is a
                // diagnostics fault, not a per-alert evaluation failure: it is not passed on to
                // the per-alert failure path and adds nothing to the failed counter.
            }
        }

        private void Skip(Alert alert, string reason, CycleCounters counters)
        {
            if (logger.IsEnabled(LogLevel.Warning))
            {
                lock (LogGate)
                {
                    logger.LogWarning(SkippedTemplate, alert.Id, alert.AccountId, reason);
                }
            }
            counters.AddSkipped();
        }

        private void RecordFailure(
            Alert alert,
            string reason,
            Exception? exception,
            CycleCounters counters
        )
        {
            if (logger.IsEnabled(LogLevel.Error))
            {
                lock (LogGate)
                {
                    logger.LogError(
                        exception,
                        AlertFailedTemplate,
                        alert.Id,
                        alert.AccountId,
                        reason
                    );
                }
            }
            metrics.AddFailed(alert.Type);
            counters.AddFailed();
        }

        private void LogCycleFailure(string reason, Exception? exception)
        {
            lock (LogGate)
            {
                logger.LogError(exception, CycleFailedTemplate, reason);
            }
        }

        // The outcome is decided after the gate wait and the enablement check, so a shutdown
        // during either throws to the cycle's cancellation catch and ends it Cancelled.
        private AlertEvaluationResult FlagDisabled(CancellationToken cancellationToken)
        {
            lock (LogGate)
            {
                bool enabled = logger.IsEnabled(LogLevel.Debug);
                cancellationToken.ThrowIfCancellationRequested();
                if (enabled)
                {
                    logger.LogDebug(FlagDisabledMessage);
                }
            }
            return new AlertEvaluationResult(
                AlertEvaluationOutcome.FlagDisabled,
                0,
                0,
                0,
                0,
                TimeSpan.Zero
            );
        }

        // Decided under the gate as in FlagDisabled, so a cycle cancelled during the wait or the
        // enablement check logs no summary and records no duration.
        private AlertEvaluationResult Finish(
            AlertEvaluationOutcome outcome,
            int alertCount,
            CycleCounters counters,
            Stopwatch stopwatch,
            CancellationToken cancellationToken
        )
        {
            stopwatch.Stop();
            string outcomeName =
                outcome == AlertEvaluationOutcome.Completed
                    ? PortfolioInsightsMetrics.OutcomeCompleted
                    : PortfolioInsightsMetrics.OutcomeFailed;
            int triggered = counters.Triggered;
            int failed = counters.Failed;
            int skipped = counters.Skipped;
            lock (LogGate)
            {
                // Checked in both branches so the log call stays directly under its IsEnabled
                // guard, which keeps its value-type arguments unboxed while the level is off.
                if (logger.IsEnabled(LogLevel.Information))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    logger.LogInformation(
                        CycleFinishedTemplate,
                        alertCount,
                        triggered,
                        failed,
                        skipped,
                        outcomeName,
                        stopwatch.ElapsedMilliseconds
                    );
                }
                else
                {
                    cancellationToken.ThrowIfCancellationRequested();
                }
            }
            metrics.RecordEvaluationDuration(stopwatch.Elapsed, outcomeName);
            return new AlertEvaluationResult(
                outcome,
                alertCount,
                triggered,
                failed,
                skipped,
                stopwatch.Elapsed
            );
        }

        // A cancelled cycle logs no summary line and records no duration.
        private AlertEvaluationResult Cancelled(int alertCount, CycleCounters counters)
        {
            int triggered = counters.Triggered;
            if (logger.IsEnabled(LogLevel.Debug))
            {
                lock (LogGate)
                {
                    logger.LogDebug(CycleCancelledTemplate, alertCount, triggered);
                }
            }
            return new AlertEvaluationResult(
                AlertEvaluationOutcome.Cancelled,
                alertCount,
                triggered,
                counters.Failed,
                counters.Skipped,
                TimeSpan.Zero
            );
        }

        private sealed record WorkItem(
            Guid AccountId,
            IReadOnlyList<Alert> Alerts,
            bool IsProfitLossGroup
        );

        private readonly record struct Observation(decimal Value, string? SkipReason)
        {
            public static Observation Of(decimal value)
            {
                return new Observation(value, null);
            }

            public static Observation Skipped(string reason)
            {
                return new Observation(0m, reason);
            }
        }

        // Shared by every work item of one cycle, which run in parallel.
        private sealed class CycleCounters
        {
            private int _triggered;
            private int _failed;
            private int _skipped;

            public int Triggered => Volatile.Read(ref _triggered);
            public int Failed => Volatile.Read(ref _failed);
            public int Skipped => Volatile.Read(ref _skipped);

            public void AddTriggered()
            {
                Interlocked.Increment(ref _triggered);
            }

            public void AddFailed()
            {
                Interlocked.Increment(ref _failed);
            }

            public void AddSkipped()
            {
                Interlocked.Increment(ref _skipped);
            }
        }
    }
}
