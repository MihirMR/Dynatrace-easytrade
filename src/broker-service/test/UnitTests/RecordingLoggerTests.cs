using System.Collections;
using System.Collections.Concurrent;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class RecordingLoggerTests
    {
        private const string LateExpiryPrefix =
            "No log entry matched [entry => entry.Message == \"late\"] within ";

        // Bounds every wait on a signal, so a broken fake fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(5);

        public enum StateWrite
        {
            IndexerSet,
            Insert,
            RemoveAt,
            Add,
            Remove,
            Clear,
            NonGenericIndexerSet,
        }

        [Theory]
        [InlineData(typeof(TimeoutException))]
        [InlineData(typeof(InvalidOperationException))]
        public async Task WaitForAsync_PredicateThrowsOnLaterEntry_ShouldSurfaceSameException(
            Type exceptionType
        )
        {
            // Arrange
            RecordingLogSink sink = new();
            Exception expected = (Exception)
                Activator.CreateInstance(exceptionType, "predicate failed")!;
            Task<LogEntry> wait = sink.WaitForAsync(
                entry => entry.Message == "later" ? throw expected : false,
                WaitBound
            );

            // Act
            sink.Add(Entry("later"));
            Exception? actual = await Record.ExceptionAsync(() => wait.WaitAsync(WaitBound));

            // Assert
            Assert.Same(expected, actual);
        }

        [Fact]
        public async Task WaitForAsync_NoMatchWithinTimeout_ShouldThrowTimeoutNamingPredicate()
        {
            // Arrange
            RecordingLogSink sink = new();
            sink.Add(Entry("other"));

            // Act
            Exception? error = await Record.ExceptionAsync(
                () =>
                    sink.WaitForAsync(entry => entry.Message == "never", TimeSpan.Zero)
                        .WaitAsync(WaitBound)
            );

            // Assert
            TimeoutException timeout = Assert.IsType<TimeoutException>(error);
            Assert.Equal(
                "No log entry matched [entry => entry.Message == \"never\"] within 00:00:00.",
                timeout.Message
            );
        }

        [Fact]
        public async Task WaitForAsync_EntryAddedAfterExpiry_ShouldStillThrowTimeout()
        {
            // Arrange
            RecordingLogSink sink = new();
            Task<LogEntry> wait = sink.WaitForAsync(
                entry => entry.Message == "late",
                TimeSpan.Zero
            );

            // Act
            sink.Add(Entry("late"));
            Exception? error = await Record.ExceptionAsync(() => wait.WaitAsync(WaitBound));

            // Assert
            TimeoutException timeout = Assert.IsType<TimeoutException>(error);
            Assert.Equal(LateExpiryPrefix + "00:00:00.", timeout.Message);
        }

        [Fact]
        public async Task WaitForAsync_EntryAddedWhileExpiryPending_ShouldStillThrowTimeout()
        {
            // Arrange
            RecordingLogSink sink = new();
            QueuedSynchronizationContext context = new();
            // The 1 ms timeout is the expiry under test, not a wait. The test waits only for the
            // continuation the expiry posts to the context, or for the wait itself should the
            // expiry come before it suspends. The context holds that continuation, so the entry
            // arrives after the expiry but before the wait resumes.
            Task<LogEntry> wait = context.Start(
                () =>
                    sink.WaitForAsync(
                        entry => entry.Message == "late",
                        TimeSpan.FromMilliseconds(1)
                    )
            );
            await Task.WhenAny(context.Posted, wait).WaitAsync(WaitBound);

            // Act
            sink.Add(Entry("late"));
            context.RunPosted();
            Exception? error = await Record.ExceptionAsync(() => wait.WaitAsync(WaitBound));

            // Assert
            TimeoutException timeout = Assert.IsType<TimeoutException>(error);
            Assert.Equal(LateExpiryPrefix + "00:00:00.0010000.", timeout.Message);
        }

        [Theory]
        [InlineData(42949672950000L)] // 4294967295 ms, one past the longest timer wait
        [InlineData(42949672940001L)] // one tick past the longest timer wait
        [InlineData(long.MaxValue)] // TimeSpan.MaxValue
        [InlineData(-10000L)] // Timeout.InfiniteTimeSpan
        [InlineData(-1L)] // one tick below zero
        public async Task WaitForAsync_TimeoutOutOfRange_ShouldThrowArgumentOutOfRange(
            long timeoutTicks
        )
        {
            // Arrange
            RecordingLogSink sink = new();

            // Act
            Exception? error = await Record.ExceptionAsync(
                () =>
                    sink.WaitForAsync(_ => true, TimeSpan.FromTicks(timeoutTicks))
                        .WaitAsync(WaitBound)
            );

            // Assert
            Assert.IsType<ArgumentOutOfRangeException>(error);
        }

        [Theory]
        [InlineData(42949672950000L)] // 4294967295 ms, one past the longest timer wait
        [InlineData(42949672940001L)] // one tick past the longest timer wait
        [InlineData(long.MaxValue)] // TimeSpan.MaxValue
        [InlineData(-10000L)] // Timeout.InfiniteTimeSpan
        [InlineData(-1L)] // one tick below zero
        public async Task WaitForAsync_TimeoutOutOfRange_ShouldRegisterNoWaiter(long timeoutTicks)
        {
            // Arrange
            RecordingLogSink sink = new();
            int predicateCalls = 0;
            Task<LogEntry> rejected = sink.WaitForAsync(
                _ =>
                {
                    predicateCalls++;
                    return true;
                },
                TimeSpan.FromTicks(timeoutTicks)
            );

            // Act
            sink.Add(Entry("any"));
            _ = await Record.ExceptionAsync(() => rejected.WaitAsync(WaitBound));

            // Assert
            Assert.Equal(0, predicateCalls);
        }

        [Fact]
        public async Task WaitForAsync_LongestSupportedTimeout_ShouldCompleteOnMatch()
        {
            // Arrange
            RecordingLogSink sink = new();
            LogEntry expected = Entry("match");
            Task<LogEntry> wait = sink.WaitForAsync(
                entry => entry.Message == "match",
                TimeSpan.FromMilliseconds(4294967294)
            );

            // Act
            sink.Add(expected);
            LogEntry matched = await wait.WaitAsync(WaitBound);

            // Assert
            Assert.Same(expected, matched);
        }

        [Fact]
        public async Task WaitForAsync_Expired_ShouldUnregisterWaiter()
        {
            // Arrange
            RecordingLogSink sink = new();
            int predicateCalls = 0;
            Task<LogEntry> expired = sink.WaitForAsync(
                _ =>
                {
                    predicateCalls++;
                    return true;
                },
                TimeSpan.Zero
            );
            _ = await Record.ExceptionAsync(() => expired.WaitAsync(WaitBound));

            // Act
            sink.Add(Entry("any"));

            // Assert
            Assert.Equal(0, predicateCalls);
        }

        [Theory]
        [InlineData(StateWrite.IndexerSet)]
        [InlineData(StateWrite.Insert)]
        [InlineData(StateWrite.RemoveAt)]
        [InlineData(StateWrite.Add)]
        [InlineData(StateWrite.Remove)]
        [InlineData(StateWrite.Clear)]
        [InlineData(StateWrite.NonGenericIndexerSet)]
        public void Log_StateCastToWritableCollection_ShouldThrowNotSupported(StateWrite write)
        {
            // Arrange
            RecordingLogger<RecordingLoggerTests> logger = new();
            logger.LogInformation("Value [{x}]", 1);
            IReadOnlyList<KeyValuePair<string, object?>> state = logger.Sink.Entries[0].State;
            KeyValuePair<string, object?> replacement = new("x", 2);
            Action attempt = write switch
            {
                StateWrite.IndexerSet => () =>
                    ((IList<KeyValuePair<string, object?>>)state)[0] = replacement,
                StateWrite.Insert => () =>
                    ((IList<KeyValuePair<string, object?>>)state).Insert(0, replacement),
                StateWrite.RemoveAt => () =>
                    ((IList<KeyValuePair<string, object?>>)state).RemoveAt(0),
                StateWrite.Add => () =>
                    ((ICollection<KeyValuePair<string, object?>>)state).Add(replacement),
                StateWrite.Remove => () =>
                    ((ICollection<KeyValuePair<string, object?>>)state).Remove(state[0]),
                StateWrite.Clear => () =>
                    ((ICollection<KeyValuePair<string, object?>>)state).Clear(),
                StateWrite.NonGenericIndexerSet => () => ((IList)state)[0] = replacement,
                _ => throw new ArgumentOutOfRangeException(nameof(write)),
            };

            // Act
            Exception? error = Record.Exception(attempt);

            // Assert
            Assert.IsType<NotSupportedException>(error);
        }

        [Fact]
        public void Log_StateSyncRootWriteAttempt_ShouldKeepLaterSnapshot()
        {
            // Arrange
            RecordingLogger<RecordingLoggerTests> logger = new();
            logger.LogInformation("Value [{x}]", 1);
            object syncRoot = ((ICollection)logger.Sink.Entries[0].State).SyncRoot;

            // Act
            // Storage behind SyncRoot, such as a wrapped array, would accept this write.
            _ = Record.Exception(
                () => ((IList)syncRoot)[0] = new KeyValuePair<string, object?>("x", 2)
            );

            // Assert
            Assert.Equal(1, logger.Sink.Entries[0].GetField("x"));
        }

        [Theory]
        [InlineData(false, true)]
        [InlineData(false, false)]
        [InlineData(true, true)]
        [InlineData(true, false)]
        public void Add_SourceArrayMutated_ShouldKeepRecordedState(
            bool builtByWith,
            bool mutatedBeforeAdd
        )
        {
            // Arrange
            RecordingLogSink sink = new();
            KeyValuePair<string, object?>[] source = [new("x", 1)];
            LogEntry entry = builtByWith
                ? Entry("built") with
                {
                    State = source,
                }
                : Entry("built", source);

            // Act
            if (mutatedBeforeAdd)
            {
                source[0] = new("x", 2);
                sink.Add(entry);
            }
            else
            {
                sink.Add(entry);
                source[0] = new("x", 2);
            }

            // Assert
            Assert.Equal(1, sink.Entries[0].GetField("x"));
        }

        [Theory]
        [InlineData(false)]
        [InlineData(true)]
        public void LogEntry_NullState_ShouldThrowArgumentNull(bool builtByWith)
        {
            // Arrange
            LogEntry original = Entry("original");

            // Act
            Exception? error = Record.Exception(
                () => builtByWith ? original with { State = null! } : Entry("built", null!)
            );

            // Assert
            Assert.IsType<ArgumentNullException>(error);
        }

        private static LogEntry Entry(string message)
        {
            return Entry(message, []);
        }

        private static LogEntry Entry(
            string message,
            IReadOnlyList<KeyValuePair<string, object?>> state
        )
        {
            return new LogEntry(
                nameof(RecordingLoggerTests),
                LogLevel.Information,
                default,
                message,
                state,
                null
            );
        }

        /// <summary>
        /// Keeps every continuation posted to it until <see cref="RunPosted"/>, so a test decides
        /// when an awaiting method captured under it resumes.
        /// </summary>
        private sealed class QueuedSynchronizationContext : SynchronizationContext
        {
            private readonly ConcurrentQueue<(SendOrPostCallback Callback, object? State)> _posted =
                new();
            private readonly TaskCompletionSource _firstPost = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            /// <summary>Completes when the first continuation is posted.</summary>
            public Task Posted => _firstPost.Task;

            /// <summary>Calls <paramref name="start"/> with this context current.</summary>
            public Task<LogEntry> Start(Func<Task<LogEntry>> start)
            {
                SynchronizationContext? previous = Current;
                SetSynchronizationContext(this);
                try
                {
                    return start();
                }
                finally
                {
                    SetSynchronizationContext(previous);
                }
            }

            public override void Post(SendOrPostCallback d, object? state)
            {
                _posted.Enqueue((d, state));
                _firstPost.TrySetResult();
            }

            /// <summary>Runs the posted continuations on this thread, in post order.</summary>
            public void RunPosted()
            {
                while (_posted.TryDequeue(out (SendOrPostCallback Callback, object? State) post))
                {
                    post.Callback(post.State);
                }
            }
        }
    }
}
