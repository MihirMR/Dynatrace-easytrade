using EasyTrade.BrokerService.Entities.Alerts.Controllers;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Scheduler;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances.Service;
using EasyTrade.BrokerService.Entities.Instruments.Service;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Trades.Scheduler;
using EasyTrade.BrokerService.Entities.Trades.Service;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OpenFeature;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>
    /// The shipped composition root, <c>AddBrokerServiceDependencyGroup()</c>, as the broker
    /// process builds it: what it registers for Portfolio Insights, the lifetimes it gives them,
    /// that the existing registrations stay in place, and that the host starts and skips its
    /// startup evaluation cycle while the flag service refuses connections.
    /// </summary>
    [Collection(BrokerHostCollection.Name)]
    public class BrokerRegistrationTests
    {
        // Bounds the schedulers' startup run, far inside the 3,600 s interval the host sets, so
        // the startup cycle is the only alert evaluation cycle a test can see.
        private static readonly TimeSpan StartupWait = TimeSpan.FromSeconds(10);

        // How long both hosted services may take to stop.
        private static readonly TimeSpan StopDeadline = TimeSpan.FromSeconds(5);

        [Fact]
        public async Task AddBrokerServiceDependencyGroup_NewServices_ShouldResolve()
        {
            // Arrange
            // The stub starts with the flag off, as BrokerTestHost asks, so the startup cycle
            // takes its skip path; the flag reads below switch it on, then off again.
            await using StubHttpServer stub = await StubHttpServer.StartAsync(
                enableGrpcListener: true
            );
            stub.SetFlagEnabled(false);
            // The real gRPC repositories stay registered, so the resolutions below see the
            // composition root's own AlertRepository rather than the host's fake.
            await using BrokerTestHost host = await BrokerTestHost.StartProductionAsync(
                stub,
                options => options.KeepRealRepositories = true
            );
            await host.WaitForStartupLinesAsync(StartupWait);
            stub.ClearRecordings();
            IServiceProvider root = host.Services;

            // Act
            await using AsyncServiceScope scope = root.CreateAsyncScope();
            await using AsyncServiceScope otherScope = root.CreateAsyncScope();
            IServiceProvider services = scope.ServiceProvider;
            IServiceProvider otherServices = otherScope.ServiceProvider;

            IPortfolioInsightsFeature feature =
                services.GetRequiredService<IPortfolioInsightsFeature>();
            PortfolioInsightsMetrics? metrics = services.GetService<PortfolioInsightsMetrics>();
            PortfolioInsightsFeatureGate? gate =
                services.GetService<PortfolioInsightsFeatureGate>();
            FeatureProvider? featureProvider = services.GetService<FeatureProvider>();
            IHostedService[] hostedServices = root.GetServices<IHostedService>().ToArray();
            MatcherPolicy[] matcherPolicies = root.GetServices<MatcherPolicy>().ToArray();

            stub.SetFlagEnabled(true);
            bool enabledRead = await feature.IsEnabledAsync(CancellationToken.None);
            StubRecordedRequest[] readsAfterEnabled = FlagReads(stub);
            stub.SetFlagEnabled(false);
            bool disabledRead = await feature.IsEnabledAsync(CancellationToken.None);
            StubRecordedRequest[] readsAfterDisabled = FlagReads(stub);

            // Assert
            // The Portfolio Insights registrations, each with its planned implementation.
            Assert.IsType<AlertRepository>(services.GetService<IAlertRepository>());
            Assert.IsType<PortfolioInsightsService>(
                services.GetService<IPortfolioInsightsService>()
            );
            Assert.IsType<AlertService>(services.GetService<IAlertService>());
            Assert.IsType<AlertEvaluationService>(services.GetService<IAlertEvaluationService>());
            Assert.IsType<PortfolioInsightsFeature>(feature);
            Assert.NotNull(gate);
            Assert.NotNull(metrics);

            // Singletons are shared across scopes; the gate is created per resolution.
            Assert.Same(feature, otherServices.GetService<IPortfolioInsightsFeature>());
            Assert.Same(metrics, otherServices.GetService<PortfolioInsightsMetrics>());
            Assert.NotSame(gate, services.GetService<PortfolioInsightsFeatureGate>());

            // Both periodic jobs run as hosted services.
            Assert.Contains(hostedServices, service => service is LongTradeSchedulerService);
            Assert.Contains(hostedServices, service => service is AlertEvaluationSchedulerService);

            // Routing holds the notifications-literal policy once, beside the framework's own.
            Assert.Single(matcherPolicies.OfType<AlertController.NotificationsMatcherPolicy>());

            // The OpenFeature provider is the one PluginProvider singleton.
            Assert.IsType<PluginProvider>(featureProvider);
            Assert.Same(featureProvider, otherServices.GetService<FeatureProvider>());
            Assert.Same(featureProvider, root.GetService<FeatureProvider>());

            // The feature reads that provider's flag-service request afresh on every call.
            Assert.True(enabledRead);
            StubRecordedRequest enabledRequest = Assert.Single(readsAfterEnabled);
            Assert.Equal(HttpMethod.Get.Method, enabledRequest.Method);
            Assert.False(disabledRead);
            Assert.Equal(2, readsAfterDisabled.Length);
            Assert.All(
                readsAfterDisabled,
                request => Assert.Equal(HttpMethod.Get.Method, request.Method)
            );

            // The registrations the existing trading flows and problem patterns rely on.
            Assert.NotNull(services.GetService<IPortfolioService>());
            Assert.NotNull(services.GetService<ITradeService>());
            Assert.NotNull(services.GetService<ILongTradeService>());
            Assert.NotNull(services.GetService<IBalanceService>());
            Assert.NotNull(services.GetService<IInstrumentService>());
            Assert.NotNull(services.GetService<IPluginManager>());
        }

        [Fact]
        public async Task StartHost_FlagServiceRefused_ShouldStartAndSkipStartupCycle()
        {
            // Arrange
            await using StubHttpServer stub = await StubHttpServer.StartAsync();
            await stub.SetModeAsync(StubRoute.Flag, StubMode.Refuse);
            stub.SetLatestPrices([]);

            // Act
            await using BrokerTestHost host = await BrokerTestHost.StartProductionAsync(stub);
            LogEntry skipLine = await host.Logs.WaitForAsync(IsEvaluationSkipLine, StartupWait);
            Exception? stopFailure = await Record.ExceptionAsync(
                () => host.StopAsync().WaitAsync(StopDeadline)
            );

            // Assert
            Assert.Equal(LogLevel.Debug, skipLine.Level);
            // Refused connections reach nothing, so the skip follows a failed read.
            Assert.Equal(0, stub.Count(StubHttpServer.FlagPath));
            Assert.Equal(0, host.Alerts.ListCallCount);
            Assert.Empty(
                host.Logs.WithMessageStartingWith(BrokerTestHost.AlertCycleFinishedPrefix)
            );
            Assert.Null(stopFailure);
        }

        private static StubRecordedRequest[] FlagReads(StubHttpServer stub)
        {
            return stub
                .Requests.Where(request =>
                    string.Equals(request.Path, StubHttpServer.FlagPath, StringComparison.Ordinal)
                )
                .ToArray();
        }

        private static bool IsEvaluationSkipLine(LogEntry entry)
        {
            return string.Equals(
                    entry.Category,
                    RecordingLogSink.CategoryOf<AlertEvaluationService>(),
                    StringComparison.Ordinal
                )
                && string.Equals(
                    entry.Message,
                    BrokerTestHost.AlertEvaluationSkippedMessage,
                    StringComparison.Ordinal
                );
        }
    }
}
