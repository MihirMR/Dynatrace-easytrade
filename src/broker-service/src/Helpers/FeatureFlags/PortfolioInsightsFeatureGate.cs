using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace EasyTrade.BrokerService.Helpers.FeatureFlags
{
    /// <summary>
    /// Answers 403 <c>{"error":"feature_disabled"}</c> while the portfolio-insights-enabled flag
    /// is off or unreadable. It is a resource filter so it runs before model binding and the
    /// automatic 400 validation of <c>[ApiController]</c>: a disabled feature reveals no
    /// validation detail and reaches no data access. Attach it with <c>[ServiceFilter]</c> only
    /// to the Portfolio Insights endpoints, never globally.
    /// </summary>
    public class PortfolioInsightsFeatureGate(IPortfolioInsightsFeature feature)
        : IAsyncResourceFilter
    {
        private readonly IPortfolioInsightsFeature _feature = feature;

        public async Task OnResourceExecutionAsync(
            ResourceExecutingContext context,
            ResourceExecutionDelegate next
        )
        {
            bool enabled = await _feature.IsEnabledAsync(context.HttpContext.RequestAborted);
            if (!enabled)
            {
                context.Result = new JsonResult(new { error = "feature_disabled" })
                {
                    StatusCode = StatusCodes.Status403Forbidden,
                    ContentType = "application/json",
                };
                return;
            }

            await next();
        }
    }
}
