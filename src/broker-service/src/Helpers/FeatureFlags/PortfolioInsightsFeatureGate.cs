using System.Runtime.CompilerServices;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing.Matching;

namespace EasyTrade.BrokerService.Helpers.FeatureFlags
{
    /// <summary>
    /// Body of the 403 that every Portfolio Insights endpoint answers while the feature is off
    /// or unreadable, serialised as <c>{"error":"feature_disabled"}</c>. The gate writes it and
    /// the endpoints declare it as their 403 response type, so both name one shape.
    /// </summary>
    /// <param name="Error">Always <c>feature_disabled</c>.</param>
    public sealed record FeatureDisabledResponse(string Error);

    /// <summary>
    /// Answers 403 <c>{"error":"feature_disabled"}</c> while the portfolio-insights-enabled flag
    /// is off or unreadable. It is a resource filter so it runs before model binding and the
    /// automatic 400 validation of <c>[ApiController]</c>: a disabled feature reveals no
    /// validation detail and reaches no data access. Attach it with <c>[ServiceFilter]</c> only
    /// to the Portfolio Insights endpoints, never globally.
    /// </summary>
    /// <remarks>
    /// Where <see cref="PortfolioInsightsFeatureMatcherPolicy"/> is registered, it has already
    /// read the flag while routing the request and stored the decision, and the gate applies
    /// that decision instead of reading the flag a second time. For a disabled decision the
    /// policy has short-circuited the endpoint, so MVC runs this filter as soon as routing has
    /// matched it, before every later middleware, and the 403 is still written here. Without a
    /// stored decision the gate reads the flag itself.
    /// </remarks>
    public class PortfolioInsightsFeatureGate(IPortfolioInsightsFeature feature)
        : IAsyncResourceFilter
    {
        private readonly IPortfolioInsightsFeature _feature = feature;

        public async Task OnResourceExecutionAsync(
            ResourceExecutingContext context,
            ResourceExecutionDelegate next
        )
        {
            if (
                !PortfolioInsightsFeatureMatcherPolicy.TryGetDecision(
                    context.HttpContext,
                    out bool enabled
                )
            )
            {
                enabled = await _feature.IsEnabledAsync(context.HttpContext.RequestAborted);
            }
            if (!enabled)
            {
                context.Result = CreateFeatureDisabledResult();
                return;
            }

            await next();
        }

        /// <summary>
        /// The gate's 403: status 403, Content-Type <c>application/json</c> and a
        /// <see cref="FeatureDisabledResponse"/> body, which MVC's camelCase JSON writes as
        /// <c>{"error":"feature_disabled"}</c>. A new result per call, as each is executed once.
        /// </summary>
        private static JsonResult CreateFeatureDisabledResult()
        {
            return new JsonResult(new FeatureDisabledResponse("feature_disabled"))
            {
                StatusCode = StatusCodes.Status403Forbidden,
                ContentType = "application/json",
            };
        }
    }

