using System.Globalization;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Service;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertTriggerRuleTests
    {
        // Thresholds and values are strings because attribute arguments cannot be decimals;
        // parsing them keeps every row exact, including the 10^-9 crossings beyond the 8-place
        // trigger-value scale. Near 9,000,000,000 a crossing of one step (0.00000001) or less
        // converts to the same double as the threshold, so those rows pass only when the
        // supplied threshold is compared as an exact decimal.
        [Theory]
        [InlineData(AlertDirection.ABOVE, "10", "10", false)]
        [InlineData(AlertDirection.ABOVE, "10", "10.00000001", true)]
        [InlineData(AlertDirection.ABOVE, "10", "9.99999999", false)]
        [InlineData(AlertDirection.ABOVE, "10", "10.000000001", true)]
        [InlineData(AlertDirection.BELOW, "10", "10", false)]
        [InlineData(AlertDirection.BELOW, "10", "10.00000001", false)]
        [InlineData(AlertDirection.BELOW, "10", "9.99999999", true)]
        [InlineData(AlertDirection.BELOW, "10", "9.999999999", true)]
        [InlineData(AlertDirection.ABOVE, "9000000000", "9000000000", false)]
        [InlineData(AlertDirection.ABOVE, "9000000000", "9000000000.00000001", true)]
        [InlineData(AlertDirection.ABOVE, "9000000000", "8999999999.99999999", false)]
        [InlineData(AlertDirection.ABOVE, "9000000000", "9000000000.000000001", true)]
        [InlineData(AlertDirection.BELOW, "9000000000", "9000000000", false)]
        [InlineData(AlertDirection.BELOW, "9000000000", "9000000000.00000001", false)]
        [InlineData(AlertDirection.BELOW, "9000000000", "8999999999.99999999", true)]
        [InlineData(AlertDirection.BELOW, "9000000000", "8999999999.999999999", true)]
        public void IsCrossed_ValueRelativeToThreshold_ShouldTriggerOnlyWhenStrictlyCrossed(
            AlertDirection direction,
            string threshold,
            string value,
            bool expected
        )
        {
            // Arrange
            decimal alertThreshold = decimal.Parse(threshold, CultureInfo.InvariantCulture);
            decimal observed = decimal.Parse(value, CultureInfo.InvariantCulture);

            // Act
            bool crossed = AlertTriggerRule.IsCrossed(direction, observed, alertThreshold);

            // Assert
            Assert.Equal(expected, crossed);
        }

        [Fact]
        public void IsCrossed_UndefinedDirection_ShouldThrowArgumentOutOfRange()
        {
            // Arrange
            const AlertDirection undefinedDirection = (AlertDirection)99;
            const decimal threshold = 10;
            const decimal observed = 11;

            // Act
            ArgumentOutOfRangeException exception = Assert.Throws<ArgumentOutOfRangeException>(
                () => AlertTriggerRule.IsCrossed(undefinedDirection, observed, threshold)
            );

            // Assert
            Assert.Equal("direction", exception.ParamName);
        }
    }
}
