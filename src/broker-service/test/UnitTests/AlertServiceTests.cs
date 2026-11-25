using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Test.Fakes;
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
                _logger
            );
        }
    }
}
