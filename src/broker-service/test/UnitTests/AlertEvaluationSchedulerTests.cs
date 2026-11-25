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
        }

        [Theory]
        [InlineData(null, 60, true)]
        [InlineData("abc", 60, true)]
        [InlineData("0", 60, true)]
        [InlineData("-5", 60, true)]
        [InlineData("4294968", 60, true)]
        [InlineData("15", 15, false)]
        [InlineData("4294967", 4294967, false)]
        public void ResolveInterval_Setting_ShouldResolve(
            string? value,
            int expected,
            bool expectWarning
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
                    Assert.StartsWith(InvalidIntervalPrefix, warning.Message);
                    Assert.Equal(value, warning.GetField("value"));
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
        [InlineData(LoopScenario.StartRunsOneCycle)]
        [InlineData(LoopScenario.ThreeTicksRunThreeMore)]
        [InlineData(LoopScenario.ThrowingCycleLoggedAndNextRuns)]
        [InlineData(LoopScenario.SourceEndsLoopStops)]
        [InlineData(LoopScenario.CancelledLoopStops)]
        public async Task RunLoop_TickSource_ShouldDriveCycles(LoopScenario scenario)
        {
            // Arrange
            int? throwOnCycle = scenario == LoopScenario.ThrowingCycleLoggedAndNextRuns ? 1 : null;
            await using LoopHarness harness = new(throwOnCycle);
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
        /// ran each one, and signals <see cref="CycleRan"/> once per cycle.
        /// </summary>
        private sealed class CycleProbe(int? throwOnCycle) : IDisposable
        {
            private readonly ConcurrentQueue<IAlertEvaluationService> _instances = new();
            private int _cycleCount;

            public SemaphoreSlim CycleRan { get; } = new(0);

            /// <summary>The 1-based cycle that fails, or null when every cycle succeeds.</summary>
            public int? ThrowOnCycle { get; } = throwOnCycle;

            public int CycleCount => Volatile.Read(ref _cycleCount);

            public IReadOnlyCollection<IAlertEvaluationService> Instances => _instances;

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
                    return Task.FromException<AlertEvaluationResult>(
                        new InvalidOperationException($"Cycle {cycle} failed on purpose.")
                    );
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

            public LoopHarness(int? throwOnCycle)
            {
                ServiceCollection services = new();
                services.AddSingleton(_ => new CycleProbe(throwOnCycle));
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
            /// Cancels the loop and waits for it, so no cycle outlives the service provider.
            /// </summary>
            public async Task StopAsync()
            {
                await _cts.CancelAsync();
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
