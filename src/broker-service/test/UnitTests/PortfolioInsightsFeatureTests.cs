using System.Diagnostics;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using OpenFeature;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Tests of <see cref="PortfolioInsightsFeature.IsEnabledAsync"/>: the flag read outcomes,
    /// caller cancellation, the read deadline and the Warning logged for an unreadable flag; of
    /// the token path through <see cref="PluginProvider"/> and
    /// <see cref="FeatureFlagServiceConnector"/>, including the unchanged token-less request that
    /// problem-pattern reads send; and of how <see cref="PortfolioInsightsFeatureGate"/> uses the
    /// read when its request is aborted. Each feature is built over a provider instance and the
    /// gate over a fake feature, so the process-wide OpenFeature API is never touched.
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

        // Lower bound of a read ended by the 2 s deadline, allowing for timer granularity.
        private static readonly TimeSpan DeadlineLowerBound = TimeSpan.FromSeconds(1.9);

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
                    WaitedForDeadline: true,
                    ConnectorTokenCancelled: true,
                    WarningReasons: "timeout"
                ),
                new DeadlineRead(
                    enabled,
                    stopwatch.Elapsed >= DeadlineLowerBound,
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
            bool WaitedForDeadline,
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
