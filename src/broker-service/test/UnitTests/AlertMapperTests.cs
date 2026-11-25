using System.Globalization;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using Google.Protobuf.WellKnownTypes;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertMapperTests
    {
        private static readonly Guid FixedAlertId = new("e0000000-0000-4000-8000-000000000001");
        private static readonly Guid FixedAccountId = new("a0000000-0000-4000-8000-000000000000");
        private static readonly Guid FixedInstrumentId = new(
            "c0000000-0000-4000-8000-000000000001"
        );

        // Tick-precise UTC instants: a Timestamp round trip must keep every 100 ns tick.
        private static readonly DateTimeOffset CreatedTime = DateTimeOffset.Parse(
            "2025-03-14T09:26:53.5891234+00:00",
            CultureInfo.InvariantCulture
        );
        private static readonly DateTimeOffset TriggerTime = DateTimeOffset.Parse(
            "2025-03-14T10:00:07.1250001+00:00",
            CultureInfo.InvariantCulture
        );

        private static readonly Alert TriggeredAlert = new(
            Id: FixedAlertId,
            AccountId: FixedAccountId,
            InstrumentId: FixedInstrumentId,
            Type: AlertType.PROFIT_LOSS,
            Direction: AlertDirection.BELOW,
            Threshold: -2.5m,
            Enabled: true,
            ArmingRevision: 3,
            TriggeredAt: TriggerTime,
            TriggerValue: -3.12345678m,
            Acknowledged: true,
            CreatedAt: CreatedTime
        );

        private static readonly Alert UntriggeredAlert = new(
            Id: FixedAlertId,
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
            CreatedAt: CreatedTime
        );

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum ProtoCase
        {
            Triggered,
            Untriggered,
            TriggeredAtWithoutValue,
            TriggerValueWithoutTriggeredAt,
            EmptyThreshold,
            InexactType,
            InexactDirection,
            MissingCreatedAt,
        }

        [Theory]
        [InlineData(ProtoCase.Triggered)]
        [InlineData(ProtoCase.Untriggered)]
        [InlineData(ProtoCase.TriggeredAtWithoutValue)]
        [InlineData(ProtoCase.TriggerValueWithoutTriggeredAt)]
        [InlineData(ProtoCase.EmptyThreshold)]
        [InlineData(ProtoCase.InexactType)]
        [InlineData(ProtoCase.InexactDirection)]
        [InlineData(ProtoCase.MissingCreatedAt)]
        public void FromProto_Alert_ShouldMapFields(ProtoCase protoCase)
        {
            // Arrange
            (AlertGrpc.AlertMessage message, Alert? expected) = BuildCase(protoCase);

            // Act
            Alert? mapped = null;
            Exception? error = Record.Exception(() => mapped = AlertMapper.FromProto(message));

            // Assert
            if (expected is null)
            {
                Assert.IsType<FormatException>(error);
            }
            else
            {
                Assert.Null(error);
                Assert.Equal(expected, mapped);
            }
        }

        [Fact]
        public void FromProto_MessageList_ShouldMapEachInOrder()
        {
            // Arrange
            AlertGrpc.AlertMessage[] messages = [TriggeredMessage(), UntriggeredMessage()];
            Alert[] expected = [TriggeredAlert, UntriggeredAlert];

            // Act
            List<Alert> alerts = AlertMapper.FromProto(messages);

            // Assert
            Assert.Equal(expected, alerts);
        }

        [Theory]
        [InlineData(AlertType.TARGET_PRICE, AlertDirection.ABOVE, "TARGET_PRICE", "ABOVE")]
        [InlineData(AlertType.PROFIT_LOSS, AlertDirection.BELOW, "PROFIT_LOSS", "BELOW")]
        public void ToDto_Alert_ShouldUseEnumNames(
            AlertType type,
            AlertDirection direction,
            string expectedType,
            string expectedDirection
        )
        {
            // Arrange
            // Domain-maximum decimals and non-default flags, so a dropped or rounded field shows.
            Alert alert = new(
                Id: FixedAlertId,
                AccountId: FixedAccountId,
                InstrumentId: FixedInstrumentId,
                Type: type,
                Direction: direction,
                Threshold: AlertNumber.MaxThreshold,
                Enabled: true,
                ArmingRevision: 2,
                TriggeredAt: TriggerTime,
                TriggerValue: AlertNumber.MaxTriggerValue,
                Acknowledged: true,
                CreatedAt: CreatedTime
            );

            // Act
            AlertDTO dto = AlertMapper.ToDto(alert);

            // Assert
            Assert.Equal(expectedType, dto.Type);
            Assert.Equal(expectedDirection, dto.Direction);
            Assert.Equal(alert.Id, dto.Id);
            Assert.Equal(alert.AccountId, dto.AccountId);
            Assert.Equal(alert.InstrumentId, dto.InstrumentId);
            Assert.Equal(alert.Threshold, dto.Threshold);
            Assert.Equal(alert.Enabled, dto.Enabled);
            Assert.Equal(alert.ArmingRevision, dto.ArmingRevision);
            Assert.Equal(alert.TriggeredAt, dto.TriggeredAt);
            Assert.Equal(alert.TriggerValue, dto.TriggerValue);
            Assert.Equal(alert.Acknowledged, dto.Acknowledged);
            Assert.Equal(alert.CreatedAt, dto.CreatedAt);
        }

        // Thresholds are strings because attribute arguments cannot be decimals; parsing keeps
        // the trailing zeros, which the wire form must drop.
        [Theory]
        [InlineData(
            AlertType.TARGET_PRICE,
            AlertDirection.ABOVE,
            "1.500000000",
            "TARGET_PRICE",
            "ABOVE",
            "1.5"
        )]
        [InlineData(
            AlertType.PROFIT_LOSS,
            AlertDirection.BELOW,
            "-2.50",
            "PROFIT_LOSS",
            "BELOW",
            "-2.5"
        )]
        public void ToCreateRequest_Values_ShouldUseExactNamesAndNormalizedThreshold(
            AlertType type,
            AlertDirection direction,
            string threshold,
            string expectedType,
            string expectedDirection,
            string expectedThreshold
        )
        {
            // Arrange
            decimal value = decimal.Parse(threshold, CultureInfo.InvariantCulture);
            AlertGrpc.CreateAlertRequest expected = new()
            {
                AccountId = FixedAccountId.ToString(),
                Type = expectedType,
                InstrumentId = FixedInstrumentId.ToString(),
                Direction = expectedDirection,
                Threshold = expectedThreshold,
            };

            // Act
            AlertGrpc.CreateAlertRequest request = AlertMapper.ToCreateRequest(
                FixedAccountId,
                type,
                FixedInstrumentId,
                direction,
                value
            );

            // Assert
            Assert.Equal(expected, request);
        }

        [Fact]
        public void ToName_UndefinedEnumValue_ShouldThrowArgumentOutOfRange()
        {
            // Arrange
            const AlertType undefinedType = (AlertType)99;
            const AlertDirection undefinedDirection = (AlertDirection)99;

            // Act and Assert
            Assert.Throws<ArgumentOutOfRangeException>(() => AlertMapper.ToName(undefinedType));
            Assert.Throws<ArgumentOutOfRangeException>(
                () => AlertMapper.ToName(undefinedDirection)
            );
        }

        // A null expected alert means the mapping must reject the message.
        private static (AlertGrpc.AlertMessage Message, Alert? Expected) BuildCase(
            ProtoCase protoCase
        )
        {
            AlertGrpc.AlertMessage message = UntriggeredMessage();
            switch (protoCase)
            {
                case ProtoCase.Triggered:
                    return (TriggeredMessage(), TriggeredAlert);
                case ProtoCase.Untriggered:
                    return (message, UntriggeredAlert);
                case ProtoCase.TriggeredAtWithoutValue:
                    // db-adapter sets and clears both trigger fields together, so a reply with
                    // only one of them is malformed and must not read as untriggered.
                    message.TriggeredAt = Timestamp.FromDateTimeOffset(TriggerTime);
                    return (message, null);
                case ProtoCase.TriggerValueWithoutTriggeredAt:
                    message.TriggerValue = "-3.12345678";
                    return (message, null);
                case ProtoCase.EmptyThreshold:
                    message.Threshold = "";
                    return (message, null);
                case ProtoCase.InexactType:
                    message.Type = "target_price";
                    return (message, null);
                case ProtoCase.InexactDirection:
                    message.Direction = "above";
                    return (message, null);
                case ProtoCase.MissingCreatedAt:
                    message.CreatedAt = null;
                    return (message, null);
                default:
                    throw new ArgumentOutOfRangeException(nameof(protoCase), protoCase, null);
            }
        }

        private static AlertGrpc.AlertMessage TriggeredMessage()
        {
            return new AlertGrpc.AlertMessage
            {
                Id = FixedAlertId.ToString(),
                AccountId = FixedAccountId.ToString(),
                Type = "PROFIT_LOSS",
                InstrumentId = FixedInstrumentId.ToString(),
                Direction = "BELOW",
                Threshold = "-2.5",
                Enabled = true,
                ArmingRevision = 3,
                TriggeredAt = Timestamp.FromDateTimeOffset(TriggerTime),
                TriggerValue = "-3.12345678",
                Acknowledged = true,
                CreatedAt = Timestamp.FromDateTimeOffset(CreatedTime),
            };
        }

        // The wire form of an arming that has not triggered: triggered_at unset and an empty
        // trigger_value.
        private static AlertGrpc.AlertMessage UntriggeredMessage()
        {
            return new AlertGrpc.AlertMessage
            {
                Id = FixedAlertId.ToString(),
                AccountId = FixedAccountId.ToString(),
                Type = "TARGET_PRICE",
                InstrumentId = FixedInstrumentId.ToString(),
                Direction = "ABOVE",
                Threshold = "105.25",
                Enabled = true,
                ArmingRevision = 1,
                TriggerValue = "",
                Acknowledged = false,
                CreatedAt = Timestamp.FromDateTimeOffset(CreatedTime),
            };
        }
    }
}
