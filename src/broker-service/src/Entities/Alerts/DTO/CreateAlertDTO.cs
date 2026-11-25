using System.Text.Json.Serialization;

namespace EasyTrade.BrokerService.Entities.Alerts.DTO
{
    /// <summary>
    /// Request body of <c>POST /v1/alerts</c>:
    /// <c>{accountId, type, instrumentId, direction, threshold}</c>. The class only carries the
    /// values; every rule (missing fields, exact enum names, the threshold domain, account,
    /// instrument and holding checks) is applied by <c>AlertService.CreateAlertAsync</c> in its
    /// documented order.
    /// </summary>
    /// <remarks>
    /// Every member is nullable so that a missing field binds to <c>null</c> and reaches the alert
    /// service, instead of being answered by the implicit required-member validation that
    /// <c>[ApiController]</c> applies to non-nullable members. Server-owned fields (id, enabled,
    /// arming revision, trigger data, acknowledgement, creation time) are deliberately absent, so
    /// a caller cannot set them.
    /// </remarks>
    public class CreateAlertDTO
    {
        public Guid? AccountId { get; set; }

        /// <summary>
        /// <c>TARGET_PRICE</c> or <c>PROFIT_LOSS</c>, matched exactly and case-sensitively by the
        /// alert service; kept as text so that no lenient enum binding accepts other spellings.
        /// </summary>
        public string? Type { get; set; }

        public Guid? InstrumentId { get; set; }

        /// <summary>
        /// <c>ABOVE</c> or <c>BELOW</c>, matched exactly and case-sensitively by the alert
        /// service; kept as text for the same reason as <see cref="Type"/>.
        /// </summary>
        public string? Direction { get; set; }

        /// <summary>
        /// A price for <c>TARGET_PRICE</c>, a percentage for <c>PROFIT_LOSS</c>. Bound from the
        /// raw JSON number token by <see cref="ExactDecimalJsonConverter"/>, so a quoted number,
        /// an exponent or an out-of-domain token fails binding rather than being rounded.
        /// </summary>
        [JsonConverter(typeof(ExactDecimalJsonConverter))]
        public decimal? Threshold { get; set; }
    }
}
