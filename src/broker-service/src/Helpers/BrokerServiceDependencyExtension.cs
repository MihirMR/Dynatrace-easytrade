using EasyTrade.BrokerService.Entities.Alerts.Controllers;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
using EasyTrade.BrokerService.Entities.Alerts.Scheduler;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Balances.Service;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Instruments.Service;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Products.Repository;
using EasyTrade.BrokerService.Entities.Trades.Notification;
using EasyTrade.BrokerService.Entities.Trades.Repository;
using EasyTrade.BrokerService.Entities.Trades.Scheduler;
using EasyTrade.BrokerService.Entities.Trades.Service;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Helpers.Metrics;
using EasyTrade.BrokerService.Middleware.CreditCardValidation;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using HostInitActions;
using Microsoft.Extensions.DependencyInjection.Extensions;
using OpenFeature;

namespace EasyTrade.BrokerService.Helpers;

// Extension for grouping Dependency Injection for this project
public static class BrokerServiceDependencyExtension
{
    public static IServiceCollection AddBrokerServiceDependencyGroup(
        this IServiceCollection services
    )
    {
        services
            .AddInstrumentDependency()
            .AddBalanceDependency()
            .AddPriceDependency()
            .AddProductDependency()
            .AddTradesDependency()
            .AddPortfolioDependency()
            .AddProblemPatternsDependency()
            .AddPortfolioInsightsDependency()
            .AddMiddlewareDependency();
        return services;
    }

    private static IServiceCollection AddBalanceDependency(this IServiceCollection services) =>
        services
            .AddTransient<IBalanceRepository, BalanceRepository>()
            .AddTransient<IBalanceService, BalanceService>();

    private static IServiceCollection AddInstrumentDependency(this IServiceCollection services) =>
        services
            .AddTransient<IInstrumentRepository, InstrumentRepository>()
            .AddTransient<IInstrumentService, InstrumentService>();

    private static IServiceCollection AddPriceDependency(this IServiceCollection services) =>
        services.AddTransient<IPriceServiceConnector, PriceServiceConnector>();

    private static IServiceCollection AddProductDependency(this IServiceCollection services) =>
        services.AddTransient<IProductRepository, ProductRepository>();

    private static IServiceCollection AddTradesDependency(this IServiceCollection services)
    {
        services
            .AddTransient<ITradeRepository, TradeRepositoryWithDbNotResponding>()
            .AddTransient<ITradeService, TradeService>()
            .AddTransient<ILongTradeService, LongTradeService>()
            .AddTransient<ITradeNotificationService, TradeNotificationService>()
            .AddHostedService<LongTradeSchedulerService>();

        return services;
    }

    private static IServiceCollection AddProblemPatternsDependency(this IServiceCollection services)
    {
        services
            .AddSingleton<IPluginManager, PluginManager>()
            .AddSingleton<FeatureProvider, PluginProvider>()
            .AddSingleton<IFeatureFlagServiceConnector, FeatureFlagServiceConnector>();
        services
            .AddAsyncServiceInitialization()
            .AddInitAction<IPluginManager>(async (service) => await service.InitializeAsync());
        return services;
    }

    private static IServiceCollection AddPortfolioDependency(this IServiceCollection services) =>
        services.AddTransient<IPortfolioService, PortfolioService>();

    private static IServiceCollection AddPortfolioInsightsDependency(
        this IServiceCollection services
    )
    {
        services
            .AddTransient<IAlertRepository, AlertRepository>()
            .AddTransient<IPortfolioInsightsService, PortfolioInsightsService>()
            .AddTransient<IAlertService, AlertService>()
            .AddTransient<IAlertEvaluationService, AlertEvaluationService>()
            .AddTransient<PortfolioInsightsFeatureGate>()
            .AddSingleton<IPortfolioInsightsFeature, PortfolioInsightsFeature>()
            .AddSingleton<PortfolioInsightsMetrics>()
            .AddHostedService<AlertEvaluationSchedulerService>();
        // PATCH and DELETE on /v1/alerts/notifications answer 404, as for any non-GUID id.
        services.TryAddEnumerable(
            ServiceDescriptor.Singleton<MatcherPolicy, AlertController.NotificationsMatcherPolicy>()
        );

        return services;
    }

    private static IServiceCollection AddMiddlewareDependency(this IServiceCollection services) =>
        services
            .AddSingleton<IMainframeServiceConnector, MainframeServiceConnector>()
            .AddSingleton<CreditCardValidationMiddleware>();
}
