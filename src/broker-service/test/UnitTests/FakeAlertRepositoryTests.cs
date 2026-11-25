using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Test.Fakes;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Pins the cancellation contract of <see cref="FakeAlertRepository"/> to the real
    /// repository's, where <see cref="EasyTrade.BrokerService.Helpers.GrpcHelper"/> wraps a call
    /// its caller's token cancelled in a <see cref="DbException"/>. A hook that honours the
    /// cancelled caller token therefore fails the call the same way, so the evaluator's
    /// cancellation tests exercise the production error path. A hook that completes normally
    /// still lets the call return, and a cancellation the caller did not request is not wrapped.
    /// </summary>
    public class FakeAlertRepositoryTests
    {
        private const decimal ObservedValue = 1.5m;

        private static readonly Guid FixedAccountId = new("a0000000-0000-4000-8000-000000000000");
        private static readonly Guid FixedInstrumentId = new(
            "c0000000-0000-4000-8000-000000000001"
        );

        // The store's clock in every case, so a committed trigger has an exact timestamp.
        private static readonly DateTimeOffset TriggeredTime =
            FakeAlertRepository.BaseTime.AddMinutes(1);

        // Bounds every await, so a call that never ends fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(10);

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum HookedCall
        {
            // ListAsync, which awaits BeforeListReturns.
            List,

            // TriggerAsync, which awaits AfterTrigger.
            Trigger,
        }

        [Theory]
        [InlineData(HookedCall.List)]
        [InlineData(HookedCall.Trigger)]
        public async Task HookedCall_HookHonoursCancelledCaller_ShouldThrowDbExceptionWrappingIt(
            HookedCall call
        )
        {
            // Arrange
            using CancellationTokenSource caller = new();
            CancellingHook hook = new(caller);
            Alert seeded = ArmedAlert();
            FakeAlertRepository fake = new FakeAlertRepository(() => TriggeredTime).Seed(seeded);
            SetHook(fake, call, hook.CancelCallerThenHonourAsync);

            // Act
            Exception? error = await Record.ExceptionAsync(
                () => CallAsync(fake, call, seeded, caller.Token)
            );

            // Assert: the inner exception is the hook's own cancellation, carrying the caller's
            // token.
            Assert.Equal(
                new CallFailure(typeof(DbException), hook.Thrown, caller.Token),
                new CallFailure(
                    error?.GetType(),
                    error?.InnerException,
                    (error?.InnerException as OperationCanceledException)?.CancellationToken
                )
            );
        }

        [Fact]
        public async Task TriggerAsync_HookHonoursCancelledCaller_ShouldKeepCommittedTrigger()
        {
            // Arrange
            using CancellationTokenSource caller = new();
            CancellingHook hook = new(caller);
            Alert seeded = ArmedAlert();
            FakeAlertRepository fake = new FakeAlertRepository(() => TriggeredTime).Seed(seeded);
            SetHook(fake, HookedCall.Trigger, hook.CancelCallerThenHonourAsync);

            // Act
            Exception? error = await Record.ExceptionAsync(
                () => CallAsync(fake, HookedCall.Trigger, seeded, caller.Token)
            );

            // Assert: the call fails as a cancelled real call does, and the write and the call
            // record the store committed before the hook ran stay as they were.
            IReadOnlyList<AlertTriggerCall> calls = fake.TriggerCalls;
            Assert.Equal(
                new TriggerAftermath(
                    typeof(DbException),
                    seeded with
                    {
                        TriggeredAt = TriggeredTime,
                        TriggerValue = ObservedValue,
                    },
                    CallCount: 1,
                    new AlertTriggerCall(
                        seeded.Id,
                        seeded.ArmingRevision,
                        ObservedValue,
                        Result: true
                    )
                ),
                new TriggerAftermath(
                    error?.GetType(),
                    fake.Get(seeded.Id),
                    calls.Count,
                    calls.LastOrDefault()
                )
            );
        }

        [Fact]
        public async Task ListAsync_HookCancelsCallerThenCompletes_ShouldReturnSnapshot()
        {
            // Arrange
            using CancellationTokenSource caller = new();
            Alert seeded = ArmedAlert();
            FakeAlertRepository fake = new FakeAlertRepository(() => TriggeredTime).Seed(seeded);
            fake.BeforeListReturns = (_, _) =>
            {
                caller.Cancel();
                return Task.CompletedTask;
            };

            // Act
            IReadOnlyList<Alert> snapshot = await fake.ListAsync(
                    accountId: null,
                    armedOnly: true,
                    triggeredOnly: false,
                    unacknowledgedOnly: false,
                    caller.Token
                )
                .WaitAsync(WaitBound);

            // Assert: no check after the hook turns a completed call into a failure.
            Assert.Equal([seeded], snapshot);
        }

        [Fact]
        public async Task TriggerAsync_HookCancelsCallerThenCompletes_ShouldReturnTrue()
        {
            // Arrange
            using CancellationTokenSource caller = new();
            Alert seeded = ArmedAlert();
            FakeAlertRepository fake = new FakeAlertRepository(() => TriggeredTime).Seed(seeded);
            fake.AfterTrigger = (_, _, _) =>
            {
                caller.Cancel();
                return Task.CompletedTask;
            };

            // Act
            bool triggered = await fake.TriggerAsync(
                    seeded.Id,
                    seeded.ArmingRevision,
                    ObservedValue,
                    caller.Token
                )
                .WaitAsync(WaitBound);

            // Assert: no check after the hook turns a completed call into a failure.
            Assert.True(triggered);
        }

        [Theory]
        [InlineData(HookedCall.List)]
        [InlineData(HookedCall.Trigger)]
        public async Task HookedCall_HookCancelledByUnrelatedToken_ShouldPropagateUnwrapped(
            HookedCall call
        )
        {
            // Arrange: only the unrelated token is cancelled; the caller's stays live.
            using CancellationTokenSource caller = new();
            using CancellationTokenSource unrelated = new();
            unrelated.Cancel();
            OperationCanceledException unrelatedCancellation = new(unrelated.Token);
            Alert seeded = ArmedAlert();
            FakeAlertRepository fake = new FakeAlertRepository(() => TriggeredTime).Seed(seeded);
            SetHook(fake, call, _ => Task.FromException(unrelatedCancellation));

            // Act
            Exception? error = await Record.ExceptionAsync(
                () => CallAsync(fake, call, seeded, caller.Token)
            );

            // Assert
            Assert.Same(unrelatedCancellation, error);
        }

        private static Alert ArmedAlert()
        {
            return new Alert(
                Guid.NewGuid(),
                FixedAccountId,
                FixedInstrumentId,
                AlertType.TARGET_PRICE,
                AlertDirection.ABOVE,
                1m,
                Enabled: true,
                ArmingRevision: 1,
                TriggeredAt: null,
                TriggerValue: null,
                Acknowledged: false,
                CreatedAt: FakeAlertRepository.BaseTime
            );
        }

        // Installs one behaviour on the hook the call awaits, so a case covers both hooked calls.
        private static void SetHook(
            FakeAlertRepository fake,
            HookedCall call,
            Func<CancellationToken, Task> hook
        )
        {
            switch (call)
            {
                case HookedCall.List:
                    fake.BeforeListReturns = (_, token) => hook(token);
                    break;
                case HookedCall.Trigger:
                    fake.AfterTrigger = (_, _, token) => hook(token);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(call), call, null);
            }
        }

        // The evaluator's arguments: the armed listing across accounts, and the trigger of the
        // listed arming.
        private static async Task<object> CallAsync(
            FakeAlertRepository fake,
            HookedCall call,
            Alert alert,
            CancellationToken cancellationToken
        )
        {
            return call switch
            {
                HookedCall.List => await fake.ListAsync(
                        accountId: null,
                        armedOnly: true,
                        triggeredOnly: false,
                        unacknowledgedOnly: false,
                        cancellationToken
                    )
                    .WaitAsync(WaitBound),
                HookedCall.Trigger => await fake.TriggerAsync(
                        alert.Id,
                        alert.ArmingRevision,
                        ObservedValue,
                        cancellationToken
                    )
                    .WaitAsync(WaitBound),
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }

        // The failure a call reported, the exception it wraps and the token that one carries.
        private sealed record CallFailure(Type? Type, Exception? Inner, CancellationToken? Token);

        // The failure a trigger reported, the row it left and the trigger calls recorded.
        private sealed record TriggerAftermath(
            Type? Failure,
            Alert? Row,
            int CallCount,
            AlertTriggerCall? LastCall
        );

        // Cancels the caller's token, then awaits work only that token can end, as a gRPC call
        // honouring it does. Nothing waits: the token is cancelled before the await begins.
        private sealed class CancellingHook(CancellationTokenSource caller)
        {
            private readonly TaskCompletionSource _neverCompletes = new();

            // The cancellation the hook threw, once it has run.
            public OperationCanceledException? Thrown { get; private set; }

            public async Task CancelCallerThenHonourAsync(CancellationToken cancellationToken)
            {
                caller.Cancel();
                try
                {
                    await _neverCompletes.Task.WaitAsync(WaitBound, cancellationToken);
                }
                catch (OperationCanceledException cancellation)
                {
                    Thrown = cancellation;
                    throw;
                }
            }
        }
    }
}
