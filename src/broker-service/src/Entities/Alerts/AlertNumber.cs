using System.Globalization;

namespace EasyTrade.BrokerService.Entities.Alerts
{
    /// <summary>
    /// The numeric domain of alert thresholds and trigger values, and their wire format.
    /// Decimals cross the db-adapter gRPC contract as normalised invariant strings, which
    /// db-adapter validates in <c>src/db-adapter/server/alert.go</c> with
    /// <c>^-?(0|[1-9][0-9]{0,9})(\.[0-9]{0,7}[1-9])?$</c> for thresholds and
    /// <c>^-?(0|[1-9][0-9]{0,19})(\.[0-9]{0,7}[1-9])?$</c> for trigger values.
    /// </summary>
    public static class AlertNumber
    {
        /// <summary>
        /// Largest threshold magnitude: 10 integer and 8 fractional digits, exactly what
        /// <c>DECIMAL(18, 8)</c> stores.
        /// </summary>
        public const decimal MaxThreshold = 9_999_999_999.99999999m;

        /// <summary>
        /// Largest trigger-value magnitude: 20 integer and 8 fractional digits (28 significant
        /// digits), which .NET <c>decimal</c> arithmetic holds exactly. Across gRPC and in
        /// db-adapter it stays decimal text, never a Go numeric type: db-adapter enforces its own
        /// equivalent of the trigger-value pattern in the class summary (the compiled
        /// <c>triggerValuePattern</c> in <c>src/db-adapter/server/alert.go</c>), passes the text
        /// unchanged as the SQL parameter, and <c>DECIMAL(28, 8)</c> stores it exactly.
        /// </summary>
        public const decimal MaxTriggerValue = 99_999_999_999_999_999_999.99999999m;

        public const int ThresholdIntegerDigits = 10;
        public const int FractionDigits = 8;
        public const int TriggerValueIntegerDigits = 20;

        private const NumberStyles WireStyles =
            NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint;

        // Sign, integer digits, point and fractional digits of the longest accepted threshold.
        private const int MaxNormalizedThresholdLength =
            1 + ThresholdIntegerDigits + 1 + FractionDigits;

        /// <summary>
        /// Reads the raw UTF-8 bytes of a JSON number token as a threshold, before any numeric
        /// conversion, so no value is rounded into the domain. Accepts only plain decimal form
        /// <c>-?(0|[1-9][0-9]*)(\.[0-9]+)?</c> with no exponent, and at most 10 integer and
        /// 8 fractional digits once trailing fractional zeros are removed.
        /// </summary>
        /// <param name="utf8Token">The token bytes, for example <c>1.500000000</c>.</param>
        /// <param name="value">The exact value, <c>1.5</c> for that example; 0 if rejected.</param>
        /// <returns>Whether the token is an exact in-domain threshold. Never throws.</returns>
        public static bool TryParseThresholdToken(ReadOnlySpan<byte> utf8Token, out decimal value)
        {
            value = 0m;
            int index = 0;
            bool negative = utf8Token.Length > 0 && utf8Token[0] == (byte)'-';
            if (negative)
            {
                index++;
            }

            int integerStart = index;
            if (index >= utf8Token.Length || !IsAsciiDigit(utf8Token[index]))
            {
                return false;
            }

            if (utf8Token[index] == (byte)'0')
            {
                index++;
            }
            else
            {
                while (index < utf8Token.Length && IsAsciiDigit(utf8Token[index]))
                {
                    index++;
                    if (index - integerStart > ThresholdIntegerDigits)
                    {
                        return false;
                    }
                }
            }

            int integerEnd = index;
            int fractionStart = index;
            int fractionEnd = index;
            if (index < utf8Token.Length)
            {
                // Rejects a leading zero followed by a digit, an exponent and any other byte.
                if (utf8Token[index] != (byte)'.')
                {
                    return false;
                }

                index++;
                fractionStart = index;
                while (index < utf8Token.Length && IsAsciiDigit(utf8Token[index]))
                {
                    index++;
                }

                if (index == fractionStart || index != utf8Token.Length)
                {
                    return false;
                }

                // Trailing zeros carry no value, so 1.500000000 stays in the domain while
                // 0.000000010000000000000000000001 does not.
                fractionEnd = index;
                while (fractionEnd > fractionStart && utf8Token[fractionEnd - 1] == (byte)'0')
                {
                    fractionEnd--;
                }

                if (fractionEnd - fractionStart > FractionDigits)
                {
                    return false;
                }
            }

            Span<char> text = stackalloc char[MaxNormalizedThresholdLength];
            int length = 0;
            if (negative)
            {
                text[length++] = '-';
            }

            for (int i = integerStart; i < integerEnd; i++)
            {
                text[length++] = (char)utf8Token[i];
            }

            if (fractionEnd > fractionStart)
            {
                text[length++] = '.';
                for (int i = fractionStart; i < fractionEnd; i++)
                {
                    text[length++] = (char)utf8Token[i];
                }
            }

            // Cannot throw: the guards above bound the text to an optional '-', at most 10 integer
            // and 8 fractional ASCII digits, always a valid in-range decimal, so neither
            // FormatException nor OverflowException can occur.
            decimal parsed = decimal.Parse(
                text[..length],
                WireStyles,
                CultureInfo.InvariantCulture
            );

            // -0 and -0.0 become plain zero.
            value = parsed == 0m ? 0m : parsed;
            return true;
        }

