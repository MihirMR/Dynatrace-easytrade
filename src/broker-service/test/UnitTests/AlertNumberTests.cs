using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertNumberTests
    {
        // The defaults MVC binds request bodies with.
        private static readonly JsonSerializerOptions WireOptions = new(JsonSerializerDefaults.Web);

        private static readonly ExactDecimalJsonConverter Converter = new();

        private static readonly Guid FixedAccountId = new("a0000000-0000-4000-8000-000000000000");
        private static readonly Guid FixedInstrumentId = new(
            "c0000000-0000-4000-8000-000000000001"
        );

        // Called directly, because the JSON reader rejects each of these before the converter runs.
        [Theory]
        [InlineData("")]
        [InlineData("-")]
        [InlineData("01")]
        [InlineData("-01")]
        [InlineData("00")]
        [InlineData("1.")]
        [InlineData("-1.")]
        [InlineData("0.")]
        [InlineData(".5")]
        [InlineData("-.5")]
        public void TryParseThresholdToken_MalformedToken_ShouldReject(string token)
        {
            // Arrange
            byte[] utf8Token = Encoding.UTF8.GetBytes(token);

            // Act
            bool accepted = AlertNumber.TryParseThresholdToken(utf8Token, out _);

            // Assert
            Assert.False(accepted);
        }

        // Values are strings because attribute arguments cannot be decimals; parsing them keeps
        // every row exact. Trailing fractional zeros are removed before the 8-digit limit applies,
        // even more of them than a decimal can hold.
        [Theory]
        [InlineData("5.0", "5")]
        [InlineData("5.000000000000000000000000000000000000", "5")]
        [InlineData("9999999999.99999999000000000000000000000", "9999999999.99999999")]
        [InlineData("-0.1000000000000000000000000000000", "-0.1")]
        public void TryParseThresholdToken_ZeroPaddedFraction_ShouldAcceptExactValue(
            string token,
            string expected
        )
        {
            // Arrange
            byte[] utf8Token = Encoding.UTF8.GetBytes(token);
            decimal expectedValue = decimal.Parse(expected, CultureInfo.InvariantCulture);

            // Act
            bool accepted = AlertNumber.TryParseThresholdToken(utf8Token, out decimal value);

            // Assert
            Assert.Equal((true, expectedValue), (accepted, value));
        }

        // Canonical zero has no sign bit and scale 0; decimal equality alone cannot tell it apart
        // from -0 or 0.000.
        [Theory]
        [InlineData("0")]
        [InlineData("-0")]
        [InlineData("-0.0")]
        [InlineData("0.000")]
        [InlineData("-0.00000000000")]
        public void TryParseThresholdToken_ZeroToken_ShouldReturnCanonicalZero(string token)
        {
            // Arrange
            byte[] utf8Token = Encoding.UTF8.GetBytes(token);

            // Act
            bool accepted = AlertNumber.TryParseThresholdToken(utf8Token, out decimal value);

            // Assert
            Assert.Equal(
                (true, 0m, (byte)0, false),
                (accepted, value, value.Scale, decimal.IsNegative(value))
            );
        }

        [Theory]
        [InlineData("-0")]
        [InlineData("-0.000")]
        [InlineData("0.000")]
        public void ToCreateRequest_ParsedZeroToken_ShouldSendCanonicalZero(string token)
        {
            // Arrange
            bool accepted = AlertNumber.TryParseThresholdToken(
                Encoding.UTF8.GetBytes(token),
                out decimal threshold
            );

            // Act
            string wireThreshold = AlertMapper
                .ToCreateRequest(
                    FixedAccountId,
                    AlertType.PROFIT_LOSS,
                    FixedInstrumentId,
                    AlertDirection.ABOVE,
                    threshold
                )
                .Threshold;

            // Assert
            Assert.Equal((true, "0"), (accepted, wireThreshold));
        }

        [Theory]
        [InlineData("-0")]
        [InlineData("-0.000")]
        [InlineData("0.000")]
        public void Serialize_BoundZeroThreshold_ShouldWriteCanonicalZero(string token)
        {
            // Arrange
            CreateAlertDTO? bound = JsonSerializer.Deserialize<CreateAlertDTO>(
                "{\"threshold\":" + token + "}",
                WireOptions
            );

            // Act
            string json = JsonSerializer.Serialize(bound, WireOptions);
            using JsonDocument written = JsonDocument.Parse(json);
            string rawThreshold = written.RootElement.GetProperty("threshold").GetRawText();

            // Assert
            Assert.Equal("0", rawThreshold);
        }

        [Theory]
        [InlineData("9999999999.99999999")]
        [InlineData("-9999999999.99999999")]
        [InlineData("0.00000001")]
        public void Deserialize_SegmentedBoundaryThreshold_ShouldBindExactly(string number)
        {
            // Arrange
            decimal expected = decimal.Parse(number, CultureInfo.InvariantCulture);
            Utf8JsonReader reader = new(SplitInsideThreshold(number));

            // Act
            CreateAlertDTO? bound = JsonSerializer.Deserialize<CreateAlertDTO>(
                ref reader,
                WireOptions
            );

            // Assert
            Assert.Equal(expected, bound?.Threshold);
        }

        // An over-precision token that a decimal conversion would round to the valid 0.00000001,
        // and one integer digit beyond the domain.
        [Theory]
        [InlineData("0.000000010000000000000000000001")]
        [InlineData("10000000000")]
        public void Deserialize_SegmentedOutOfDomainThreshold_ShouldThrowJsonException(
            string number
        )
        {
            // Arrange
            ReadOnlySequence<byte> body = SplitInsideThreshold(number);

            // Act and Assert
            Assert.Throws<JsonException>(() =>
            {
                Utf8JsonReader reader = new(body);
                _ = JsonSerializer.Deserialize<CreateAlertDTO>(ref reader, WireOptions);
            });
        }

        // The serializer never hands a null token to this converter, so only a direct call
        // reaches its null branch.
        [Fact]
        public void Read_NullToken_ShouldReturnNull()
        {
            // Arrange
            Utf8JsonReader reader = new("null"u8);
            reader.Read();

            // Act
            decimal? value = Converter.Read(ref reader, typeof(decimal?), WireOptions);

            // Assert
            Assert.Null(value);
        }

        [Fact]
        public void Deserialize_ExplicitNullThreshold_ShouldBindNull()
        {
            // Arrange
            const string body = "{\"threshold\":null}";

            // Act
            CreateAlertDTO? bound = JsonSerializer.Deserialize<CreateAlertDTO>(body, WireOptions);

            // Assert
            Assert.Null(bound!.Threshold);
        }

        // A null row writes the JSON null literal; every other row a number token, never a string.
        [Theory]
        [InlineData("1.500000000", "1.5")]
        [InlineData("-9999999999.99999999", "-9999999999.99999999")]
        [InlineData("0.00000001", "0.00000001")]
        [InlineData("0.000", "0")]
        [InlineData(null, "null")]
        public void Write_Value_ShouldWriteCanonicalUnquotedToken(string? value, string expected)
        {
            // Arrange
            decimal? threshold = value is null
                ? null
                : decimal.Parse(value, CultureInfo.InvariantCulture);
            ArrayBufferWriter<byte> buffer = new();
            using Utf8JsonWriter writer = new(buffer);

            // Act
            Converter.Write(writer, threshold, WireOptions);
            writer.Flush();

            // Assert
            Assert.Equal(expected, Encoding.UTF8.GetString(buffer.WrittenSpan));
        }

        // Builds {"threshold":<number>} as three segments that cut the number text twice, so its
        // token spans every segment and the reader exposes it only through ValueSequence.
        private static ReadOnlySequence<byte> SplitInsideThreshold(string number)
        {
            if (number.Length < 3)
            {
                throw new ArgumentException(
                    "Cutting the number twice needs at least 3 characters.",
                    nameof(number)
                );
            }

            int firstCut = number.Length / 3;
            int secondCut = (2 * number.Length) / 3;
            BufferSegment first = new(
                Encoding.UTF8.GetBytes("{\"threshold\":" + number[..firstCut])
            );
            BufferSegment last = first
                .Append(Encoding.UTF8.GetBytes(number[firstCut..secondCut]))
                .Append(Encoding.UTF8.GetBytes(number[secondCut..] + "}"));
            ReadOnlySequence<byte> body = new(first, 0, last, last.Memory.Length);

            // A token inside one segment would let a reader of ValueSpan alone pass.
            Utf8JsonReader probe = new(body);
            bool numberSpansSegments = false;
            while (probe.Read())
            {
                if (probe.TokenType == JsonTokenType.Number)
                {
                    numberSpansSegments = probe.HasValueSequence;
                }
            }

            if (!numberSpansSegments)
            {
                throw new InvalidOperationException("The threshold token must span the segments.");
            }

            return body;
        }

        private sealed class BufferSegment : ReadOnlySequenceSegment<byte>
        {
            public BufferSegment(ReadOnlyMemory<byte> memory)
            {
                Memory = memory;
            }

            public BufferSegment Append(ReadOnlyMemory<byte> memory)
            {
                BufferSegment next = new(memory) { RunningIndex = RunningIndex + Memory.Length };
                Next = next;
                return next;
            }
        }
    }
}
