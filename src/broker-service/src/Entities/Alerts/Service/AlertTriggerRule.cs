namespace EasyTrade.BrokerService.Entities.Alerts.Service
{
    /// <summary>
    /// Decides whether an armed alert is crossed by an observed value. This is the only place the
    /// trigger comparison is made.
    /// </summary>
    public static class AlertTriggerRule
    {
        /// <summary>
        /// Returns whether <paramref name="value"/> strictly crosses <paramref name="threshold"/>
        /// in <paramref name="direction"/>: <see cref="AlertDirection.ABOVE"/> when the value is
        /// greater than the threshold, <see cref="AlertDirection.BELOW"/> when it is less.
        /// Equality never triggers in either direction.
        /// </summary>
        /// <remarks>
        /// The comparison is exact <see cref="decimal"/> arithmetic on the unrounded observed
        /// value. The stored trigger value is rounded to 8 places only after this decision, so a
        /// crossing such as 10.000000001 above 10 still triggers.
        /// </remarks>
        /// <param name="direction">The alert's direction.</param>
        /// <param name="value">The unrounded observed price or P/L percent.</param>
        /// <param name="threshold">The alert's threshold.</param>
        /// <returns><c>true</c> when the alert is crossed; otherwise <c>false</c>.</returns>
        /// <exception cref="ArgumentOutOfRangeException">
        /// <paramref name="direction"/> is not a defined <see cref="AlertDirection"/>.
        /// </exception>
        public static bool IsCrossed(AlertDirection direction, decimal value, decimal threshold)
        {
            return direction switch
            {
                AlertDirection.ABOVE => value > threshold,
                AlertDirection.BELOW => value < threshold,
                _ => throw new ArgumentOutOfRangeException(
                    nameof(direction),
                    direction,
                    "Unknown alert direction"
                ),
            };
        }
    }
}
