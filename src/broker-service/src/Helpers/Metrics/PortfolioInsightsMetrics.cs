using System.Diagnostics.Metrics;
using EasyTrade.BrokerService.Entities.Alerts;

namespace EasyTrade.BrokerService.Helpers.Metrics
{
    /// <summary>
    /// The four Portfolio Insights and Alerts instruments on the meter
    /// <see cref="MeterName"/>. Registered as a singleton; every recording is thread-safe.
    /// </summary>
    public class PortfolioInsightsMetrics
    {
        public const string MeterName = "EasyTrade.BrokerService";
        public const string CalculationDurationName =
            "easytrade.broker.portfolio.calculation.duration";
        public const string EvaluationDurationName = "easytrade.broker.alerts.evaluation.duration";
        public const string TriggeredName = "easytrade.broker.alerts.triggered";
        public const string EvaluationFailedName = "easytrade.broker.alerts.evaluation.failed";

        public const string CycleOutcomeTag = "cycle.outcome";
        public const string AlertTypeTag = "alert.type";
        public const string OutcomeCompleted = "completed";
        public const string OutcomeFailed = "failed";

        private readonly Histogram<double> _calculationDuration;
        private readonly Histogram<double> _evaluationDuration;
        private readonly Counter<long> _triggered;
        private readonly Counter<long> _evaluationFailed;

        // The factory owns and disposes the meter, so this class neither disposes it nor
        // keeps it in a static field that would be shared between hosts.
        public PortfolioInsightsMetrics(IMeterFactory meterFactory)
        {
            Meter meter = meterFactory.Create(MeterName);
            _calculationDuration = meter.CreateHistogram<double>(
                CalculationDurationName,
                "s",
                "Time to compute the portfolio insights of one account"
            );
            _evaluationDuration = meter.CreateHistogram<double>(
                EvaluationDurationName,
                "s",
                "Time of one alert evaluation cycle that completed or failed"
            );
            _triggered = meter.CreateCounter<long>(
                TriggeredName,
                "{alert}",
                "Alerts triggered by a successful conditional trigger write"
            );
            _evaluationFailed = meter.CreateCounter<long>(
                EvaluationFailedName,
                "{alert}",
                "Alerts whose evaluation failed within a cycle"
            );
        }

        /// <summary>Records the duration of one computed insights result.</summary>
        public void RecordCalculationDuration(TimeSpan duration)
        {
            _calculationDuration.Record(duration.TotalSeconds);
        }

        /// <summary>
        /// Records the duration of one evaluation cycle, tagged <see cref="CycleOutcomeTag"/>
        /// with <paramref name="outcome"/>: <see cref="OutcomeCompleted"/> or
        /// <see cref="OutcomeFailed"/>.
        /// </summary>
        public void RecordEvaluationDuration(TimeSpan duration, string outcome)
        {
            _evaluationDuration.Record(
                duration.TotalSeconds,
                new KeyValuePair<string, object?>(CycleOutcomeTag, outcome)
            );
        }

        /// <summary>Counts one triggered alert, tagged <see cref="AlertTypeTag"/>.</summary>
        public void AddTriggered(AlertType type)
        {
            _triggered.Add(1, new KeyValuePair<string, object?>(AlertTypeTag, ToTagValue(type)));
        }

        /// <summary>
        /// Counts one per-alert evaluation failure, tagged <see cref="AlertTypeTag"/>.
        /// </summary>
        public void AddFailed(AlertType type)
        {
            _evaluationFailed.Add(
                1,
                new KeyValuePair<string, object?>(AlertTypeTag, ToTagValue(type))
            );
        }

        // AlertType member names are the wire values TARGET_PRICE and PROFIT_LOSS.
        private static string ToTagValue(AlertType type)
        {
            return type.ToString();
        }
    }
}
