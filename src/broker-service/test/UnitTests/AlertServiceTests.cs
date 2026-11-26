using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Test.Fakes;
using Grpc.Core;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertServiceTests
    {
        private static readonly Guid AccountId = new("a1000000-0000-4000-8000-000000000001");
        private static readonly Guid OtherAccountId = new("a1000000-0000-4000-8000-000000000002");
        private static readonly Guid UnknownAccountId = new("a1000000-0000-4000-8000-0000000000ff");
        private static readonly Guid ProductId = new("b1000000-0000-4000-8000-000000000001");
        private static readonly Guid HeldInstrumentId = new("c1000000-0000-4000-8000-000000000001");
        private static readonly Guid ZeroQuantityInstrumentId = new(
            "c1000000-0000-4000-8000-000000000002"
        );
        private static readonly Guid UnheldInstrumentId = new(
            "c1000000-0000-4000-8000-000000000003"
        );
        private static readonly Guid UnknownInstrumentId = new(
            "c1000000-0000-4000-8000-0000000000ff"
        );
        private static readonly Guid UnknownAlertId = new("e1000000-0000-4000-8000-0000000000ff");

        // Bounds each wait on a test task, so a request that never ends fails the row instead of
        // hanging the run.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(5);

        private static readonly DateTimeOffset CreatedTime = FakeAlertRepository.BaseTime.AddDays(
            -1
        );
        private static readonly DateTimeOffset TriggerTime = CreatedTime.AddHours(1);

        private static readonly Alert ArmedAlert = new(
            Id: new Guid("e1000000-0000-4000-8000-000000000001"),
            AccountId: AccountId,
            InstrumentId: HeldInstrumentId,
            Type: AlertType.TARGET_PRICE,
            Direction: AlertDirection.ABOVE,
            Threshold: 10m,
            Enabled: true,
            ArmingRevision: 1,
            TriggeredAt: null,
            TriggerValue: null,
            Acknowledged: false,
            CreatedAt: CreatedTime
        );

        // Created before UnacknowledgedNotification but triggered after it, so creation order and
        // trigger order differ and each listing shows which one it sorts by.
        private static readonly Alert AcknowledgedNotification = new(
            Id: new Guid("e1000000-0000-4000-8000-000000000002"),
            AccountId: AccountId,
            InstrumentId: HeldInstrumentId,
            Type: AlertType.PROFIT_LOSS,
            Direction: AlertDirection.BELOW,
            Threshold: -5m,
            Enabled: true,
            ArmingRevision: 1,
            TriggeredAt: TriggerTime.AddMinutes(2),
            TriggerValue: -6.25m,
            Acknowledged: true,
            CreatedAt: CreatedTime.AddMinutes(1)
        );

        private static readonly Alert UnacknowledgedNotification = new(
            Id: new Guid("e1000000-0000-4000-8000-000000000003"),
            AccountId: AccountId,
            InstrumentId: UnheldInstrumentId,
            Type: AlertType.TARGET_PRICE,
            Direction: AlertDirection.BELOW,
            Threshold: 20m,
            Enabled: true,
            ArmingRevision: 2,
            TriggeredAt: TriggerTime.AddMinutes(1),
            TriggerValue: 19.5m,
            Acknowledged: false,
            CreatedAt: CreatedTime.AddMinutes(2)
        );

        // Newest of all rows; any listing that shows it has ignored the account filter.
        private static readonly Alert OtherAccountNotification = new(
            Id: new Guid("e1000000-0000-4000-8000-000000000004"),
            AccountId: OtherAccountId,
            InstrumentId: UnheldInstrumentId,
            Type: AlertType.TARGET_PRICE,
            Direction: AlertDirection.ABOVE,
            Threshold: 30m,
            Enabled: true,
            ArmingRevision: 1,
            TriggeredAt: TriggerTime.AddMinutes(3),
            TriggerValue: 31m,
            Acknowledged: false,
            CreatedAt: CreatedTime.AddMinutes(3)
        );

        private static readonly Alert TriggeredAlert = new(
            Id: new Guid("e1000000-0000-4000-8000-000000000005"),
            AccountId: AccountId,
            InstrumentId: HeldInstrumentId,
            Type: AlertType.PROFIT_LOSS,
            Direction: AlertDirection.ABOVE,
            Threshold: 12m,
            Enabled: true,
            ArmingRevision: 1,
            TriggeredAt: TriggerTime,
            TriggerValue: 12.5m,
            Acknowledged: true,
            CreatedAt: CreatedTime
        );

        private FakeAlertRepository? _alertRepository;
        private FakeBalanceRepository? _balanceRepository;
        private FakeInstrumentRepository? _instrumentRepository;
        private RecordingLogger<AlertService>? _logger;

        // The case enums are public, not private: xUnit passes them to the public theories, and a
        // public method cannot take a parameter of a less accessible type.
        public enum ValidCase
        {
            TargetPriceAboveHeld,
            TargetPriceBelowUnheld,
            ProfitLossAboveHeld,
            ProfitLossBelowNegativeHeld,
        }

        // Every rejecting branch of CreateAlertAsync, the threshold domain included, plus three
        // order rows: a field error answers before the account check, the account check before
        // the instrument check, and the instrument check before the holding check.
        public enum CreateCase
        {
            MissingAccountId,
            MissingInstrumentId,
            LowercaseType,
            LowercaseDirection,
            MissingThreshold,
            ThresholdTooManyIntegerDigits,
            ThresholdTooManyFractionalDigits,
            TargetPriceZeroThreshold,
            TargetPriceNegativeThreshold,
            ProfitLossUnheldInstrument,
            ProfitLossZeroQuantityInstrument,
            MissingThresholdUnknownAccount,
            UnknownAccount,
            UnknownAccountAndInstrument,
            UnknownInstrument,
            ProfitLossUnknownInstrument,
        }

        public enum UpdateCase
        {
            EnableTriggered,
            DisableTriggered,
            MissingEnabled,
        }

        public enum MissCase
        {
            DeleteUnknownAlert,
            AcknowledgeUnknownAlert,
            UpdateUnknownAlert,
            DeleteFalseAfterFoundGet,
            AcknowledgeFalseAfterFoundGet,
        }

        public enum FoundCase
        {
            Delete,
            AcknowledgeTriggered,
        }

        public enum ListCase
        {
            AlertsOfUnknownAccount,
            NotificationsOfUnknownAccount,
            AlertsOfAccountWithoutAlerts,
            AlertsOfAccount,
            AllNotifications,
            UnacknowledgedNotifications,
        }

        [Theory]
        [InlineData(ValidCase.TargetPriceAboveHeld)]
        [InlineData(ValidCase.TargetPriceBelowUnheld)]
        [InlineData(ValidCase.ProfitLossAboveHeld)]
        [InlineData(ValidCase.ProfitLossBelowNegativeHeld)]
        public async Task CreateAlert_Valid_ShouldReturnArmedAlert(ValidCase validCase)
        {
            // Arrange
            (CreateAlertDTO Request, AlertType Type, AlertDirection Direction) testCase =
                validCase switch
                {
                    ValidCase.TargetPriceAboveHeld => (
                        Request("TARGET_PRICE", HeldInstrumentId, "ABOVE", 10m),
                        AlertType.TARGET_PRICE,
                        AlertDirection.ABOVE
                    ),
                    ValidCase.TargetPriceBelowUnheld => (
                        Request("TARGET_PRICE", UnheldInstrumentId, "BELOW", 10m),
                        AlertType.TARGET_PRICE,
                        AlertDirection.BELOW
                    ),
                    ValidCase.ProfitLossAboveHeld => (
                        Request("PROFIT_LOSS", HeldInstrumentId, "ABOVE", 5m),
                        AlertType.PROFIT_LOSS,
                        AlertDirection.ABOVE
                    ),
                    ValidCase.ProfitLossBelowNegativeHeld => (
                        Request("PROFIT_LOSS", HeldInstrumentId, "BELOW", -5m),
                        AlertType.PROFIT_LOSS,
                        AlertDirection.BELOW
                    ),
                    _ => throw new ArgumentOutOfRangeException(nameof(validCase), validCase, null),
                };
            AlertService service = BuildFixtureService([]);

            // Act
            AlertDTO created = await service.CreateAlertAsync(testCase.Request);

            // Assert
            Alert expected = new(
                Id: created.Id,
                AccountId: AccountId,
                InstrumentId: testCase.Request.InstrumentId!.Value,
                Type: testCase.Type,
                Direction: testCase.Direction,
                Threshold: testCase.Request.Threshold!.Value,
                Enabled: true,
                ArmingRevision: 1,
                TriggeredAt: null,
                TriggerValue: null,
                Acknowledged: false,
                CreatedAt: created.CreatedAt
            );
            AssertDtoRepresents(expected, created);
            Assert.Equal(expected, Assert.Single(_alertRepository!.All()));
        }

        [Theory]
        [InlineData(CreateCase.MissingAccountId, typeof(InvalidAlertException))]
        [InlineData(CreateCase.MissingInstrumentId, typeof(InvalidAlertException))]
        [InlineData(CreateCase.LowercaseType, typeof(InvalidAlertException))]
        [InlineData(CreateCase.LowercaseDirection, typeof(InvalidAlertException))]
        [InlineData(CreateCase.MissingThreshold, typeof(InvalidAlertException))]
        [InlineData(CreateCase.ThresholdTooManyIntegerDigits, typeof(InvalidAlertException))]
        [InlineData(CreateCase.ThresholdTooManyFractionalDigits, typeof(InvalidAlertException))]
        [InlineData(CreateCase.TargetPriceZeroThreshold, typeof(InvalidAlertException))]
        [InlineData(CreateCase.TargetPriceNegativeThreshold, typeof(InvalidAlertException))]
        [InlineData(CreateCase.ProfitLossUnheldInstrument, typeof(InvalidAlertException))]
        [InlineData(CreateCase.ProfitLossZeroQuantityInstrument, typeof(InvalidAlertException))]
        [InlineData(CreateCase.MissingThresholdUnknownAccount, typeof(InvalidAlertException))]
        [InlineData(CreateCase.UnknownAccount, typeof(BalanceNotFoundException))]
        [InlineData(CreateCase.UnknownAccountAndInstrument, typeof(BalanceNotFoundException))]
        [InlineData(CreateCase.UnknownInstrument, typeof(InstrumentNotFoundException))]
        [InlineData(CreateCase.ProfitLossUnknownInstrument, typeof(InstrumentNotFoundException))]
        public async Task CreateAlert_Invalid_ShouldThrow(CreateCase createCase, Type expected)
        {
            // Arrange
            CreateAlertDTO request = InvalidRequest(createCase);
            AlertService service = BuildFixtureService([]);

            // Act & Assert: the first failing check answers and nothing is written.
            await Assert.ThrowsAsync(expected, () => service.CreateAlertAsync(request));
            Assert.Empty(_alertRepository!.All());
        }

        [Fact]
        public async Task CreateAlert_Success_ShouldLogNamedFields()
        {
            // Arrange
            AlertService service = BuildFixtureService([]);
            CreateAlertDTO request = Request("PROFIT_LOSS", HeldInstrumentId, "BELOW", -5m);

            // Act
            AlertDTO created = await service.CreateAlertAsync(request);

            // Assert: the logged id is the one the repository generated, so the line was written
            // after the repository call returned.
            LogEntry entry = Assert.Single(_logger!.Sink.ByLevel(LogLevel.Information));
            (string Name, object Value)[] expectedFields =
            [
                ("alertId", created.Id),
                ("accountId", AccountId),
                ("type", "PROFIT_LOSS"),
                ("instrumentId", HeldInstrumentId),
                ("direction", "BELOW"),
                ("threshold", -5m),
            ];
            Assert.All(
                expectedFields,
                field => Assert.Equal(field.Value, entry.GetField(field.Name))
            );
        }

        // Both references pass the checks, then the create RPC fails as the real repository
        // reports it. NotFound means a reference was removed before the insert: the 404 names
        // both ids and nothing is read again. Any other status stays the DbException thrown.
        // Strict mocks admit only the two check reads; no row is stored and nothing is logged.
        [Theory]
        [InlineData(StatusCode.NotFound)]
        [InlineData(StatusCode.Unavailable)]
        [InlineData(StatusCode.DeadlineExceeded)]
        public async Task CreateAlert_CreateRpcFailsAfterChecks_ShouldMapToDomainOrPropagate(
            StatusCode rpcStatus
        )
        {
            // Arrange: each reference is read once, by its own check.
            Balance balance = new(AccountId, 1000);
            Instrument instrument = new(HeldInstrumentId, ProductId, "HELD", "Held", "Held");
            DbException createFailure = CreateFailure(rpcStatus, rpcStatus.ToString());
            Mock<IBalanceRepository> balances = new(MockBehavior.Strict);
            balances
                .Setup(repository => repository.GetBalanceOfAccountAsync(AccountId))
                .ReturnsAsync(balance);
            Mock<IInstrumentRepository> instruments = new(MockBehavior.Strict);
            instruments
                .Setup(repository => repository.GetInstrumentAsync(HeldInstrumentId))
                .ReturnsAsync(instrument);
            FakeAlertRepository alerts = new();
            alerts.ThrowOnNext(FakeAlertRepositoryMethod.Create, createFailure);
            RecordingLogger<AlertService> logger = new();
            AlertService service = new(
                alerts,
                balances.Object,
                instruments.Object,
                TimeProvider.System,
                logger
            );
            CreateAlertDTO request = Request("TARGET_PRICE", HeldInstrumentId, "ABOVE", 10m);

            // Act
            Exception thrown = await Assert.ThrowsAnyAsync<Exception>(
                () => service.CreateAlertAsync(request)
            );

            // Assert: NotFound is the 404 naming both ids; any other status is the very
            // DbException thrown below the service.
            if (rpcStatus == StatusCode.NotFound)
            {
                BalanceNotFoundException notFound = Assert.IsType<BalanceNotFoundException>(thrown);
                Assert.Equal(
                    $"Account {AccountId} or instrument {HeldInstrumentId} not found",
                    notFound.Message
                );
            }
            else
            {
                Assert.Same(createFailure, thrown);
            }
            Assert.Equal(1, alerts.CallCount(FakeAlertRepositoryMethod.Create));
            balances.Verify(
                repository => repository.GetBalanceOfAccountAsync(AccountId),
                Times.Once()
            );
            instruments.Verify(
                repository => repository.GetInstrumentAsync(HeldInstrumentId),
                Times.Once()
            );
            balances.VerifyNoOtherCalls();
            instruments.VerifyNoOtherCalls();
            Assert.Empty(alerts.All());
            Assert.Empty(logger.Entries);
        }

        // Public, not private, like the case enums above: xUnit passes it to the public theory
        // below, and a public method cannot take a parameter of a less accessible type.
        public enum NullCase
        {
            Create,
            UpdateEnabled,
        }

        // The null-request guards of CreateAlertAsync and UpdateEnabledAsync, which only a direct
        // caller reaches: MVC never binds a null body. With an alert seeded, the rejection names
        // the parameter and leaves no repository call, row change or log line behind.
        [Theory]
        [InlineData(NullCase.Create)]
        [InlineData(NullCase.UpdateEnabled)]
        public async Task RequestDto_Null_ShouldThrowArgumentNullWithoutRepositoryCall(
            NullCase nullCase
        )
        {
            // Arrange
            AlertService service = BuildFixtureService([ArmedAlert]);
            Func<Task> act = nullCase switch
            {
                NullCase.Create => () => service.CreateAlertAsync(null!),
                NullCase.UpdateEnabled => () => service.UpdateEnabledAsync(ArmedAlert.Id, null!),
                _ => throw new ArgumentOutOfRangeException(nameof(nullCase), nullCase, null),
            };

            // Act
            ArgumentNullException thrown = await Assert.ThrowsAsync<ArgumentNullException>(act);

            // Assert
            Assert.Equal("request", thrown.ParamName);
            Assert.All(
                Enum.GetValues<FakeAlertRepositoryMethod>(),
                method => Assert.Equal(0, _alertRepository!.CallCount(method))
            );
            Assert.Equal(ArmedAlert, Assert.Single(_alertRepository!.All()));
            Assert.Empty(_logger!.Entries);
        }

        [Theory]
        [InlineData(UpdateCase.EnableTriggered)]
        [InlineData(UpdateCase.DisableTriggered)]
        [InlineData(UpdateCase.MissingEnabled)]
        public async Task UpdateEnabled_Value_ShouldApplyRule(UpdateCase updateCase)
        {
            // Arrange: a null expectation means the request is rejected and the row is untouched.
            (bool? Enabled, Alert? Expected) testCase = updateCase switch
            {
                UpdateCase.EnableTriggered => (
                    true,
                    TriggeredAlert with
                    {
                        Enabled = true,
                        ArmingRevision = 2,
                        TriggeredAt = null,
                        TriggerValue = null,
                        Acknowledged = false,
                    }
                ),
                UpdateCase.DisableTriggered => (false, TriggeredAlert with { Enabled = false }),
                UpdateCase.MissingEnabled => (null, null),
                _ => throw new ArgumentOutOfRangeException(nameof(updateCase), updateCase, null),
            };
            AlertService service = BuildFixtureService([TriggeredAlert]);
            UpdateAlertDTO request = new() { Enabled = testCase.Enabled };
            Func<Task<AlertDTO>> act = () => service.UpdateEnabledAsync(TriggeredAlert.Id, request);

            // Act & Assert
            if (testCase.Expected is null)
            {
                await Assert.ThrowsAsync<InvalidAlertException>(act);
                Assert.Equal(TriggeredAlert, _alertRepository!.Get(TriggeredAlert.Id));
                return;
            }
            AssertDtoRepresents(testCase.Expected, await act());
            Assert.Equal(testCase.Expected, _alertRepository!.Get(TriggeredAlert.Id));
        }

        [Theory]
        [InlineData(MissCase.DeleteUnknownAlert)]
        [InlineData(MissCase.AcknowledgeUnknownAlert)]
        [InlineData(MissCase.UpdateUnknownAlert)]
        [InlineData(MissCase.DeleteFalseAfterFoundGet)]
        [InlineData(MissCase.AcknowledgeFalseAfterFoundGet)]
        public async Task AlertById_RepositoryReportsMiss_ShouldThrowAlertNotFound(
            MissCase missCase
        )
        {
            // Arrange
            AlertService service = BuildFixtureService([ArmedAlert]);
            FakeAlertRepositoryMethod? missingWrite = missCase switch
            {
                MissCase.DeleteFalseAfterFoundGet => FakeAlertRepositoryMethod.Delete,
                MissCase.AcknowledgeFalseAfterFoundGet => FakeAlertRepositoryMethod.Acknowledge,
                _ => null,
            };
            if (missingWrite is FakeAlertRepositoryMethod method)
            {
                // The read still finds the alert; only the write reports it gone, as after a
                // concurrent delete.
                _alertRepository!.MissNext(method);
            }
            Func<Task> act = missCase switch
            {
                MissCase.DeleteUnknownAlert => () => service.DeleteAlertAsync(UnknownAlertId),
                MissCase.AcknowledgeUnknownAlert => () =>
                    service.AcknowledgeAlertAsync(UnknownAlertId),
                MissCase.UpdateUnknownAlert => () =>
                    service.UpdateEnabledAsync(
                        UnknownAlertId,
                        new UpdateAlertDTO { Enabled = true }
                    ),
                MissCase.DeleteFalseAfterFoundGet => () => service.DeleteAlertAsync(ArmedAlert.Id),
                MissCase.AcknowledgeFalseAfterFoundGet => () =>
                    service.AcknowledgeAlertAsync(ArmedAlert.Id),
                _ => throw new ArgumentOutOfRangeException(nameof(missCase), missCase, null),
            };

            // Act & Assert: the miss is a 404, and no audit line claims a completed write.
            await Assert.ThrowsAsync<AlertNotFoundException>(act);
            Assert.Empty(_logger!.Sink.ByLevel(LogLevel.Information));
        }

        // The write paths of DeleteAlertAsync and AcknowledgeAlertAsync when the alert exists.
        [Theory]
        [InlineData(FoundCase.Delete)]
        [InlineData(FoundCase.AcknowledgeTriggered)]
        public async Task AlertById_Found_ShouldApplyWrite(FoundCase foundCase)
        {
            // Arrange: a null expectation means the row is gone afterwards.
            Guid id = UnacknowledgedNotification.Id;
            AlertService service = BuildFixtureService([UnacknowledgedNotification]);
            (Func<Task> Act, Alert? Expected) testCase = foundCase switch
            {
                FoundCase.Delete => (() => service.DeleteAlertAsync(id), null),
                FoundCase.AcknowledgeTriggered => (
                    () => service.AcknowledgeAlertAsync(id),
                    UnacknowledgedNotification with
                    {
                        Acknowledged = true,
                    }
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(foundCase), foundCase, null),
            };

            // Act
            await testCase.Act();

            // Assert
            Assert.Equal(testCase.Expected, _alertRepository!.Get(id));
        }

        public enum TokenCase
        {
            CreateAlert,
            GetAlerts,
            GetNotifications,
            UpdateEnabled,
            DeleteAlert,
            AcknowledgeAlert,
        }

        // Each member passes its caller's token to the alert repository. The token is cancelled
        // before the call, so the first alert repository call fails as a cancelled gRPC call does,
        // before it decides anything.
        [Theory]
        [InlineData(TokenCase.CreateAlert)]
        [InlineData(TokenCase.GetAlerts)]
        [InlineData(TokenCase.GetNotifications)]
        [InlineData(TokenCase.UpdateEnabled)]
        [InlineData(TokenCase.DeleteAlert)]
        [InlineData(TokenCase.AcknowledgeAlert)]
        public async Task AlertCall_CancelledToken_ShouldFailWithoutWriteOrAudit(
            TokenCase tokenCase
        )
        {
            // Arrange: a triggered, unacknowledged row, which every write would change.
            Guid id = UnacknowledgedNotification.Id;
            AlertService service = BuildFixtureService([UnacknowledgedNotification]);
            using CancellationTokenSource caller = new();
            caller.Cancel();
            CancellationToken token = caller.Token;
            (Func<Task> Act, FakeAlertRepositoryMethod FirstCall) testCase = tokenCase switch
            {
                TokenCase.CreateAlert => (
                    () =>
                        service.CreateAlertAsync(
                            Request("TARGET_PRICE", HeldInstrumentId, "ABOVE", 10m),
                            token
                        ),
                    FakeAlertRepositoryMethod.Create
                ),
                TokenCase.GetAlerts => (
                    () => service.GetAlertsAsync(AccountId, token),
                    FakeAlertRepositoryMethod.List
                ),
                TokenCase.GetNotifications => (
                    () => service.GetNotificationsAsync(AccountId, false, token),
                    FakeAlertRepositoryMethod.List
                ),
                TokenCase.UpdateEnabled => (
                    () =>
                        service.UpdateEnabledAsync(
                            id,
                            new UpdateAlertDTO { Enabled = true },
                            token
                        ),
                    FakeAlertRepositoryMethod.UpdateEnabled
                ),
                TokenCase.DeleteAlert => (
                    () => service.DeleteAlertAsync(id, token),
                    FakeAlertRepositoryMethod.Get
                ),
                TokenCase.AcknowledgeAlert => (
                    () => service.AcknowledgeAlertAsync(id, token),
                    FakeAlertRepositoryMethod.Get
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(tokenCase), tokenCase, null),
            };

            // Act: bounded, so a call that never ends fails the test instead of hanging it.
            DbException error = await Assert.ThrowsAsync<DbException>(
                () => testCase.Act().WaitAsync(TimeSpan.FromSeconds(5))
            );

            // Assert: the failure carries this very token, the call that saw it was the first
            // alert repository call and the only one, no row changed and no audit line followed.
            OperationCanceledException cancellation = Assert.IsType<OperationCanceledException>(
                error.InnerException
            );
            Assert.Equal(token, cancellation.CancellationToken);
            Assert.Equal(1, _alertRepository!.CallCount(testCase.FirstCall));
            Assert.All(
                Enum.GetValues<FakeAlertRepositoryMethod>()
                    .Where(other => other != testCase.FirstCall),
                method => Assert.Equal(0, _alertRepository.CallCount(method))
            );
            Assert.Equal(UnacknowledgedNotification, Assert.Single(_alertRepository.All()));
            Assert.Empty(_logger!.Sink.ByLevel(LogLevel.Information));
        }

        [Fact]
        public async Task Acknowledge_NotTriggered_ShouldChangeNothing()
        {
            // Arrange
            AlertService service = BuildFixtureService([ArmedAlert]);

            // Act
            await service.AcknowledgeAlertAsync(ArmedAlert.Id);

            // Assert: no notification is acknowledged in advance of a future trigger.
            Assert.Equal(ArmedAlert, _alertRepository!.Get(ArmedAlert.Id));
        }

        public enum AcknowledgeAuditCase
        {
            Triggered,
            NotTriggered,
        }

        // db-adapter acknowledges only an arming that has triggered when it writes, and the
        // broker learns only that the alert exists, so a real acknowledgement and the no-op on an
        // untriggered arming write the same outcome-neutral line.
        [Theory]
        [InlineData(AcknowledgeAuditCase.Triggered)]
        [InlineData(AcknowledgeAuditCase.NotTriggered)]
        public async Task Acknowledge_ArmingState_ShouldLogAcceptedRequest(
            AcknowledgeAuditCase auditCase
        )
        {
            // Arrange
            Alert seeded = auditCase switch
            {
                AcknowledgeAuditCase.Triggered => UnacknowledgedNotification,
                AcknowledgeAuditCase.NotTriggered => ArmedAlert,
                _ => throw new ArgumentOutOfRangeException(nameof(auditCase), auditCase, null),
            };
            (string Name, object Value)[] expectedFields =
            [
                ("alertId", seeded.Id),
                ("accountId", AccountId),
            ];
            AlertService service = BuildFixtureService([seeded]);

            // Act
            await service.AcknowledgeAlertAsync(seeded.Id);

            // Assert: exactly one line, with the accepted template and only the alert and account
            // ids as named fields, and its rendered text claims neither outcome.
            LogEntry entry = Assert.Single(_logger!.Sink.ByLevel(LogLevel.Information));
            Assert.Equal(
                "Alert [{alertId}] of account [{accountId}] acknowledgement request accepted",
                entry.GetField("{OriginalFormat}")
            );
            Assert.Equal(
                expectedFields.Select(field => field.Name).Append("{OriginalFormat}"),
                entry.State.Select(pair => pair.Key)
            );
            Assert.All(
                expectedFields,
                field => Assert.Equal(field.Value, entry.GetField(field.Name))
            );
            Assert.DoesNotContain(
                "acknowledged",
                entry.Message,
                StringComparison.OrdinalIgnoreCase
            );
            Assert.DoesNotContain(
                "changed nothing",
                entry.Message,
                StringComparison.OrdinalIgnoreCase
            );
        }

        [Theory]
        [InlineData(ListCase.AlertsOfUnknownAccount)]
        [InlineData(ListCase.NotificationsOfUnknownAccount)]
        [InlineData(ListCase.AlertsOfAccountWithoutAlerts)]
        [InlineData(ListCase.AlertsOfAccount)]
        [InlineData(ListCase.AllNotifications)]
        [InlineData(ListCase.UnacknowledgedNotifications)]
        public async Task ListAlerts_Account_ShouldMatchContract(ListCase listCase)
        {
            // Arrange: a null expectation means the account is unknown.
            Alert[] seeded =
                listCase == ListCase.AlertsOfAccountWithoutAlerts
                    ? []
                    :
                    [
                        ArmedAlert,
                        AcknowledgedNotification,
                        UnacknowledgedNotification,
                        OtherAccountNotification,
                    ];
            AlertService service = BuildFixtureService(seeded);
            (Func<Task<IEnumerable<AlertDTO>>> Act, Guid[]? ExpectedIds) testCase = listCase switch
            {
                ListCase.AlertsOfUnknownAccount => (
                    () => service.GetAlertsAsync(UnknownAccountId),
                    null
                ),
                ListCase.NotificationsOfUnknownAccount => (
                    () => service.GetNotificationsAsync(UnknownAccountId, true),
                    null
                ),
                ListCase.AlertsOfAccountWithoutAlerts => (
                    () => service.GetAlertsAsync(AccountId),
                    []
                ),
                // Newest created first.
                ListCase.AlertsOfAccount => (
                    () => service.GetAlertsAsync(AccountId),
                    [UnacknowledgedNotification.Id, AcknowledgedNotification.Id, ArmedAlert.Id]
                ),
                // Triggered alerts only, newest trigger first.
                ListCase.AllNotifications => (
                    () => service.GetNotificationsAsync(AccountId, false),
                    [AcknowledgedNotification.Id, UnacknowledgedNotification.Id]
                ),
                ListCase.UnacknowledgedNotifications => (
                    () => service.GetNotificationsAsync(AccountId, true),
                    [UnacknowledgedNotification.Id]
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(listCase), listCase, null),
            };

            // Act & Assert
            if (testCase.ExpectedIds is null)
            {
                await Assert.ThrowsAsync<BalanceNotFoundException>(testCase.Act);
                return;
            }
            IEnumerable<AlertDTO> results = await testCase.Act();
            Assert.Equal(testCase.ExpectedIds, results.Select(alert => alert.Id));
        }

        [Fact]
        public async Task GetNotifications_RepositoryOrder_ShouldBePreserved()
        {
            // Arrange: db-adapter's order, newest trigger first, then two alerts triggered at the
            // same instant in ascending id order. The fake store breaks such ties by id
            // descending, so a stub returns this order; any service-side re-sort with an id
            // tie-break would swap the last two.
            Alert[] listed =
            [
                AcknowledgedNotification,
                UnacknowledgedNotification with
                {
                    TriggeredAt = TriggerTime,
                },
                TriggeredAlert,
            ];
            Mock<IAlertRepository> alertRepository = new(MockBehavior.Strict);
            alertRepository
                .Setup(repository =>
                    repository.ListAsync(
                        AccountId,
                        false,
                        true,
                        false,
                        It.IsAny<CancellationToken>()
                    )
                )
                .ReturnsAsync(listed);
            AlertService service = new(
                alertRepository.Object,
                new FakeBalanceRepository([new Balance(AccountId, 1000)], []),
                new FakeInstrumentRepository(),
                TimeProvider.System,
                new RecordingLogger<AlertService>()
            );

            // Act
            IEnumerable<AlertDTO> results = await service.GetNotificationsAsync(AccountId, false);

            // Assert
            Assert.Equal(listed.Select(alert => alert.Id), results.Select(alert => alert.Id));
        }

        // Public, not private, like the case enums above: xUnit passes it to the public theories
        // below, and a public method cannot take a parameter of a less accessible type.
        public enum ReferenceCheck
        {
            AccountOnCreate,
            AccountOnList,
            AccountOnNotifications,
            InstrumentOnCreate,
            HoldingOnProfitLossCreate,
        }

        // The account, instrument and holding checks read through existing repositories that set
        // no deadline and take no token. The checked read never answers, as on a db-adapter that
        // accepted the call and stopped: the request stays pending until the alert call budget has
        // passed, then fails as a db-adapter failure naming that read, before any alert call and
        // without a log line.
        [Theory]
        [InlineData(
            ReferenceCheck.AccountOnCreate,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.AccountOnList,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.AccountOnNotifications,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.InstrumentOnCreate,
            nameof(IInstrumentRepository.GetInstrumentAsync)
        )]
        [InlineData(
            ReferenceCheck.HoldingOnProfitLossCreate,
            nameof(IInstrumentRepository.GetOwnedInstrumentsOfAccountAsync)
        )]
        public async Task ReferenceCheck_ReadNeverAnswers_ShouldFailAtCallTimeoutWithoutAlertCall(
            ReferenceCheck check,
            string operation
        )
        {
            // Arrange
            ManualTimeProvider time = new();
            AlertService service = BuildUnansweredCheckService(check, time);
            Task request = StartCheckedRequest(service, check, CancellationToken.None);

            // Act
            (bool pendingBeforeBudget, Exception? error) = await ExpireCallBudgetAsync(
                time,
                request
            );

            // Assert
            Assert.Equal(
                (true, typeof(DbException), typeof(TimeoutException), true, 0, 0),
                (
                    pendingBeforeBudget,
                    error?.GetType(),
                    error?.InnerException?.GetType(),
                    NamesOperation(error, operation),
                    TotalAlertCalls(),
                    _logger!.Entries.Count
                )
            );
        }

        // The caller's token cancels while the checked read is pending: the wait ends at once,
        // with no time passing, as a db-adapter failure that wraps the cancellation of that very
        // token, before any alert call and without a log line.
        [Theory]
        [InlineData(
            ReferenceCheck.AccountOnCreate,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.AccountOnList,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.AccountOnNotifications,
            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
        )]
        [InlineData(
            ReferenceCheck.InstrumentOnCreate,
            nameof(IInstrumentRepository.GetInstrumentAsync)
        )]
        [InlineData(
            ReferenceCheck.HoldingOnProfitLossCreate,
            nameof(IInstrumentRepository.GetOwnedInstrumentsOfAccountAsync)
        )]
        public async Task ReferenceCheck_CallerCancelsDuringRead_ShouldFailWithCancellation(
            ReferenceCheck check,
            string operation
        )
        {
            // Arrange
            ManualTimeProvider time = new();
            AlertService service = BuildUnansweredCheckService(check, time);
            using CancellationTokenSource caller = new();
            Task request = StartCheckedRequest(service, check, caller.Token);
            await time.WaitForCreatedTimersAsync(1).WaitAsync(WaitBound);

            // Act
            await caller.CancelAsync();
            Exception? error = await Record.ExceptionAsync(() => request.WaitAsync(WaitBound));

            // Assert
            Assert.Equal(
                (typeof(DbException), true, true, ManualTimeProvider.DefaultStart, 0, 0),
                (
                    error?.GetType(),
                    error?.InnerException is OperationCanceledException cancellation
                        && (cancellation.CancellationToken == caller.Token),
                    NamesOperation(error, operation),
                    time.GetUtcNow(),
                    TotalAlertCalls(),
                    _logger!.Entries.Count
                )
            );
        }

        // Waits until the code under test has started its bound, moves the clock to one tick
        // short of the alert call budget and notes whether the request is still pending with that
        // bound scheduled, then moves the last tick and returns the request's exception.
        private static async Task<(
            bool PendingBeforeBudget,
            Exception? Error
        )> ExpireCallBudgetAsync(ManualTimeProvider time, Task request)
        {
            await time.WaitForCreatedTimersAsync(1).WaitAsync(WaitBound);
            time.Advance(AlertRepository.CallTimeout - TimeSpan.FromTicks(1));
            bool pending = !request.IsCompleted && (time.ScheduledTimerCount == 1);
            time.Advance(TimeSpan.FromTicks(1));
            Exception? error = await Record.ExceptionAsync(() => request.WaitAsync(WaitBound));
            return (pending, error);
        }

        // GrpcHelper's prefix, which the exception filter reads the failed call's name from.
        private static bool NamesOperation(Exception? error, string operation)
        {
            return error?.Message.StartsWith(
                    $"Db Adapter call error in \"{operation}\" method: ",
                    StringComparison.Ordinal
                ) == true;
        }

        // The request whose first unanswered read is the given check's.
        private static Task StartCheckedRequest(
            AlertService service,
            ReferenceCheck check,
            CancellationToken cancellationToken
        )
        {
            switch (check)
            {
                case ReferenceCheck.AccountOnCreate:
                case ReferenceCheck.InstrumentOnCreate:
                    return service.CreateAlertAsync(
                        Request("TARGET_PRICE", HeldInstrumentId, "ABOVE", 10m),
                        cancellationToken
                    );
                case ReferenceCheck.AccountOnList:
                    return service.GetAlertsAsync(AccountId, cancellationToken);
                case ReferenceCheck.AccountOnNotifications:
                    return service.GetNotificationsAsync(AccountId, true, cancellationToken);
                case ReferenceCheck.HoldingOnProfitLossCreate:
                    return service.CreateAlertAsync(
                        Request("PROFIT_LOSS", HeldInstrumentId, "ABOVE", 5m),
                        cancellationToken
                    );
                default:
                    throw new ArgumentOutOfRangeException(nameof(check), check, null);
            }
        }

        // Strict mocks answer the account, instrument and holding reads of the fixture account
        // and its held instrument, except the read of the given check, whose task never
        // completes. The fake alert repository counts any alert call that follows.
        private AlertService BuildUnansweredCheckService(ReferenceCheck check, TimeProvider time)
        {
            Mock<IBalanceRepository> balances = new(MockBehavior.Strict);
            balances
                .Setup(repository => repository.GetBalanceOfAccountAsync(AccountId))
                .Returns(
                    check
                        is ReferenceCheck.AccountOnCreate
                            or ReferenceCheck.AccountOnList
                            or ReferenceCheck.AccountOnNotifications
                        ? NeverAnswered<Balance?>()
                        : Task.FromResult<Balance?>(new Balance(AccountId, 1000))
                );
            Mock<IInstrumentRepository> instruments = new(MockBehavior.Strict);
            instruments
                .Setup(repository => repository.GetInstrumentAsync(HeldInstrumentId))
                .Returns(
                    check == ReferenceCheck.InstrumentOnCreate
                        ? NeverAnswered<Instrument?>()
                        : Task.FromResult<Instrument?>(
                            new Instrument(HeldInstrumentId, ProductId, "HELD", "Held", "Held")
                        )
                );
            instruments
                .Setup(repository => repository.GetOwnedInstrumentsOfAccountAsync(AccountId))
                .Returns(
                    check == ReferenceCheck.HoldingOnProfitLossCreate
                        ? NeverAnswered<List<OwnedInstrument>>()
                        : Task.FromResult(
                            new List<OwnedInstrument>
                            {
                                new(AccountId, HeldInstrumentId, 5, CreatedTime),
                            }
                        )
                );
            _alertRepository = new FakeAlertRepository();
            _logger = new RecordingLogger<AlertService>();
            return new AlertService(
                _alertRepository,
                balances.Object,
                instruments.Object,
                time,
                _logger
            );
        }

        private static Task<T> NeverAnswered<T>()
        {
            return new TaskCompletionSource<T>().Task;
        }

        private int TotalAlertCalls()
        {
            return Enum.GetValues<FakeAlertRepositoryMethod>().Sum(_alertRepository!.CallCount);
        }

        // A failed create as the real repository reports it: GrpcHelper wraps the RpcException.
        private static DbException CreateFailure(StatusCode status, string detail)
        {
            return new DbException(
                $"Db Adapter call error in \"CreateAsync\" method: {detail}",
                new RpcException(new Status(status, detail))
            );
        }

        private static CreateAlertDTO Request(
            string type,
            Guid instrumentId,
            string direction,
            decimal threshold
        )
        {
            return new CreateAlertDTO
            {
                AccountId = AccountId,
                Type = type,
                InstrumentId = instrumentId,
                Direction = direction,
                Threshold = threshold,
            };
        }

        // A valid TARGET_PRICE request with exactly the fields of the case changed.
        private static CreateAlertDTO InvalidRequest(CreateCase createCase)
        {
            CreateAlertDTO request = Request("TARGET_PRICE", HeldInstrumentId, "ABOVE", 10m);
            switch (createCase)
            {
                case CreateCase.MissingAccountId:
                    request.AccountId = null;
                    break;
                case CreateCase.MissingInstrumentId:
                    request.InstrumentId = null;
                    break;
                case CreateCase.LowercaseType:
                    request.Type = "target_price";
                    break;
                case CreateCase.LowercaseDirection:
                    request.Direction = "above";
                    break;
                case CreateCase.MissingThreshold:
                    request.Threshold = null;
                    break;
                case CreateCase.ThresholdTooManyIntegerDigits:
                    request.Threshold = 10000000000m;
                    break;
                case CreateCase.ThresholdTooManyFractionalDigits:
                    request.Threshold = 0.000000001m;
                    break;
                case CreateCase.TargetPriceZeroThreshold:
                    request.Threshold = 0m;
                    break;
                case CreateCase.TargetPriceNegativeThreshold:
                    request.Threshold = -1m;
                    break;
                case CreateCase.ProfitLossUnheldInstrument:
                    request.Type = "PROFIT_LOSS";
                    request.InstrumentId = UnheldInstrumentId;
                    break;
                case CreateCase.ProfitLossZeroQuantityInstrument:
                    request.Type = "PROFIT_LOSS";
                    request.InstrumentId = ZeroQuantityInstrumentId;
                    break;
                case CreateCase.MissingThresholdUnknownAccount:
                    request.Threshold = null;
                    request.AccountId = UnknownAccountId;
                    break;
                case CreateCase.UnknownAccount:
                    request.AccountId = UnknownAccountId;
                    break;
                case CreateCase.UnknownAccountAndInstrument:
                    request.AccountId = UnknownAccountId;
                    request.InstrumentId = UnknownInstrumentId;
                    break;
                case CreateCase.UnknownInstrument:
                    request.InstrumentId = UnknownInstrumentId;
                    break;
                case CreateCase.ProfitLossUnknownInstrument:
                    request.Type = "PROFIT_LOSS";
                    request.InstrumentId = UnknownInstrumentId;
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(createCase), createCase, null);
            }
            return request;
        }

        // AlertDTO has reference equality, so its fields are compared, as one value, with the
        // alert it must represent. Enum member names are the exact wire names.
        private static void AssertDtoRepresents(Alert expected, AlertDTO actual)
        {
            Assert.Equal(
                new
                {
                    expected.Id,
                    expected.AccountId,
                    expected.InstrumentId,
                    Type = expected.Type.ToString(),
                    Direction = expected.Direction.ToString(),
                    expected.Threshold,
                    expected.Enabled,
                    expected.ArmingRevision,
                    expected.TriggeredAt,
                    expected.TriggerValue,
                    expected.Acknowledged,
                    expected.CreatedAt,
                },
                new
                {
                    actual.Id,
                    actual.AccountId,
                    actual.InstrumentId,
                    actual.Type,
                    actual.Direction,
                    actual.Threshold,
                    actual.Enabled,
                    actual.ArmingRevision,
                    actual.TriggeredAt,
                    actual.TriggerValue,
                    actual.Acknowledged,
                    actual.CreatedAt,
                }
            );
        }

        // The known account with a balance; three known instruments, of which the account holds
        // one with a positive quantity and one at quantity 0. The unheld instrument is held only
        // by another account, so a holding check that ignored the account would accept it.
        private AlertService BuildFixtureService(Alert[] seeded)
        {
            return BuildService(
                [new Balance(AccountId, 1000)],
                [
                    new Instrument(HeldInstrumentId, ProductId, "HELD", "Held", "Held instrument"),
                    new Instrument(
                        ZeroQuantityInstrumentId,
                        ProductId,
                        "ZERO",
                        "Zero",
                        "Instrument held at quantity 0"
                    ),
                    new Instrument(
                        UnheldInstrumentId,
                        ProductId,
                        "UNHELD",
                        "Unheld",
                        "Instrument the account does not hold"
                    ),
                ],
                [
                    new OwnedInstrument(AccountId, HeldInstrumentId, 5, CreatedTime),
                    new OwnedInstrument(AccountId, ZeroQuantityInstrumentId, 0, CreatedTime),
                    new OwnedInstrument(OtherAccountId, UnheldInstrumentId, 7, CreatedTime),
                ],
                seeded
            );
        }

        private AlertService BuildService(
            Balance[] balances,
            Instrument[] instruments,
            OwnedInstrument[] owned,
            Alert[] seeded
        )
        {
            _balanceRepository = new FakeBalanceRepository([.. balances], []);
            _instrumentRepository = new FakeInstrumentRepository([.. instruments], [.. owned]);
            _alertRepository = new FakeAlertRepository();
            foreach (Alert alert in seeded)
            {
                _alertRepository.Seed(alert);
            }
            _logger = new RecordingLogger<AlertService>();
            return new AlertService(
                _alertRepository,
                _balanceRepository,
                _instrumentRepository,
                TimeProvider.System,
                _logger
            );
        }
    }
}