    /// <summary>
    /// Reads the portfolio-insights-enabled flag while a request to a Portfolio Insights endpoint
    /// is routed, so the bounded fail-closed decision is taken before the middleware that runs
    /// after routing. The problem-pattern middleware there read their own flags from the same
    /// flag service without a deadline; were the gate's read left to MVC, a hung flag service
    /// would hold the request in that middleware long past the feature's read deadline instead
    /// of answering 403.
    /// </summary>
    /// <remarks>
    /// An endpoint is gated when its metadata carries the
    /// <c>[ServiceFilter(typeof(PortfolioInsightsFeatureGate))]</c> that attaches the gate, so
    /// the gated routes are those the gate itself names. The flag is read once, and only when a
    /// gated endpoint is still a valid candidate after route values, constraints and HTTP method
    /// have matched, so a path that matches no route keeps its 404 and other routes never read
    /// it. The decision is stored for <see cref="PortfolioInsightsFeatureGate"/> either way, and
    /// enabled leaves every candidate in place. Disabled replaces each valid gated candidate with
    /// that same endpoint marked to short-circuit: its own MVC request delegate, route pattern,
    /// order, name and metadata, plus the short-circuit marker of <c>ShortCircuit()</c>. Routing
    /// then runs MVC as soon as it has matched the endpoint, skipping every later middleware, and
    /// MVC runs the gate, which answers 403 from the stored decision before model binding.
    /// Routing refuses to short-circuit an endpoint with authorization, CORS or antiforgery
    /// metadata, so such a gated endpoint stays in place: it reaches the gate after the later
    /// middleware, and still answers 403.
    /// </remarks>
    public sealed class PortfolioInsightsFeatureMatcherPolicy(IPortfolioInsightsFeature feature)
        : MatcherPolicy,
            IEndpointSelectorPolicy
    {
        // Private to this type, so no other code can set or read the decision.
        private static readonly object DecisionKey = new();

        private readonly IPortfolioInsightsFeature _feature = feature;

        // One short-circuited copy per gated endpoint, kept only as long as that endpoint is alive.
        private readonly ConditionalWeakTable<RouteEndpoint, Endpoint> _shortCircuitedEndpoints =
            new();

        /// <summary>
        /// After every built-in policy, the last of which, MVC's action constraints, has order
        /// 100000, so a candidate's validity is settled when the flag is read.
        /// </summary>
        public override int Order => int.MaxValue;

        public bool AppliesToEndpoints(IReadOnlyList<Endpoint> endpoints)
        {
            ArgumentNullException.ThrowIfNull(endpoints);
            return endpoints.Any(IsGated);
        }

        public async Task ApplyAsync(HttpContext httpContext, CandidateSet candidates)
        {
            ArgumentNullException.ThrowIfNull(httpContext);
            ArgumentNullException.ThrowIfNull(candidates);
            if (!HasValidGatedCandidate(candidates))
            {
                return;
            }

            // Caller cancellation propagates, as it does from the gate.
            bool enabled = await _feature.IsEnabledAsync(httpContext.RequestAborted);
            httpContext.Items[DecisionKey] = enabled;
            if (enabled)
            {
                return;
            }

            for (int i = 0; i < candidates.Count; i++)
            {
                if (
                    candidates.IsValidCandidate(i)
                    && candidates[i].Endpoint is RouteEndpoint gated
                    && IsGated(gated)
                    && CanShortCircuit(gated)
                )
                {
                    candidates.ReplaceEndpoint(
                        i,
                        _shortCircuitedEndpoints.GetValue(gated, CreateShortCircuitedEndpoint),
                        candidates[i].Values
                    );
                }
            }
        }

        /// <summary>
        /// The decision this policy stored for <paramref name="httpContext"/>; false when the
        /// policy did not read the flag for the request.
        /// </summary>
        internal static bool TryGetDecision(HttpContext httpContext, out bool enabled)
        {
            if (
                httpContext.Items.TryGetValue(DecisionKey, out object? decision)
                && decision is bool value
            )
            {
                enabled = value;
                return true;
            }
            enabled = false;
            return false;
        }

        // Only route endpoints, whose route pattern the short-circuited copy keeps.
        private static bool IsGated(Endpoint endpoint)
        {
            return endpoint is RouteEndpoint
                && endpoint
                    .Metadata.GetOrderedMetadata<ServiceFilterAttribute>()
                    .Any(filter => filter.ServiceType == typeof(PortfolioInsightsFeatureGate));
        }

        private static bool HasValidGatedCandidate(CandidateSet candidates)
        {
            for (int i = 0; i < candidates.Count; i++)
            {
                if (candidates.IsValidCandidate(i) && IsGated(candidates[i].Endpoint))
                {
                    return true;
                }
            }
            return false;
        }

        // The checks routing makes before it short-circuits an endpoint, which it refuses, by
        // throwing, for authorization, CORS or antiforgery metadata that a later middleware must
        // enforce; antiforgery is refused here for every method, not only form posts.
        private static bool CanShortCircuit(RouteEndpoint gated)
        {
            return gated.Metadata.GetMetadata<IAuthorizeData>() is null
                && gated.Metadata.GetMetadata<ICorsMetadata>() is null
                && gated.Metadata.GetMetadata<IAntiforgeryMetadata>()
                    is not { RequiresValidation: true };
        }

        // The gated endpoint itself, marked to short-circuit: the same MVC request delegate,
        // which runs the action its ActionDescriptor metadata names with all its filters, the
        // same route pattern, order and name, so request metrics and traces still name the
        // route, and every metadata item in its order, followed by the short-circuit marker.
        // Build() adds only the route diagnostics metadata MVC endpoints already carry, when it
        // is absent, and adjusts metadata only for CORS, which is never short-circuited.
        private static Endpoint CreateShortCircuitedEndpoint(RouteEndpoint gated)
        {
            RouteEndpointBuilder builder = new(
                gated.RequestDelegate,
                gated.RoutePattern,
                gated.Order
            )
            {
                DisplayName = gated.DisplayName,
            };
            foreach (object metadata in gated.Metadata)
            {
                builder.Metadata.Add(metadata);
            }
            new EndpointConventions(builder).ShortCircuit();
            return builder.Build();
        }

        // Applies each convention an extension adds straight to one endpoint builder, so the
        // short-circuit metadata, whose type is not public, comes from ShortCircuit(). That
        // extension adds through Add alone. Finally keeps the interface's default, which throws,
        // so a framework that moved it there would fail every short-circuited copy the tests
        // build.
        private sealed class EndpointConventions(EndpointBuilder builder)
            : IEndpointConventionBuilder
        {
            public void Add(Action<EndpointBuilder> convention)
            {
                ArgumentNullException.ThrowIfNull(convention);
                convention(builder);
            }
        }
    }
}
