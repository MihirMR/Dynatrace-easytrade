using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.Logging;
using OpenFeature;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    /// <summary>
    /// Tests of <see cref="PortfolioInsightsFeature.IsEnabledAsync"/>: the flag read outcomes,
    /// caller cancellation and the Warning logged for an unreadable flag. Each feature is built
    /// over a provider instance, so the process-wide OpenFeature API is never touched.
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

        /// <summary>
        /// Cancels the caller's token and then answers enabled at once: a flag read that
        /// completes in the same moment its request is aborted.
        /// </summary>
        private sealed class CancellingSuccessProvider(CancellationTokenSource caller)
            : FeatureProvider
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

            // The feature reads only a boolean, so the other value types are never resolved.
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
    }
}
