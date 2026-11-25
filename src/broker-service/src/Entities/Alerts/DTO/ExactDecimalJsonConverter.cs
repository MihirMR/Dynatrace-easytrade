using System.Buffers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace EasyTrade.BrokerService.Entities.Alerts.DTO
{
    /// <summary>
    /// Binds an alert threshold from the raw JSON number token, before any numeric conversion,
    /// so no value is ever rounded into the threshold domain. Only a JSON number in plain decimal
    /// form within that domain is accepted; a quoted number, a boolean, an exponent or an
    /// out-of-domain token throws <see cref="JsonException"/>, which MVC binding turns into a 400.
    /// The grammar and the domain are owned by <see cref="AlertNumber.TryParseThresholdToken"/>.
    /// Writes the normalised number token of <see cref="AlertNumber.ToWire"/>, never a string.
    /// </summary>
    public class ExactDecimalJsonConverter : JsonConverter<decimal?>
    {
        private const string NotANumberMessage =
            "The threshold must be a JSON number in plain decimal form.";

        private static readonly string OutOfDomainMessage =
            "The threshold must be a plain decimal without exponent, with at most "
            + $"{AlertNumber.ThresholdIntegerDigits} integer and "
            + $"{AlertNumber.FractionDigits} fractional digits.";

        public override decimal? Read(
            ref Utf8JsonReader reader,
            Type typeToConvert,
            JsonSerializerOptions options
        )
        {
            if (reader.TokenType == JsonTokenType.Null)
            {
                return null;
            }

            // Strings are rejected even with AllowReadingFromString, which the web defaults set
            // but which applies only to built-in converters.
            if (reader.TokenType != JsonTokenType.Number)
            {
                throw new JsonException(NotANumberMessage);
            }

            // The raw token bytes, never GetDecimal or GetDouble: both would round an
            // over-precision token such as 0.000000010000000000000000000001 into the domain.
            ReadOnlySpan<byte> raw = reader.HasValueSequence
                ? reader.ValueSequence.ToArray()
                : reader.ValueSpan;
            if (!AlertNumber.TryParseThresholdToken(raw, out decimal value))
            {
                throw new JsonException(OutOfDomainMessage);
            }

            return value;
        }

        public override void Write(
            Utf8JsonWriter writer,
            decimal? value,
            JsonSerializerOptions options
        )
        {
            if (value is null)
            {
                writer.WriteNullValue();
                return;
            }

            writer.WriteRawValue(AlertNumber.ToWire(value.Value));
        }
    }
}
