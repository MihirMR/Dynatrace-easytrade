using System.Globalization;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Helpers;

namespace EasyTrade.BrokerService.Entities.Alerts.Scheduler
{
    /// <summary>
    /// Runs one alert evaluation cycle at startup, then one every
    /// <c>ALERT_EVALUATION_INTERVAL_SECONDS</c>. Cycles in one process never overlap.
    /// </summary>
    public class AlertEvaluationSchedulerService(
        IServiceScopeFactory scopeFactory,
        IConfiguration configuration,
        ILogger<AlertEvaluationSchedulerService> logger
    ) : BackgroundService
    {
        /// <summary>
        /// The interval used when the configured value is unset or invalid.
        /// </summary>
        public const int DefaultIntervalSeconds = 60;

        /// <summary>
        /// The largest accepted interval. <see cref="PeriodicTimer"/> rejects any period above
        /// 4,294,967,294 ms at construction, so a larger value would fault the service.
        /// </summary>
        public const int MaxIntervalSeconds = 4_294_967;

        /// <summary>
        /// Reads <c>ALERT_EVALUATION_INTERVAL_SECONDS</c>. A whole number from 1 to
        /// <see cref="MaxIntervalSeconds"/> is used as given; anything else, an unset value
        /// included, logs a Warning and gives <see cref="DefaultIntervalSeconds"/>.
        /// </summary>
        public static int ResolveInterval(IConfiguration configuration, ILogger logger)
        {
            string? raw = configuration[Constants.AlertEvaluationIntervalSeconds];
            if (
                int.TryParse(
                    raw,
                    NumberStyles.Integer,
                    CultureInfo.InvariantCulture,
                    out int seconds
                )
                && (seconds >= 1)
                && (seconds <= MaxIntervalSeconds)
            )
            {
                return seconds;
            }

            logger.LogWarning("Invalid ALERT_EVALUATION_INTERVAL_SECONDS [{value}], using 60", raw);
            return DefaultIntervalSeconds;
        }

        /// <summary>
        /// Runs one cycle immediately, then one more each time <paramref name="waitForNextTick"/>
        /// yields <c>true</c>, and returns when it yields <c>false</c> or the token is cancelled.
        /// A failed cycle is logged and the loop continues; the method never throws.
        /// </summary>
        public async Task RunLoopAsync(
            Func<CancellationToken, ValueTask<bool>> waitForNextTick,
            CancellationToken cancellationToken
        )
        {
            try
            {
                do
                {
                    await RunCycleInScopeAsync(cancellationToken);
                } while (await waitForNextTick(cancellationToken));
            }
            catch (OperationCanceledException) { }
            catch (Exception) when (cancellationToken.IsCancellationRequested) { }
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            int intervalSeconds = ResolveInterval(configuration, logger);
            // The guard avoids boxing the interval when Information is off (CA1873).
            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(
                    "Starting alert evaluation scheduler with an interval of {interval}s.",
                    intervalSeconds
                );
            }

            using PeriodicTimer timer = new(TimeSpan.FromSeconds(intervalSeconds));
            await RunLoopAsync(timer.WaitForNextTickAsync, stoppingToken);
        }

        private async Task RunCycleInScopeAsync(CancellationToken cancellationToken)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                IAlertEvaluationService evaluationService =
                    scope.ServiceProvider.GetRequiredService<IAlertEvaluationService>();
                _ = await evaluationService.RunCycleAsync(cancellationToken);
            }
            // Filtered on the token, not on the exception type: an OperationCanceledException
            // from an internal timeout while the host keeps running is a failed cycle, and the
            // next tick must still run.
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                logger.LogError(exception, "Error running alert evaluation cycle");
            }
        }
    }
}
