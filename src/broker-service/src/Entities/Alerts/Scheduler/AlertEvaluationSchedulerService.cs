using System.Globalization;
using System.Text;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.ExceptionHandling;
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
    ) : BackgroundService, IHostedLifecycleService
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
        /// The most characters of an invalid interval value that its Warning carries. Valid
        /// values have at most seven digits; the bound still keeps a mistyped or unexpanded
        /// placeholder readable while capping what configuration can write into the log.
        /// </summary>
        private const int MaxLoggedValueLength = 64;

        // Guards the one-time resolution of the interval and its startup lines.
        private readonly Lock _startupGate = new();

        // The interval this instance runs on, or null until ResolveIntervalOnce first runs.
        private int? _intervalSeconds;

        /// <summary>
        /// Reads <c>ALERT_EVALUATION_INTERVAL_SECONDS</c>. A whole number from 1 to
        /// <see cref="MaxIntervalSeconds"/> is used as given; anything else, an unset value
        /// included, logs a Warning and gives <see cref="DefaultIntervalSeconds"/>. The Warning
        /// carries the value as <see cref="ToSingleLineLogValue"/> renders it, so configuration
        /// text can neither break the record across lines nor grow it without bound.
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

            // The guard skips escaping the value when Warning is off (CA1873).
            if (logger.IsEnabled(LogLevel.Warning))
            {
                logger.LogWarning(
                    "Invalid ALERT_EVALUATION_INTERVAL_SECONDS [{value}], using 60",
                    ToSingleLineLogValue(raw)
                );
            }
            return DefaultIntervalSeconds;
        }

        /// <summary>
        /// Runs one cycle immediately, then one more each time <paramref name="waitForNextTick"/>
        /// yields <c>true</c>, and returns when it yields <c>false</c>. A cycle's scope opens
        /// only while <paramref name="cancellationToken"/> is live: the token is read before the
        /// first cycle and after each tick that yields <c>true</c>, and once it is cancelled the
        /// loop returns normally without opening another scope, whether or not
        /// <paramref name="waitForNextTick"/> honours the token.
        /// </summary>
        /// <remarks>
        /// A cycle that throws while <paramref name="cancellationToken"/> is live, whatever the
        /// exception type, is logged at Error by the per-cycle handler, and the loop waits for
        /// the next tick. An <see cref="OperationCanceledException"/> thrown by
        /// <paramref name="waitForNextTick"/>, or any exception raised while
        /// <paramref name="cancellationToken"/> is cancelled, ends the loop normally without
        /// logging.
        /// </remarks>
        /// <exception cref="Exception">
        /// An exception other than <see cref="OperationCanceledException"/> that
        /// <paramref name="waitForNextTick"/> throws while <paramref name="cancellationToken"/>
        /// is live propagates to the caller.
        /// </exception>
        public async Task RunLoopAsync(
            Func<CancellationToken, ValueTask<bool>> waitForNextTick,
            CancellationToken cancellationToken
        )
        {
            try
            {
                // Read before every scope, so neither a token cancelled before the first cycle
                // nor a tick that yields true once cancellation has arrived dispatches a cycle.
                while (!cancellationToken.IsCancellationRequested)
                {
                    await RunCycleInScopeAsync(cancellationToken);
                    if (!await waitForNextTick(cancellationToken))
                    {
                        return;
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // Shutdown is the normal end of the loop, never a cycle failure.
                return;
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                // A fault raised while the loop is stopping is treated as the stop it
                // accompanies, never as a cycle failure.
                return;
            }
        }

        /// <summary>
        /// Resolves the interval and writes the startup lines: the interval's Warning, when the
        /// configured value is invalid, then the startup line.
        /// </summary>
        public Task StartingAsync(CancellationToken cancellationToken)
        {
            // The host calls this before it starts any hosted service, so the startup lines are
            // written while the host starts and never interleave with another service's console
            // output.
            _ = ResolveIntervalOnce();
            return Task.CompletedTask;
        }

        /// <summary>Nothing runs here: the cycles run in <see cref="ExecuteAsync"/>.</summary>
        public Task StartedAsync(CancellationToken cancellationToken)
        {
            return Task.CompletedTask;
        }

        /// <summary>Nothing runs here: StopAsync cancels the cycles.</summary>
        public Task StoppingAsync(CancellationToken cancellationToken)
        {
            return Task.CompletedTask;
        }

        /// <summary>Nothing runs here: StopAsync has already ended the cycles.</summary>
        public Task StoppedAsync(CancellationToken cancellationToken)
        {
            return Task.CompletedTask;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            // Returns the interval StartingAsync resolved. Where StartingAsync never ran, as when
            // StartAsync is called directly, this resolves it and writes the startup lines first.
            int intervalSeconds = ResolveIntervalOnce();
            using PeriodicTimer timer = new(TimeSpan.FromSeconds(intervalSeconds));
            await RunLoopAsync(timer.WaitForNextTickAsync, stoppingToken);
        }

        /// <summary>
        /// On the first call for this instance, resolves the interval through
        /// <see cref="ResolveInterval"/>, which writes the Warning for an invalid value, then
        /// writes the startup line. Every later call returns the stored interval and writes
        /// nothing, so each line appears once whichever of <see cref="StartingAsync"/> and
        /// <see cref="ExecuteAsync"/> comes first.
        /// </summary>
        private int ResolveIntervalOnce()
        {
            lock (_startupGate)
            {
                if (_intervalSeconds is int resolved)
                {
                    return resolved;
                }

                int intervalSeconds = ResolveInterval(configuration, logger);
                // Stored before the startup line, so no later call writes the Warning again.
                _intervalSeconds = intervalSeconds;
                // The guard avoids boxing the interval when Information is off (CA1873).
                if (logger.IsEnabled(LogLevel.Information))
                {
                    logger.LogInformation(
                        "Starting alert evaluation scheduler with an interval of [{interval}]s.",
                        intervalSeconds
                    );
                }
                return intervalSeconds;
            }
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
                // The console logger prints only the rendered message, so the exception is
                // carried as text, which never includes a db-adapter driver or RPC diagnostic.
                // The guard skips rendering it while Error is off (CA1873).
                if (logger.IsEnabled(LogLevel.Error))
                {
                    logger.LogError(
                        exception,
                        "Error running alert evaluation cycle ({exception})",
                        BrokerExceptionFilter.DescribeForLog(exception)
                    );
                }
            }
        }

        /// <summary>
        /// Renders a configuration value for one log line. A backslash becomes <c>\\</c>;
        /// carriage return, line feed and tab become <c>\r</c>, <c>\n</c> and <c>\t</c>; every
        /// other control character, every format character of the Basic Multilingual Plane
        /// (such as a bidirectional override) and the Unicode line and paragraph separators
        /// become <c>\uXXXX</c>. A value longer than <see cref="MaxLoggedValueLength"/>
        /// characters keeps at most that many, never half of a surrogate pair, followed by
        /// <c>...(truncated from N chars)</c>. Null stays null, and a value within the bound
        /// that holds none of those characters renders unchanged.
        /// </summary>
        private static string? ToSingleLineLogValue(string? value)
        {
            if (value is null)
            {
                return null;
            }

            int kept = value.Length;
            if (kept > MaxLoggedValueLength)
            {
                kept = char.IsSurrogatePair(
                    value[MaxLoggedValueLength - 1],
                    value[MaxLoggedValueLength]
                )
                    ? MaxLoggedValueLength - 1
                    : MaxLoggedValueLength;
            }

            StringBuilder builder = new(kept);
            for (int index = 0; index < kept; index++)
            {
                char character = value[index];
                string? shortEscape = character switch
                {
                    '\\' => @"\\",
                    '\r' => @"\r",
                    '\n' => @"\n",
                    '\t' => @"\t",
                    _ => null,
                };
                if (shortEscape is not null)
                {
                    builder.Append(shortEscape);
                }
                else if (
                    char.GetUnicodeCategory(character)
                    is UnicodeCategory.Control
                        or UnicodeCategory.Format
                        or UnicodeCategory.LineSeparator
                        or UnicodeCategory.ParagraphSeparator
                )
                {
                    builder.Append(CultureInfo.InvariantCulture, $"\\u{(int)character:X4}");
                }
                else
                {
                    builder.Append(character);
                }
            }

            if (kept < value.Length)
            {
                builder.Append(
                    CultureInfo.InvariantCulture,
                    $"...(truncated from {value.Length} chars)"
                );
            }
            return builder.ToString();
        }
    }
}
