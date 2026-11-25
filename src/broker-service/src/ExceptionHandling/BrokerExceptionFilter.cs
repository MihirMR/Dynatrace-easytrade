using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace EasyTrade.BrokerService.ExceptionHandling;

public class BrokerExceptionFilter(ILogger<BrokerExceptionFilter> logger) : IExceptionFilter
{
    // Public message of a database failure on a Portfolio Insights endpoint. DbException text
    // names the db-adapter call site and carries the gRPC transport error, which is server
    // diagnostics: the handled-exception log line keeps it, the response body does not.
    private const string DatabaseUnavailableMessage = "Database is unavailable";

    private readonly ILogger _logger = logger;

    public void OnException(ExceptionContext context) => UpdateContext(context, GetStatusCode(context.Exception));

    private static int GetStatusCode(Exception exception) =>
        exception switch
        {
            BalanceNotFoundException
            or InstrumentNotFoundException
            or ProductNotFoundException
            or PriceNotFoundException
            or AlertNotFoundException => StatusCodes.Status404NotFound,
            NotEnoughMoneyException
            or NotEnoughAssetsException
            or NegativeAmountException
            or InvalidAlertException => StatusCodes.Status400BadRequest,
            DbException or PricingUnavailableException => StatusCodes.Status503ServiceUnavailable,
            _ => StatusCodes.Status500InternalServerError,
        };

    private void UpdateContext(ExceptionContext context, int statusCode)
    {
        var typeName = context.Exception.GetType().ToString();
        var message = context.Exception.Message;

        if (statusCode == StatusCodes.Status500InternalServerError)
        {
            _logger.LogError("Exception not handled: ({type}: {message})", typeName, message);
            return;
        }

        ErrorResponse response = new(statusCode, GetPublicMessage(context));
        context.Result = new ObjectResult(response) { StatusCode = statusCode };
        context.ExceptionHandled = true;

        _logger.LogInformation(
            "Exception handled with status [{status}]: ({type}: {message})",
            statusCode,
            typeName.Split('.').Last(),
            message
        );
    }

    // Only the Portfolio Insights endpoints get the stable message; every other endpoint answers
    // with the exception's own message.
    private static string GetPublicMessage(ExceptionContext context)
    {
        if (context.Exception is DbException && IsPortfolioInsightsEndpoint(context))
        {
            return DatabaseUnavailableMessage;
        }

        return context.Exception.Message;
    }

    // An endpoint is a Portfolio Insights endpoint when PortfolioInsightsFeatureGate is attached
    // to it through [ServiceFilter], on the action or on its controller.
    private static bool IsPortfolioInsightsEndpoint(ExceptionContext context)
    {
        return context.ActionDescriptor.FilterDescriptors.Any(descriptor =>
            descriptor.Filter is ServiceFilterAttribute serviceFilter
            && serviceFilter.ServiceType == typeof(PortfolioInsightsFeatureGate)
        );
    }
}
