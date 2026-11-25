using EasyTrade.BrokerService.Entities.Alerts.DTO;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;

namespace EasyTrade.BrokerService.Entities.Alerts.Repository
{
    /// <summary>
    /// The only translation between db-adapter's alert messages, the <see cref="Alert"/> domain
    /// record and <see cref="AlertDTO"/>. Enum values cross both boundaries as their exact,
    /// case-sensitive names, and decimals cross gRPC only through <see cref="AlertNumber"/>.
    /// </summary>
    public static class AlertMapper
    {
        /// <summary>
        /// Reads an exact alert type name. Ordinal and case-sensitive, unlike
        /// <c>Enum.TryParse</c>, which would also accept <c>"target_price"</c> or <c>"0"</c>.
        /// </summary>
        /// <returns>Whether <paramref name="value"/> is <c>TARGET_PRICE</c> or
        /// <c>PROFIT_LOSS</c>.</returns>
        public static bool TryParseType(string? value, out AlertType type)
        {
            switch (value)
            {
                case "TARGET_PRICE":
                    type = AlertType.TARGET_PRICE;
                    return true;
                case "PROFIT_LOSS":
                    type = AlertType.PROFIT_LOSS;
                    return true;
                default:
                    type = default;
                    return false;
            }
        }

        /// <summary>Reads an exact, case-sensitive alert direction name.</summary>
        /// <returns>Whether <paramref name="value"/> is <c>ABOVE</c> or <c>BELOW</c>.</returns>
        public static bool TryParseDirection(string? value, out AlertDirection direction)
        {
            switch (value)
            {
                case "ABOVE":
                    direction = AlertDirection.ABOVE;
                    return true;
                case "BELOW":
                    direction = AlertDirection.BELOW;
                    return true;
                default:
                    direction = default;
                    return false;
            }
        }

        /// <summary>The exact wire and JSON name of <paramref name="type"/>.</summary>
        /// <exception cref="ArgumentOutOfRangeException">
        /// The value is not a defined type.
        /// </exception>
        public static string ToName(AlertType type)
        {
            return type switch
            {
                AlertType.TARGET_PRICE => "TARGET_PRICE",
                AlertType.PROFIT_LOSS => "PROFIT_LOSS",
                _ => throw new ArgumentOutOfRangeException(
                    nameof(type),
                    type,
                    "Undefined alert type."
                ),
            };
        }

        /// <summary>The exact wire and JSON name of <paramref name="direction"/>.</summary>
        /// <exception cref="ArgumentOutOfRangeException">
        /// The value is not a defined direction.
        /// </exception>
        public static string ToName(AlertDirection direction)
        {
            return direction switch
            {
                AlertDirection.ABOVE => "ABOVE",
                AlertDirection.BELOW => "BELOW",
                _ => throw new ArgumentOutOfRangeException(
                    nameof(direction),
                    direction,
                    "Undefined alert direction."
                ),
            };
        }

        /// <summary>
        /// Maps one db-adapter alert. The trigger fields are set only when the message carries
        /// both a <c>triggered_at</c> and a non-empty <c>trigger_value</c>; otherwise both are
        /// null, because either one missing means the current arming has not triggered.
        /// </summary>
        /// <exception cref="FormatException">
        /// An id, enum name or decimal is malformed, the threshold is empty, or
        /// <c>created_at</c> is unset.
        /// </exception>
        public static Alert FromProto(AlertGrpc.AlertMessage message)
        {
            if (!TryParseType(message.Type, out AlertType type))
            {
                throw new FormatException($"Unknown alert type [{message.Type}].");
            }

            if (!TryParseDirection(message.Direction, out AlertDirection direction))
            {
                throw new FormatException($"Unknown alert direction [{message.Direction}].");
            }

            DateTimeOffset? triggeredAt = null;
            decimal? triggerValue = null;
            if (message.TriggeredAt is not null && !string.IsNullOrEmpty(message.TriggerValue))
            {
                triggeredAt = message.TriggeredAt.ToDateTimeOffset();
                triggerValue = AlertNumber.FromWire(message.TriggerValue);
            }

            DateTimeOffset createdAt =
                message.CreatedAt?.ToDateTimeOffset()
                ?? throw new FormatException($"Alert [{message.Id}] has no created_at.");

            return new Alert(
                Id: Guid.Parse(message.Id),
                AccountId: Guid.Parse(message.AccountId),
                InstrumentId: Guid.Parse(message.InstrumentId),
                Type: type,
                Direction: direction,
                Threshold: AlertNumber.FromWire(message.Threshold),
                Enabled: message.Enabled,
                ArmingRevision: message.ArmingRevision,
                TriggeredAt: triggeredAt,
                TriggerValue: triggerValue,
                Acknowledged: message.Acknowledged,
                CreatedAt: createdAt
            );
        }

        /// <summary>Maps every message, keeping db-adapter's order.</summary>
        public static List<Alert> FromProto(IEnumerable<AlertGrpc.AlertMessage> messages)
        {
            return [.. messages.Select(FromProto)];
        }

        /// <summary>
        /// Builds the create request with exact enum names and the normalised threshold text.
        /// </summary>
        public static AlertGrpc.CreateAlertRequest ToCreateRequest(
            Guid accountId,
            AlertType type,
            Guid instrumentId,
            AlertDirection direction,
            decimal threshold
        )
        {
            return new AlertGrpc.CreateAlertRequest
            {
                AccountId = accountId.ToString(),
                Type = ToName(type),
                InstrumentId = instrumentId.ToString(),
                Direction = ToName(direction),
                Threshold = AlertNumber.ToWire(threshold),
            };
        }

        /// <summary>Copies every field into the REST shape, without rounding.</summary>
        public static AlertDTO ToDto(Alert alert)
        {
            return new AlertDTO(
                id: alert.Id,
                accountId: alert.AccountId,
                instrumentId: alert.InstrumentId,
                type: ToName(alert.Type),
                direction: ToName(alert.Direction),
                threshold: alert.Threshold,
                enabled: alert.Enabled,
                armingRevision: alert.ArmingRevision,
                triggeredAt: alert.TriggeredAt,
                triggerValue: alert.TriggerValue,
                acknowledged: alert.Acknowledged,
                createdAt: alert.CreatedAt
            );
        }
    }
}
