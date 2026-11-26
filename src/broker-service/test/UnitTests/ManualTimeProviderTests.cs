using EasyTrade.BrokerService.Test.Fakes;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    // Covers the fake's own clock and scheduling, which the consumer suites reach only through
    // Task.WaitAsync: one one-shot timer per wait, disposed when it fires or the wait ends.
    public class ManualTimeProviderTests
    {
        private static readonly TimeSpan DueTime = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan LaterDueTime = TimeSpan.FromSeconds(20);
        private static readonly TimeSpan FarAdvance = TimeSpan.FromSeconds(25);
        private static readonly TimeSpan OneTick = TimeSpan.FromTicks(1);

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum TimerScenario
        {
            OneShotShortOfDue,
            OneShotAtDue,
            OneShotFarPastDue,
            PeriodicOverTwoPeriods,
            InfiniteDue,
            ChangedToInfinite,
            ChangedToLaterDue,
            Disposed,
        }

        public enum InvalidSpan
        {
            DueTime,
            Period,
        }

        // The expected list holds the clock time each callback saw, from the start, in order.
        [Theory]
        [InlineData(TimerScenario.OneShotShortOfDue)]
        [InlineData(TimerScenario.OneShotAtDue)]
        [InlineData(TimerScenario.OneShotFarPastDue)]
        [InlineData(TimerScenario.PeriodicOverTwoPeriods)]
        [InlineData(TimerScenario.InfiniteDue)]
        [InlineData(TimerScenario.ChangedToInfinite)]
        [InlineData(TimerScenario.ChangedToLaterDue)]
        [InlineData(TimerScenario.Disposed)]
        public void Advance_TimerScenario_ShouldFireOnlyAtDueTimes(TimerScenario scenario)
        {
            // Arrange
            ManualTimeProvider time = new();
            List<TimeSpan> fired = [];
            TimerCase timerCase = BuildTimerCase(scenario);
            ITimer timer = time.CreateTimer(
                _ => fired.Add(time.GetUtcNow() - ManualTimeProvider.DefaultStart),
                null,
                timerCase.DueTime,
                timerCase.Period
            );
            timerCase.AfterCreate(timer);

            // Act
            time.Advance(timerCase.Advance);

            // Assert
            Assert.Equal(timerCase.ExpectedFirings, fired);
        }

        [Fact]
        public void Advance_TimersDueTogether_ShouldFireInScheduleOrder()
        {
            // Arrange: the second timer is scheduled first, both for the same due time.
            ManualTimeProvider time = new();
            List<string> fired = [];
            using ITimer second = time.CreateTimer(
                _ => fired.Add("second"),
                null,
                LaterDueTime,
                Timeout.InfiniteTimeSpan
            );
            using ITimer first = time.CreateTimer(
                _ => fired.Add("first"),
                null,
                DueTime,
                Timeout.InfiniteTimeSpan
            );
            _ = second.Change(DueTime, Timeout.InfiniteTimeSpan);

            // Act
            time.Advance(FarAdvance);

            // Assert: the change rescheduled the second timer after the first.
            Assert.Equal(["first", "second"], fired);
        }

        [Fact]
        public void Advance_Delta_ShouldMoveWallClockAndTimestamp()
        {
            // Arrange
            ManualTimeProvider time = new();
            long started = time.GetTimestamp();

            // Act
            time.Advance(DueTime);

            // Assert
            Assert.Equal(
                (ManualTimeProvider.DefaultStart + DueTime, DueTime),
                (time.GetUtcNow(), time.GetElapsedTime(started))
            );
        }

        [Fact]
        public async Task WaitForCreatedTimers_CountReached_ShouldCompleteOnlyThen()
        {
            // Arrange
            ManualTimeProvider time = new();
            Task created = time.WaitForCreatedTimersAsync(1);
            bool pendingBeforeCreation = !created.IsCompleted;

            // Act
            using ITimer timer = time.CreateTimer(
                _ => { },
                null,
                DueTime,
                Timeout.InfiniteTimeSpan
            );
            await created.WaitAsync(TimeSpan.FromSeconds(5));

            // Assert
            Assert.Equal((true, 1), (pendingBeforeCreation, time.CreatedTimerCount));
        }

        [Fact]
        public void Change_DisposedTimer_ShouldReturnFalseAndStaySilent()
        {
            // Arrange
            ManualTimeProvider time = new();
            int firings = 0;
            ITimer timer = time.CreateTimer(
                _ => firings++,
                null,
                DueTime,
                Timeout.InfiniteTimeSpan
            );
            timer.Dispose();

            // Act
            bool changed = timer.Change(TimeSpan.Zero, Timeout.InfiniteTimeSpan);
            time.Advance(FarAdvance);

            // Assert
            Assert.Equal((false, 0, 0), (changed, firings, time.ScheduledTimerCount));
        }

        [Theory]
        [InlineData(InvalidSpan.DueTime, "dueTime")]
        [InlineData(InvalidSpan.Period, "period")]
        public void CreateTimer_NegativeSpan_ShouldThrowArgumentOutOfRange(
            InvalidSpan invalidSpan,
            string parameterName
        )
        {
            // Arrange
            ManualTimeProvider time = new();
            TimeSpan negative = -OneTick;

            // Act and Assert
            Assert.Throws<ArgumentOutOfRangeException>(
                parameterName,
                () =>
                    time.CreateTimer(
                        _ => { },
                        null,
                        invalidSpan == InvalidSpan.DueTime ? negative : DueTime,
                        invalidSpan == InvalidSpan.Period ? negative : Timeout.InfiniteTimeSpan
                    )
            );
        }

        private static TimerCase BuildTimerCase(TimerScenario scenario)
        {
            TimeSpan never = Timeout.InfiniteTimeSpan;
            Action<ITimer> nothing = _ => { };
            return scenario switch
            {
                TimerScenario.OneShotShortOfDue => new(
                    DueTime,
                    never,
                    nothing,
                    DueTime - OneTick,
                    []
                ),
                TimerScenario.OneShotAtDue => new(DueTime, never, nothing, DueTime, [DueTime]),
                TimerScenario.OneShotFarPastDue => new(
                    DueTime,
                    never,
                    nothing,
                    FarAdvance,
                    [DueTime]
                ),
                TimerScenario.PeriodicOverTwoPeriods => new(
                    DueTime,
                    DueTime,
                    nothing,
                    FarAdvance,
                    [DueTime, LaterDueTime]
                ),
                TimerScenario.InfiniteDue => new(never, never, nothing, FarAdvance, []),
                TimerScenario.ChangedToInfinite => new(
                    DueTime,
                    never,
                    timer => timer.Change(never, never),
                    FarAdvance,
                    []
                ),
                TimerScenario.ChangedToLaterDue => new(
                    DueTime,
                    never,
                    timer => timer.Change(LaterDueTime, never),
                    FarAdvance,
                    [LaterDueTime]
                ),
                TimerScenario.Disposed => new(
                    DueTime,
                    never,
                    timer => timer.Dispose(),
                    FarAdvance,
                    []
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(scenario), scenario, null),
            };
        }

        private sealed record TimerCase(
            TimeSpan DueTime,
            TimeSpan Period,
            Action<ITimer> AfterCreate,
            TimeSpan Advance,
            TimeSpan[] ExpectedFirings
        );
    }
}
