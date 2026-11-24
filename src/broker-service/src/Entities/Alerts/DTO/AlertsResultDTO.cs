namespace EasyTrade.BrokerService.Entities.Alerts.DTO
{
    /// <summary>
    /// <c>{"results": [...]}</c> envelope of the alert list and the notification list. An empty
    /// list serializes as <c>{"results": []}</c>. The order of <see cref="Results"/> is decided by
    /// the alert service (newest first); this class does not reorder it.
    /// </summary>
    public class AlertsResultDTO(IEnumerable<AlertDTO> results)
    {
        public IEnumerable<AlertDTO> Results { get; set; } = results;
    }
}
