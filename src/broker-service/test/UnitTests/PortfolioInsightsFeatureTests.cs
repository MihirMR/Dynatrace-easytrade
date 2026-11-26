using System.Diagnostics;
using System.Net;
using System.Text;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Cors;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Routing.Matching;
using Microsoft.AspNetCore.Routing.Patterns;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OpenFeature;
using OpenFeature.Constant;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Tests of <see cref="PortfolioInsightsFeature.IsEnabledAsync"/>: the flag read outcomes,
    /// caller cancellation, the read deadline and the Warning logged for an unreadable flag; of
    /// the token path through <see cref="PluginProvider"/> and
    /// <see cref="FeatureFlagServiceConnector"/>, including the unchanged token-less request that
    /// problem-pattern reads send; of how <see cref="PortfolioInsightsFeatureGate"/> uses the
    /// read when its request is aborted; and of <see cref="PortfolioInsightsFeatureMatcherPolicy"/>,
    /// which takes the gate's decision while the request is routed. Each feature is built over a
    /// provider instance and the gate and policy over fake features, so the process-wide
    /// OpenFeature API is never touched.
    /// </summary>
    public class PortfolioInsightsFeatureTests
    {
        private const string UnreadableWarningPrefix = "Portfolio insights flag unreadable";

        // Literal rather than the constant, so the tests prove the hyphenated id reaches each hop.
        private const string HyphenatedFlagId = "portfolio-insights-enabled";
        private const string FlagServiceAddress = "http://flags.test";
        private const string ExpectedFlagUri =
            "http://flags.test/v1/flags/portfolio-insights-enabled";

        // Bounds every read, so a regression that hangs fails its test instead of the run.
        private static readonly TimeSpan ReadBound = TimeSpan.FromSeconds(10);

        // Both sides of the fixed 2 s read deadline, as literals rather than the feature's own
        // value, so a changed deadline fails: the lower bound allows for timer granularity and
        // the upper for scheduling jitter, while any deadline of 2.5 s or more lands outside.
        private static readonly TimeSpan DeadlineLowerBound = TimeSpan.FromSeconds(1.9);
        private static readonly TimeSpan DeadlineUpperBound = TimeSpan.FromSeconds(2.5);

        [Theory]
        [InlineData(SwitchableFlagMode.Enabled, true, 0)]
        [InlineData(SwitchableFlagMode.Disabled, false, 0)]
        [InlineData(SwitchableFlagMode.ReturnNull, false, 0)]
        [InlineData(SwitchableFlagMode.ThrowHttpRequest, false, 1)]
        [InlineData(SwitchableFlagMode.ThrowJson, false, 1)]
        public async Task IsEnabled_ProviderOutcome_ShouldResolve(
            SwitchableFlagMode mode,
            bool expectedEnabled,
            int expectedUnreadableWarnings
        )
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(mode);

            // Act
            bool enabled = await subject
                .Feature.IsEnabledAsync(CancellationToken.None)
                .WaitAsync(ReadBound);

            // Assert
            Assert.Equal(
                (expectedEnabled, expectedUnreadableWarnings),
                (enabled, UnreadableWarnings(subject.Logger.Sink).Count())
            );
        }

        [Fact]
        public async Task IsEnabled_Deadline_ShouldCancelConnectorTokenAndReturnFalse()
        {
            // Arrange
            SwitchableFeatureFlagServiceConnector connector = new(mode: SwitchableFlagMode.Hang);
            FinishSignallingConnector observed = new(connector);
            RecordingLogSink sink = new();
            PortfolioInsightsFeature feature = new(
                new PluginProvider(observed),
                new RecordingLogger<PortfolioInsightsFeature>(sink)
            );
            Stopwatch stopwatch = Stopwatch.StartNew();

            // Act
            bool enabled = await feature
                .IsEnabledAsync(CancellationToken.None)
                .WaitAsync(ReadBound);
            stopwatch.Stop();
            // The feature can return before the hung connector call has unwound, so the
            // connector's record is read only once that call has finished.
            await observed.CallFinished.WaitAsync(ReadBound);

            // Assert
            Assert.Equal(
                new DeadlineRead(
                    Enabled: false,
                    EndedAtDeadline: true,
                    ConnectorTokenCancelled: true,
                    WarningReasons: "timeout"
                ),
                new DeadlineRead(
                    enabled,
                    (stopwatch.Elapsed >= DeadlineLowerBound)
                        && (stopwatch.Elapsed < DeadlineUpperBound),
                    connector.ObservedCancellation,
                    string.Join(
                        ",",
                        UnreadableWarnings(sink).Select(entry => entry.GetField("reason"))
                    )
                )
            );
        }

        [Fact]
        public async Task IsEnabled_CallerCancelled_ShouldThrowOperationCanceled()
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(SwitchableFlagMode.Hang);
            using CancellationTokenSource caller = new();
            // The hung connector call has started by the time the read's task is returned.
            Task<bool> read = subject.Feature.IsEnabledAsync(caller.Token);

            // Act
            caller.Cancel();

            // Assert
            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => read.WaitAsync(ReadBound)
            );
        }

        [Fact]
        public async Task IsEnabled_CallerCancelledDuringRead_ShouldLogNoWarning()
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(SwitchableFlagMode.Hang);
            using CancellationTokenSource caller = new();
            Task<bool> read = subject.Feature.IsEnabledAsync(caller.Token);

            // Act
            caller.Cancel();
            _ = await Record.ExceptionAsync(() => read.WaitAsync(ReadBound));

            // Assert
            Assert.Empty(subject.Logger.Sink.ByLevel(LogLevel.Warning));
        }

        [Fact]
        public async Task IsEnabled_CalledTwice_ShouldReadProviderTwice()
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(SwitchableFlagMode.Enabled);

            // Act
            _ = await subject.Feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);
            _ = await subject.Feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Equal(2, subject.Connector.CallCount);
        }

        [Fact]
        public async Task IsEnabled_ProviderAnswersAsDeadlineExpires_ShouldReturnFalseWithTimeout()
        {
            // Arrange
            RecordingLogSink sink = new();
            PortfolioInsightsFeature feature = new(
                new LateAnsweringProvider(),
                new RecordingLogger<PortfolioInsightsFeature>(sink)
            );

            // Act
            bool enabled = await feature
                .IsEnabledAsync(CancellationToken.None)
                .WaitAsync(ReadBound);

            // Assert
            Assert.Equal((false, "timeout"), (enabled, UnreadableReasons(sink)));
        }

        [Theory]
        [InlineData("""{"id":"portfolio-insights-enabled","enabled":true}""", true, "")]
        [InlineData("""{"id":"portfolio-insights-enabled","enabled":false}""", false, "")]
        [InlineData("""{"id":"db_not_responding","enabled":true}""", false, "unexpected_flag_id")]
        [InlineData(
            """{"id":"Portfolio-Insights-Enabled","enabled":true}""",
            false,
            "unexpected_flag_id"
        )]
        [InlineData("""{"id":"","enabled":true}""", false, "unexpected_flag_id")]
        [InlineData("""{"id":null,"enabled":true}""", false, "unexpected_flag_id")]
        [InlineData("""{"enabled":true}""", false, "unexpected_flag_id")]
        public async Task IsEnabled_FlagServiceAnswer_ShouldEnableOnlyForRequestedFlag(
            string answerBody,
            bool expectedEnabled,
            string expectedWarningReasons
        )
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            factory.Handler.RespondWith(HttpStatusCode.OK, answerBody);
            RecordingLogSink sink = new();
            PortfolioInsightsFeature feature = new(
                new PluginProvider(BuildConnector(factory)),
                new RecordingLogger<PortfolioInsightsFeature>(sink)
            );

            // Act
            bool enabled = await feature
                .IsEnabledAsync(CancellationToken.None)
                .WaitAsync(ReadBound);

            // Assert
            Assert.Equal(
                (expectedEnabled, expectedWarningReasons),
                (enabled, UnreadableReasons(sink))
            );
        }

        // Problem-pattern reads resolve exactly as before: the requested key and the value from
        // whichever flag answered, or the default without an answer, and nothing else, whatever
        // id the answer carried. A key differing from the feature flag only in case is another
        // flag, because keys are matched ordinally.
        [Theory]
        [InlineData(
            Constants.DbNotResponding,
            HttpStatusCode.OK,
            """{"id":"db_not_responding","enabled":true}""",
            false,
            true
        )]
        [InlineData(
            Constants.DbNotResponding,
            HttpStatusCode.OK,
            """{"id":"db_not_responding","enabled":false}""",
            true,
            false
        )]
        [InlineData(
            Constants.DbNotResponding,
            HttpStatusCode.OK,
            """{"id":"another-flag","enabled":true}""",
            false,
            true
        )]
        [InlineData(
            Constants.DbNotResponding,
            HttpStatusCode.OK,
            """{"enabled":true}""",
            false,
            true
        )]
        [InlineData(Constants.DbNotResponding, HttpStatusCode.NotFound, null, true, true)]
        [InlineData(
            Constants.DbNotResponding,
            HttpStatusCode.InternalServerError,
            null,
            false,
            false
        )]
        [InlineData(
            Constants.HighCpuUsage,
            HttpStatusCode.OK,
            """{"id":"high_cpu_usage","enabled":true}""",
            false,
            true
        )]
        [InlineData(
            "Portfolio-Insights-Enabled",
            HttpStatusCode.OK,
            """{"id":"Portfolio-Insights-Enabled","enabled":true}""",
            false,
            true
        )]
        public async Task ResolveBooleanValue_OtherFlagAnswer_ShouldResolveValueOnly(
            string flagKey,
            HttpStatusCode status,
            string? answerBody,
            bool defaultValue,
            bool expectedValue
        )
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            factory.Handler.RespondWith(status, answerBody);
            PluginProvider provider = new(BuildConnector(factory));

            // Act
            ResolutionDetails<bool> details = await provider.ResolveBooleanValueAsync(
                flagKey,
                defaultValue
            );

            // Assert
            Assert.Equal(
                (
                    flagKey,
                    expectedValue,
                    ErrorType.None,
                    (string?)null,
                    (string?)null,
                    (string?)null,
                    (ImmutableMetadata?)null
                ),
                (
                    details.FlagKey,
                    details.Value,
                    details.ErrorType,
                    details.Reason,
                    details.Variant,
                    details.ErrorMessage,
                    details.FlagMetadata
                )
            );
        }

        // The feature flag's read keeps the same value mapping, the value from whichever flag
        // answered, and also names that flag: its id, empty for an answer without one, and no
        // id at all when the service gave no answer.
        [Theory]
        [InlineData(
            HttpStatusCode.OK,
            """{"id":"portfolio-insights-enabled","enabled":true}""",
            false,
            true,
            "portfolio-insights-enabled"
        )]
        [InlineData(
            HttpStatusCode.OK,
            """{"id":"portfolio-insights-enabled","enabled":false}""",
            true,
            false,
            "portfolio-insights-enabled"
        )]
        [InlineData(
            HttpStatusCode.OK,
            """{"id":"another-flag","enabled":true}""",
            false,
            true,
            "another-flag"
        )]
        [InlineData(HttpStatusCode.OK, """{"enabled":true}""", false, true, "")]
        [InlineData(HttpStatusCode.NotFound, null, true, true, null)]
        [InlineData(HttpStatusCode.InternalServerError, null, false, false, null)]
        public async Task ResolveBooleanValue_PortfolioInsightsFlagAnswer_ShouldKeepValueAndReportAnsweredId(
            HttpStatusCode status,
            string? answerBody,
            bool defaultValue,
            bool expectedValue,
            string? expectedAnsweredId
        )
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            factory.Handler.RespondWith(status, answerBody);
            PluginProvider provider = new(BuildConnector(factory));

            // Act
            ResolutionDetails<bool> details = await provider.ResolveBooleanValueAsync(
                HyphenatedFlagId,
                defaultValue
            );

            // Assert
            Assert.Equal(
                (expectedValue, expectedAnsweredId),
                (details.Value, details.FlagMetadata?.GetString(PluginProvider.FlagIdMetadataKey))
            );
        }

        [Theory]
        [InlineData(SwitchableFlagMode.Enabled, true)]
        [InlineData(SwitchableFlagMode.Disabled, false)]
        public async Task ResolveBooleanValue_HyphenatedFlag_ShouldReturnFlagState(
            SwitchableFlagMode mode,
            bool expected
        )
        {
            // Arrange
            SwitchableFeatureFlagServiceConnector connector = new(mode: mode);

            // Act
            ResolutionDetails<bool> details = await new PluginProvider(
                connector
            ).ResolveBooleanValueAsync(
                Constants.PortfolioInsightsEnabled,
                false,
                null,
                CancellationToken.None
            );

            // Assert
            Assert.Equal(expected, details.Value);
            Assert.Equal(HyphenatedFlagId, Assert.Single(connector.RequestedIds));
        }

        [Fact]
        public async Task GetFlag_HyphenatedId_ShouldRequestFlagPath()
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            FeatureFlagServiceConnector connector = BuildConnector(factory);

            // Act
            _ = await connector.GetFlag(Constants.PortfolioInsightsEnabled, CancellationToken.None);

            // Assert
            Assert.Collection(
                factory.Handler.Requests,
                request => Assert.Equal(ExpectedFlagUri, request.RequestUri?.AbsoluteUri)
            );
        }

        [Fact]
        public async Task GetFlag_WithoutToken_ShouldSendUnchangedRequest()
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            FeatureFlagServiceConnector connector = BuildConnector(factory);
            (HttpMethod, string?, string) expected = (HttpMethod.Get, ExpectedFlagUri, "");

            // Act
            _ = await connector.GetFlag(Constants.PortfolioInsightsEnabled);

            // Assert
            Assert.Collection(
                factory.Handler.Requests,
                request =>
                    Assert.Equal(
                        expected,
                        (
                            request.Method,
                            request.RequestUri?.AbsoluteUri,
                            string.Join(",", request.Headers.Keys)
                        )
                    )
            );
        }

        [Fact]
        public async Task GetFlag_WithoutToken_ShouldReturnFlagFromBody()
        {
            // Arrange
            FeatureFlagServiceConnector connector = BuildConnector(
                new RecordingHttpClientFactory()
            );

            // Act
            Flag? flag = await connector.GetFlag(Constants.PortfolioInsightsEnabled);

            // Assert
            // The handler's default body carries the hyphenated id with Enabled set to true.
            Flag read = Assert.IsType<Flag>(flag);
            Assert.Equal((HyphenatedFlagId, true), (read.Id, read.Enabled));
        }

        [Fact]
        public async Task IsEnabled_CallerCancelledWhileProviderSucceeds_ShouldThrowCanceled()
        {
            // Arrange
            using CancellationTokenSource caller = new();
            PortfolioInsightsFeature feature = new(
                new CancellingSuccessProvider(caller),
                new RecordingLogger<PortfolioInsightsFeature>(new RecordingLogSink())
            );

            // Act and Assert
            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => feature.IsEnabledAsync(caller.Token).WaitAsync(ReadBound)
            );
        }

        [Fact]
        public async Task IsEnabled_CallerCancelledWhileProviderSucceeds_ShouldLogNoWarning()
        {
            // Arrange
            RecordingLogSink sink = new();
            using CancellationTokenSource caller = new();
            PortfolioInsightsFeature feature = new(
                new CancellingSuccessProvider(caller),
                new RecordingLogger<PortfolioInsightsFeature>(sink)
            );

            // Act
            _ = await Record.ExceptionAsync(
                () => feature.IsEnabledAsync(caller.Token).WaitAsync(ReadBound)
            );

            // Assert
            Assert.Empty(sink.ByLevel(LogLevel.Warning));
        }

        [Theory]
        [InlineData(SwitchableFlagMode.ThrowHttpRequest)]
        [InlineData(SwitchableFlagMode.ThrowJson)]
        public async Task IsEnabled_UnreadableFlag_ShouldLogWarningWithoutException(
            SwitchableFlagMode mode
        )
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(mode);

            // Act
            _ = await subject.Feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Collection(
                UnreadableWarnings(subject.Logger.Sink),
                entry => Assert.Null(entry.Exception)
            );
        }

        [Theory]
        [InlineData(SwitchableFlagMode.ThrowHttpRequest, "HttpRequestException")]
        [InlineData(SwitchableFlagMode.ThrowJson, "JsonException")]
        public async Task IsEnabled_UnreadableFlag_ShouldRecordReasonField(
            SwitchableFlagMode mode,
            string expectedReason
        )
        {
            // Arrange
            FeatureUnderTest subject = BuildFeature(mode);

            // Act
            _ = await subject.Feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Collection(
                UnreadableWarnings(subject.Logger.Sink),
                entry => Assert.Equal(expectedReason, entry.GetField("reason"))
            );
        }

        [Fact]
        public async Task IsEnabled_ProviderIgnoresDeadline_ShouldReturnFalse()
        {
            // Arrange
            using DeadlineIgnoringProvider provider = new();
            PortfolioInsightsFeature feature = new(
                provider,
                new RecordingLogger<PortfolioInsightsFeature>(new RecordingLogSink())
            );

            // Act
            bool enabled = await feature
                .IsEnabledAsync(CancellationToken.None)
                .WaitAsync(ReadBound);

            // Assert
            Assert.False(enabled);
        }

        [Fact]
        public async Task IsEnabled_ProviderIgnoresDeadline_ShouldLogTimeoutWarning()
        {
            // Arrange
            RecordingLogSink sink = new();
            using DeadlineIgnoringProvider provider = new();
            PortfolioInsightsFeature feature = new(
                provider,
                new RecordingLogger<PortfolioInsightsFeature>(sink)
            );

            // Act
            _ = await feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Collection(
                UnreadableWarnings(sink),
                entry => Assert.Equal("timeout", entry.GetField("reason"))
            );
        }

        [Fact]
        public async Task OnResourceExecution_RequestAborted_ShouldPropagateCancellation()
        {
            // Act
            AbortedGateRun run = await RunGateUntilRequestAbortedAsync();

            // Assert
            Assert.IsAssignableFrom<OperationCanceledException>(run.Error);
        }

        [Fact]
        public async Task OnResourceExecution_RequestAborted_ShouldNotCallNext()
        {
            // Act
            AbortedGateRun run = await RunGateUntilRequestAbortedAsync();

            // Assert
            Assert.False(run.NextCalled);
        }

        [Fact]
        public async Task OnResourceExecution_RequestAborted_ShouldSetNoResult()
        {
            // Act
            AbortedGateRun run = await RunGateUntilRequestAbortedAsync();

            // Assert
            Assert.Null(run.Result);
        }

        [Theory]
        [InlineData("gated", true)]
        [InlineData("gatedAmongOthers", true)]
        [InlineData("otherServiceFilter", false)]
        [InlineData("noFilter", false)]
        [InlineData("gatedNonRouteEndpoint", false)]
        [InlineData("none", false)]
        public void AppliesToEndpoints_Endpoints_ShouldMatchOnlyGatedRoutes(
            string endpoints,
            bool expected
        )
        {
            // Arrange
            PortfolioInsightsFeatureMatcherPolicy policy = new(new FixedFeature(true));
            Endpoint[] list = endpoints switch
            {
                "gated" => [GatedEndpoint()],
                "gatedAmongOthers" => [UngatedEndpoint(), GatedEndpoint()],
                "otherServiceFilter" =>
                [
                    BuildEndpoint(new ServiceFilterAttribute(typeof(FixedFeature))),
                ],
                "noFilter" => [UngatedEndpoint()],
                "gatedNonRouteEndpoint" =>
                [
                    new Endpoint(
                        _ => Task.CompletedTask,
                        new EndpointMetadataCollection(GateFilter()),
                        "Not routed"
                    ),
                ],
                "none" => [],
                _ => throw new ArgumentOutOfRangeException(nameof(endpoints), endpoints, null),
            };

            // Act
            bool applies = policy.AppliesToEndpoints(list);

            // Assert
            Assert.Equal(expected, applies);
        }

        [Fact]
        public async Task ApplyAsync_FeatureDisabled_ShouldReplaceOnlyValidGatedCandidates()
        {
            // Arrange
            FixedFeature feature = new(false);
            PortfolioInsightsFeatureMatcherPolicy policy = new(feature);
            // Metadata as MVC gives an action: its descriptor, its filters and its HTTP method.
            RouteEndpoint gated = BuildEndpoint(
                new ActionDescriptor(),
                GateFilter(),
                new HttpMethodMetadata([HttpMethods.Get])
            );
            RouteEndpoint invalidGated = GatedEndpoint();
            RouteEndpoint ungated = UngatedEndpoint();
            RouteValueDictionary values = new() { ["accountId"] = Guid.NewGuid() };
            CandidateSet candidates = new(
                [gated, invalidGated, ungated],
                [values, new RouteValueDictionary(), new RouteValueDictionary()],
                [0, 0, 0]
            );
            candidates.SetValidity(1, false);
            CandidateSet nextRequest = SingleCandidate(gated);

            // Act
            await policy.ApplyAsync(new DefaultHttpContext(), candidates);
            await policy.ApplyAsync(new DefaultHttpContext(), nextRequest);

            // Assert
            // One flag read per request, whatever the number of candidates.
            Assert.Equal(2, feature.Calls);
            RouteEndpoint shortCircuited = Assert.IsType<RouteEndpoint>(candidates[0].Endpoint);
            Assert.NotSame(gated, shortCircuited);
            Assert.True(candidates.IsValidCandidate(0));
            Assert.Same(values, candidates[0].Values);
            // The gated endpoint itself: the delegate MVC runs it with, its route, so request
            // metrics and traces still name it, its name, and every metadata item in its order,
            // the gate attribute included, followed by the one short-circuit marker.
            Assert.Same(gated.RequestDelegate, shortCircuited.RequestDelegate);
            Assert.Same(gated.RoutePattern, shortCircuited.RoutePattern);
            Assert.Equal(gated.Order, shortCircuited.Order);
            Assert.Equal(gated.DisplayName, shortCircuited.DisplayName);
            Assert.Equal<object>(
                gated.Metadata,
                shortCircuited.Metadata.Take(gated.Metadata.Count),
                ReferenceEqualityComparer.Instance
            );
            Assert.IsType(
                ShortCircuitMarkerType(),
                Assert.Single(shortCircuited.Metadata.Skip(gated.Metadata.Count))
            );
            Assert.Same(invalidGated, candidates[1].Endpoint);
            Assert.False(candidates.IsValidCandidate(1));
            Assert.Same(ungated, candidates[2].Endpoint);
            // The short-circuited copy is built once per gated endpoint.
            Assert.Same(shortCircuited, nextRequest[0].Endpoint);
        }

        [Fact]
        public async Task ApplyAsync_DisabledReplacementExecuted_ShouldAnswerGate403FromDecision()
        {
            // Arrange
            // The gate's own read would answer enabled, so only the decision the policy stored
            // can make the gate, reached through the gated endpoint's delegate, answer 403.
            FixedFeature policyFeature = new(false);
            FixedFeature gateFeature = new(true);
            PortfolioInsightsFeatureMatcherPolicy policy = new(policyFeature);
            PortfolioInsightsFeatureGate gate = new(gateFeature);
            CandidateSet candidates = SingleCandidate(
                BuildEndpoint(
                    context => RunGateAsResourceFilterAsync(gate, context),
                    [GateFilter()]
                )
            );
            ServiceCollection serviceCollection = new();
            serviceCollection.AddLogging().AddControllers();
            await using ServiceProvider services = serviceCollection.BuildServiceProvider();
            using MemoryStream body = new();
            DefaultHttpContext httpContext = new() { RequestServices = services };
            httpContext.Response.Body = body;
            await policy.ApplyAsync(httpContext, candidates);
            RequestDelegate shortCircuited = Assert.IsType<RequestDelegate>(
                candidates[0].Endpoint.RequestDelegate
            );

            // Act
            await shortCircuited(httpContext).WaitAsync(ReadBound);

            // Assert
            Assert.Equal(StatusCodes.Status403Forbidden, httpContext.Response.StatusCode);
            Assert.Equal("application/json", httpContext.Response.ContentType);
            Assert.Equal(
                "{\"error\":\"feature_disabled\"}",
                Encoding.UTF8.GetString(body.ToArray())
            );
            Assert.Equal((1, 0), (policyFeature.Calls, gateFeature.Calls));
        }

        [Theory]
        [InlineData("authorize", false)]
        [InlineData("cors", false)]
        [InlineData("antiforgeryRequired", false)]
        [InlineData("antiforgeryNotRequired", true)]
        public async Task ApplyAsync_DisabledEndpointMetadata_ShouldShortCircuitOnlyWhereRoutingCan(
            string endpoint,
            bool expectShortCircuited
        )
        {
            // Arrange
            PortfolioInsightsFeatureMatcherPolicy policy = new(new FixedFeature(false));
            RouteEndpoint gated = endpoint switch
            {
                "authorize" => BuildEndpoint(GateFilter(), new AuthorizeAttribute()),
                "cors" => BuildEndpoint(GateFilter(), new EnableCorsAttribute()),
                "antiforgeryRequired" => BuildEndpoint(
                    GateFilter(),
                    new RequireAntiforgeryTokenAttribute()
                ),
                "antiforgeryNotRequired" => BuildEndpoint(
                    GateFilter(),
                    new RequireAntiforgeryTokenAttribute(required: false)
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(endpoint), endpoint, null),
            };
            CandidateSet candidates = SingleCandidate(gated);
            DefaultHttpContext httpContext = new();
            // Reached later, the gate's own read would answer enabled.
            FixedFeature gateFeature = new(true);
            ResourceExecutingContext gateContext = new(
                new ActionContext(httpContext, new RouteData(), new ActionDescriptor()),
                [],
                []
            );

            // Act
            await policy.ApplyAsync(httpContext, candidates);
            await new PortfolioInsightsFeatureGate(gateFeature).OnResourceExecutionAsync(
                gateContext,
                () => Task.FromResult(new ResourceExecutedContext(gateContext, gateContext.Filters))
            );

            // Assert
            // Routing would throw for a short-circuited copy of the others, so they stay in place
            // for the gate, which still answers 403 from the stored decision: closed either way.
            Endpoint routed = candidates[0].Endpoint;
            Assert.Equal(expectShortCircuited, !ReferenceEquals(gated, routed));
            Assert.Equal(
                expectShortCircuited,
                routed.Metadata.Any(item => item.GetType() == ShortCircuitMarkerType())
            );
            JsonResult forbidden = Assert.IsType<JsonResult>(gateContext.Result);
            Assert.Equal(StatusCodes.Status403Forbidden, forbidden.StatusCode);
            Assert.Equal(0, gateFeature.Calls);
        }

        [Theory]
        [InlineData("gatedInvalid")]
        [InlineData("ungatedOnly")]
        public async Task ApplyAsync_NoValidGatedCandidate_ShouldNotReadFlag(string candidate)
        {
            // Arrange
            FixedFeature feature = new(false);
            PortfolioInsightsFeatureMatcherPolicy policy = new(feature);
            RouteEndpoint endpoint = candidate switch
            {
                "gatedInvalid" => GatedEndpoint(),
                "ungatedOnly" => UngatedEndpoint(),
                _ => throw new ArgumentOutOfRangeException(nameof(candidate), candidate, null),
            };
            CandidateSet candidates = SingleCandidate(endpoint);
            if (candidate == "gatedInvalid")
            {
                // As a route constraint or HTTP method mismatch leaves it.
                candidates.SetValidity(0, false);
            }
            DefaultHttpContext httpContext = new();

            // Act
            await policy.ApplyAsync(httpContext, candidates);

            // Assert
            Assert.Equal(0, feature.Calls);
            Assert.Same(endpoint, candidates[0].Endpoint);
            Assert.Empty(httpContext.Items);
        }

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public async Task OnResourceExecution_PolicyDecided_ShouldApplyDecisionWithoutReading(
            bool enabled
        )
        {
            // Arrange
            FixedFeature policyFeature = new(enabled);
            PortfolioInsightsFeatureMatcherPolicy policy = new(policyFeature);
            RouteEndpoint gated = GatedEndpoint();
            CandidateSet candidates = SingleCandidate(gated);
            DefaultHttpContext httpContext = new();
            await policy.ApplyAsync(httpContext, candidates);
            // A second read would answer the opposite, so only the stored decision passes.
            FixedFeature gateFeature = new(!enabled);
            PortfolioInsightsFeatureGate gate = new(gateFeature);
            ResourceExecutingContext context = new(
                new ActionContext(httpContext, new RouteData(), new ActionDescriptor()),
                [],
                []
            );
            bool nextCalled = false;

            // Act
            await gate.OnResourceExecutionAsync(
                context,
                () =>
                {
                    nextCalled = true;
                    return Task.FromResult(new ResourceExecutedContext(context, context.Filters));
                }
            );

            // Assert
            Assert.Equal(1, policyFeature.Calls);
            Assert.Equal(0, gateFeature.Calls);
            Assert.Equal(enabled, nextCalled);
            // Enabled keeps the routed endpoint; disabled replaced it with its short-circuited
            // copy, and the gate answers 403.
            Assert.Equal(enabled, ReferenceEquals(gated, candidates[0].Endpoint));
            if (enabled)
            {
                Assert.Null(context.Result);
            }
            else
            {
                JsonResult forbidden = Assert.IsType<JsonResult>(context.Result);
                Assert.Equal(StatusCodes.Status403Forbidden, forbidden.StatusCode);
                Assert.Equal(new FeatureDisabledResponse("feature_disabled"), forbidden.Value);
            }
        }

        [Fact]
        public async Task ApplyAsync_RequestAborted_ShouldPropagateCancellation()
        {
            // Arrange
            UnansweredFeature feature = new();
            PortfolioInsightsFeatureMatcherPolicy policy = new(feature);
            RouteEndpoint gated = GatedEndpoint();
            CandidateSet candidates = SingleCandidate(gated);
            using CancellationTokenSource requestAborted = new();
            DefaultHttpContext httpContext = new() { RequestAborted = requestAborted.Token };

            // Act
            Task apply = policy.ApplyAsync(httpContext, candidates);
            await feature.CallReceived.WaitAsync(ReadBound);
            requestAborted.Cancel();
            Exception? error = await Record.ExceptionAsync(() => apply.WaitAsync(ReadBound));

            // Assert
            Assert.IsAssignableFrom<OperationCanceledException>(error);
            Assert.Same(gated, candidates[0].Endpoint);
            Assert.Empty(httpContext.Items);
        }

        // The feature over the production PluginProvider and a connector in the given mode.
        private static FeatureUnderTest BuildFeature(SwitchableFlagMode mode)
        {
            SwitchableFeatureFlagServiceConnector connector = new(mode: mode);
            RecordingLogger<PortfolioInsightsFeature> logger = new();
            return new FeatureUnderTest(
                new PortfolioInsightsFeature(new PluginProvider(connector), logger),
                connector,
                logger
            );
        }

        // The production connector over the recording factory, addressed by in-memory
        // configuration rather than an environment variable.
        private static FeatureFlagServiceConnector BuildConnector(
            RecordingHttpClientFactory factory
        )
        {
            IConfiguration configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(
                    new Dictionary<string, string?>
                    {
                        [Constants.FeatureFlagServiceAddress] = FlagServiceAddress,
                    }
                )
                .Build();
            return new FeatureFlagServiceConnector(
                configuration,
                factory,
                new RecordingLogger<FeatureFlagServiceConnector>()
            );
        }

        private static IEnumerable<LogEntry> UnreadableWarnings(RecordingLogSink sink)
        {
            return sink.ByLevel(LogLevel.Warning)
                .Where(entry =>
                    entry.Message.StartsWith(UnreadableWarningPrefix, StringComparison.Ordinal)
                );
        }

        // The reason of each unreadable-flag Warning, in order, so one comparison shows both how
        // many were logged and why.
        private static string UnreadableReasons(RecordingLogSink sink)
        {
            return string.Join(
                ",",
                UnreadableWarnings(sink).Select(entry => entry.GetField("reason"))
            );
        }

        // Runs the production gate over a flag read that only the token the gate passes can end,
        // aborts the request once the read has started, and records how the gate ended.
        private static async Task<AbortedGateRun> RunGateUntilRequestAbortedAsync()
        {
            using CancellationTokenSource requestAborted = new();
            ResourceExecutingContext context = new(
                new ActionContext(
                    new DefaultHttpContext { RequestAborted = requestAborted.Token },
                    new RouteData(),
                    new ActionDescriptor()
                ),
                [],
                []
            );
            UnansweredFeature feature = new();
            PortfolioInsightsFeatureGate gate = new(feature);
            bool nextCalled = false;

            Task gateRun = gate.OnResourceExecutionAsync(
                context,
                () =>
                {
                    nextCalled = true;
                    return Task.FromResult(new ResourceExecutedContext(context, context.Filters));
                }
            );
            await feature.CallReceived.WaitAsync(ReadBound);
            requestAborted.Cancel();
            // The bound fails the test outright, so only a gate that has settled is recorded.
            _ = await Task.WhenAny(gateRun).WaitAsync(ReadBound);
            Exception? error = await Record.ExceptionAsync(() => gateRun);
            return new AbortedGateRun(error, nextCalled, context.Result);
        }

        /// <summary>
        /// Cancels the caller's token and then answers enabled at once: a flag read that
        /// completes in the same moment its request is aborted.
        /// </summary>
        private sealed class CancellingSuccessProvider(CancellationTokenSource caller)
            : BooleanOnlyProvider
        {
            public override Metadata GetMetadata()
            {
                return new Metadata("Cancelling success provider");
            }

            public override Task<ResolutionDetails<bool>> ResolveBooleanValueAsync(
                string flagKey,
                bool defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                caller.Cancel();
                return Task.FromResult(new ResolutionDetails<bool>(flagKey, true));
            }
        }

        /// <summary>
        /// Receives the deadline token but never observes it, like a provider that ignores
        /// cancellation: its read stays pending until the provider is disposed, so only the
        /// feature's own bound on the wait can end the read.
        /// </summary>
        private sealed class DeadlineIgnoringProvider : BooleanOnlyProvider, IDisposable
        {
            private readonly TaskCompletionSource<ResolutionDetails<bool>> _read = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            public override Metadata GetMetadata()
            {
                return new Metadata("Deadline ignoring provider");
            }

            public override Task<ResolutionDetails<bool>> ResolveBooleanValueAsync(
                string flagKey,
                bool defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                return _read.Task;
            }

            // Ends the pending read, so it does not outlive its test.
            public void Dispose()
            {
                _read.TrySetCanceled();
            }
        }

        /// <summary>
        /// Blocks until the deadline token it receives is cancelled and then answers the
        /// requested flag enabled, already completed: a read that succeeds in the moment its
        /// deadline expires, so the feature's own wait cannot tell it from a timely answer.
        /// </summary>
        private sealed class LateAnsweringProvider : BooleanOnlyProvider
        {
            public override Metadata GetMetadata()
            {
                return new Metadata("Late answering provider");
            }

            public override Task<ResolutionDetails<bool>> ResolveBooleanValueAsync(
                string flagKey,
                bool defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                // Waits on the deadline itself, bounded so a feature that never cancels the
                // token fails the test instead of hanging it.
                _ = cancellationToken.WaitHandle.WaitOne(ReadBound);
                // Names the requested flag as PluginProvider does, so only the deadline can
                // make the feature refuse this answer.
                return Task.FromResult(
                    new ResolutionDetails<bool>(
                        flagKey,
                        true,
                        flagMetadata: new ImmutableMetadata(
                            new Dictionary<string, object>
                            {
                                [PluginProvider.FlagIdMetadataKey] = flagKey,
                            }
                        )
                    )
                );
            }
        }

        /// <summary>
        /// Base of the test providers. The feature reads only a boolean, so the other value
        /// types are never resolved.
        /// </summary>
        private abstract class BooleanOnlyProvider : FeatureProvider
        {
            public override Task<ResolutionDetails<string>> ResolveStringValueAsync(
                string flagKey,
                string defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                throw new NotSupportedException();
            }

            public override Task<ResolutionDetails<int>> ResolveIntegerValueAsync(
                string flagKey,
                int defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                throw new NotSupportedException();
            }

            public override Task<ResolutionDetails<double>> ResolveDoubleValueAsync(
                string flagKey,
                double defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                throw new NotSupportedException();
            }

            public override Task<ResolutionDetails<Value>> ResolveStructureValueAsync(
                string flagKey,
                Value defaultValue,
                EvaluationContext? context = null,
                CancellationToken cancellationToken = default
            )
            {
                throw new NotSupportedException();
            }
        }

        /// <summary>
        /// A flag read that never answers: it signals that the gate called it and then ends
        /// only when the token the gate passed is cancelled.
        /// </summary>
        private sealed class UnansweredFeature : IPortfolioInsightsFeature
        {
            private readonly TaskCompletionSource _callReceived = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            private readonly TaskCompletionSource<bool> _answer = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            public Task CallReceived => _callReceived.Task;

            public Task<bool> IsEnabledAsync(CancellationToken cancellationToken)
            {
                _callReceived.TrySetResult();
                return _answer.Task.WaitAsync(cancellationToken);
            }
        }

        /// <summary>A flag read that always answers <paramref name="enabled"/> and counts calls.</summary>
        private sealed class FixedFeature(bool enabled) : IPortfolioInsightsFeature
        {
            private int _calls;

            public int Calls => Volatile.Read(ref _calls);

            public Task<bool> IsEnabledAsync(CancellationToken cancellationToken)
            {
                Interlocked.Increment(ref _calls);
                return Task.FromResult(enabled);
            }
        }

        // The attribute that attaches the gate, which the routing policy looks for.
        private static ServiceFilterAttribute GateFilter()
        {
            return new ServiceFilterAttribute(typeof(PortfolioInsightsFeatureGate));
        }

        private static RouteEndpoint GatedEndpoint()
        {
            return BuildEndpoint(GateFilter());
        }

        private static RouteEndpoint UngatedEndpoint()
        {
            return BuildEndpoint();
        }

        // A route endpoint shaped like the insights action, with the given metadata.
        private static RouteEndpoint BuildEndpoint(params object[] metadata)
        {
            return BuildEndpoint(_ => Task.CompletedTask, metadata);
        }

        // Built as MVC builds its endpoints, so it also carries the route diagnostics metadata.
        private static RouteEndpoint BuildEndpoint(
            RequestDelegate requestDelegate,
            object[] metadata
        )
        {
            RouteEndpointBuilder builder = new(
                requestDelegate,
                RoutePatternFactory.Parse("v1/portfolio/insights/{accountId:guid}"),
                0
            )
            {
                DisplayName = "Insights test endpoint",
            };
            foreach (object item in metadata)
            {
                builder.Metadata.Add(item);
            }
            return Assert.IsType<RouteEndpoint>(builder.Build());
        }

        // Runs the gate as MVC's resource filter stage does for the endpoint routing matched, and
        // executes the result it set, as MVC does when a resource filter short-circuits.
        private static async Task RunGateAsResourceFilterAsync(
            PortfolioInsightsFeatureGate gate,
            HttpContext httpContext
        )
        {
            ActionContext actionContext = new(httpContext, new RouteData(), new ActionDescriptor());
            ResourceExecutingContext context = new(actionContext, [], []);
            await gate.OnResourceExecutionAsync(
                context,
                () => Task.FromResult(new ResourceExecutedContext(context, context.Filters))
            );
            if (context.Result is not null)
            {
                await context.Result.ExecuteResultAsync(actionContext);
            }
        }

        // The type of the marker ShortCircuit() adds, which is not public: the one item that
        // convention adds to an empty endpoint builder.
        private static Type ShortCircuitMarkerType()
        {
            RouteEndpointBuilder builder = new(null, RoutePatternFactory.Parse("/"), 0);
            new ConventionCollector(builder).ShortCircuit();
            return Assert.Single(builder.Metadata).GetType();
        }

        /// <summary>Applies each convention it is given straight to <paramref name="builder"/>.</summary>
        private sealed class ConventionCollector(EndpointBuilder builder)
            : IEndpointConventionBuilder
        {
            public void Add(Action<EndpointBuilder> convention)
            {
                convention(builder);
            }
        }

        // One valid candidate, as routing leaves a request that matched a single endpoint.
        private static CandidateSet SingleCandidate(Endpoint endpoint)
        {
            return new CandidateSet([endpoint], [new RouteValueDictionary()], [0]);
        }

        /// <summary>
        /// Passes every call to <paramref name="inner"/> and signals once its first call has
        /// finished, so a test reads the inner connector's record only after that call unwound.
        /// </summary>
        private sealed class FinishSignallingConnector(IFeatureFlagServiceConnector inner)
            : IFeatureFlagServiceConnector
        {
            private readonly TaskCompletionSource _callFinished = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            public Task CallFinished => _callFinished.Task;

            public Task<Flag?> GetFlag(string id)
            {
                return GetFlag(id, CancellationToken.None);
            }

            public async Task<Flag?> GetFlag(string id, CancellationToken cancellationToken)
            {
                try
                {
                    return await inner.GetFlag(id, cancellationToken);
                }
                finally
                {
                    _callFinished.TrySetResult();
                }
            }
        }

        /// <summary>A feature over the production provider, its connector and its logger.</summary>
        private sealed record FeatureUnderTest(
            PortfolioInsightsFeature Feature,
            SwitchableFeatureFlagServiceConnector Connector,
            RecordingLogger<PortfolioInsightsFeature> Logger
        );

        /// <summary>
        /// What a read ended by the deadline showed, compared whole so one assertion reports
        /// every part that differs.
        /// </summary>
        private sealed record DeadlineRead(
            bool Enabled,
            bool EndedAtDeadline,
            bool ConnectorTokenCancelled,
            string WarningReasons
        );

        /// <summary>How the gate ended for a request aborted during its flag read.</summary>
        private sealed record AbortedGateRun(
            Exception? Error,
            bool NextCalled,
            IActionResult? Result
        );
    }
}
