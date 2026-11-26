using System.Collections.Frozen;
using EasyTrade.BrokerService.Entities.Alerts.DTO;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.ExceptionHandling;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Mvc.ModelBinding.Metadata;
using Microsoft.AspNetCore.Routing.Matching;

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
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        /// <returns>The created alert, enabled and not yet triggered</returns>
        [ProducesResponseType(typeof(AlertDTO), StatusCodes.Status201Created)]
        // ApiExplorer keeps one response type per status code, so the description names both.
        [ProducesResponseType(
            typeof(ErrorResponse),
            StatusCodes.Status400BadRequest,
            Description = nameof(ErrorResponse)
                + " when a create rule rejects the alert; "
                + nameof(ValidationProblemDetails)
                + " (application/problem+json) when the body cannot bind, such as malformed"
                + " JSON, a member value that does not convert to its type, or a threshold"
                + " token outside the exact decimal grammar and domain"
        )]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPost]
        public async Task<ActionResult<AlertDTO>> CreateAlert(
            [FromBody] CreateAlertDTO request,
            CancellationToken cancellationToken
        )
        {
            AlertDTO alert = await alertService.CreateAlertAsync(request, cancellationToken);
            // Not CreatedAtAction: there is no GET-by-id route, so no Location header is sent.
            return StatusCode(StatusCodes.Status201Created, alert);
        }

        /// <summary>
        /// Get every alert of an account, newest first
        /// </summary>
        /// <param name="accountId">Account ID</param>
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        /// <returns>Alerts of the account</returns>
        [ProducesResponseType(typeof(AlertsResultDTO), StatusCodes.Status200OK)]
        [ProducesResponseType(typeof(ValidationProblemDetails), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpGet]
        public async Task<AlertsResultDTO> GetAlerts(
            [FromQuery, BindRequired] Guid accountId,
            CancellationToken cancellationToken
        )
        {
            IEnumerable<AlertDTO> alerts = await alertService.GetAlertsAsync(
                accountId,
                cancellationToken
            );
            return AlertMapper.ToResult(alerts);
        }

        /// <summary>
        /// Get the triggered alerts of an account, most recently triggered first
        /// </summary>
        /// <param name="accountId">Account ID</param>
        /// <param name="unacknowledged">When true, only notifications not yet acknowledged</param>
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        /// <returns>Triggered alerts of the account</returns>
        [ProducesResponseType(typeof(AlertsResultDTO), StatusCodes.Status200OK)]
        [ProducesResponseType(typeof(ValidationProblemDetails), StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpGet("notifications")]
        public async Task<AlertsResultDTO> GetNotifications(
            [FromQuery, BindRequired] Guid accountId,
            // Each supplied value must be a boolean; a blank one is not an omitted filter.
            [FromQuery, ModelBinder(typeof(UnacknowledgedFilterBinder))]
                bool? unacknowledged,
            CancellationToken cancellationToken
        )
        {
            IEnumerable<AlertDTO> notifications = await alertService.GetNotificationsAsync(
                accountId,
                unacknowledged == true,
                cancellationToken
            );
            return AlertMapper.ToResult(notifications);
        }

        /// <summary>
        /// Enable or disable an alert; enabling re-arms it and clears its trigger data
        /// </summary>
        /// <param name="id">Alert ID</param>
        /// <param name="request">The enabled value to set</param>
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        /// <returns>The alert as this update wrote it</returns>
        [ProducesResponseType(typeof(AlertDTO), StatusCodes.Status200OK)]
        // ApiExplorer keeps one response type per status code, so the description names both.
        [ProducesResponseType(
            typeof(ErrorResponse),
            StatusCodes.Status400BadRequest,
            Description = nameof(ErrorResponse)
                + " when enabled is missing or null; "
                + nameof(ValidationProblemDetails)
                + " (application/problem+json) when the body cannot bind, such as malformed"
                + " JSON or an enabled value that is not a JSON boolean"
        )]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPatch("{id:guid}")]
        public async Task<AlertDTO> UpdateAlert(
            Guid id,
            [FromBody] UpdateAlertDTO request,
            CancellationToken cancellationToken
        )
        {
            return await alertService.UpdateEnabledAsync(id, request, cancellationToken);
        }

        /// <summary>
        /// Delete an alert together with its notification
        /// </summary>
        /// <param name="id">Alert ID</param>
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        [ProducesResponseType(StatusCodes.Status204NoContent)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpDelete("{id:guid}")]
        public async Task<IActionResult> DeleteAlert(Guid id, CancellationToken cancellationToken)
        {
            await alertService.DeleteAlertAsync(id, cancellationToken);
            return NoContent();
        }

        /// <summary>
        /// Acknowledge the notification of the alert's current arming; an alert whose current
        /// arming has not triggered is left unchanged
        /// </summary>
        /// <param name="id">Alert ID</param>
        /// <param name="cancellationToken">Request abort token, passed to the service</param>
        [ProducesResponseType(StatusCodes.Status204NoContent)]
        [ProducesResponseType(StatusCodes.Status403Forbidden)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
        [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
        [HttpPost("{id:guid}/acknowledge")]
        public async Task<IActionResult> AcknowledgeAlert(
            Guid id,
            CancellationToken cancellationToken
        )
        {
            await alertService.AcknowledgeAlertAsync(id, cancellationToken);
            return NoContent();
        }

        /// <summary>
        /// Gives <c>PATCH</c> and <c>DELETE /v1/alerts/notifications</c> routing's 404, as any id
        /// segment that is not a GUID gets, instead of 405.
        /// </summary>
        /// <remarks>
        /// <c>notifications</c> stands where the <c>{id:guid}</c> segment of
        /// <see cref="UpdateAlert"/> and <see cref="DeleteAlert"/> does. Routing's
        /// <c>DfaMatcherBuilder</c> drops those endpoints from the literal's node, because the
        /// literal can never satisfy the GUID constraint, so only <see cref="GetNotifications"/>
        /// remains there, and <see cref="HttpMethodMatcherPolicy"/> would answer PATCH and DELETE
        /// with 405 and <c>Allow: GET</c>. This policy runs first, on that node only, and sends
        /// those two methods to the matcher's exit: no endpoint is selected, so the response is
        /// the plain 404 without an <c>Allow</c> header, and the feature gate, a filter of the
        /// selected endpoint, never runs, whether the feature is on or off. Every other method
        /// continues on one edge to <see cref="HttpMethodMatcherPolicy"/>, which selects the
        /// action for GET and answers 405 with <c>Allow: GET</c> to the rest.
        /// </remarks>
        public sealed class NotificationsMatcherPolicy : MatcherPolicy, INodeBuilderPolicy
        {
            // The methods of UpdateAlert and DeleteAlert, whose {id:guid} segment the
            // notifications literal fills; case-insensitive, as HttpMethodMatcherPolicy compares.
            private static readonly FrozenSet<string> IdRouteMethods = FrozenSet.ToFrozenSet(
                [HttpMethods.Patch, HttpMethods.Delete],
                StringComparer.OrdinalIgnoreCase
            );

            // The state of the one edge, and its label in the matcher's debug graph.
            private const string OtherMethodsEdge = "other methods";

            /// <summary>
            /// One ahead of <see cref="HttpMethodMatcherPolicy"/>, whose order is -1000, so the
            /// two methods never reach its 405 endpoint.
            /// </summary>
            public override int Order => -1001;

            /// <summary>
            /// True for a node whose endpoints are all <see cref="GetNotifications"/>, the
            /// <c>notifications</c> literal's node; every other node keeps the framework's method
            /// handling.
            /// </summary>
            public bool AppliesToEndpoints(IReadOnlyList<Endpoint> endpoints)
            {
                // All holds for an empty list too, and an empty node is no notifications node.
                return endpoints.Count > 0 && endpoints.All(IsGetNotifications);
            }

            /// <summary>
            /// One edge with every endpoint, so <see cref="HttpMethodMatcherPolicy"/> still
            /// handles the methods this policy does not send to the exit.
            /// </summary>
            public IReadOnlyList<PolicyNodeEdge> GetEdges(IReadOnlyList<Endpoint> endpoints)
            {
                return [new PolicyNodeEdge(OtherMethodsEdge, endpoints)];
            }

            /// <summary>
            /// PATCH and DELETE, in any case, go to <paramref name="exitDestination"/>; every
            /// other method goes to the one edge <see cref="GetEdges"/> built.
            /// </summary>
            public PolicyJumpTable BuildJumpTable(
                int exitDestination,
                IReadOnlyList<PolicyJumpTableEdge> edges
            )
            {
                return new IdRouteMethodJumpTable(edges.Single().Destination, exitDestination);
            }

            // MVC puts each action's descriptor in its endpoint's metadata.
            private static bool IsGetNotifications(Endpoint endpoint)
            {
                ControllerActionDescriptor? action =
                    endpoint.Metadata.GetMetadata<ControllerActionDescriptor>();
                return action is not null
                    && action.ControllerTypeInfo.AsType() == typeof(AlertController)
                    && action.MethodInfo.Name == nameof(GetNotifications);
            }

            private sealed class IdRouteMethodJumpTable(int edgeDestination, int exitDestination)
                : PolicyJumpTable
            {
                public override int GetDestination(HttpContext httpContext)
                {
                    return IdRouteMethods.Contains(httpContext.Request.Method)
                        ? exitDestination
                        : edgeDestination;
                }
            }
        }

        /// <summary>
        /// Binds the optional <c>unacknowledged</c> filter of <see cref="GetNotifications"/>
        /// strictly. MVC's default binder turns a supplied empty or whitespace-only value into
        /// <c>null</c>, which reads as omitted, and converts only the first of repeated values.
        /// Here every supplied value must be a boolean; otherwise the parameter gets a model-state
        /// error, so <c>[ApiController]</c> answers with its automatic 400 problem response.
        /// <list type="bullet">
        /// <item>Omitted: no result, so the value stays <c>null</c>.</item>
        /// <item>Every value <c>true</c> or <c>false</c>, in any case and with surrounding
        /// whitespace: the first value, as MVC binds a repeated scalar.</item>
        /// <item>Any value anything else, empty and whitespace-only included: the framework's
        /// invalid-value message naming the first such value, as that value alone gets, while
        /// model state records the whole supplied value as the attempted value.</item>
        /// </list>
        /// </summary>
        private sealed class UnacknowledgedFilterBinder : IModelBinder
        {
            public Task BindModelAsync(ModelBindingContext bindingContext)
            {
                string modelName = bindingContext.ModelName;
                ValueProviderResult supplied = bindingContext.ValueProvider.GetValue(modelName);
                if (supplied == ValueProviderResult.None)
                {
                    return Task.CompletedTask;
                }

                bindingContext.ModelState.SetModelValue(modelName, supplied);
                bool? first = null;
                foreach (string? value in supplied.Values)
                {
                    // bool.TryParse ignores case and surrounding whitespace, and rejects an empty
                    // or whitespace-only value.
                    if (!bool.TryParse(value, out bool parsed))
                    {
                        ModelBindingMessageProvider messages = bindingContext
                            .ModelMetadata
                            .ModelBindingMessageProvider;
                        bindingContext.ModelState.TryAddModelError(
                            modelName,
                            // The rejected value itself: the joined supplied value would leave
                            // out an empty one.
                            messages.NonPropertyAttemptedValueIsInvalidAccessor(
                                value ?? string.Empty
                            )
                        );
                        return Task.CompletedTask;
                    }
                    first ??= parsed;
                }

                bindingContext.Result = ModelBindingResult.Success(first);
                return Task.CompletedTask;
            }
        }
    }
}
