using System.Collections.Concurrent;
using EasyTrade.BrokerService.Entities.Alerts.Scheduler;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertEvaluationSchedulerTests
    {
        private const string InvalidIntervalPrefix = "Invalid ALERT_EVALUATION_INTERVAL_SECONDS";
        private const string CycleErrorPrefix = "Error running alert evaluation cycle";
        private const string StartupPrefix = "Starting alert evaluation scheduler";

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
        }

        [Theory]
        [InlineData(null, 60, true, null)]
        [InlineData("abc", 60, true, "abc")]
        [InlineData("0", 60, true, "0")]
        [InlineData("-5", 60, true, "-5")]
        [InlineData("4294968", 60, true, "4294968")]
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
                settings[Constants.AlertEvaluationIntervalSeconds] = value;
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
                settings[Constants.AlertEvaluationIntervalSeconds] = value;
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
        public async Task RunLoop_TickSource_ShouldDriveCycles(LoopScenario scenario)
        {
            // Arrange
            bool holdFault = scenario == LoopScenario.FaultWhileStoppingEndsQuietly;
            int? throwOnCycle =
                scenario == LoopScenario.ThrowingCycleLoggedAndNextRuns || holdFault ? 1 : null;
            await using LoopHarness harness = new(throwOnCycle, holdFault);
            int expectedCycles = 1;
            int expectedErrors = 0;

            // Act
            harness.Start();
            Assert.True(await harness.Probe.WaitForCycleAsync(), "The startup cycle did not run.");
            switch (scenario)
            {
                case LoopScenario.StartRunsOneCycle:
                    // No tick was released, so the loop must be parked on the tick source.
                    Assert.False(harness.Loop.IsCompleted);
                    break;

                case LoopScenario.ThreeTicksRunThreeMore:
                    for (int tick = 1; tick <= 3; tick++)
                    {
                        harness.ReleaseTick();
                        Assert.True(
                            await harness.Probe.WaitForCycleAsync(),
                            $"No cycle ran after tick {tick}."
                        );
                    }
                    expectedCycles = 4;
                    break;

                case LoopScenario.ThrowingCycleLoggedAndNextRuns:
                    LogEntry error = await harness.Logger.Sink.WaitForMessageStartingWithAsync(
                        CycleErrorPrefix,
                        WaitBound
                    );
                    Assert.Equal(LogLevel.Error, error.Level);
                    Assert.IsType<InvalidOperationException>(error.Exception);
                    harness.ReleaseTick();
                    Assert.True(
                        await harness.Probe.WaitForCycleAsync(),
                        "No cycle ran after the failed one."
                    );
                    Assert.False(harness.Loop.IsCompleted);
                    expectedCycles = 2;
                    expectedErrors = 1;
                    break;

                case LoopScenario.SourceEndsLoopStops:
                    harness.EndSource();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    break;

                case LoopScenario.CancelledLoopStops:
                    await harness.CancelAsync();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    break;

                case LoopScenario.FaultWhileStoppingEndsQuietly:
                    // The startup cycle is held before it throws. Shutdown begins first, so its
                    // ordinary exception must end the loop as the stop, not as a failed cycle.
                    Assert.False(harness.Loop.IsCompleted);
                    await harness.CancelAsync();
                    harness.Probe.ReleaseFault();
                    await harness.Loop.WaitAsync(WaitBound);
                    Assert.True(harness.Loop.IsCompletedSuccessfully);
                    break;

                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null);
            }
            await harness.StopAsync();

            // Assert
            Assert.True(harness.Loop.IsCompletedSuccessfully);
            Assert.Equal(expectedCycles, harness.Probe.CycleCount);
            Assert.Equal(
                expectedCycles,
                harness.Probe.Instances.Distinct(ReferenceEqualityComparer.Instance).Count()
            );
            Assert.Equal(expectedErrors, harness.Logger.Sink.ByLevel(LogLevel.Error).Count);
        }

        /// <summary>
        /// Singleton shared by every cycle: counts cycles, keeps the scoped service instance that
        /// ran each one, and signals <see cref="CycleRan"/> once per cycle. A held fault keeps the
        /// failing cycle waiting on <see cref="FaultReleased"/> until <see cref="ReleaseFault"/>.
        /// </summary>
        private sealed class CycleProbe(int? throwOnCycle, bool holdFault) : IDisposable
        {
            private readonly ConcurrentQueue<IAlertEvaluationService> _instances = new();

            // Continuations run asynchronously, so releasing the gate never runs the held cycle
            // on the releasing thread.
            private readonly TaskCompletionSource _faultGate = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            private int _cycleCount;

            public SemaphoreSlim CycleRan { get; } = new(0);

            /// <summary>The 1-based cycle that fails, or null when every cycle succeeds.</summary>
            public int? ThrowOnCycle { get; } = throwOnCycle;

            public int CycleCount => Volatile.Read(ref _cycleCount);

            public IReadOnlyCollection<IAlertEvaluationService> Instances => _instances;

            /// <summary>Completes when the failing cycle may throw: at once unless held.</summary>
            public Task FaultReleased => holdFault ? _faultGate.Task : Task.CompletedTask;

            public void ReleaseFault()
            {
                _faultGate.TrySetResult();
            }

            public int Record(IAlertEvaluationService instance)
            {
                _instances.Enqueue(instance);
                int cycle = Interlocked.Increment(ref _cycleCount);
                CycleRan.Release();
                return cycle;
            }

            public Task<bool> WaitForCycleAsync()
            {
                return CycleRan.WaitAsync(WaitBound);
            }

            public void Dispose()
            {
                CycleRan.Dispose();
            }
        }

        private sealed class ProbeEvaluationService(CycleProbe probe) : IAlertEvaluationService
        {
            public Task<AlertEvaluationResult> RunCycleAsync(CancellationToken cancellationToken)
            {
                int cycle = probe.Record(this);
                if (cycle == probe.ThrowOnCycle)
                {
                    return FailAsync(cycle);
                }
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

            // Waits on the probe's gate without the cycle token, so a held fault is still raised
            // as an ordinary exception after shutdown begins.
            private async Task<AlertEvaluationResult> FailAsync(int cycle)
            {
                await probe.FaultReleased;
                throw new InvalidOperationException($"Cycle {cycle} failed on purpose.");
            }
        }

        /// <summary>
        /// Owns the scheduler under test, its service provider and its tick source. Each
        /// <see cref="ReleaseTick"/> completes exactly one tick.
        /// </summary>
        private sealed class LoopHarness : IAsyncDisposable
        {
            private readonly ServiceProvider _provider;
            private readonly AlertEvaluationSchedulerService _scheduler;
            private readonly SemaphoreSlim _ticks = new(0);
            private readonly CancellationTokenSource _cts = new();
            private bool _sourceEnded;

            public LoopHarness(int? throwOnCycle, bool holdFault = false)
            {
                ServiceCollection services = new();
                services.AddSingleton(_ => new CycleProbe(throwOnCycle, holdFault));
                services.AddScoped<IAlertEvaluationService, ProbeEvaluationService>();
                _provider = services.BuildServiceProvider(
                    new ServiceProviderOptions { ValidateOnBuild = true, ValidateScopes = true }
                );
                Probe = _provider.GetRequiredService<CycleProbe>();
                _scheduler = new AlertEvaluationSchedulerService(
                    _provider.GetRequiredService<IServiceScopeFactory>(),
                    new ConfigurationBuilder().AddInMemoryCollection().Build(),
                    Logger
                );
            }

            public CycleProbe Probe { get; }

            public RecordingLogger<AlertEvaluationSchedulerService> Logger { get; } = new();

            public Task Loop { get; private set; } = Task.CompletedTask;

            public void Start()
            {
                Loop = _scheduler.RunLoopAsync(WaitForNextTickAsync, _cts.Token);
            }

            public void ReleaseTick()
            {
                _ticks.Release();
            }

            /// <summary>Completes one more tick that reports the source as finished.</summary>
            public void EndSource()
            {
                Volatile.Write(ref _sourceEnded, true);
                _ticks.Release();
            }

            public Task CancelAsync()
            {
                return _cts.CancelAsync();
            }

            /// <summary>
            /// Cancels the loop, then releases a held fault so no cycle stays parked, and waits
            /// for the loop, so no cycle outlives the service provider.
            /// </summary>
            public async Task StopAsync()
            {
                await _cts.CancelAsync();
                Probe.ReleaseFault();
                await Loop.WaitAsync(WaitBound);
            }

            public async ValueTask DisposeAsync()
            {
                try
                {
                    await StopAsync();
                }
                finally
                {
                    _scheduler.Dispose();
                    await _provider.DisposeAsync();
                    _ticks.Dispose();
                    _cts.Dispose();
                }
            }

            private async ValueTask<bool> WaitForNextTickAsync(CancellationToken cancellationToken)
            {
                await _ticks.WaitAsync(cancellationToken);
                return !Volatile.Read(ref _sourceEnded);
            }
        }
    }
}
