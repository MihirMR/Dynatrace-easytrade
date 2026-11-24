using System.Runtime.CompilerServices;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// One recorded log call. <see cref="State"/> holds the structured pairs of the call, including
    /// <c>{OriginalFormat}</c> and every named placeholder of the message template.
    /// </summary>
    public sealed record LogEntry(
        string Category,
        LogLevel Level,
        EventId EventId,
        string Message,
        IReadOnlyList<KeyValuePair<string, object?>> State,
        Exception? Exception
    )
    {
        /// <summary>Value of the first state pair named <paramref name="name"/>, or null.</summary>
        public object? GetField(string name)
        {
            foreach (KeyValuePair<string, object?> pair in State)
            {
                if (string.Equals(pair.Key, name, StringComparison.Ordinal))
                {
                    return pair.Value;
                }
            }
            return null;
        }

        /// <summary>
        /// Whether a state pair named <paramref name="name"/> exists, even with a null value.
        /// </summary>
        public bool HasField(string name)
        {
            return State.Any(pair => string.Equals(pair.Key, name, StringComparison.Ordinal));
        }
    }

    /// <summary>
    /// Thread-safe store of log entries shared by any number of recording loggers. Waits complete
    /// when a matching entry is added, so tests synchronise on log lines without sleeps or polling.
    /// </summary>
    public sealed class RecordingLogSink
    {
        private readonly Lock _gate = new();
        private readonly List<LogEntry> _entries = [];
        private readonly List<Waiter> _waiters = [];

        /// <summary>Snapshot of the entries recorded since creation or the last Clear.</summary>
        public IReadOnlyList<LogEntry> Entries
        {
            get
            {
                lock (_gate)
                {
                    return _entries.ToArray();
                }
            }
        }

        public void Add(LogEntry entry)
        {
            ArgumentNullException.ThrowIfNull(entry);
            List<Waiter> matched = [];
            lock (_gate)
            {
                _entries.Add(entry);
                _waiters.RemoveAll(waiter =>
                {
                    if (!waiter.Matches(entry))
                    {
                        return false;
                    }
                    matched.Add(waiter);
                    return true;
                });
            }
            // Completed outside the lock so a continuation never runs while the sink is held.
            foreach (Waiter waiter in matched)
            {
                waiter.Complete(entry);
            }
        }

        /// <summary>Removes the recorded entries; waits already pending stay registered.</summary>
        public void Clear()
        {
            lock (_gate)
            {
                _entries.Clear();
            }
        }

        public IReadOnlyList<LogEntry> ByLevel(LogLevel level)
        {
            return Snapshot(entry => entry.Level == level);
        }

        public IReadOnlyList<LogEntry> ByCategory(string category)
        {
            return Snapshot(entry =>
                string.Equals(entry.Category, category, StringComparison.Ordinal)
            );
        }

        public IReadOnlyList<LogEntry> ByCategory<T>()
        {
            return ByCategory(CategoryOf<T>());
        }

        public IReadOnlyList<LogEntry> WithMessageStartingWith(string prefix)
        {
            return Snapshot(entry => entry.Message.StartsWith(prefix, StringComparison.Ordinal));
        }

        public IReadOnlyList<LogEntry> WithMessageContaining(string text)
        {
            return Snapshot(entry => entry.Message.Contains(text, StringComparison.Ordinal));
        }

        /// <summary>
        /// Returns the first recorded entry matching <paramref name="predicate"/>, or waits for
        /// the next one added. <paramref name="timeout"/> only bounds the wait; on expiry a
        /// <see cref="TimeoutException"/> names the predicate.
        /// </summary>
        public async Task<LogEntry> WaitForAsync(
            Func<LogEntry, bool> predicate,
            TimeSpan timeout,
            [CallerArgumentExpression(nameof(predicate))] string? predicateText = null
        )
        {
            ArgumentNullException.ThrowIfNull(predicate);
            // Waits are always bounded, so an infinite or negative timeout is a test bug.
            ArgumentOutOfRangeException.ThrowIfLessThan(timeout, TimeSpan.Zero);
            Waiter waiter;
            lock (_gate)
            {
                foreach (LogEntry entry in _entries)
                {
                    if (predicate(entry))
                    {
                        return entry;
                    }
                }
                waiter = new Waiter(predicate);
                _waiters.Add(waiter);
            }

            try
            {
                return await waiter.Completion.Task.WaitAsync(timeout);
            }
            catch (TimeoutException exception)
            {
                lock (_gate)
                {
                    _waiters.Remove(waiter);
                }
                throw new TimeoutException(
                    $"No log entry matched [{predicateText}] within {timeout}.",
                    exception
                );
            }
        }

        public Task<LogEntry> WaitForMessageStartingWithAsync(string prefix, TimeSpan timeout)
        {
            ArgumentNullException.ThrowIfNull(prefix);
            return WaitForAsync(
                entry => entry.Message.StartsWith(prefix, StringComparison.Ordinal),
                timeout,
                $"message starting with \"{prefix}\""
            );
        }

        public Task<LogEntry> WaitForMessageContainingAsync(string text, TimeSpan timeout)
        {
            ArgumentNullException.ThrowIfNull(text);
            return WaitForAsync(
                entry => entry.Message.Contains(text, StringComparison.Ordinal),
                timeout,
                $"message containing \"{text}\""
            );
        }

        /// <summary>The category <see cref="RecordingLogger{T}"/> records under.</summary>
        internal static string CategoryOf<T>()
        {
            return typeof(T).FullName ?? typeof(T).Name;
        }

        private LogEntry[] Snapshot(Func<LogEntry, bool> predicate)
        {
            lock (_gate)
            {
                return _entries.Where(predicate).ToArray();
            }
        }

        private sealed class Waiter(Func<LogEntry, bool> predicate)
        {
            private Exception? _predicateError;

            public TaskCompletionSource<LogEntry> Completion { get; } =
                new(TaskCreationOptions.RunContinuationsAsynchronously);

            // A throwing predicate faults its own wait rather than the logging call being recorded.
            public bool Matches(LogEntry entry)
            {
                try
                {
                    return predicate(entry);
                }
                catch (Exception exception)
                {
                    _predicateError = exception;
                    return true;
                }
            }

            public void Complete(LogEntry entry)
            {
                if (_predicateError is null)
                {
                    Completion.TrySetResult(entry);
                }
                else
                {
                    Completion.TrySetException(_predicateError);
                }
            }
        }
    }

    /// <summary>
    /// Logger that records every call, at every level except <see cref="LogLevel.None"/>, into a
    /// <see cref="RecordingLogSink"/> together with its structured state.
    /// </summary>
    public class RecordingLogger(string category, RecordingLogSink sink) : ILogger
    {
        public string Category { get; } =
            category ?? throw new ArgumentNullException(nameof(category));

        public RecordingLogSink Sink { get; } =
            sink ?? throw new ArgumentNullException(nameof(sink));

        /// <summary>All entries of <see cref="Sink"/>, from every category sharing it.</summary>
        public IReadOnlyList<LogEntry> Entries => Sink.Entries;

        public IDisposable BeginScope<TState>(TState state)
            where TState : notnull
        {
            return NoopScope.Instance;
        }

        // Always enabled: ASP.NET Core hosting creates the request Activity only while a logger is
        // enabled, and the trace-context tests depend on that Activity.
        public bool IsEnabled(LogLevel logLevel)
        {
            return logLevel != LogLevel.None;
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
            if (!IsEnabled(logLevel))
            {
                return;
            }

            // Copied, so a recorded entry never depends on the caller's state object afterwards.
            KeyValuePair<string, object?>[] fields = state
                is IEnumerable<KeyValuePair<string, object?>> pairs
                ? [.. pairs]
                : [];
            Sink.Add(
                new LogEntry(
                    Category,
                    logLevel,
                    eventId,
                    formatter(state, exception),
                    fields,
                    exception
                )
            );
        }

        // Scopes are not part of what the tests assert, so they are accepted and not recorded.
        private sealed class NoopScope : IDisposable
        {
            public static readonly NoopScope Instance = new();

            private NoopScope() { }

            public void Dispose() { }
        }
    }

    /// <summary>
    /// Typed recording logger for constructor injection; records under the full name of
    /// <typeparamref name="T"/>.
    /// </summary>
    public sealed class RecordingLogger<T>(RecordingLogSink sink)
        : RecordingLogger(RecordingLogSink.CategoryOf<T>(), sink),
            ILogger<T>
    {
        public RecordingLogger()
            : this(new RecordingLogSink()) { }
    }

    /// <summary>Logger provider whose loggers all record into one shared sink.</summary>
    public sealed class RecordingLoggerProvider(RecordingLogSink sink) : ILoggerProvider
    {
        public RecordingLoggerProvider()
            : this(new RecordingLogSink()) { }

        public RecordingLogSink Sink { get; } =
            sink ?? throw new ArgumentNullException(nameof(sink));

        public ILogger CreateLogger(string categoryName)
        {
            return new RecordingLogger(categoryName, Sink);
        }

        // The sink is kept on purpose: tests read its entries after their host is disposed.
        public void Dispose() { }
    }
}
