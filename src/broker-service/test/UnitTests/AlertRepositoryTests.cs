using System.Globalization;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Test.Fakes;
using EasyTrade.DbAdapter.Common.Grpc;
using Google.Protobuf;
using Grpc.Core;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;
// Imported alone because Google.Protobuf.WellKnownTypes also declares a Type, which would make
// System.Type ambiguous in this file.
using Timestamp = Google.Protobuf.WellKnownTypes.Timestamp;

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

        // The wire text of the ids, written out so the expected requests check the contract
        // independently of how the repository formats a Guid.
        private const string AlertIdText = "e0000000-0000-4000-8000-000000000001";
        private const string AccountIdText = "a0000000-0000-4000-8000-000000000000";
        private const string InstrumentIdText = "c0000000-0000-4000-8000-000000000001";
        private const string ListedAlertIdText = "e0000000-0000-4000-8000-000000000002";

        // Written out for the same reason: the method path is db-adapter's contract, not a value
        // to take from the generated client.
        private const string AlertServicePath = "/easytrade.dbadapter.alert.AlertService/";

        private static readonly DateTimeOffset CreatedTime = DateTimeOffset.Parse(
            "2025-03-14T09:26:53.5891234+00:00",
            CultureInfo.InvariantCulture
        );
        private static readonly DateTimeOffset TriggerTime = DateTimeOffset.Parse(
            "2025-03-14T10:00:07.1250001+00:00",
            CultureInfo.InvariantCulture
        );
        private static readonly DateTimeOffset ListedCreatedTime = DateTimeOffset.Parse(
            "2025-03-13T08:15:00.2500000+00:00",
            CultureInfo.InvariantCulture
        );

        // Disabled after its third arming triggered and was acknowledged, so every field differs
        // from a newly created alert and a result not read from the reply shows.
        private static readonly Alert SnapshotAlert = new(
            Id: FixedAlertId,
            AccountId: FixedAccountId,
            InstrumentId: FixedInstrumentId,
            Type: AlertType.PROFIT_LOSS,
            Direction: AlertDirection.BELOW,
            Threshold: -2.5m,
            Enabled: false,
            ArmingRevision: 3,
            TriggeredAt: TriggerTime,
            TriggerValue: -3.12345678m,
            Acknowledged: true,
            CreatedAt: CreatedTime
        );

        // The second alert of the list reply: armed and untriggered.
        private static readonly Alert ListedAlert = new(
            Id: Guid.Parse(ListedAlertIdText),
            AccountId: FixedAccountId,
            InstrumentId: FixedInstrumentId,
            Type: AlertType.TARGET_PRICE,
            Direction: AlertDirection.ABOVE,
            Threshold: 105.25m,
            Enabled: true,
            ArmingRevision: 1,
            TriggeredAt: null,
            TriggerValue: null,
            Acknowledged: false,
            CreatedAt: ListedCreatedTime
        );

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

        // Public for the same reason. One argument set per row of the request theory; the list
        // rows set each filter alone and the update rows send both values.
        public enum RequestCase
        {
            Create,
            ListAccountArmed,
            ListAllTriggered,
            ListAllUnacknowledged,
            Get,
            UpdateEnabledTrue,
            UpdateEnabledFalse,
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

        [Theory]
        [InlineData(RepositoryCall.Create, "CreateAlert")]
        [InlineData(RepositoryCall.List, "ListAlerts")]
        [InlineData(RepositoryCall.Get, "GetAlert")]
        [InlineData(RepositoryCall.UpdateEnabled, "UpdateAlertEnabled")]
        [InlineData(RepositoryCall.Delete, "DeleteAlert")]
        [InlineData(RepositoryCall.Acknowledge, "AcknowledgeAlert")]
        [InlineData(RepositoryCall.Trigger, "TriggerAlert")]
        public async Task Call_Sent_ShouldUseAlertServiceMethodPath(
            RepositoryCall call,
            string expectedMethod
        )
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(SuccessReply(call));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            await InvokeAsync(repository, call, CancellationToken.None).WaitAsync(TestBound);

            // Assert
            Assert.Equal(AlertServicePath + expectedMethod, Assert.Single(handler.RequestPaths));
        }

        [Theory]
        [InlineData(RequestCase.Create)]
        [InlineData(RequestCase.ListAccountArmed)]
        [InlineData(RequestCase.ListAllTriggered)]
        [InlineData(RequestCase.ListAllUnacknowledged)]
        [InlineData(RequestCase.Get)]
        [InlineData(RequestCase.UpdateEnabledTrue)]
        [InlineData(RequestCase.UpdateEnabledFalse)]
        [InlineData(RequestCase.Delete)]
        [InlineData(RequestCase.Acknowledge)]
        [InlineData(RequestCase.Trigger)]
        public async Task Call_Arguments_ShouldSendExactRequest(RequestCase requestCase)
        {
            // Arrange
            (RepositoryCall call, Func<AlertRepository, Task> send, IMessage expected) =
                BuildRequestCase(requestCase);
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(SuccessReply(call));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            await send(repository).WaitAsync(TestBound);

            // Assert: decoded as the expected message type, so every field is compared.
            IMessage sent = expected.Descriptor.Parser.ParseFrom(
                Assert.Single(handler.RequestMessages)
            );
            Assert.Equal(expected, sent);
        }

        [Theory]
        [InlineData(RepositoryCall.Create)]
        [InlineData(RepositoryCall.List)]
        [InlineData(RepositoryCall.Get)]
        [InlineData(RepositoryCall.UpdateEnabled)]
        [InlineData(RepositoryCall.Delete)]
        [InlineData(RepositoryCall.Acknowledge)]
        [InlineData(RepositoryCall.Trigger)]
        public async Task Call_SuccessReply_ShouldReturnMappedResult(RepositoryCall call)
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(SuccessReply(call));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            object? result = await InvokeAsync(repository, call, CancellationToken.None)
                .WaitAsync(TestBound);

            // Assert
            Assert.Equal(ExpectedResult(call), result);
        }

        [Fact]
        public async Task Acknowledge_ReplyAffectedZero_ShouldReturnTrue()
        {
            // Arrange: db-adapter's answer for an existing alert whose arming has not triggered.
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(new BatchResponse { Affected = 0 });
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            bool found = await repository.AcknowledgeAsync(FixedAlertId).WaitAsync(TestBound);

            // Assert: only a NotFound status is a miss.
            Assert.True(found);
        }

        [Theory]
        [InlineData(RepositoryCall.Create)]
        [InlineData(RepositoryCall.List)]
        [InlineData(RepositoryCall.Get)]
        [InlineData(RepositoryCall.UpdateEnabled)]
        public async Task Call_MalformedAlertReply_ShouldWrapFormatException(RepositoryCall call)
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(MalformedReply(call));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            DbException exception = await Assert.ThrowsAsync<DbException>(
                () => InvokeAsync(repository, call, CancellationToken.None).WaitAsync(TestBound)
            );

            // Assert: a reply the mapper rejects is a failed call, never a miss or a partial list.
            Assert.IsType<FormatException>(exception.InnerException);
        }

        // The request is built before the call is wrapped, so an undefined enum value is the
        // caller's error rather than a db-adapter failure, and nothing is sent.
        [Theory]
        [InlineData((AlertType)99, AlertDirection.ABOVE)]
        [InlineData(AlertType.TARGET_PRICE, (AlertDirection)99)]
        public async Task Create_UndefinedEnum_ShouldThrowBeforeTransport(
            AlertType type,
            AlertDirection direction
        )
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.ReplyWithMessage(SuccessReply(RepositoryCall.Create));
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);

            // Act
            Exception? error = await Record.ExceptionAsync(
                () =>
                    repository
                        .CreateAsync(FixedAccountId, type, FixedInstrumentId, direction, 10m)
                        .WaitAsync(TestBound)
            );

            // Assert
            Assert.IsType<ArgumentOutOfRangeException>(error);
            Assert.Equal(0, handler.CallCount);
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
        public async Task Trigger_Token_ShouldReachCallOptions()
        {
            // Arrange
            GrpcStatusHandler handler = new();
            handler.Hold();
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertRepository repository = new(connector);
            using CancellationTokenSource cts = new();
            Task<bool> triggering = repository.TriggerAsync(
                FixedAlertId,
                armingRevision: 1,
                triggerValue: 10.5m,
                cts.Token
            );
            await handler.CallReceived.WaitAsync(TestBound);

            // Act
            cts.Cancel();

            // Assert: only the caller's token can end a held call before its deadline.
            await Assert.ThrowsAsync<DbException>(() => triggering.WaitAsync(TestBound));
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

        // A successful reply of each call's response type, as db-adapter sends it. The alert
        // replies carry the snapshot, and the list reply two alerts, so ExpectedResult can tell a
        // mapped reply from a fabricated or reordered one.
        private static IMessage SuccessReply(RepositoryCall call)
        {
            return call switch
            {
                RepositoryCall.Create or RepositoryCall.Get or RepositoryCall.UpdateEnabled =>
                    SnapshotMessage(),
                RepositoryCall.List => new AlertGrpc.AlertsResponse
                {
                    Alerts = { SnapshotMessage(), ListedMessage() },
                },
                RepositoryCall.Delete or RepositoryCall.Acknowledge => new BatchResponse
                {
                    Affected = 1,
                },
                RepositoryCall.Trigger => new AlertGrpc.TriggerAlertResponse { Triggered = true },
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }

        // What each call must return for its SuccessReply: the mapped alerts in reply order, or
        // true for a write db-adapter reports as done.
        private static object ExpectedResult(RepositoryCall call)
        {
            return call switch
            {
                RepositoryCall.Create or RepositoryCall.Get or RepositoryCall.UpdateEnabled =>
                    SnapshotAlert,
                RepositoryCall.List => new[] { SnapshotAlert, ListedAlert },
                RepositoryCall.Delete or RepositoryCall.Acknowledge or RepositoryCall.Trigger =>
                    true,
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }

        // An otherwise valid alert with an inexact type name, which the mapper rejects. The list
        // reply puts it after a valid alert, so skipping it would show as a partial result.
        private static IMessage MalformedReply(RepositoryCall call)
        {
            AlertGrpc.AlertMessage malformed = SnapshotMessage();
            malformed.Type = "target_price";
            return call switch
            {
                RepositoryCall.Create or RepositoryCall.Get or RepositoryCall.UpdateEnabled =>
                    malformed,
                RepositoryCall.List => new AlertGrpc.AlertsResponse
                {
                    Alerts = { SnapshotMessage(), malformed },
                },
                _ => throw new ArgumentOutOfRangeException(nameof(call), call, null),
            };
        }

        // The call a row makes, and the request db-adapter must decode from it. The arguments
        // make a dropped, swapped or defaulted field visible: non-default enum names, decimals
        // with trailing zeros, a revision other than 1, each list filter set alone, and both
        // enabled values, false included, which the BoolValue wrapper must carry.
        private static (
            RepositoryCall Call,
            Func<AlertRepository, Task> Send,
            IMessage Expected
        ) BuildRequestCase(RequestCase requestCase)
        {
            return requestCase switch
            {
                RequestCase.Create => (
                    RepositoryCall.Create,
                    repository =>
                        repository.CreateAsync(
                            FixedAccountId,
                            AlertType.PROFIT_LOSS,
                            FixedInstrumentId,
                            AlertDirection.BELOW,
                            threshold: 1.500m
                        ),
                    new AlertGrpc.CreateAlertRequest
                    {
                        AccountId = AccountIdText,
                        Type = "PROFIT_LOSS",
                        InstrumentId = InstrumentIdText,
                        Direction = "BELOW",
                        Threshold = "1.5",
                    }
                ),
                RequestCase.ListAccountArmed => (
                    RepositoryCall.List,
                    repository =>
                        repository.ListAsync(
                            FixedAccountId,
                            armedOnly: true,
                            triggeredOnly: false,
                            unacknowledgedOnly: false
                        ),
                    new AlertGrpc.ListAlertsRequest { AccountId = AccountIdText, ArmedOnly = true }
                ),
                RequestCase.ListAllTriggered => (
                    RepositoryCall.List,
                    repository =>
                        repository.ListAsync(
                            accountId: null,
                            armedOnly: false,
                            triggeredOnly: true,
                            unacknowledgedOnly: false
                        ),
                    new AlertGrpc.ListAlertsRequest { AccountId = "", TriggeredOnly = true }
                ),
                RequestCase.ListAllUnacknowledged => (
                    RepositoryCall.List,
                    repository =>
                        repository.ListAsync(
                            accountId: null,
                            armedOnly: false,
                            triggeredOnly: false,
                            unacknowledgedOnly: true
                        ),
                    new AlertGrpc.ListAlertsRequest { AccountId = "", UnacknowledgedOnly = true }
                ),
                RequestCase.Get => (
                    RepositoryCall.Get,
                    repository => repository.GetAlertAsync(FixedAlertId),
                    new AlertGrpc.AlertIdRequest { Id = AlertIdText }
                ),
                RequestCase.UpdateEnabledTrue => (
                    RepositoryCall.UpdateEnabled,
                    repository => repository.UpdateEnabledAsync(FixedAlertId, enabled: true),
                    new AlertGrpc.UpdateAlertEnabledRequest { Id = AlertIdText, Enabled = true }
                ),
                RequestCase.UpdateEnabledFalse => (
                    RepositoryCall.UpdateEnabled,
                    repository => repository.UpdateEnabledAsync(FixedAlertId, enabled: false),
                    new AlertGrpc.UpdateAlertEnabledRequest { Id = AlertIdText, Enabled = false }
                ),
                RequestCase.Delete => (
                    RepositoryCall.Delete,
                    repository => repository.DeleteAsync(FixedAlertId),
                    new AlertGrpc.AlertIdRequest { Id = AlertIdText }
                ),
                RequestCase.Acknowledge => (
                    RepositoryCall.Acknowledge,
                    repository => repository.AcknowledgeAsync(FixedAlertId),
                    new AlertGrpc.AlertIdRequest { Id = AlertIdText }
                ),
                RequestCase.Trigger => (
                    RepositoryCall.Trigger,
                    repository =>
                        repository.TriggerAsync(
                            FixedAlertId,
                            armingRevision: 4,
                            triggerValue: 10.50000000m
                        ),
                    new AlertGrpc.TriggerAlertRequest
                    {
                        Id = AlertIdText,
                        ArmingRevision = 4,
                        TriggerValue = "10.5",
                    }
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(requestCase), requestCase, null),
            };
        }

        // The wire form of SnapshotAlert.
        private static AlertGrpc.AlertMessage SnapshotMessage()
        {
            return new AlertGrpc.AlertMessage
            {
                Id = AlertIdText,
                AccountId = AccountIdText,
                Type = "PROFIT_LOSS",
                InstrumentId = InstrumentIdText,
                Direction = "BELOW",
                Threshold = "-2.5",
                Enabled = false,
                ArmingRevision = 3,
                TriggeredAt = Timestamp.FromDateTimeOffset(TriggerTime),
                TriggerValue = "-3.12345678",
                Acknowledged = true,
                CreatedAt = Timestamp.FromDateTimeOffset(CreatedTime),
            };
        }

        // The wire form of ListedAlert: triggered_at unset and an empty trigger_value.
        private static AlertGrpc.AlertMessage ListedMessage()
        {
            return new AlertGrpc.AlertMessage
            {
                Id = ListedAlertIdText,
                AccountId = AccountIdText,
                Type = "TARGET_PRICE",
                InstrumentId = InstrumentIdText,
                Direction = "ABOVE",
                Threshold = "105.25",
                Enabled = true,
                ArmingRevision = 1,
                TriggerValue = "",
                Acknowledged = false,
                CreatedAt = Timestamp.FromDateTimeOffset(ListedCreatedTime),
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
