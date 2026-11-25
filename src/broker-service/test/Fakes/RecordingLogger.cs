using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// One recorded log call. <see cref="State"/> holds the structured pairs of the call, including
    /// <c>{OriginalFormat}</c> and every named placeholder of the message template, as an immutable
    /// copy taken when the entry is constructed.
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
        private readonly ImmutableList<KeyValuePair<string, object?>> _state = CopyState(State);

        /// <summary>
        /// Immutable copy of the pairs given at construction or by a <c>with</c> expression, so
        /// neither the caller's collection nor a reader of a snapshot can change a recorded entry.
        /// </summary>
        public IReadOnlyList<KeyValuePair<string, object?>> State
        {
            get => _state;
            init => _state = CopyState(value);
        }

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

        // An immutable copy, so no public route reaches writable storage: every write through a
        // cast to IList<T>, ICollection<T> or IList throws NotSupportedException, and
        // ICollection.SyncRoot is the list itself. An immutable list given is kept as it is.
        private static ImmutableList<KeyValuePair<string, object?>> CopyState(
            IReadOnlyList<KeyValuePair<string, object?>> state
        )
        {
            ArgumentNullException.ThrowIfNull(state);
            return state.ToImmutableList();
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

        // The longest wait a CancellationTokenSource timer can time: uint.MaxValue - 1 ms.
        private static readonly TimeSpan MaxWaitTimeout = TimeSpan.FromMilliseconds(
            uint.MaxValue - 1
        );

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

        /// <summary>
        /// Records <paramref name="entry"/> and completes the waits it matches. Every
        /// <see cref="LogEntry"/> holds its own immutable copy of its state, so a change the caller
        /// makes afterwards to the pairs it built the entry from never reaches the recorded entry.
        /// </summary>
        public void Add(LogEntry entry)
        {
            ArgumentNullException.ThrowIfNull(entry);
            List<Waiter> matched = [];
            lock (_gate)
            {
                _entries.Add(entry);
                // Removal under the lock claims a waiter, as the expiry's does, so a wait the
                // expiry already claimed is not listed and its predicate never sees this entry.
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
        /// the next one added. <paramref name="timeout"/> only bounds the wait and must lie from
        /// zero to 4294967294 ms, the longest wait the timer supports, or an
        /// <see cref="ArgumentOutOfRangeException"/> is thrown before any wait is registered.
        /// A pending wait ends exactly once, by whichever claims it first under the sink's lock:
        /// an added entry, which returns that entry or the exception the predicate threw for it,
        /// a <see cref="TimeoutException"/> included, unchanged; or the expiry, which throws a
        /// <see cref="TimeoutException"/> naming the predicate. No entry added after the expiry
        /// reaches the predicate.
        /// </summary>
        public async Task<LogEntry> WaitForAsync(
            Func<LogEntry, bool> predicate,
            TimeSpan timeout,
            [CallerArgumentExpression(nameof(predicate))] string? predicateText = null
        )
        {
            ArgumentNullException.ThrowIfNull(predicate);
            // Waits are always bounded, so an infinite or negative timeout is a test bug. Both
            // bounds are checked before a waiter is registered, so a rejected wait leaves none.
            ArgumentOutOfRangeException.ThrowIfLessThan(timeout, TimeSpan.Zero);
            ArgumentOutOfRangeException.ThrowIfGreaterThan(timeout, MaxWaitTimeout);
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
                // A zero timeout starts the source cancelled, so Register runs the expiry at once.
                using CancellationTokenSource expiry = new(timeout);
                using CancellationTokenRegistration registration = expiry.Token.Register(
                    () => Expire(waiter, predicateText, timeout)
                );
                // Exactly one claim completes the waiter: the expiry's, or that of the Add whose
                // entry matched or made the predicate throw.
                return await waiter.Completion.Task;
            }
            finally
            {
                // Every exit leaves the waiter unregistered; removing it again is harmless.
                lock (_gate)
                {
                    _waiters.Remove(waiter);
                }
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

        // Runs when the timeout elapses. Removing the waiter under the lock is the same claim Add
        // makes, so the expiry fails the wait only while no added entry has claimed it, and no
        // entry added after the expiry reaches the predicate.
        private void Expire(Waiter waiter, string? predicateText, TimeSpan timeout)
        {
            bool claimed;
            lock (_gate)
            {
                claimed = _waiters.Remove(waiter);
            }
            if (claimed)
            {
                // Completed outside the lock, as Add completes the waits it claims.
                waiter.Completion.TrySetException(
                    new TimeoutException(
                        $"No log entry matched [{predicateText}] within {timeout}."
                    )
                );
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

        // This logger declines no level except None. The LoggerFactory applies the host's filter
        // rules before it consults this method: LoggerFilterOptions, with its minimum level
        // (Information by default) and its category and provider rules from AddFilter or the
        // Logging configuration section. Those rules, not this method alone, decide whether a
        // category's line is recorded, a Debug line for example, and whether the
        // Microsoft.AspNetCore.Hosting.Diagnostics logger counts as enabled. ASP.NET Core hosting
        // checks that logger at Critical; while it is enabled, hosting starts the request
        // Activity, parented to any inbound traceparent, whatever any ActivitySource listener's
        // sampling decides. A DiagnosticListener subscriber enabled for the HttpRequestIn event
        // does the same; an ActivitySource listener alone only samples the Activity, so a
        // declined sample leaves none. A host that relies on this logger for the request Activity
        // must register this provider without filtering that category out.
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

            // Materialised from the caller's state object; the entry keeps its own immutable copy,
            // so neither that object nor a reader of a sink snapshot can change it afterwards.
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
