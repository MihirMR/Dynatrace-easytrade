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
    /// Runs one alert evaluation cycle over the armed alerts of every account: one flag read, one
    /// armed-alert listing and one latest-price fetch per cycle, then one conditional trigger
    /// write per crossed alert. Whether a crossing notifies is decided by that write alone.
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

        /// <inheritdoc/>
        public async Task<AlertEvaluationResult> RunCycleAsync(CancellationToken cancellationToken)
        {
            bool enabled;
            try
            {
                enabled = await feature.IsEnabledAsync(cancellationToken);
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                return Cancelled(0, new CycleCounters());
            }

            if (!enabled)
            {
                logger.LogDebug(FlagDisabledMessage);
                return new AlertEvaluationResult(
                    AlertEvaluationOutcome.FlagDisabled,
                    0,
                    0,
                    0,
                    0,
                    TimeSpan.Zero
                );
            }

            Stopwatch stopwatch = Stopwatch.StartNew();
            CycleCounters counters = new();
            int alertCount = 0;
            try
            {
                IReadOnlyList<Alert>? armed = await ListArmedAsync(cancellationToken);
                if (armed is null)
                {
                    return Finish(AlertEvaluationOutcome.Failed, alertCount, counters, stopwatch);
                }

                alertCount = armed.Count;
                if (alertCount == 0)
                {
                    return Finish(
                        AlertEvaluationOutcome.Completed,
                        alertCount,
                        counters,
                        stopwatch
                    );
                }

                IReadOnlyDictionary<Guid, Price>? selected = await FetchSelectedPricesAsync(
                    cancellationToken
                );
                if (selected is null)
                {
                    return Finish(AlertEvaluationOutcome.Failed, alertCount, counters, stopwatch);
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

                return Finish(AlertEvaluationOutcome.Completed, alertCount, counters, stopwatch);
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
                // Inside the try so a price list that cannot be read counts as a failed fetch.
                selected = LatestPriceSelector.Select(prices);
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                LogCycleFailure(ReasonPricesFailed, exception);
                return null;
            }

            // The price fetch takes no token, so cancellation is checked once it returns.
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

            // Log calls with value-type arguments are guarded by IsEnabled so the arguments are
            // boxed only when the level is on (CA1873); the rendered text is unchanged.
            if (logger.IsEnabled(LogLevel.Information))
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
            metrics.AddTriggered(alert.Type);
            counters.AddTriggered();
        }

        private void Skip(Alert alert, string reason, CycleCounters counters)
        {
            if (logger.IsEnabled(LogLevel.Warning))
            {
                logger.LogWarning(SkippedTemplate, alert.Id, alert.AccountId, reason);
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
                logger.LogError(exception, AlertFailedTemplate, alert.Id, alert.AccountId, reason);
            }
            metrics.AddFailed(alert.Type);
            counters.AddFailed();
        }

        private void LogCycleFailure(string reason, Exception? exception)
        {
            logger.LogError(exception, CycleFailedTemplate, reason);
        }

        private AlertEvaluationResult Finish(
            AlertEvaluationOutcome outcome,
            int alertCount,
            CycleCounters counters,
            Stopwatch stopwatch
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
            if (logger.IsEnabled(LogLevel.Information))
            {
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
                logger.LogDebug(CycleCancelledTemplate, alertCount, triggered);
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