        /// <summary>
        /// Whether <paramref name="value"/> fits <c>DECIMAL(18, 8)</c> without rounding:
        /// a magnitude of at most <see cref="MaxThreshold"/> and at most 8 fractional digits.
        /// </summary>
        public static bool IsInThresholdDomain(decimal value)
        {
            return Math.Abs(value) <= MaxThreshold && Math.Round(value, FractionDigits) == value;
        }

        /// <summary>
        /// Whether <paramref name="value"/> is a valid threshold for <paramref name="type"/>:
        /// in the threshold domain, and greater than zero for <see cref="AlertType.TARGET_PRICE"/>.
        /// <see cref="AlertType.PROFIT_LOSS"/> allows zero and negative percentages.
        /// An undefined type is never valid.
        /// </summary>
        public static bool IsValidThreshold(AlertType type, decimal value)
        {
            bool allowedForType = type switch
            {
                AlertType.TARGET_PRICE => value > 0m,
                AlertType.PROFIT_LOSS => true,
                _ => false,
            };
            return allowedForType && IsInThresholdDomain(value);
        }

        /// <summary>
        /// Rounds an observed value to the 8 fractional digits a trigger value is stored with,
        /// midpoints away from zero (<c>1.000000005</c> becomes <c>1.00000001</c>).
        /// </summary>
        public static decimal RoundTriggerValue(decimal value)
        {
            return Math.Round(value, FractionDigits, MidpointRounding.AwayFromZero);
        }

        /// <summary>
        /// Whether <paramref name="value"/> fits <c>DECIMAL(28, 8)</c> without rounding:
        /// at most <see cref="TriggerValueIntegerDigits"/> integer digits
        /// (<see cref="MaxTriggerValue"/>) and at most 8 fractional digits.
        /// </summary>
        public static bool IsValidTriggerValue(decimal value)
        {
            return Math.Abs(value) <= MaxTriggerValue && Math.Round(value, FractionDigits) == value;
        }

        /// <summary>
        /// Writes the normalised wire form: invariant culture, no exponent, no group separators,
        /// no trailing fractional zeros, and <c>"0"</c> for any zero, so <c>1.500000000</c>
        /// travels as <c>"1.5"</c>. Pass only in-domain values, either validated thresholds or
        /// values already passed through <see cref="RoundTriggerValue"/>: the format rounds any
        /// digit beyond the eighth fractional place.
        /// </summary>
        public static string ToWire(decimal value)
        {
            // A negative zero would otherwise be written as "-0".
            if (value == 0m)
            {
                return "0";
            }

            return value.ToString("0.########", CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Reads a wire decimal with invariant culture. A missing value never defaults to 0.
        /// </summary>
        /// <exception cref="FormatException">
        /// <paramref name="text"/> is null, empty or not a plain decimal.
        /// </exception>
        public static decimal FromWire(string? text)
        {
            if (string.IsNullOrEmpty(text))
            {
                throw new FormatException("The wire decimal is empty; a value is required.");
            }

            return decimal.Parse(text, WireStyles, CultureInfo.InvariantCulture);
        }

        private static bool IsAsciiDigit(byte character)
        {
            return character >= (byte)'0' && character <= (byte)'9';
        }
    }
}
