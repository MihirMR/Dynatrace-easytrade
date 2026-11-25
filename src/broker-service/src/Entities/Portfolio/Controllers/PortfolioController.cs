using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Portfolio.Service;
using EasyTrade.BrokerService.ExceptionHandling;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using Microsoft.AspNetCore.Mvc;

namespace EasyTrade.BrokerService.Entities.Portfolio.Controllers;

[ApiController]
[Route("v1/portfolio")]
[TypeFilter(typeof(BrokerExceptionFilter))]
public class PortfolioController(
    IPortfolioService portfolioService,
    IPortfolioInsightsService insightsService
) : ControllerBase
{
    [ProducesResponseType(typeof(PortfolioHistoryDTO), StatusCodes.Status200OK)]
    [HttpGet("history/{accountId:guid}")]
    public async Task<PortfolioHistoryDTO> GetPortfolioHistory(Guid accountId)
    {
        var results = await portfolioService.GetPortfolioHistoryAsync(accountId);
        return new PortfolioHistoryDTO(results);
    }

    /// <summary>
    /// Portfolio insights (requires the portfolio-insights-enabled feature flag)
    /// </summary>
    /// <param name="accountId">Account id</param>
    [ProducesResponseType(typeof(PortfolioInsightsDTO), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ErrorResponse), StatusCodes.Status503ServiceUnavailable)]
    [ServiceFilter(typeof(PortfolioInsightsFeatureGate))]
    [HttpGet("insights/{accountId:guid}")]
    public async Task<PortfolioInsightsDTO> GetPortfolioInsights(Guid accountId)
    {
        return await insightsService.GetInsightsAsync(accountId);
    }
}
