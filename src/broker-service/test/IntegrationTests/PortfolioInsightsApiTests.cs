using System.Net;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Entities.Prices.ServiceConnector;
using EasyTrade.BrokerService.Entities.Trades;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    [Collection(BrokerHostCollection.Name)]
    public class PortfolioInsightsApiTests
    {
        private const string InsightsPath = "v1/portfolio/insights/";
        private const string HistoryPath = "v1/portfolio/history/";
        private const string AlphaName = "Alpha";
        private const string BetaName = "Beta";
        private const decimal AccountBalance = 10000;

        // Decimal division keeps 28 significant digits, so a percent computed in another order
        // than the endpoint's may differ in its last digits.
        private const decimal PercentTolerance = 0.000000000001m;

        private static readonly Guid ProductId = Guid.NewGuid();
        private static readonly DateTimeOffset Time = new(2025, 1, 1, 12, 0, 0, TimeSpan.Zero);

        [Fact]
        public async Task GetInsights_FlagDisabled_ShouldReturn403FeatureDisabled()
        {
            // Arrange
            Mock<IPriceServiceConnector> prices = new();
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync(options =>
                options.PriceServiceConnectorOverride = prices.Object
            );
            host.Flag.SetEnabled(false);
            SeededAccount account = SeedAccount(host, (AlphaName, 10m));

            // Act
            using HttpResponseMessage response = await GetInsightsAsync(host, account.AccountId);

            // Assert
            await BrokerTestHost.AssertFeatureDisabledAsync(response);
            // The gate read the flag once and answered before the service reached pricing.
            Assert.Equal(1, host.Flag.CallCount);
            prices.Verify(p => p.GetLatestPrices(), Times.Never());
            prices.VerifyNoOtherCalls();
        }

        [Fact]
        public async Task GetInsights_UnknownAccount_ShouldReturn404()
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);

            // Act
            using HttpResponseMessage response = await GetInsightsAsync(host, Guid.NewGuid());

            // Assert
            await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.NotFound);
        }

        [Theory]
        [InlineData("noRows")]
        [InlineData("zeroQuantityRow")]
        public async Task GetInsights_NoHoldingsPricingUnreachable_ShouldReturnEmpty200(
            string ownedRows
        )
        {
            // Arrange
            Mock<IPriceServiceConnector> prices = UnreachablePricing();
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync(options =>
                options.PriceServiceConnectorOverride = prices.Object
            );
            host.Flag.SetEnabled(true);
            SeededAccount account = ownedRows switch
            {
                "noRows" => SeedAccount(host),
                // A zero quantity is not a holding.
                "zeroQuantityRow" => SeedAccount(host, (AlphaName, 0m)),
                _ => throw new ArgumentOutOfRangeException(nameof(ownedRows), ownedRows, null),
            };

            // Act
            using HttpResponseMessage response = await GetInsightsAsync(host, account.AccountId);
            JsonElement body = await ReadOkJsonAsync(response);

            // Assert
            Assert.Equal(0m, body.GetProperty("totalValue").GetDecimal());
            Assert.Equal(0m, body.GetProperty("totalInvested").GetDecimal());
            Assert.Equal(0m, body.GetProperty("unrealizedPnl").GetDecimal());
            Assert.Equal(0m, body.GetProperty("unrealizedPnlPercent").GetDecimal());
            JsonElement allocations = body.GetProperty("allocations");
            Assert.Equal(JsonValueKind.Array, allocations.ValueKind);
            Assert.Equal(0, allocations.GetArrayLength());
            // GetProperty throws for a missing member, so both nulls are present, not omitted.
            Assert.Equal(JsonValueKind.Null, body.GetProperty("largestPosition").ValueKind);
            Assert.Equal(JsonValueKind.Null, body.GetProperty("riskLevel").ValueKind);
            prices.Verify(p => p.GetLatestPrices(), Times.Never());
        }

        [Fact]
        public async Task GetInsights_TwoHoldings_ShouldReturnCalculatedFigures()
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            SeededAccount account = SeedAccount(host, (AlphaName, 10m), (BetaName, 5m));
            Guid alphaId = account.InstrumentIds[0];
            Guid betaId = account.InstrumentIds[1];
            // The executed buy explains all 10 Alpha units, so Alpha has no opening lot and
            // costs 10 x 100. Beta has no trades, so its 5 units are an opening lot at the latest
            // close and cost 5 x 60.
            host.Trades.Add(
                new Trade(
                    Guid.NewGuid(),
                    account.AccountId,
                    alphaId,
                    "buy",
                    10m,
                    100m,
                    Time.AddHours(-1),
                    Time.AddHours(-1),
                    true,
                    true,
                    "Instant Buy done."
                )
            );
            // Alpha has two candles at the newest timestamp; the greater close, 110, prices it.
            host.Prices.AddPrice(new Price(alphaId, Time, 100m, 112m, 99m, 105m))
                .AddPrice(new Price(alphaId, Time, 100m, 112m, 99m, 110m))
                .AddPrice(new Price(betaId, Time, 58m, 61m, 57m, 60m));

            // Act
            using HttpResponseMessage response = await GetInsightsAsync(host, account.AccountId);
            JsonElement body = await ReadOkJsonAsync(response);

            // Assert
            // Value 10 x 110 + 5 x 60 = 1400; invested 1000 + 300 = 1300.
            Assert.Equal(1400m, body.GetProperty("totalValue").GetDecimal());
            Assert.Equal(1300m, body.GetProperty("totalInvested").GetDecimal());
            Assert.Equal(100m, body.GetProperty("unrealizedPnl").GetDecimal());
            AssertWithinTolerance(
                (100m / 1300m) * 100m,
                body.GetProperty("unrealizedPnlPercent").GetDecimal()
            );

            JsonElement[] allocations = [.. body.GetProperty("allocations").EnumerateArray()];
            Assert.Equal(2, allocations.Length);
            AssertAllocation(allocations[0], alphaId, AlphaName, 10m, 1100m, 1100m / 1400m);
            AssertAllocation(allocations[1], betaId, BetaName, 5m, 300m, 300m / 1400m);
            AssertWithinTolerance(
                100m,
                allocations.Sum(allocation => allocation.GetProperty("percent").GetDecimal())
            );

            JsonElement largest = body.GetProperty("largestPosition");
            AssertAllocation(largest, alphaId, AlphaName, 10m, 1100m, 1100m / 1400m);
            // Alpha holds 78.57 % of the value, above the 50 % HIGH boundary.
            Assert.Equal("HIGH", body.GetProperty("riskLevel").GetString());
        }

        [Theory]
        [InlineData("throws")]
        [InlineData("empty")]
        public async Task GetInsights_PricingFailure_ShouldReturn503(string failure)
        {
            // Arrange
            // "empty" keeps the host's own price fake, which holds no candle.
            IPriceServiceConnector? priceOverride = failure switch
            {
                "throws" => UnreachablePricing().Object,
                "empty" => null,
                _ => throw new ArgumentOutOfRangeException(nameof(failure), failure, null),
            };
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync(options =>
                options.PriceServiceConnectorOverride = priceOverride
            );
            host.Flag.SetEnabled(true);
            SeededAccount account = SeedAccount(host, (AlphaName, 3m));

            // Act
            using HttpResponseMessage response = await GetInsightsAsync(host, account.AccountId);

            // Assert
            await BrokerTestHost.AssertErrorResponseAsync(
                response,
                HttpStatusCode.ServiceUnavailable
            );
        }

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public async Task GetInsights_NonGuidAccount_ShouldReturn404(bool flagEnabled)
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(flagEnabled);

            // Act
            using HttpResponseMessage response = await host.Client.GetAsync(
                $"{InsightsPath}not-a-guid"
            );

            // Assert
            // The {accountId:guid} constraint matches no route, so the gate never runs.
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            Assert.Equal(0, host.Flag.CallCount);
        }

        [Fact]
        public async Task GetPortfolioHistory_FlagDisabled_ShouldReturn200()
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(false);
            SeededAccount account = SeedAccount(host, (AlphaName, 2m));
            // Inside the route's 24 h window; earlier points fall back to this oldest candle.
            host.Prices.AddPrice(
                new Price(
                    account.InstrumentIds[0],
                    DateTimeOffset.UtcNow.AddMinutes(-30),
                    49m,
                    51m,
                    48m,
                    50m
                )
            );

            // Act
            using HttpResponseMessage response = await host.Client.GetAsync(
                $"{HistoryPath}{account.AccountId}"
            );
            JsonElement body = await ReadOkJsonAsync(response);

            // Assert
            JsonElement results = body.GetProperty("results");
            Assert.Equal(JsonValueKind.Array, results.ValueKind);
            Assert.NotEqual(0, results.GetArrayLength());
            Assert.All(
                results.EnumerateArray(),
                point => Assert.Equal(100m, point.GetProperty("totalValue").GetDecimal())
            );
            // The gate is attached to the insights action only, so history never reads the flag.
            Assert.Equal(0, host.Flag.CallCount);
        }

        // Adds an account with a balance and, per entry, a new instrument and an owned row of it.
        private static SeededAccount SeedAccount(
            BrokerTestHost host,
            params (string Name, decimal Quantity)[] ownedRows
        )
        {
            Guid accountId = Guid.NewGuid();
            host.Balances.AddBalance(new Balance(accountId, AccountBalance));
            List<Guid> instrumentIds = [];
            foreach ((string name, decimal quantity) in ownedRows)
            {
                Guid instrumentId = Guid.NewGuid();
                host.Instruments.AddInstrument(
                    new Instrument(
                        instrumentId,
                        ProductId,
                        name.ToUpperInvariant(),
                        name,
                        $"{name} instrument"
                    )
                );
                host.Instruments.AddOwned(new OwnedInstrument(accountId, instrumentId, quantity));
                instrumentIds.Add(instrumentId);
            }
            return new SeededAccount(accountId, instrumentIds);
        }

        private static Mock<IPriceServiceConnector> UnreachablePricing()
        {
            Mock<IPriceServiceConnector> prices = new();
            prices
                .Setup(p => p.GetLatestPrices())
                .ThrowsAsync(new HttpRequestException("Simulated pricing service outage"));
            return prices;
        }

        private static Task<HttpResponseMessage> GetInsightsAsync(
            BrokerTestHost host,
            Guid accountId
        )
        {
            return host.Client.GetAsync($"{InsightsPath}{accountId}");
        }

        // Parses the body first, so a wrong status reports the body it came with.
        private static async Task<JsonElement> ReadOkJsonAsync(HttpResponseMessage response)
        {
            JsonElement body = await BrokerTestHost.ReadJsonAsync(response);
            Assert.True(
                response.StatusCode == HttpStatusCode.OK,
                $"Expected 200 OK, got {(int)response.StatusCode} with body [{body.GetRawText()}]."
            );
            return body;
        }

        private static void AssertAllocation(
            JsonElement allocation,
            Guid instrumentId,
            string name,
            decimal quantity,
            decimal value,
            decimal share
        )
        {
            Assert.Equal(instrumentId, allocation.GetProperty("instrumentId").GetGuid());
            Assert.Equal(name, allocation.GetProperty("name").GetString());
            Assert.Equal(quantity, allocation.GetProperty("quantity").GetDecimal());
            Assert.Equal(value, allocation.GetProperty("value").GetDecimal());
            AssertWithinTolerance(share * 100m, allocation.GetProperty("percent").GetDecimal());
        }

        private static void AssertWithinTolerance(decimal expected, decimal actual)
        {
            Assert.True(
                Math.Abs(expected - actual) <= PercentTolerance,
                $"Expected {expected} within {PercentTolerance}, got {actual}."
            );
        }

        private sealed record SeededAccount(Guid AccountId, IReadOnlyList<Guid> InstrumentIds);
    }
}
