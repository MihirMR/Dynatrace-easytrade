using System.Globalization;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Alerts.Service;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class AlertTriggerRuleTests
    {
        // Values are strings because attribute arguments cannot be decimals; parsing them keeps
        // every row exact, including the 10^-9 crossings beyond the 8-place trigger-value scale.
        [Theory]
        [InlineData(AlertDirection.ABOVE, "10", false)]
        [InlineData(AlertDirection.ABOVE, "10.00000001", true)]
        [InlineData(AlertDirection.ABOVE, "9.99999999", false)]
        [InlineData(AlertDirection.ABOVE, "10.000000001", true)]
        [InlineData(AlertDirection.BELOW, "10", false)]
        [InlineData(AlertDirection.BELOW, "10.00000001", false)]
        [InlineData(AlertDirection.BELOW, "9.99999999", true)]
        [InlineData(AlertDirection.BELOW, "9.999999999", true)]
        public void IsCrossed_ValueRelativeToThreshold_ShouldTriggerOnlyWhenStrictlyCrossed(
            AlertDirection direction,
            string value,
            bool expected
        )
        {
            // Arrange
            const decimal threshold = 10;
            decimal observed = decimal.Parse(value, CultureInfo.InvariantCulture);

            // Act
            bool crossed = AlertTriggerRule.IsCrossed(direction, observed, threshold);

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
