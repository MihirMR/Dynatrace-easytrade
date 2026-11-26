using System.Collections.Concurrent;
using System.Threading.Channels;
using EasyTrade.BrokerService.Entities.Alerts.Scheduler;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertEvaluationSchedulerTests
    {
        private const string InvalidIntervalPrefix = "Invalid ALERT_EVALUATION_INTERVAL_SECONDS";
        private const string CycleErrorPrefix = "Error running alert evaluation cycle";
        private const string StartupPrefix = "Starting alert evaluation scheduler";

        // The variable name the deployment manifests publish, written out rather than taken from
        // Constants so that renaming the key the scheduler reads fails the resolution matrix.
        private const string PublishedIntervalKey = "ALERT_EVALUATION_INTERVAL_SECONDS";

        // 63 characters, one short of the length bound on a logged interval value, so a row can
        // end its value at the bound, past it, or with a surrogate pair straddling it.
        private const string Digits63 =
            "123456789012345678901234567890123456789012345678901234567890123";

        // Bounds every wait, so a broken loop fails the test instead of hanging it. Progress is
        // driven only by the test's tick source, never by elapsed time.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(5);

        public enum LoopScenario
        {
            StartRunsOneCycle,
            ThreeTicksRunThreeMore,
            ThrowingCycleLoggedAndNextRuns,
            SourceEndsLoopStops,
            CancelledLoopStops,
            FaultWhileStoppingEndsQuietly,
            HeldCycleDefersNextTick,
            CycleCancellationWhileLiveLoggedAndNextRuns,
            TickCancellationWhileLiveEndsQuietly,
            TickFaultWhileLivePropagates,
            TickAcceptedAfterCancellationEndsWithoutCycle,
        }

        [Theory]
        [InlineData(null, 60, true, null)]
        [InlineData("abc", 60, true, "abc")]
        [InlineData("0", 60, true, "0")]
        [InlineData("-5", 60, true, "-5")]
        [InlineData("4294968", 60, true, "4294968")]
        [InlineData("1", 1, false, null)]
        [InlineData("15", 15, false, null)]
        [InlineData("4294967", 4294967, false, null)]
        [InlineData(
            "15\r\n[12:00:00 | Error] forged",
            60,
            true,
            @"15\r\n[12:00:00 | Error] forged"
        )]
        [InlineData(
            "1\t\u001B[31m\u0085\u2028\u2029\u202E\\",
            60,
            true,
            @"1\t\u001B[31m\u0085\u2028\u2029\u202E\\"
        )]
        [InlineData(Digits63 + "4", 60, true, Digits63 + "4")]
        [InlineData(Digits63 + "45", 60, true, Digits63 + "4...(truncated from 65 chars)")]
        [InlineData(Digits63 + "\U0001F600", 60, true, Digits63 + "...(truncated from 65 chars)")]
        public void ResolveInterval_Setting_ShouldResolve(
            string? value,
            int expected,
            bool expectWarning,
            string? expectedLoggedValue
        )
        {
            // Arrange
            Dictionary<string, string?> settings = [];
            if (value is not null)
            {
                settings[PublishedIntervalKey] = value;
            }
            IConfiguration configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(settings)
                .Build();
            RecordingLogger<AlertEvaluationSchedulerService> logger = new();

            // Act
            int resolved = AlertEvaluationSchedulerService.ResolveInterval(configuration, logger);

            // Assert
            Assert.Equal(expected, resolved);
            IReadOnlyList<LogEntry> warnings = logger.Sink.ByLevel(LogLevel.Warning);
            Assert.Equal(expectWarning ? 1 : 0, warnings.Count);
            Assert.All(
                warnings,
                warning =>
                {
                    Assert.Equal(expectedLoggedValue, warning.GetField("value"));
                    // Microsoft.Extensions.Logging renders a null field as "(null)".
                    Assert.Equal(
                        $"{InvalidIntervalPrefix} [{expectedLoggedValue ?? "(null)"}], using 60",
                        warning.Message
                    );
                    // The record stays one line: no control character or separator reaches it.
                    Assert.DoesNotContain(
                        warning.Message,
                        character => char.IsControl(character) || character is '\u2028' or '\u2029'
                    );
                }
            );
            // Every resolved interval must be a period PeriodicTimer accepts; MaxIntervalSeconds
            // is the largest such whole number of seconds.
            Exception? timerError = Record.Exception(
                () => new PeriodicTimer(TimeSpan.FromSeconds(resolved)).Dispose()
            );
            Assert.Null(timerError);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("abc")]
        [InlineData("0")]
        [InlineData("15\r\n[12:00:00 | Error] forged")]
        [InlineData(Digits63 + "45")]
        public void ResolveInterval_WarningDisabled_ShouldFallBackWithoutLogging(string? value)
        {
            // Arrange
            Dictionary<string, string?> settings = [];
            if (value is not null)
            {
                settings[PublishedIntervalKey] = value;
            }
            IConfiguration configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(settings)
                .Build();
            MinimumLevelLogger<AlertEvaluationSchedulerService> logger = new(LogLevel.Error);

            // Act
            int resolved = AlertEvaluationSchedulerService.ResolveInterval(configuration, logger);

            // Assert
            Assert.Equal(AlertEvaluationSchedulerService.DefaultIntervalSeconds, resolved);
            Assert.Empty(logger.Calls);
        }

        [Fact]
        public async Task ExecuteAsync_Start_ShouldLogBracketedInterval()
        {
            // Arrange
            ServiceCollection services = new();
            services.AddScoped<IAlertEvaluationService, CompletedEvaluationService>();
            await using ServiceProvider provider = services.BuildServiceProvider(
                new ServiceProviderOptions { ValidateOnBuild = true, ValidateScopes = true }
            );
            IConfiguration configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(
                    new Dictionary<string, string?>
                    {
                        [Constants.AlertEvaluationIntervalSeconds] = "15",
                    }
                )
                .Build();
            RecordingLogger<AlertEvaluationSchedulerService> logger = new();
            using AlertEvaluationSchedulerService scheduler = new(
                provider.GetRequiredService<IServiceScopeFactory>(),
                configuration,
                logger
            );
            using CancellationTokenSource stopBound = new(WaitBound);

            // Act
            await scheduler.StartAsync(CancellationToken.None);
            // ExecuteAsync can still be running when StartAsync returns, so wait for the entry.
            LogEntry started = await logger.Sink.WaitForMessageStartingWithAsync(
                StartupPrefix,
                WaitBound
            );
            await scheduler.StopAsync(stopBound.Token);

            // Assert
            Assert.Equal(LogLevel.Information, started.Level);
            Assert.Equal(
                "Starting alert evaluation scheduler with an interval of [{interval}]s.",
                started.GetField("{OriginalFormat}")
            );
            Assert.Equal(
                "Starting alert evaluation scheduler with an interval of [15]s.",
                started.Message
            );
            Assert.Equal(15, started.GetField("interval"));
        }

        [Fact]
        public async Task ExecuteAsync_InformationDisabled_ShouldRunCycleWithoutStartupLine()
        {
            // Arrange
            ServiceCollection services = new();
            services.AddSingleton(_ => new CycleProbe(null, false));
            services.AddScoped<IAlertEvaluationService, ProbeEvaluationService>();
            await using ServiceProvider provider = services.BuildServiceProvider(
                new ServiceProviderOptions { ValidateOnBuild = true, ValidateScopes = true }
            );
            CycleProbe probe = provider.GetRequiredService<CycleProbe>();
            IConfiguration configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(
                    new Dictionary<string, string?>
                    {
                        [Constants.AlertEvaluationIntervalSeconds] = "15",
                    }
                )
                .Build();
            MinimumLevelLogger<AlertEvaluationSchedulerService> logger = new(LogLevel.Warning);
            using AlertEvaluationSchedulerService scheduler = new(
                provider.GetRequiredService<IServiceScopeFactory>(),
                configuration,
                logger
            );
            using CancellationTokenSource stopBound = new(WaitBound);

            // Act
            await scheduler.StartAsync(CancellationToken.None);
            // The startup line, when written, precedes the first cycle, so the cycle's signal
            // means every startup log call has already been made.
            bool cycleRan = await probe.WaitForCycleAsync();
            await scheduler.StopAsync(stopBound.Token);

            // Assert
            Assert.True(cycleRan, "The startup cycle did not run.");
            Assert.DoesNotContain(logger.Calls, call => call.Level == LogLevel.Information);
        }

        [Theory]
        [InlineData("15", 15, false)]
        [InlineData("abc", 60, true)]
        public async Task StartingAsync_HostStart_ShouldLogStartupLinesBeforeEarlierServiceRuns(
            string value,
            int expectedInterval,
            bool expectWarning
        )
        {
            // Arrange
            RecordingLoggerProvider loggerProvider = new();
            HostApplicationBuilder builder = Host.CreateApplicationBuilder(
                new HostApplicationBuilderSettings
                {
                    // No environment variables, settings files or default providers, so the
                    // interval and every recorded line come from this test alone.
                    DisableDefaults = true,
                    EnvironmentName = Environments.Production,
                    ContentRootPath = AppContext.BaseDirectory,
                }
            );
            builder.Configuration.AddInMemoryCollection(
                new Dictionary<string, string?> { [PublishedIntervalKey] = value }
            );
            builder.Logging.ClearProviders();
            builder.Logging.AddProvider(loggerProvider);
            builder.ConfigureContainer(
                new DefaultServiceProviderFactory(
                    new ServiceProviderOptions { ValidateOnBuild = true, ValidateScopes = true }
                )
            );
            builder.Services.AddSingleton(loggerProvider.Sink);
            builder.Services.AddSingleton(_ => new CycleProbe(null, false));
            builder.Services.AddScoped<IAlertEvaluationService, ProbeEvaluationService>();
            // Registered ahead of the scheduler, as the long-trade scheduler is in production,
            // so the host starts it first.
            builder.Services.AddHostedService<EarlierServiceProbe>();
            builder.Services.AddHostedService<AlertEvaluationSchedulerService>();
            using IHost host = builder.Build();
            EarlierServiceProbe earlierService = host
                .Services.GetServices<IHostedService>()
                .OfType<EarlierServiceProbe>()
                .Single();
            CycleProbe cycles = host.Services.GetRequiredService<CycleProbe>();
            List<string> expectedLines = [];
            if (expectWarning)
            {
                expectedLines.Add($"{InvalidIntervalPrefix} [{value}], using 60");
            }
            expectedLines.Add(
                $"Starting alert evaluation scheduler with an interval of [{expectedInterval}]s."
            );
            using CancellationTokenSource startBound = new(WaitBound);
            using CancellationTokenSource stopBound = new(WaitBound);

            // Act
            await host.StartAsync(startBound.Token);
            IReadOnlyList<string> seenByEarlierService =
                await earlierService.SchedulerLines.WaitAsync(WaitBound);
            bool cycleRan = await cycles.WaitForCycleAsync();
            // The first cycle starts only once ExecuteAsync has passed its startup step, so the
            // lines read now are every startup line the whole start wrote.
            IReadOnlyList<string> afterFirstCycle = SchedulerMessages(loggerProvider.Sink);
            await host.StopAsync(stopBound.Token);

            // Assert
            Assert.True(cycleRan, "The startup cycle did not run.");
            // The service the host started first already sees the Warning, when there is one,
            // and the startup line, so neither can be written while that service writes its own.
            Assert.Equal(expectedLines, seenByEarlierService);
            // Each line was written once, the Warning first, and ExecuteAsync wrote neither again.
            Assert.Equal(expectedLines, afterFirstCycle);
        }

        /// <summary>The messages the scheduler has logged so far, in logging order.</summary>
        private static IReadOnlyList<string> SchedulerMessages(RecordingLogSink sink)
        {
            return
            [
                .. sink.ByCategory<AlertEvaluationSchedulerService>()
                    .Select(entry => entry.Message),
            ];
        }

        /// <summary>
        /// Hosted service registered ahead of the scheduler, as the long-trade scheduler is in
        /// production. As its ExecuteAsync begins, where that scheduler writes its own startup
        /// lines, it records the messages the alert scheduler has logged so far.
        /// </summary>
        private sealed class EarlierServiceProbe(RecordingLogSink sink) : BackgroundService
        {
            private readonly TaskCompletionSource<IReadOnlyList<string>> _schedulerLines = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            /// <summary>The scheduler's messages as this service's ExecuteAsync began.</summary>
            public Task<IReadOnlyList<string>> SchedulerLines => _schedulerLines.Task;

            protected override Task ExecuteAsync(CancellationToken stoppingToken)
            {
                _schedulerLines.TrySetResult(SchedulerMessages(sink));
                return Task.CompletedTask;
            }
        }

        /// <summary>A cycle that completes at once with no armed alert to evaluate.</summary>
        private sealed class CompletedEvaluationService : IAlertEvaluationService
        {
            public Task<AlertEvaluationResult> RunCycleAsync(CancellationToken cancellationToken)
            {
                return Task.FromResult(
                    new AlertEvaluationResult(
                        AlertEvaluationOutcome.Completed,
                        0,
                        0,
                        0,
                        0,
                        TimeSpan.Zero
                    )
                );
            }
        }

        /// <summary>One <see cref="ILogger.Log{TState}"/> call and its rendered message.</summary>
        private sealed record LoggedCall(LogLevel Level, string Message);

        /// <summary>
        /// Logger that reports every level below its minimum as disabled, as a host filtered to
        /// that minimum does. It records every call, enabled or not, so a log call made without
        /// first checking <see cref="IsEnabled"/> is still seen. Safe for concurrent callers.
        /// </summary>
        private sealed class MinimumLevelLogger<T>(LogLevel minimumLevel) : ILogger<T>
        {
            private readonly ConcurrentQueue<LoggedCall> _calls = new();

            /// <summary>Every call made so far, in order; enumeration takes a snapshot.</summary>
            public IReadOnlyCollection<LoggedCall> Calls => _calls;

            // Scopes are not part of what these tests assert, so none is created.
            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                return null;
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                return logLevel != LogLevel.None && logLevel >= minimumLevel;
            }

            public void Log<TState>(
                LogLevel logLevel,
                EventId eventId,
                TState state,
                Exception? exception,
                Func<TState, Exception?, string> formatter
            )
            {
                ArgumentNullException.ThrowIfNull(formatter);
                _calls.Enqueue(new LoggedCall(logLevel, formatter(state, exception)));
            }
        }

        [Theory]
        [InlineData(LoopScenario.StartRunsOneCycle)]
        [InlineData(LoopScenario.ThreeTicksRunThreeMore)]
        [InlineData(LoopScenario.ThrowingCycleLoggedAndNextRuns)]
        [InlineData(LoopScenario.SourceEndsLoopStops)]
        [InlineData(LoopScenario.CancelledLoopStops)]
        [InlineData(LoopScenario.FaultWhileStoppingEndsQuietly)]
        [InlineData(LoopScenario.HeldCycleDefersNextTick)]
        [InlineData(LoopScenario.CycleCancellationWhileLiveLoggedAndNextRuns)]
        [InlineData(LoopScenario.TickCancellationWhileLiveEndsQuietly)]
        [InlineData(LoopScenario.TickFaultWhileLivePropagates)]
        [InlineData(LoopScenario.TickAcceptedAfterCancellationEndsWithoutCycle)]
        public async Task RunLoop_TickSource_ShouldDriveCycles(LoopScenario scenario)
        {
            // Arrange
            Exception? cycleFault = scenario switch
            {
                LoopScenario.ThrowingCycleLoggedAndNextRuns
                or LoopScenario.FaultWhileStoppingEndsQuietly => new InvalidOperationException(
                    "Cycle 1 failed on purpose."
                ),
                // Cancelled through a token of the cycle's own, as an internal timeout is, while
                // the loop's token stays live.
                LoopScenario.CycleCancellationWhileLiveLoggedAndNextRuns =>
                    new OperationCanceledException(
                        "Cycle 1 timed out on purpose.",
                        new CancellationToken(canceled: true)
                    ),
                _ => null,
            };
            bool holdFirstCycle =
                scenario
                    is LoopScenario.FaultWhileStoppingEndsQuietly
                        or LoopScenario.HeldCycleDefersNextTick;
            await using LoopHarness harness = new(cycleFault, holdFirstCycle);
            int expectedCycles = 1;
            int expectedErrors = 0;
            // Whether the log ends with the tick requested after the last cycle; null when the
            // row accepts the log either with or without that request.
            bool? tickAfterLastCycle = true;
            TaskStatus expectedStatus = TaskStatus.RanToCompletion;

            // Act
            harness.Start();
            Assert.True(await harness.Probe.WaitForCycleAsync(), "The startup cycle did not run.");
            switch (scenario)
            {
                case LoopScenario.StartRunsOneCycle:
                    // With the token live, the loop asks for the tick that follows the startup
                    // cycle. No tick is released, so it stays parked on that request.
                    Assert.True(
                        await harness.Probe.WaitForTickRequestsAsync(1),
                        "The loop did not ask for a tick after the startup cycle."
                    );
                    Assert.False(harness.Loop.IsCompleted);
                    break;

                case LoopScenario.ThreeTicksRunThreeMore:
                    // Each released tick runs one more cycle. The loop is stopped only once it
                    // has asked, with the token live, for the tick after the fourth cycle.
                    for (int tick = 1; tick <= 3; tick++)
                    {
                        harness.ReleaseTick();
                        Assert.True(
                            await harness.Probe.WaitForCycleAsync(),
                            $"No cycle ran after tick {tick}."
                        );
                    }
                    Assert.True(
                        await harness.Probe.WaitForTickRequestsAsync(4),
                        "The loop did not ask for a tick after the fourth cycle."
                    );
                    expectedCycles = 4;
                    break;

                case LoopScenario.ThrowingCycleLoggedAndNextRuns:
                case LoopScenario.CycleCancellationWhileLiveLoggedAndNextRuns:
                    // The startup cycle throws while the token is live: it is logged at Error,
                    // the released tick runs a second cycle, and the loop stays live to ask, with
                    // the token live, for the tick after that cycle.
                    LogEntry error = await harness.Logger.Sink.WaitForMessageStartingWithAsync(
                        CycleErrorPrefix,
                        WaitBound
                    );
                    Assert.Equal(LogLevel.Error, error.Level);
                    Assert.Same(cycleFault, error.Exception);
                    // The console logger prints only the message, so the message carries the
                    // exception's type and text.
                    Assert.Equal(
                        scenario == LoopScenario.ThrowingCycleLoggedAndNextRuns
                            ? "Error running alert evaluation cycle (InvalidOperationException: "
                                + "Cycle 1 failed on purpose.)"
                            : "Error running alert evaluation cycle (OperationCanceledException: "
                                + "Cycle 1 timed out on purpose.)",
                        error.Message
                    );
                    harness.ReleaseTick();
                    Assert.True(
                        await harness.Probe.WaitForCycleAsync(),
                        "No cycle ran after the failed one."
                    );
                    Assert.True(
                        await harness.Probe.WaitForTickRequestsAsync(2),
                        "The loop did not ask for a tick after the second cycle."
                    );
                    Assert.False(harness.Loop.IsCompleted);
                    expectedCycles = 2;
                    expectedErrors = 1;
                    break;

                case LoopScenario.SourceEndsLoopStops:
                    // The tick requested after the startup cycle reports the source as finished,
                    // so that request is what ends the loop.
                    harness.EndSource();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    break;

                case LoopScenario.CancelledLoopStops:
                    // The token is cancelled only once the loop has asked for the tick after the
                    // startup cycle, so the cancellation ends that pending tick wait.
                    Assert.True(
                        await harness.Probe.WaitForTickRequestsAsync(1),
                        "The loop did not ask for a tick after the startup cycle."
                    );
                    await harness.CancelAsync();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    break;

                case LoopScenario.FaultWhileStoppingEndsQuietly:
                    // The startup cycle is held before it throws. Shutdown begins first, so its
                    // ordinary exception must end the loop as the stop, not as a failed cycle.
                    // The loop may end on that fault, or absorb it in its cycle handler and end on
                    // the cancelled wait for the next tick, so the log may end with that request.
                    Assert.False(harness.Loop.IsCompleted);
                    await harness.CancelAsync();
                    harness.Probe.ReleaseHeldCycle();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    tickAfterLastCycle = null;
                    break;

                case LoopScenario.HeldCycleDefersNextTick:
                    // The next tick is released while the startup cycle is held. A loop that does
                    // not await its running cycle has already asked for that tick, so it starts
                    // the next cycle before the held one ends. The loop is stopped only once it
                    // has asked, with the token live, for the tick after the second cycle.
                    harness.ReleaseTick();
                    harness.Probe.ReleaseHeldCycle();
                    Assert.True(
                        await harness.Probe.WaitForCycleAsync(),
                        "No cycle ran after the held one."
                    );
                    Assert.True(
                        await harness.Probe.WaitForTickRequestsAsync(2),
                        "The loop did not ask for a tick after the second cycle."
                    );
                    expectedCycles = 2;
                    break;

                case LoopScenario.TickCancellationWhileLiveEndsQuietly:
                    // The loop's token stays live; only the tick requested after the startup
                    // cycle reports cancellation, and that request ends the loop quietly.
                    harness.FailTick(new OperationCanceledException("Tick cancelled on purpose."));
                    await harness.Loop.WaitAsync(WaitBound);
                    break;

                case LoopScenario.TickFaultWhileLivePropagates:
                    // The tick requested after the startup cycle throws an ordinary fault while
                    // the token is live, and the loop must end by propagating it.
                    InvalidOperationException tickFault = new("Tick source failed on purpose.");
                    harness.FailTick(tickFault);
                    Assert.Same(
                        tickFault,
                        await Record.ExceptionAsync(() => harness.Loop.WaitAsync(WaitBound))
                    );
                    expectedStatus = TaskStatus.Faulted;
                    break;

                case LoopScenario.TickAcceptedAfterCancellationEndsWithoutCycle:
                    // The tick requested after the startup cycle cancels the loop's token and
                    // still yields true, as a tick source that ignores cancellation, or a timer
                    // tick that lands as shutdown begins, can. The loop must end normally on
                    // that tick without opening another scope.
                    harness.CancelThenReleaseTick();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    Assert.Equal(1, harness.ScopesCreated);
                    break;

                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
            await harness.StopAsync();

            // Assert
            Assert.Equal(expectedStatus, harness.Loop.Status);
            // Read after the loop is joined and before the provider is disposed, so every
            // Disposed entry is a scope the scheduler disposed itself. The order and disposal
            // between cycles are exact in every row. The tick request after the last cycle is
            // required where the row waited for it with the token live or where that request
            // drives the outcome. Only the stop during a held cycle accepts either ending: it is
            // held to the variant its log ends with, so the whole log is still compared exactly.
            string log = harness.Probe.Log;
            bool trailingTick =
                tickAfterLastCycle ?? log.EndsWith(" TickRequested", StringComparison.Ordinal);
            Assert.Equal(SerialCycleLog(expectedCycles, trailingTick), log);
            Assert.Equal(expectedErrors, harness.Logger.Sink.ByLevel(LogLevel.Error).Count);
        }

        [Fact]
        public async Task RunLoop_TokenCancelledBeforeStart_ShouldReturnWithoutScopeOrCycle()
        {
            // Arrange
            await using LoopHarness harness = new(null, false);
            await harness.CancelAsync();

            // Act
            harness.Start();
            await harness.Loop.WaitAsync(WaitBound);

            // Assert
            // The loop ends normally before the immediate first cycle: it opens no scope, runs
            // no cycle and never asks for a tick, so the probe log stays empty.
            Assert.True(harness.Loop.IsCompletedSuccessfully);
            Assert.Equal(0, harness.ScopesCreated);
            Assert.Equal(string.Empty, harness.Probe.Log);
            Assert.Empty(harness.Logger.Sink.ByLevel(LogLevel.Error));
        }

        /// <summary>
        /// The probe log of <paramref name="cycles"/> cycles run one at a time: each cycle starts
        /// and ends and its own scoped service is disposed before the next tick is requested, so
        /// no cycle starts before the previous one ends. With
        /// <paramref name="tickAfterLastCycle"/> true the log ends with the tick requested after
        /// the last cycle; with it false the log ends with the last cycle's disposal.
        /// </summary>
        private static string SerialCycleLog(int cycles, bool tickAfterLastCycle)
        {
            List<string> events = [];
            for (int cycle = 1; cycle <= cycles; cycle++)
            {
                events.Add($"CycleStarted({cycle})");
                events.Add($"CycleEnded({cycle})");
                events.Add($"Disposed({cycle})");
                if (cycle < cycles || tickAfterLastCycle)
                {
                    events.Add("TickRequested");
                }
            }
            return string.Join(' ', events);
        }

        /// <summary>
        /// Singleton shared by every cycle. It numbers the cycles, signals
        /// <see cref="CycleRan"/> as each one starts, counts and signals each tick request for
        /// <see cref="WaitForTickRequestsAsync"/>, and keeps the loop's event log, which is
        /// safe for concurrent writers and keeps the order the events happened in. The first
        /// cycle can be held on a gate until <see cref="ReleaseHeldCycle"/>, and can end by
        /// throwing a given fault.
        /// </summary>
        /// <param name="firstCycleFault">What the first cycle throws as it ends, or null.</param>
        /// <param name="holdFirstCycle">Whether the first cycle waits on the gate to end.</param>
        private sealed class CycleProbe(Exception? firstCycleFault, bool holdFirstCycle)
            : IDisposable
        {
            private readonly ConcurrentQueue<string> _log = new();

            // Continuations run asynchronously, so releasing the gate never runs the held cycle
            // on the releasing thread.
            private readonly TaskCompletionSource _gate = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            // Released once per tick request, after the request is counted.
            private readonly SemaphoreSlim _tickRequested = new(0);
            private int _cycleCount;
            private int _tickRequestCount;

            public SemaphoreSlim CycleRan { get; } = new(0);

            /// <summary>
            /// The events so far, space-separated in order: <c>CycleStarted(n)</c> and
            /// <c>CycleEnded(n)</c> for cycle n, <c>Disposed(n)</c> when the scoped service that
            /// ran cycle n is disposed, and <c>TickRequested</c> when the loop asks for a tick.
            /// </summary>
            public string Log => string.Join(' ', _log);

            public void ReleaseHeldCycle()
            {
                _gate.TrySetResult();
            }

            /// <summary>Numbers and logs a starting cycle, then signals its start.</summary>
            public int StartCycle()
            {
                int cycle = Interlocked.Increment(ref _cycleCount);
                _log.Enqueue($"CycleStarted({cycle})");
                CycleRan.Release();
                return cycle;
            }

            /// <summary>
            /// Holds the first cycle on the gate when asked to, logs the cycle's end, then throws
            /// the first cycle's fault, if any. The gate is awaited without the cycle token, so a
            /// held fault is still raised as an ordinary exception after shutdown begins.
            /// </summary>
            public async Task EndCycleAsync(int cycle)
            {
                if (cycle == 1 && holdFirstCycle)
                {
                    await _gate.Task;
                }
                _log.Enqueue($"CycleEnded({cycle})");
                if (cycle == 1 && firstCycleFault is not null)
                {
                    throw firstCycleFault;
                }
            }

            public void RecordDisposed(int cycle)
            {
                _log.Enqueue($"Disposed({cycle})");
            }

            /// <summary>Logs a tick request, then counts and signals it.</summary>
            public void RecordTickRequested()
            {
                _log.Enqueue("TickRequested");
                Interlocked.Increment(ref _tickRequestCount);
                _tickRequested.Release();
            }

            public Task<bool> WaitForCycleAsync()
            {
                return CycleRan.WaitAsync(WaitBound);
            }

            /// <summary>
            /// Waits until the loop has asked for at least <paramref name="count"/> ticks in all.
            /// Each wait for a further request is bounded by <see cref="WaitBound"/>; the result
            /// is false when a bound elapses first.
            /// </summary>
            public async Task<bool> WaitForTickRequestsAsync(int count)
            {
                while (Volatile.Read(ref _tickRequestCount) < count)
                {
                    if (!await _tickRequested.WaitAsync(WaitBound))
                    {
                        return false;
                    }
                }
                return true;
            }

            public void Dispose()
            {
                CycleRan.Dispose();
                _tickRequested.Dispose();
            }
        }

        /// <summary>
        /// Scoped service that runs one cycle on the probe and logs its own disposal under that
        /// cycle's number. It implements only <see cref="IAsyncDisposable"/>, so disposing its
        /// scope synchronously throws instead of disposing it.
        /// </summary>
        private sealed class ProbeEvaluationService(CycleProbe probe)
            : IAlertEvaluationService,
                IAsyncDisposable
        {
            private int _cycle;

            public async Task<AlertEvaluationResult> RunCycleAsync(
                CancellationToken cancellationToken
            )
            {
                _cycle = probe.StartCycle();
                await probe.EndCycleAsync(_cycle);
                return new AlertEvaluationResult(
                    AlertEvaluationOutcome.Completed,
                    0,
                    0,
                    0,
                    0,
                    TimeSpan.Zero
                );
            }

            public ValueTask DisposeAsync()
            {
                probe.RecordDisposed(_cycle);
                return ValueTask.CompletedTask;
            }
        }

        /// <summary>
        /// Scope factory that counts every scope opened through it and returns the provider's
        /// own scope, so each scope resolves and disposes exactly as the provider's does. Safe
        /// for concurrent callers.
        /// </summary>
        private sealed class CountingScopeFactory(IServiceScopeFactory inner) : IServiceScopeFactory
        {
            private int _created;

            /// <summary>The number of scopes opened so far.</summary>
            public int Created => Volatile.Read(ref _created);

            public IServiceScope CreateScope()
            {
                Interlocked.Increment(ref _created);
                return inner.CreateScope();
            }
        }

        /// <summary>
        /// Owns the scheduler under test, its service provider and its tick source. Each
        /// <see cref="ReleaseTick"/>, <see cref="CancelThenReleaseTick"/>,
        /// <see cref="EndSource"/> or <see cref="FailTick"/> completes exactly one tick, in the
        /// order they are called.
        /// </summary>
        private sealed class LoopHarness : IAsyncDisposable
        {
            private readonly ServiceProvider _provider;
            private readonly CountingScopeFactory _scopes;
            private readonly AlertEvaluationSchedulerService _scheduler;

            // Each item is one tick: it returns whether the source goes on, or throws as a
            // failing source does.
            private readonly Channel<Func<bool>> _ticks = Channel.CreateUnbounded<Func<bool>>();
            private readonly CancellationTokenSource _cts = new();
            private Task? _join;

            public LoopHarness(Exception? firstCycleFault, bool holdFirstCycle)
            {
                ServiceCollection services = new();
                services.AddSingleton(_ => new CycleProbe(firstCycleFault, holdFirstCycle));
                services.AddScoped<IAlertEvaluationService, ProbeEvaluationService>();
                _provider = services.BuildServiceProvider(
                    new ServiceProviderOptions { ValidateOnBuild = true, ValidateScopes = true }
                );
                Probe = _provider.GetRequiredService<CycleProbe>();
                _scopes = new CountingScopeFactory(
                    _provider.GetRequiredService<IServiceScopeFactory>()
                );
                _scheduler = new AlertEvaluationSchedulerService(
                    _scopes,
                    new ConfigurationBuilder().AddInMemoryCollection().Build(),
                    Logger
                );
            }

            public CycleProbe Probe { get; }

            /// <summary>The number of scopes the scheduler has opened so far.</summary>
            public int ScopesCreated => _scopes.Created;

            public RecordingLogger<AlertEvaluationSchedulerService> Logger { get; } = new();

            public Task Loop { get; private set; } = Task.CompletedTask;

            public void Start()
            {
                Loop = _scheduler.RunLoopAsync(WaitForNextTickAsync, _cts.Token);
            }

            public void ReleaseTick()
            {
                QueueTick(() => true);
            }

            /// <summary>
            /// Completes one more tick that cancels the loop's token and then reports the source
            /// as going on, as a tick source that ignores cancellation does.
            /// </summary>
            public void CancelThenReleaseTick()
            {
                QueueTick(() =>
                {
                    _cts.Cancel();
                    return true;
                });
            }

            /// <summary>Completes one more tick that reports the source as finished.</summary>
            public void EndSource()
            {
                QueueTick(() => false);
            }

            /// <summary>Completes one more tick by throwing <paramref name="fault"/>.</summary>
            public void FailTick(Exception fault)
            {
                ArgumentNullException.ThrowIfNull(fault);
                QueueTick(() => throw fault);
            }

            public Task CancelAsync()
            {
                return _cts.CancelAsync();
            }

            /// <summary>
            /// Stops the loop and joins it, once: every call returns the same join. It cancels
            /// the loop's token, closes the tick source so a pending or later tick wait reports
            /// the end without relying on that token, and releases a held cycle. The join
            /// fails with <see cref="TimeoutException"/> when the loop is still running after
            /// <see cref="WaitBound"/>. A loop that ended by faulting has stopped, and its fault
            /// is left to the test to assert.
            /// </summary>
            public Task StopAsync()
            {
                return _join ??= StopAndJoinAsync();
            }

            /// <summary>
            /// Joins the loop through <see cref="StopAsync"/>, so a join that already failed is
            /// not waited for again, and never throws: a failed join is reported by the test's
            /// own call, and an exception from teardown would replace the test's own failure.
            /// The scheduler, the service provider and the token source are disposed only once
            /// the loop has ended.
            /// </summary>
            public async ValueTask DisposeAsync()
            {
                await StopAsync().ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
                if (!Loop.IsCompleted)
                {
                    // The loop may still hold a scope, the probe's signal or the token, so they
                    // are left undisposed rather than torn down while it runs.
                    return;
                }
                _scheduler.Dispose();
                await _provider.DisposeAsync();
                _cts.Dispose();
            }

            private async Task StopAndJoinAsync()
            {
                await _cts.CancelAsync();
                _ticks.Writer.TryComplete();
                Probe.ReleaseHeldCycle();
                await Loop.WaitAsync(WaitBound)
                    .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
                if (!Loop.IsCompleted)
                {
                    throw new TimeoutException($"The loop was still running after {WaitBound}.");
                }
            }

            private void QueueTick(Func<bool> tick)
            {
                if (!_ticks.Writer.TryWrite(tick))
                {
                    throw new InvalidOperationException("The tick source is already closed.");
                }
            }

            private async ValueTask<bool> WaitForNextTickAsync(CancellationToken cancellationToken)
            {
                // Logged and signalled on entry, before any wait, so the log shows when the loop
                // asked and a test can wait for the request.
                Probe.RecordTickRequested();
                while (await _ticks.Reader.WaitToReadAsync(cancellationToken))
                {
                    if (_ticks.Reader.TryRead(out Func<bool>? tick))
                    {
                        return tick();
                    }
                }
                // A closed source with no tick left has ended.
                return false;
            }
        }
    }
}
