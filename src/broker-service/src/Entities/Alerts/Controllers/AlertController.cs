using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.ExceptionHandling;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;

namespace EasyTrade.BrokerService.Entities.Alerts.Controllers
{
    /// <summary>
    /// Price and profit/loss alerts of the Portfolio Insights demo feature. Every action passes
    /// straight through to <see cref="IAlertService"/>. The class-level
    /// <see cref="PortfolioInsightsFeatureGate"/> answers 403 <c>{"error":"feature_disabled"}</c>
    /// before model binding while the feature is off, and <see cref="BrokerExceptionFilter"/>
    /// maps the service's exceptions to <see cref="ErrorResponse"/> bodies.
    /// </summary>
    [ApiController]
    [Route("v1/alerts")]
    [TypeFilter(typeof(BrokerExceptionFilter))]
    [ServiceFilter(typeof(PortfolioInsightsFeatureGate))]
    public class AlertController(IAlertService alertService) : ControllerBase
    {
        /// <summary>
        /// Create a TARGET_PRICE or PROFIT_LOSS alert for an account
        /// </summary>
        /// <param name="request">Alert account, type, instrument, direction and threshold</param>
        /// <returns>The created alert, enabled and not yet triggered</returns>
        [ProducesResponseType(typeof(AlertDTO), StatusCodes.Status201Created)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPost]
        public async Task<ActionResult<AlertDTO>> CreateAlert([FromBody] CreateAlertDTO request)
        {
            AlertDTO alert = await alertService.CreateAlertAsync(request);
            // Not CreatedAtAction: there is no GET-by-id route, so no Location header is sent.
            return StatusCode(StatusCodes.Status201Created, alert);
        }

        /// <summary>
        /// Get every alert of an account, newest first
        /// </summary>
        /// <param name="accountId">Account ID</param>
        /// <returns>Alerts of the account</returns>
        [ProducesResponseType(typeof(AlertsResultDTO), StatusCodes.Status200OK)]
        [ProducesResponseType(typeof(ValidationProblemDetails), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpGet]
        public async Task<AlertsResultDTO> GetAlerts([FromQuery, BindRequired] Guid accountId)
        {
            IEnumerable<AlertDTO> alerts = await alertService.GetAlertsAsync(accountId);
            return new AlertsResultDTO(alerts);
        }

        /// <summary>
        /// Get the triggered alerts of an account, most recently triggered first
        /// </summary>
        /// <param name="accountId">Account ID</param>
        /// <param name="unacknowledged">When true, only notifications not yet acknowledged</param>
        /// <returns>Triggered alerts of the account</returns>
        [ProducesResponseType(typeof(AlertsResultDTO), StatusCodes.Status200OK)]
        [ProducesResponseType(typeof(ValidationProblemDetails), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpGet("notifications")]
        public async Task<AlertsResultDTO> GetNotifications(
            [FromQuery, BindRequired] Guid accountId,
            [FromQuery] bool? unacknowledged
        )
        {
            IEnumerable<AlertDTO> notifications = await alertService.GetNotificationsAsync(
                accountId,
                unacknowledged == true
            );
            return new AlertsResultDTO(notifications);
        }

        /// <summary>
        /// Enable or disable an alert; enabling re-arms it and clears its trigger data
        /// </summary>
        /// <param name="id">Alert ID</param>
        /// <param name="request">The enabled value to set</param>
        /// <returns>The alert as this update wrote it</returns>
        [ProducesResponseType(typeof(AlertDTO), StatusCodes.Status200OK)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPatch("{id:guid}")]
        public async Task<AlertDTO> UpdateAlert(Guid id, [FromBody] UpdateAlertDTO request)
        {
            return await alertService.UpdateEnabledAsync(id, request);
        }

        /// <summary>
        /// Delete an alert together with its notification
        /// </summary>
        /// <param name="id">Alert ID</param>
        [ProducesResponseType(StatusCodes.Status204NoContent)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpDelete("{id:guid}")]
        public async Task<IActionResult> DeleteAlert(Guid id)
        {
            await alertService.DeleteAlertAsync(id);
            return NoContent();
        }

        /// <summary>
        /// Acknowledge the notification of the alert's current arming; an alert whose current
        /// arming has not triggered is left unchanged
        /// </summary>
        /// <param name="id">Alert ID</param>
        [ProducesResponseType(StatusCodes.Status204NoContent)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPost("{id:guid}/acknowledge")]
        public async Task<IActionResult> AcknowledgeAlert(Guid id)
        {
            await alertService.AcknowledgeAlertAsync(id);
            return NoContent();
        }
    }
}
