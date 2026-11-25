using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Test.Fakes;
using Google.Protobuf;
using Grpc.Core;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertRepositoryTests
    {
        private static readonly Guid FixedAlertId = new("e0000000-0000-4000-8000-000000000001");
        private static readonly Guid FixedAccountId = new("a0000000-0000-4000-8000-000000000000");
        private static readonly Guid FixedInstrumentId = new(
            "c0000000-0000-4000-8000-000000000001"
        );

        // Bounds every await, so a call that never ends fails the test instead of hanging it.
        private static readonly TimeSpan TestBound = TimeSpan.FromSeconds(5);

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum RepositoryCall
        {
            Create,
            List,
            Get,
            UpdateEnabled,
            Delete,
            Acknowledge,
            Trigger,
        }

        // A Type as the expected outcome means the call must throw that exception; any other
        // value is the result the call must return.
        [Theory]
        [InlineData(RepositoryCall.Get, StatusCode.NotFound, null)]
        [InlineData(RepositoryCall.UpdateEnabled, StatusCode.NotFound, null)]
        [InlineData(RepositoryCall.Delete, StatusCode.NotFound, false)]
        [InlineData(RepositoryCall.Acknowledge, StatusCode.NotFound, false)]
        [InlineData(RepositoryCall.Create, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.List, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.Get, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.UpdateEnabled, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.Delete, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.Acknowledge, StatusCode.Unavailable, typeof(DbException))]
        [InlineData(RepositoryCall.Trigger, StatusCode.Unavailable, typeof(DbException))]
        public async Task Call_GrpcStatus_ShouldMapThroughRealWrapper(
            RepositoryCall call,
            StatusCode status,
            object? expected
        )
        {
            // Arrange
            GrpcStatusHandler handler = new(status);
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            object? result = null;
            Exception? error = await Record.ExceptionAsync(
                async () =>
                    result = await InvokeAsync(repository, call, CancellationToken.None)
                        .WaitAsync(TestBound)
            );

            // Assert
            if (expected is Type exceptionType)
            {
                Assert.IsType(exceptionType, error);
            }
            else
            {
                Assert.Null(error);
                Assert.Equal(expected, result);
            }
        }

        [Fact]
        public async Task List_Token_ShouldReachCallOptions()
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.Hold();
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);
            using CancellationTokenSource cts = new();
            Task<IReadOnlyList<Alert>> listing = repository.ListAsync(
                accountId: null,
                armedOnly: true,
                triggeredOnly: false,
                unacknowledgedOnly: false,
                cts.Token
            );
            await handler.CallReceived.WaitAsync(TestBound);

            // Act
            cts.Cancel();

            // Assert: only the caller's token can end a held call before its deadline.
            await Assert.ThrowsAsync<DbException>(() => listing.WaitAsync(TestBound));
            Assert.True(handler.ObservedCancellation);
        }

        [Fact]
        public async Task Trigger_ResponseFalse_ShouldReturnFalse()
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(new AlertGrpc.TriggerAlertResponse { Triggered = false });
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            bool triggered = await repository
                .TriggerAsync(FixedAlertId, armingRevision: 1, triggerValue: 10.5m)
                .WaitAsync(TestBound);

            // Assert
            Assert.False(triggered);
        }

        [Theory]
        [InlineData(RepositoryCall.List)]
        [InlineData(RepositoryCall.Trigger)]
        public async Task EvaluatorCall_Sent_ShouldCarryBoundedDeadline(RepositoryCall call)
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(SuccessReply(call));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);
            using CancellationTokenSource host = new();

            // Act
            await InvokeAsync(repository, call, host.Token).WaitAsync(TestBound);

            // Assert
            TimeSpan? timeout = Assert.Single(handler.RequestTimeouts);
            Assert.NotNull(timeout);
            Assert.InRange(
                timeout.Value,
                TimeSpan.FromTicks(1),
                AlertRepository.EvaluatorCallTimeout
            );
        }

        [Theory]
        [InlineData(RepositoryCall.List)]
        [InlineData(RepositoryCall.Trigger)]
        public async Task EvaluatorCall_DeadlineExceeded_ShouldThrowDbExceptionWithoutCancellation(
            RepositoryCall call
        )
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithStatus(StatusCode.DeadlineExceeded);
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);
            using CancellationTokenSource host = new();

            // Act
            DbException exception = await Assert.ThrowsAsync<DbException>(
                () => InvokeAsync(repository, call, host.Token).WaitAsync(TestBound)
            );

            // Assert: the evaluator's failure path, which it tells apart from cancellation by the
            // host token alone.
            RpcException rpcException = Assert.IsType<RpcException>(exception.InnerException);
            Assert.Equal(StatusCode.DeadlineExceeded, rpcException.StatusCode);
            Assert.False(host.IsCancellationRequested);
        }

        // Only the evaluator calls carry a deadline, so only they need a successful reply.
        private static IMessage SuccessReply(RepositoryCall call)
        {
            return call switch
            {
                RepositoryCall.List => new AlertGrpc.AlertsResponse(),
                RepositoryCall.Trigger => new AlertGrpc.TriggerAlertResponse { Triggered = true },
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }

        // Fixed valid arguments, so only the reply decides the outcome. Only the evaluator calls,
        // List and Trigger, take the token.
        private static async Task<object?> InvokeAsync(
            AlertRepository repository,
            RepositoryCall call,
            CancellationToken cancellationToken
        )
        {
            return call switch
            {
                RepositoryCall.Create => await repository.CreateAsync(
                    FixedAccountId,
                    AlertType.TARGET_PRICE,
                    FixedInstrumentId,
                    AlertDirection.ABOVE,
                    threshold: 10m
                ),
                RepositoryCall.List => await repository.ListAsync(
                    accountId: null,
                    armedOnly: true,
                    triggeredOnly: false,
                    unacknowledgedOnly: false,
                    cancellationToken
                ),
                RepositoryCall.Get => await repository.GetAlertAsync(FixedAlertId),
                RepositoryCall.UpdateEnabled => await repository.UpdateEnabledAsync(
                    FixedAlertId,
                    enabled: true
                ),
                RepositoryCall.Delete => await repository.DeleteAsync(FixedAlertId),
                RepositoryCall.Acknowledge => await repository.AcknowledgeAsync(FixedAlertId),
                RepositoryCall.Trigger => await repository.TriggerAsync(
                    FixedAlertId,
                    armingRevision: 1,
                    triggerValue: 10.5m,
                    cancellationToken
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }
    }
}
