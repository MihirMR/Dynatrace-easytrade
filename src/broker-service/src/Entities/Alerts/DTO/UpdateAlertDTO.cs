namespace EasyTrade.BrokerService.Entities.Alerts.DTO
{
    /// <summary>
    /// Request body of <c>PATCH /v1/alerts/{id}</c>: <c>{"enabled": bool}</c>.
    /// </summary>
    public class UpdateAlertDTO
    {
        /// <summary>
        /// <c>true</c> re-arms the alert: it is enabled, its trigger data and acknowledgement are
        /// cleared, and its arming revision increases. <c>false</c> only disables it and keeps any
        /// trigger data. A missing or <c>null</c> value is rejected by the alert service with 400.
        /// </summary>
        /// <remarks>
        /// Nullable so that an omitted field binds to <c>null</c> instead of <c>false</c>, which
        /// would silently disable the alert.
        /// </remarks>
        public bool? Enabled { get; set; }
    }
}
