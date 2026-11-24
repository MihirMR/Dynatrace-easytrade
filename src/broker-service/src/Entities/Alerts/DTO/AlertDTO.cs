namespace EasyTrade.BrokerService.Entities.Alerts.DTO
{
    /// <summary>
    /// REST representation of one alert, also used for every notification.
    /// Type and Direction carry the exact enum names produced by AlertMapper.ToName;
    /// this class performs no conversion.
    /// </summary>
    public class AlertDTO(
        Guid id,
        Guid accountId,
        Guid instrumentId,
        string type,
        string direction,
        decimal threshold,
        bool enabled,
        int armingRevision,
        DateTimeOffset? triggeredAt,
        decimal? triggerValue,
        bool acknowledged,
        DateTimeOffset createdAt
    )
    {
        public Guid Id { get; set; } = id;
        public Guid AccountId { get; set; } = accountId;
        public Guid InstrumentId { get; set; } = instrumentId;
        public string Type { get; set; } = type;
        public string Direction { get; set; } = direction;
        public decimal Threshold { get; set; } = threshold;
        public bool Enabled { get; set; } = enabled;
        public int ArmingRevision { get; set; } = armingRevision;
        public DateTimeOffset? TriggeredAt { get; set; } = triggeredAt;
        public decimal? TriggerValue { get; set; } = triggerValue;
        public bool Acknowledged { get; set; } = acknowledged;
        public DateTimeOffset CreatedAt { get; set; } = createdAt;
    }
}
