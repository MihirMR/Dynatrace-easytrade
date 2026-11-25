using System.Diagnostics;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Portfolio.DTO;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;
using EasyTrade.BrokerService.Entities.Trades.Repository;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers.Metrics;

namespace EasyTrade.BrokerService.Entities.Portfolio.Service
{
    /// <summary>
    /// Loads an account's holdings, trades and latest prices through the existing data access and
    /// leaves every valuation rule to <see cref="PortfolioInsightsCalculator"/> and
    /// <see cref="LatestPriceSelector"/>. It holds no state, so the alert evaluator may call it
    /// from parallel tasks.
    /// </summary>
    public class PortfolioInsightsService(
        IBalanceRepository balanceRepository,
        IInstrumentRepository instrumentRepository,
        ITradeRepository tradeRepository,
        IPriceServiceConnector priceServiceConnector,
        PortfolioInsightsMetrics metrics,
        ILogger<PortfolioInsightsService> logger
    ) : IPortfolioInsightsService
    {
        private const string PricesUnavailableMessage = "Latest prices are unavailable";

        private static readonly IReadOnlyDictionary<Guid, string> NoNames =
            new Dictionary<Guid, string>();

        /// <inheritdoc />
        public async Task<PortfolioInsightsDTO> GetInsightsAsync(Guid accountId)
        {
            Stopwatch stopwatch = Stopwatch.StartNew();

            _ =
                await balanceRepository.GetBalanceOfAccountAsync(accountId)
                ?? throw new BalanceNotFoundException(accountId);

            IReadOnlyList<OwnedInstrument> holdings = PortfolioInsightsCalculator.SelectHoldings(
                await instrumentRepository.GetOwnedInstrumentsOfAccountAsync(accountId)
            );
            if (holdings.Count == 0)
            {
                // Names, trades and prices are not read, so an unreachable pricing service cannot
                // turn the empty result of an account without holdings into a 503.
                return Complete(accountId, PortfolioInsightsCalculator.Empty(), 0, stopwatch);
            }

            Task<List<Instrument>> instrumentsTask = instrumentRepository.GetAllInstrumentsAsync();
            Task<List<Trade>> tradesTask = tradeRepository.GetAccountTradesAsync(
                accountId,
                false,
                false
            );
            Task<List<Price>> pricesTask = FetchLatestPricesAsync();
            await Task.WhenAll(instrumentsTask, tradesTask, pricesTask);

            // The connector answers a non-200 from pricing with an empty list.
            List<Price> prices = await pricesTask;
            if (prices.Count == 0)
            {
                throw new PricingUnavailableException(PricesUnavailableMessage);
            }
            IReadOnlyDictionary<Guid, Price> selected = LatestPriceSelector.Select(prices);

            // TryAdd keeps the first name of a duplicated id where ToDictionary would throw.
            Dictionary<Guid, string> names = new();
            foreach (Instrument instrument in await instrumentsTask)
            {
                names.TryAdd(instrument.Id, instrument.Name);
            }

            IReadOnlyList<HoldingPosition> positions = PortfolioInsightsCalculator.BuildPositions(
                holdings,
                names,
                await tradesTask,
                selected
            );
            foreach (HoldingPosition position in positions)
            {
                if (!position.HasPrice)
                {
                    LogMissingPrice(position.InstrumentId, accountId);
                }
            }

            PortfolioInsightsDTO dto = PortfolioInsightsCalculator.Calculate(positions);
            return Complete(accountId, dto, positions.Count, stopwatch);
        }

        /// <inheritdoc />
        public async Task<IReadOnlyList<HoldingPosition>> GetHoldingPositionsAsync(
            Guid accountId,
            IReadOnlyDictionary<Guid, Price> selectedPrices
        )
        {
            ArgumentNullException.ThrowIfNull(selectedPrices);

            Task<List<OwnedInstrument>> holdingsTask =
                instrumentRepository.GetOwnedInstrumentsOfAccountAsync(accountId);
            Task<List<Trade>> tradesTask = tradeRepository.GetAccountTradesAsync(
                accountId,
                false,
                false
            );
            await Task.WhenAll(holdingsTask, tradesTask);

            return PortfolioInsightsCalculator.BuildPositions(
                await holdingsTask,
                NoNames,
                await tradesTask,
                selectedPrices
            );
        }

        // Materialised inside the try, so a lazily evaluated sequence that fails while being
        // enumerated is reported as unavailable pricing too.
        private async Task<List<Price>> FetchLatestPricesAsync()
        {
            try
            {
                return [.. await priceServiceConnector.GetLatestPrices()];
            }
            catch (Exception exception)
            {
                throw new PricingUnavailableException(PricesUnavailableMessage, exception);
            }
        }

        private PortfolioInsightsDTO Complete(
            Guid accountId,
            PortfolioInsightsDTO dto,
            int holdingCount,
            Stopwatch stopwatch
        )
        {
            stopwatch.Stop();
            metrics.RecordCalculationDuration(stopwatch.Elapsed);

            // The guard avoids boxing the arguments when Information is off (CA1873). The
            // template is binding: tests read its fields and the stack scripts grep its text.
            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(
                    "Portfolio insights for account [{accountId}] holdings [{holdingCount}] "
                        + "value [{totalValue}] risk [{riskLevel}] duration [{durationMs}] ms "
                        + "trace [{traceId}]",
                    accountId,
                    holdingCount,
                    dto.TotalValue,
                    dto.RiskLevel,
                    stopwatch.ElapsedMilliseconds,
                    Activity.Current?.TraceId.ToString()
                );
            }
            return dto;
        }

        private void LogMissingPrice(Guid instrumentId, Guid accountId)
        {
            // The guard avoids boxing the ids when Warning is off (CA1873).
            if (logger.IsEnabled(LogLevel.Warning))
            {
                logger.LogWarning(
                    "Instrument [{instrumentId}] has no latest price for account [{accountId}], "
                        + "valuing it at 0",
                    instrumentId,
                    accountId
                );
            }
        }
    }
}
