using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>The <see cref="IAlertRepository"/> members a test can count or steer.</summary>
    public enum FakeAlertRepositoryMethod
    {
        Create,
        List,
        Get,
        UpdateEnabled,
        Delete,
        Acknowledge,
        Trigger,
    }

    /// <summary>Arguments of one <see cref="FakeAlertRepository.ListAsync"/> call.</summary>
    public sealed record AlertListCall(
        Guid? AccountId,
        bool ArmedOnly,
        bool TriggeredOnly,
        bool UnacknowledgedOnly
    );

    /// <summary>One <see cref="FakeAlertRepository.TriggerAsync"/> call and its outcome.</summary>
    /// <param name="Id">Alert id passed by the caller.</param>
    /// <param name="ArmingRevision">Arming revision passed by the caller.</param>
    /// <param name="TriggerValue">Trigger value passed by the caller.</param>
    /// <param name="Result">
    /// The store's decision, recorded before <see cref="FakeAlertRepository.AfterTrigger"/> runs,
    /// so a throwing hook, including one whose cancellation surfaces as a
    /// <see cref="DbException"/>, leaves it intact. <c>null</c> when the call failed before
    /// deciding: an injected exception or an already-cancelled token.
    /// </param>
    public sealed record AlertTriggerCall(
        Guid Id,
        int ArmingRevision,
        decimal TriggerValue,
        bool? Result
    );

    /// <summary>
    /// In-memory alert store with db-adapter's <c>Alerts</c> semantics. <see cref="TriggerAsync"/>
    /// is the single conditional write, applied atomically under the lock, so each arming
    /// (id, revision) triggers at most once however many evaluators race. Every row change is
    /// atomic and every result is an immutable snapshot. Hooks run outside the lock, so a test
    /// can hold callers at a barrier without blocking the store. Safe for concurrent callers.
    /// </summary>
    /// <param name="clock">
    /// Stamps <see cref="Alert.CreatedAt"/> and <see cref="Alert.TriggeredAt"/>. The default
    /// returns a strictly increasing time after <see cref="BaseTime"/>, so newest-first order is
    /// deterministic.
    /// </param>
    public sealed class FakeAlertRepository(Func<DateTimeOffset>? clock = null) : IAlertRepository
    {
        /// <summary>Origin of the default clock; earlier times sort as older rows.</summary>
        public static readonly DateTimeOffset BaseTime = new(2025, 1, 1, 0, 0, 0, TimeSpan.Zero);

        // Process-wide and never rewound, so default timestamps never repeat in a test run.
        private static long _defaultClockTicks;

        private static readonly FakeAlertRepositoryMethod[] MissableMethods =
        [
            FakeAlertRepositoryMethod.Get,
            FakeAlertRepositoryMethod.UpdateEnabled,
            FakeAlertRepositoryMethod.Delete,
            FakeAlertRepositoryMethod.Acknowledge,
        ];

        private readonly Func<DateTimeOffset> _clock = clock ?? NextDefaultTime;
        private readonly Lock _lock = new();
        private readonly Dictionary<Guid, Alert> _alerts = [];
        private readonly Dictionary<FakeAlertRepositoryMethod, int> _callCounts = [];
        private readonly List<AlertListCall> _listCalls = [];
        private readonly List<AlertTriggerCall> _triggerCalls = [];
        private readonly Dictionary<FakeAlertRepositoryMethod, Exception> _throwOnNext = [];
        private readonly Dictionary<FakeAlertRepositoryMethod, Exception> _throwAlways = [];
        private readonly HashSet<FakeAlertRepositoryMethod> _missNext = [];
        private int _listOrdinal;
        private Func<int, CancellationToken, Task>? _beforeListReturns;
        private Func<Guid, bool, CancellationToken, Task>? _afterTrigger;

        /// <summary>
        /// Awaited by every successful <see cref="ListAsync"/> after its snapshot is taken and
        /// before it returns, with the call's 1-based ordinal (its index in
        /// <see cref="ListCalls"/> plus one) and the caller's token. A hook that completes
        /// normally lets the call return its snapshot, even when it cancelled the caller's
        /// token. An <see cref="OperationCanceledException"/> it throws while the caller's token
        /// is cancelled surfaces as a <see cref="DbException"/> wrapping it, as the real
        /// repository reports a cancelled call; any other hook exception propagates unchanged.
        /// </summary>
        public Func<int, CancellationToken, Task>? BeforeListReturns
        {
            get
            {
                lock (_lock)
                {
                    return _beforeListReturns;
                }
            }
            set
            {
                lock (_lock)
                {
                    _beforeListReturns = value;
                }
            }
        }

        /// <summary>
        /// Awaited by every <see cref="TriggerAsync"/> that reaches the store's decision, outside
        /// the lock and before it returns, with the alert id, the result and the caller's token.
        /// It runs after the committed write for <c>true</c> and after a miss that wrote nothing
        /// for <c>false</c>, but not when the call failed before deciding. The decision stays
        /// committed and recorded whatever the hook does. A hook that completes normally lets the
        /// call return the decision, even when it cancelled the caller's token. An
        /// <see cref="OperationCanceledException"/> it throws while the caller's token is
        /// cancelled surfaces as a <see cref="DbException"/> wrapping it, as the real repository
        /// reports a cancelled call; any other hook exception propagates unchanged.
        /// </summary>
        public Func<Guid, bool, CancellationToken, Task>? AfterTrigger
        {
            get
            {
                lock (_lock)
                {
                    return _afterTrigger;
                }
            }
            set
            {
                lock (_lock)
                {
                    _afterTrigger = value;
                }
            }
        }

        /// <summary>Calls to <see cref="ListAsync"/> since the last reset.</summary>
        public int ListCallCount => CallCount(FakeAlertRepositoryMethod.List);

        /// <summary>
        /// Every <see cref="ListAsync"/> call since the last reset, in call order.
        /// </summary>
        public IReadOnlyList<AlertListCall> ListCalls
        {
            get
            {
                lock (_lock)
                {
                    return _listCalls.ToArray();
                }
            }
        }

        /// <summary>
        /// Every <see cref="TriggerAsync"/> call since the last reset, in the order the store
        /// recorded them under its lock, including calls that failed before deciding.
        /// </summary>
        public IReadOnlyList<AlertTriggerCall> TriggerCalls
        {
            get
            {
                lock (_lock)
                {
                    return _triggerCalls.ToArray();
                }
            }
        }

        /// <summary>Calls to <paramref name="method"/> since the last reset.</summary>
        public int CallCount(FakeAlertRepositoryMethod method)
        {
            RequireDefined(method);
            lock (_lock)
            {
                return _callCounts.GetValueOrDefault(method);
            }
        }

        /// <summary>Inserts or replaces a row by <see cref="Alert.Id"/>, as it stands.</summary>
        public FakeAlertRepository Seed(Alert alert)
        {
            ArgumentNullException.ThrowIfNull(alert);
            lock (_lock)
            {
                _alerts[alert.Id] = alert;
            }
            return this;
        }

        /// <summary>The stored row, read without counting a call or running any hook.</summary>
        public Alert? Get(Guid id)
        {
            lock (_lock)
            {
                return _alerts.GetValueOrDefault(id);
            }
        }

        /// <summary>Every stored row, newest first, read without counting a call.</summary>
        public IReadOnlyList<Alert> All()
        {
            lock (_lock)
            {
                return Ordered(_alerts.Values, false);
            }
        }

        /// <summary>Clears call counts, call records and the list ordinal.</summary>
        public void ResetCalls()
        {
            lock (_lock)
            {
                ResetCallsLocked();
            }
        }

        /// <summary>
        /// Clears rows, call records, hooks, injected exceptions and miss switches. The default
        /// clock keeps counting, so later timestamps stay newer than earlier ones.
        /// </summary>
        public void Reset()
        {
            lock (_lock)
            {
                ResetCallsLocked();
                _alerts.Clear();
                _throwOnNext.Clear();
                _throwAlways.Clear();
                _missNext.Clear();
                _beforeListReturns = null;
                _afterTrigger = null;
            }
        }

        /// <summary>
        /// The next call to <paramref name="method"/> fails with <paramref name="exception"/>
        /// before it touches any row. Takes precedence over <see cref="ThrowAlways"/> once.
        /// </summary>
        public void ThrowOnNext(FakeAlertRepositoryMethod method, Exception exception)
        {
            RequireDefined(method);
            ArgumentNullException.ThrowIfNull(exception);
            lock (_lock)
            {
                _throwOnNext[method] = exception;
            }
        }

        /// <summary>
        /// Every call to <paramref name="method"/> fails with <paramref name="exception"/> before
        /// it touches any row, until <see cref="ClearThrow"/> or <see cref="Reset"/>.
        /// </summary>
        public void ThrowAlways(FakeAlertRepositoryMethod method, Exception exception)
        {
            RequireDefined(method);
            ArgumentNullException.ThrowIfNull(exception);
            lock (_lock)
            {
                _throwAlways[method] = exception;
            }
        }

        /// <summary>Removes both injected exceptions of <paramref name="method"/>.</summary>
        public void ClearThrow(FakeAlertRepositoryMethod method)
        {
            RequireDefined(method);
            lock (_lock)
            {
                _throwOnNext.Remove(method);
                _throwAlways.Remove(method);
            }
        }

        /// <summary>
        /// The next call to <paramref name="method"/> reports a missing alert (<c>null</c> or
        /// <c>false</c>) whatever the rows hold, as after a concurrent delete. Only
        /// <see cref="FakeAlertRepositoryMethod.Get"/>,
        /// <see cref="FakeAlertRepositoryMethod.UpdateEnabled"/>,
        /// <see cref="FakeAlertRepositoryMethod.Delete"/> and
        /// <see cref="FakeAlertRepositoryMethod.Acknowledge"/> can miss.
        /// </summary>
        public void MissNext(FakeAlertRepositoryMethod method)
        {
            if (!MissableMethods.Contains(method))
            {
                throw new ArgumentOutOfRangeException(
                    nameof(method),
                    method,
                    "Only Get, UpdateEnabled, Delete and Acknowledge can report a missing alert."
                );
            }
            lock (_lock)
            {
                _missNext.Add(method);
            }
        }

        public Task<Alert> CreateAsync(
            Guid accountId,
            AlertType type,
            Guid instrumentId,
            AlertDirection direction,
            decimal threshold
        )
        {
            return RunLocked(
                FakeAlertRepositoryMethod.Create,
                () =>
                {
                    Alert alert = new(
                        Guid.NewGuid(),
                        accountId,
                        instrumentId,
                        type,
                        direction,
                        threshold,
                        Enabled: true,
                        ArmingRevision: 1,
                        TriggeredAt: null,
                        TriggerValue: null,
                        Acknowledged: false,
                        CreatedAt: _clock()
                    );
                    _alerts[alert.Id] = alert;
                    return alert;
                }
            );
        }

        public async Task<IReadOnlyList<Alert>> ListAsync(
            Guid? accountId,
            bool armedOnly,
            bool triggeredOnly,
            bool unacknowledgedOnly,
            CancellationToken cancellationToken = default
        )
        {
            Alert[] snapshot;
            int ordinal;
            Func<int, CancellationToken, Task>? beforeListReturns;
            lock (_lock)
            {
                Exception? failure = BeginCallLocked(FakeAlertRepositoryMethod.List);
                _listCalls.Add(
                    new AlertListCall(accountId, armedOnly, triggeredOnly, unacknowledgedOnly)
                );
                ordinal = ++_listOrdinal;
                failure ??= CancellationFailure(cancellationToken);
                if (failure is not null)
                {
                    throw failure;
                }

                IEnumerable<Alert> rows = _alerts.Values;
                if (accountId is Guid account)
                {
                    rows = rows.Where(alert => alert.AccountId == account);
                }
                if (armedOnly)
                {
                    rows = rows.Where(alert => alert is { Enabled: true, TriggeredAt: null });
                }
                if (triggeredOnly)
                {
                    rows = rows.Where(alert => alert.TriggeredAt is not null);
                }
                if (unacknowledgedOnly)
                {
                    rows = rows.Where(alert => !alert.Acknowledged);
                }
                snapshot = Ordered(rows, triggeredOnly);
                beforeListReturns = _beforeListReturns;
            }

            if (beforeListReturns is not null)
            {
                try
                {
                    await beforeListReturns(ordinal, cancellationToken);
                }
                catch (OperationCanceledException cancellation)
                    when (cancellationToken.IsCancellationRequested)
                {
                    throw CancelledCallFailure(cancellation);
                }
            }
            return snapshot;
        }

        public Task<Alert?> GetAlertAsync(Guid id)
        {
            return RunLocked<Alert?>(
                FakeAlertRepositoryMethod.Get,
                () =>
                    _missNext.Remove(FakeAlertRepositoryMethod.Get)
                        ? null
                        : _alerts.GetValueOrDefault(id)
            );
        }

        public Task<Alert?> UpdateEnabledAsync(Guid id, bool enabled)
        {
            return RunLocked<Alert?>(
                FakeAlertRepositoryMethod.UpdateEnabled,
                () =>
                {
                    if (
                        _missNext.Remove(FakeAlertRepositoryMethod.UpdateEnabled)
                        || !_alerts.TryGetValue(id, out Alert? row)
                    )
                    {
                        return null;
                    }

                    // Enabling re-arms whatever the previous state; disabling keeps trigger data.
                    Alert written = enabled
                        ? row with
                        {
                            Enabled = true,
                            ArmingRevision = row.ArmingRevision + 1,
                            TriggeredAt = null,
                            TriggerValue = null,
                            Acknowledged = false,
                        }
                        : row with
                        {
                            Enabled = false,
                        };
                    _alerts[id] = written;
                    return written;
                }
            );
        }

        public Task<bool> DeleteAsync(Guid id)
        {
            return RunLocked(
                FakeAlertRepositoryMethod.Delete,
                () => !_missNext.Remove(FakeAlertRepositoryMethod.Delete) && _alerts.Remove(id)
            );
        }

        public Task<bool> AcknowledgeAsync(Guid id)
        {
            return RunLocked(
                FakeAlertRepositoryMethod.Acknowledge,
                () =>
                {
                    if (
                        _missNext.Remove(FakeAlertRepositoryMethod.Acknowledge)
                        || !_alerts.TryGetValue(id, out Alert? row)
                    )
                    {
                        return false;
                    }

                    // Only a triggered arming has a notification to acknowledge; otherwise the
                    // call is a successful no-op, so it never pre-acknowledges a future trigger.
                    if (row.TriggeredAt is not null)
                    {
                        _alerts[id] = row with { Acknowledged = true };
                    }
                    return true;
                }
            );
        }

        public async Task<bool> TriggerAsync(
            Guid id,
            int armingRevision,
            decimal triggerValue,
            CancellationToken cancellationToken = default
        )
        {
            bool triggered;
            Func<Guid, bool, CancellationToken, Task>? afterTrigger;
            lock (_lock)
            {
                Exception? failure =
                    BeginCallLocked(FakeAlertRepositoryMethod.Trigger)
                    ?? CancellationFailure(cancellationToken);
                if (failure is not null)
                {
                    _triggerCalls.Add(new AlertTriggerCall(id, armingRevision, triggerValue, null));
                    throw failure;
                }

                // db-adapter's predicate: Id, ArmingRevision, Enabled and TriggeredAt IS NULL.
                // A miss affects zero rows and is a normal false, never an error.
                triggered =
                    _alerts.TryGetValue(id, out Alert? row)
                    && row.ArmingRevision == armingRevision
                    && row is { Enabled: true, TriggeredAt: null };
                if (triggered)
                {
                    _alerts[id] = row! with
                    {
                        TriggeredAt = _clock(),
                        TriggerValue = triggerValue,
                        Acknowledged = false,
                    };
                }
                _triggerCalls.Add(
                    new AlertTriggerCall(id, armingRevision, triggerValue, triggered)
                );
                afterTrigger = _afterTrigger;
            }

            if (afterTrigger is not null)
            {
                // The decision above stays committed and recorded whatever the hook does.
                try
                {
                    await afterTrigger(id, triggered, cancellationToken);
                }
                catch (OperationCanceledException cancellation)
                    when (cancellationToken.IsCancellationRequested)
                {
                    throw CancelledCallFailure(cancellation);
                }
            }
            return triggered;
        }

        private static DateTimeOffset NextDefaultTime()
        {
            return BaseTime.AddMilliseconds(Interlocked.Increment(ref _defaultClockTicks));
        }

        // Mirrors the real repository: its gRPC call options carry the token, and GrpcHelper
        // wraps the resulting cancellation in DbException.
        private static DbException? CancellationFailure(CancellationToken cancellationToken)
        {
            return cancellationToken.IsCancellationRequested
                ? CancelledCallFailure(new OperationCanceledException(cancellationToken))
                : null;
        }

        // The failure the real repository reports for a call its caller's token cancelled.
        private static DbException CancelledCallFailure(OperationCanceledException cancellation)
        {
            return new DbException("Db Adapter call error: cancelled", cancellation);
        }

        private static Alert[] Ordered(IEnumerable<Alert> rows, bool byTriggeredAt)
        {
            IOrderedEnumerable<Alert> ordered = byTriggeredAt
                ? rows.OrderByDescending(alert => alert.TriggeredAt)
                : rows.OrderByDescending(alert => alert.CreatedAt);
            // Canonical lowercase text order, as PostgreSQL compares uuid values.
            return ordered
                .ThenByDescending(alert => alert.Id.ToString("D"), StringComparer.Ordinal)
                .ToArray();
        }

        private static void RequireDefined(FakeAlertRepositoryMethod method)
        {
            if (!Enum.IsDefined(method))
            {
                throw new ArgumentOutOfRangeException(nameof(method), method, "Unknown method.");
            }
        }

        // Counts the call and returns the exception it must fail with, if one is injected.
        private Exception? BeginCallLocked(FakeAlertRepositoryMethod method)
        {
            _callCounts[method] = _callCounts.GetValueOrDefault(method) + 1;
            if (_throwOnNext.Remove(method, out Exception? once))
            {
                return once;
            }
            return _throwAlways.GetValueOrDefault(method);
        }

        // Runs a hook-free call atomically and reports any failure through the returned task,
        // as the real asynchronous repository does.
        private Task<T> RunLocked<T>(FakeAlertRepositoryMethod method, Func<T> operation)
        {
            lock (_lock)
            {
                Exception? failure = BeginCallLocked(method);
                if (failure is not null)
                {
                    return Task.FromException<T>(failure);
                }
                try
                {
                    return Task.FromResult(operation());
                }
                catch (Exception exception)
                {
                    return Task.FromException<T>(exception);
                }
            }
        }

        private void ResetCallsLocked()
        {
            _callCounts.Clear();
            _listCalls.Clear();
            _triggerCalls.Clear();
            _listOrdinal = 0;
        }
    }
}
