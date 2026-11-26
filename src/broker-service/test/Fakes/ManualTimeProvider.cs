using System.Diagnostics.CodeAnalysis;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// A <see cref="TimeProvider"/> whose clock moves only when a test calls
    /// <see cref="Advance"/>, so a test drives every timeout of the code under test without
    /// waiting. A timer it creates fires only inside <see cref="Advance"/>, on the calling thread,
    /// once the clock reaches its due time; timers due together fire in the order they were
    /// scheduled, each with the clock set to its own due time. Safe for concurrent callers, and
    /// concurrent <see cref="Advance"/> calls run one after the other.
    /// </summary>
    /// <param name="start">The clock's initial time; it is kept in UTC.</param>
    public sealed class ManualTimeProvider(DateTimeOffset start) : TimeProvider
    {
        /// <summary>The initial time of a clock created without one.</summary>
        public static readonly DateTimeOffset DefaultStart = new(
            2025,
            1,
            1,
            0,
            0,
            0,
            TimeSpan.Zero
        );

        private readonly Lock _gate = new();

        // Held for a whole Advance, so the firings of two advances never interleave.
        private readonly Lock _advanceGate = new();
        private readonly DateTimeOffset _start = start.ToUniversalTime();
        private readonly List<ManualTimer> _scheduled = [];
        private readonly List<TimerWaiter> _waiters = [];
        private DateTimeOffset _utcNow = start.ToUniversalTime();
        private int _createdCount;

        // Orders timers that fall due at the same time by when they were scheduled.
        private long _scheduleSequence;

        public ManualTimeProvider()
            : this(DefaultStart) { }

        /// <summary>Timers created since construction, whatever their state now.</summary>
        public int CreatedTimerCount
        {
            get
            {
                lock (_gate)
                {
                    return _createdCount;
                }
            }
        }

        /// <summary>
        /// Timers that will fire once the clock reaches their due time: neither disposed, nor set
        /// to an infinite due time, nor one-shot timers that have already fired.
        /// </summary>
        public int ScheduledTimerCount
        {
            get
            {
                lock (_gate)
                {
                    return _scheduled.Count;
                }
            }
        }

        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public override DateTimeOffset GetUtcNow()
        {
            lock (_gate)
            {
                return _utcNow;
            }
        }

        public override long GetTimestamp()
        {
            lock (_gate)
            {
                return (_utcNow - _start).Ticks;
            }
        }

        /// <summary>
        /// Completes once <paramref name="count"/> timers in all have been created, so a test
        /// advances the clock only after the code under test has started the timeout it drives.
        /// Its continuations run asynchronously, never inside <see cref="CreateTimer"/>.
        /// </summary>
        public Task WaitForCreatedTimersAsync(int count)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(count);
            lock (_gate)
            {
                if (_createdCount >= count)
                {
                    return Task.CompletedTask;
                }
                TaskCompletionSource signal = new(
                    TaskCreationOptions.RunContinuationsAsynchronously
                );
                _waiters.Add(new TimerWaiter(count, signal));
                return signal.Task;
            }
        }

        /// <summary>
        /// Moves the clock forward by <paramref name="delta"/> and fires, in due-time order, every
        /// timer that falls due on the way, a periodic timer once per elapsed period. A timer a
        /// callback schedules within the advanced span fires during the same call.
        /// </summary>
        public void Advance(TimeSpan delta)
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(delta, TimeSpan.Zero);
            lock (_advanceGate)
            {
                DateTimeOffset target;
                lock (_gate)
                {
                    target = _utcNow + delta;
                }
                // Each callback runs outside _gate, so it may create, change or dispose timers.
                while (TryTakeDueTimer(target, out ManualTimer? due))
                {
                    due.Fire();
                }
            }
        }

        public override ITimer CreateTimer(
            TimerCallback callback,
            object? state,
            TimeSpan dueTime,
            TimeSpan period
        )
        {
            ArgumentNullException.ThrowIfNull(callback);
            ThrowIfInvalidSpan(dueTime, nameof(dueTime));
            ThrowIfInvalidSpan(period, nameof(period));

            ManualTimer timer = new(this, callback, state);
            List<TaskCompletionSource> reached = [];
            lock (_gate)
            {
                ScheduleLocked(timer, dueTime, period);
                _createdCount++;
                foreach (TimerWaiter waiter in _waiters)
                {
                    if (waiter.Count <= _createdCount)
                    {
                        reached.Add(waiter.Signal);
                    }
                }
                _waiters.RemoveAll(waiter => waiter.Count <= _createdCount);
            }
            foreach (TaskCompletionSource signal in reached)
            {
                signal.TrySetResult();
            }
            return timer;
        }

        // Timeout.InfiniteTimeSpan never fires; any other negative span is rejected, as
        // System.Threading.Timer rejects it.
        private static void ThrowIfInvalidSpan(TimeSpan value, string parameterName)
        {
            if ((value < TimeSpan.Zero) && (value != Timeout.InfiniteTimeSpan))
            {
                throw new ArgumentOutOfRangeException(
                    parameterName,
                    value,
                    "The span must not be negative unless it is Timeout.InfiniteTimeSpan."
                );
            }
        }

        // Takes the earliest timer due by target, moving the clock to its due time, and
        // reschedules it when it is periodic. Without one, the clock moves to target.
        private bool TryTakeDueTimer(
            DateTimeOffset target,
            [NotNullWhen(true)] out ManualTimer? due
        )
        {
            lock (_gate)
            {
                due = null;
                foreach (ManualTimer timer in _scheduled)
                {
                    bool earlier =
                        due is null
                        || (timer.DueAt < due.DueAt)
                        || ((timer.DueAt == due.DueAt) && (timer.Sequence < due.Sequence));
                    if ((timer.DueAt <= target) && earlier)
                    {
                        due = timer;
                    }
                }

                if (due is null)
                {
                    _utcNow = target;
                    return false;
                }

                if (due.DueAt > _utcNow)
                {
                    _utcNow = due.DueAt;
                }
                if (due.Period > TimeSpan.Zero)
                {
                    due.DueAt += due.Period;
                    due.Sequence = ++_scheduleSequence;
                }
                else
                {
                    _scheduled.Remove(due);
                }
                return true;
            }
        }

        // A zero or infinite period makes a one-shot timer; an infinite due time stops it.
        private void ScheduleLocked(ManualTimer timer, TimeSpan dueTime, TimeSpan period)
        {
            _scheduled.Remove(timer);
            timer.Period = period == Timeout.InfiniteTimeSpan ? TimeSpan.Zero : period;
            if (dueTime == Timeout.InfiniteTimeSpan)
            {
                return;
            }
            timer.DueAt = _utcNow + dueTime;
            timer.Sequence = ++_scheduleSequence;
            _scheduled.Add(timer);
        }

        private bool Reschedule(ManualTimer timer, TimeSpan dueTime, TimeSpan period)
        {
            ThrowIfInvalidSpan(dueTime, nameof(dueTime));
            ThrowIfInvalidSpan(period, nameof(period));
            lock (_gate)
            {
                if (timer.Disposed)
                {
                    return false;
                }
                ScheduleLocked(timer, dueTime, period);
                return true;
            }
        }

        private void Release(ManualTimer timer)
        {
            lock (_gate)
            {
                timer.Disposed = true;
                _scheduled.Remove(timer);
            }
        }

        private sealed record TimerWaiter(int Count, TaskCompletionSource Signal);

        // Its schedule is read and written only under the owner's _gate.
        private sealed class ManualTimer(
            ManualTimeProvider owner,
            TimerCallback callback,
            object? state
        ) : ITimer
        {
            public DateTimeOffset DueAt { get; set; }

            public TimeSpan Period { get; set; }

            public long Sequence { get; set; }

            public bool Disposed { get; set; }

            /// <summary>Reschedules the timer; <c>false</c> once it is disposed.</summary>
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                return owner.Reschedule(this, dueTime, period);
            }

            public void Dispose()
            {
                owner.Release(this);
            }

            public ValueTask DisposeAsync()
            {
                owner.Release(this);
                return ValueTask.CompletedTask;
            }

            public void Fire()
            {
                callback(state);
            }
        }
    }
}
