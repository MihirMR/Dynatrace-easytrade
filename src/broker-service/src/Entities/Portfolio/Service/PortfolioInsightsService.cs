using System.Diagnostics;
using EasyTrade.BrokerService.Entities.Alerts.Repository;
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
    /// <see cref="LatestPriceSelector"/>. The existing data access sets no deadline, so
    /// <see cref="GetInsightsAsync"/> awaits each of its calls within
    /// <see cref="AlertRepository.CallTimeout"/> on the injected <see cref="TimeProvider"/>'s
    /// clock, while <see cref="GetHoldingPositionsAsync"/> awaits its reads to the end. It holds
    /// no state, so the alert evaluator may call it from parallel tasks.
    /// </summary>
    public class PortfolioInsightsService(
        IBalanceRepository balanceRepository,
        IInstrumentRepository instrumentRepository,
        ITradeRepository tradeRepository,
        IPriceServiceConnector priceServiceConnector,
        PortfolioInsightsMetrics metrics,
        TimeProvider timeProvider,
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
                await BoundedReadAsync(
                    balanceRepository.GetBalanceOfAccountAsync(accountId),
                    nameof(IBalanceRepository.GetBalanceOfAccountAsync)
                ) ?? throw new BalanceNotFoundException(accountId);

            IReadOnlyList<OwnedInstrument> holdings = PortfolioInsightsCalculator.SelectHoldings(
                await BoundedReadAsync(
                    instrumentRepository.GetOwnedInstrumentsOfAccountAsync(accountId),
                    nameof(IInstrumentRepository.GetOwnedInstrumentsOfAccountAsync)
                )
            );
            if (holdings.Count == 0)
            {
                // Names, trades and prices are not read, so an unreachable pricing service cannot
                // turn the empty result of an account without holdings into a 503.
                return Complete(accountId, PortfolioInsightsCalculator.Empty(), 0, stopwatch);
            }

            Task<List<Instrument>> instrumentsTask = BoundedReadAsync(
                instrumentRepository.GetAllInstrumentsAsync(),
                nameof(IInstrumentRepository.GetAllInstrumentsAsync)
            );
            Task<List<Trade>> tradesTask = BoundedReadAsync(
                tradeRepository.GetAccountTradesAsync(accountId, false, false),
                nameof(ITradeRepository.GetAccountTradesAsync)
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

            // Not bounded by the call budget: these reads take no token, so a wait abandoned at
            // the budget would leave them running while the evaluator's workers start the next
            // accounts, and its concurrency limit would no longer bound db-adapter load. The
            // cycle checks its token once the reads return.
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

        // A db-adapter read through the existing repositories, which set no gRPC deadline, bounded
        // so a db-adapter that never answers fails it with a DbException (503).
        private Task<T> BoundedReadAsync<T>(Task<T> call, string operation)
        {
            return AlertRepository.BoundExistingReadAsync(call, operation, timeProvider);
        }

        // Materialised inside the try, so a lazily evaluated sequence that fails while being
        // enumerated is reported as unavailable pricing too. The existing connector waits for
        // HttpClient's 100 s default, so a fetch with no reply within the call budget is
        // unavailable pricing as well. A malformed response can deserialize to a null candle
        // despite the annotation; it is rejected after the try, so the error is not wrapped twice
        // and never reaches the selector.
        private async Task<List<Price>> FetchLatestPricesAsync()
        {
            List<Price> prices;
            try
            {
                prices =
                [
                    .. await AlertRepository.WithinCallTimeoutAsync(
                        priceServiceConnector.GetLatestPrices(),
                        timeProvider
                    ),
                ];
            }
            catch (Exception exception)
            {
                throw new PricingUnavailableException(PricesUnavailableMessage, exception);
            }

            if (prices.Exists(price => price is null))
            {
                throw new PricingUnavailableException(PricesUnavailableMessage);
            }
            return prices;
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
