using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Logging;
using OpenFeature;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Tests of <see cref="PortfolioInsightsFeature.IsEnabledAsync"/>: the flag read outcomes,
    /// caller cancellation, the read deadline and the Warning logged for an unreadable flag; and
    /// of how <see cref="PortfolioInsightsFeatureGate"/> uses that read when its request is
    /// aborted. Each feature is built over a provider instance and the gate over a fake feature,
    /// so the process-wide OpenFeature API is never touched.
    /// </summary>
    public class PortfolioInsightsFeatureTests
    {
        private const string UnreadableWarningPrefix = "Portfolio insights flag unreadable";

        // Bounds every read, so a regression that hangs fails its test instead of the run.
        private static readonly TimeSpan ReadBound = TimeSpan.FromSeconds(10);

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
            RecordingLogSink sink = new();
            PortfolioInsightsFeature feature = BuildUnreadableFeature(mode, sink);

            // Act
            _ = await feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Collection(UnreadableWarnings(sink), entry => Assert.Null(entry.Exception));
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
            RecordingLogSink sink = new();
            PortfolioInsightsFeature feature = BuildUnreadableFeature(mode, sink);

            // Act
            _ = await feature.IsEnabledAsync(CancellationToken.None).WaitAsync(ReadBound);

            // Assert
            Assert.Collection(
                UnreadableWarnings(sink),
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

        // The production PluginProvider over a connector that fails in the given mode.
        private static PortfolioInsightsFeature BuildUnreadableFeature(
            SwitchableFlagMode mode,
            RecordingLogSink sink
        )
        {
            return new PortfolioInsightsFeature(
                new PluginProvider(new SwitchableFeatureFlagServiceConnector(mode: mode)),
                new RecordingLogger<PortfolioInsightsFeature>(sink)
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

        /// <summary>How the gate ended for a request aborted during its flag read.</summary>
        private sealed record AbortedGateRun(
            Exception? Error,
            bool NextCalled,
            IActionResult? Result
        );
    }
}
