using System.Diagnostics;
using System.Net;
using EasyTrade.BrokerService.Entities.Alerts.Service;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.Entities.Instruments.Repository;
using EasyTrade.BrokerService.Entities.Prices;
using EasyTrade.BrokerService.Test.Fakes;
using Microsoft.Extensions.DependencyInjection;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>
    /// Proves, at the receiving side, which W3C trace context the broker's existing clients send:
    /// the flag connector, the pricing connector and the shared db-adapter gRPC channel all point
    /// at a <see cref="StubHttpServer"/> that records every request's headers. The broker runs
    /// its shipped registrations with the real repositories, so db-adapter calls reach the
    /// stub's HTTP/2 listener, which answers each with <c>grpc-status</c> 12; the broker's
    /// responses are therefore errors, and only the recorded headers are asserted.
    /// </summary>
    /// <remarks>
    /// No <c>ActivityListener</c> and no tracing package is involved: ASP.NET Core hosting starts
    /// the request <c>Activity</c> parented to the inbound <c>traceparent</c>, and the HTTP and
    /// gRPC clients inject the current <c>Activity</c>'s context, and only when there is one.
    /// </remarks>
    [Collection(BrokerHostCollection.Name)]
    public class TraceContextTests
    {
        /// <summary>The outbound calls a broker request is expected to cause.</summary>
        [Flags]
        public enum OutboundLeg
        {
            /// <summary>
            /// <c>GET /v1/flags/portfolio-insights-enabled</c> on the flag listener.
            /// </summary>
            Flag = 1,

            /// <summary>Any gRPC call on the stub's HTTP/2 listener.</summary>
            DbAdapter = 2,

            /// <summary><c>GET /v1/prices/latest</c> on the pricing listener.</summary>
            Price = 4,
        }

        // Every new endpoint reads the flag and then calls db-adapter.
        private const OutboundLeg FlagAndDbAdapter = OutboundLeg.Flag | OutboundLeg.DbAdapter;
        private const OutboundLeg AllLegs = FlagAndDbAdapter | OutboundLeg.Price;

        private const string TraceId = "0af7651916cd43dd8448eb211c80319c";
        private const string InboundTraceparent = "00-" + TraceId + "-b7ad6b7169203331-01";
        private const string TraceparentHeader = "traceparent";

        private const string AccountIdText = "3f2b8c1e-5a47-4d9b-8e21-6c0d4f7a9b13";
        private const string AlertIdText = "8d4e2f6a-1b3c-4e5f-9a7b-0c2d4e6f8a1b";
        private const string InstrumentIdText = "c0000000-0000-4000-8000-000000000001";

        private const string InsightsPath = "v1/portfolio/insights/" + AccountIdText;
        private const string AlertsPath = "v1/alerts";
        private const string AlertPath = AlertsPath + "/" + AlertIdText;
        private const string ListPath = AlertsPath + "?accountId=" + AccountIdText;
        private const string NotificationsPath =
            AlertsPath + "/notifications?accountId=" + AccountIdText + "&unacknowledged=true";
        private const string AcknowledgePath = AlertPath + "/acknowledge";

        // Passes every field rule, so the request reaches the account check on db-adapter.
        private const string CreateBody =
            "{\"accountId\":\""
            + AccountIdText
            + "\",\"type\":\"TARGET_PRICE\",\"instrumentId\":\""
            + InstrumentIdText
            + "\",\"direction\":\"ABOVE\",\"threshold\":100.5}";

        private const string EnableBody = "{\"enabled\":true}";

        private static readonly Guid AccountId = Guid.Parse(AccountIdText);
        private static readonly Guid InstrumentId = Guid.Parse(InstrumentIdText);

        // Bounds the wait for both schedulers' startup runs; no test sleeps.
        private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(10);

        /// <summary>
        /// Every outbound flag, price and db-adapter request a broker request causes carries the
        /// inbound trace id. The <c>insights-price-leg</c> row replaces only the balance and
        /// instrument repositories with seeded fakes (<paramref name="seedHolding"/>): with every
        /// repository real the balance check fails before pricing, whereas with a known account
        /// holding 10 units the insights service starts the trades load (real gRPC), the names
        /// load and the latest-prices fetch together, so one request crosses all three legs.
        /// </summary>
        [Theory]
        [InlineData("insights", "GET", InsightsPath, null, false, FlagAndDbAdapter)]
        [InlineData("create", "POST", AlertsPath, CreateBody, false, FlagAndDbAdapter)]
        [InlineData("list", "GET", ListPath, null, false, FlagAndDbAdapter)]
        [InlineData("notifications", "GET", NotificationsPath, null, false, FlagAndDbAdapter)]
        [InlineData("patch", "PATCH", AlertPath, EnableBody, false, FlagAndDbAdapter)]
        [InlineData("delete", "DELETE", AlertPath, null, false, FlagAndDbAdapter)]
        [InlineData("acknowledge", "POST", AcknowledgePath, null, false, FlagAndDbAdapter)]
        [InlineData("insights-price-leg", "GET", InsightsPath, null, true, AllLegs)]
        public async Task Request_FixedTraceparent_ShouldReachEveryOutboundCall(
            string name,
            string method,
            string path,
            string? rawBody,
            bool seedHolding,
            OutboundLeg expectedLegs
        )
        {
            await using StubHttpServer stub = await StubHttpServer.StartAsync(
                enableGrpcListener: true
            );
            await using BrokerTestHost host = await StartHostAsync(stub, seedHolding);

            HttpStatusCode status;
            using (
                HttpResponseMessage response = await BrokerTestHost.SendJsonAsync(
                    host.Client,
                    new HttpMethod(method),
                    path,
                    rawBody,
                    [new KeyValuePair<string, string>(TraceparentHeader, InboundTraceparent)]
                )
            )
            {
                status = response.StatusCode;
            }

            IReadOnlyList<StubRecordedRequest> recorded = stub.Requests;
            string context =
                $"[{name}] {method} {path} answered {(int)status}. Recorded: {Describe(recorded)}";
            AssertLeg(recorded, expectedLegs, OutboundLeg.Flag, IsFlagRequest, context);
            AssertLeg(recorded, expectedLegs, OutboundLeg.DbAdapter, IsDbAdapterRequest, context);
            AssertLeg(recorded, expectedLegs, OutboundLeg.Price, IsPriceRequest, context);
            foreach (StubRecordedRequest request in recorded)
            {
                Assert.True(
                    string.Equals(TraceId, ReadTraceId(request), StringComparison.Ordinal),
                    $"{request.Listener} {request.Method} {request.Path} did not carry trace id "
                        + $"[{TraceId}]. {context}"
                );
            }
        }

        /// <summary>
        /// An evaluation cycle outside any request has no ambient <c>Activity</c>, so neither its
        /// flag read nor its db-adapter call carries a <c>traceparent</c>.
        /// </summary>
        [Fact]
        public async Task RunCycle_OutsideRequest_ShouldSendNoTraceparent()
        {
            await using StubHttpServer stub = await StubHttpServer.StartAsync(
                enableGrpcListener: true
            );
            await using BrokerTestHost host = await StartHostAsync(stub, false);

            Assert.Null(Activity.Current);
            AlertEvaluationResult result = await host.RunCycleAsync();

            IReadOnlyList<StubRecordedRequest> recorded = stub.Requests;
            string context = $"Outcome {result.Outcome}. Recorded: {Describe(recorded)}";
            // The flag read succeeded and ListAlerts reached the gRPC stub, whose status 12 fails
            // the cycle; Failed therefore proves the db-adapter leg ran.
            Assert.True(result.Outcome == AlertEvaluationOutcome.Failed, context);
            Assert.True(recorded.Any(IsFlagRequest), $"No flag request. {context}");
            Assert.True(recorded.Any(IsDbAdapterRequest), $"No db-adapter request. {context}");
            foreach (StubRecordedRequest request in recorded)
            {
                Assert.False(
                    request.Headers.ContainsKey(TraceparentHeader),
                    $"{request.Listener} {request.Method} {request.Path} carried a traceparent. "
                        + context
                );
            }
        }

        // Production registrations with the real repositories on the stub's gRPC listener. The
        // flag answers false until both schedulers have finished their startup runs, so the
        // alert cycle takes its skip path; it is then switched on so requests pass the gate, and
        // the recordings are cleared so a test sees only the requests it caused.
        private static async Task<BrokerTestHost> StartHostAsync(
            StubHttpServer stub,
            bool seedHolding
        )
        {
            stub.SetFlagEnabled(false);
            stub.SetLatestPrices(
                [new Price(InstrumentId, DateTimeOffset.UtcNow, 100m, 102m, 99m, 101m)]
            );

            BrokerTestHost host = await BrokerTestHost.StartProductionAsync(
                stub,
                options =>
                {
                    options.KeepRealRepositories = true;
                    if (seedHolding)
                    {
                        options.ConfigureServices = services =>
                        {
                            services.AddSingleton<IBalanceRepository>(provider =>
                                provider.GetRequiredService<FakeBalanceRepository>()
                            );
                            services.AddSingleton<IInstrumentRepository>(provider =>
                                provider.GetRequiredService<FakeInstrumentRepository>()
                            );
                        };
                    }
                }
            );

            try
            {
                await host.WaitForStartupLinesAsync(StartupTimeout);
                // Seeded once the schedulers are idle, as the fakes' lists are not synchronised.
                if (seedHolding)
                {
                    host.Balances.AddBalance(new Balance(AccountId, 1000m));
                    host.Instruments.AddInstrument(
                        new Instrument(InstrumentId, Guid.Empty, "STUB", "Stub instrument", "")
                    );
                    host.Instruments.AddOwned(new OwnedInstrument(AccountId, InstrumentId, 10m));
                }
                stub.SetFlagEnabled(true);
                stub.ClearRecordings();
                return host;
            }
            catch
            {
                await host.DisposeAsync();
                throw;
            }
        }

        private static void AssertLeg(
            IReadOnlyList<StubRecordedRequest> recorded,
            OutboundLeg expectedLegs,
            OutboundLeg leg,
            Func<StubRecordedRequest, bool> isLeg,
            string context
        )
        {
            if (expectedLegs.HasFlag(leg))
            {
                Assert.True(recorded.Any(isLeg), $"No {leg} request was recorded. {context}");
            }
        }

        private static bool IsFlagRequest(StubRecordedRequest request)
        {
            return IsHttpPath(request, StubHttpServer.FlagPath);
        }

        private static bool IsPriceRequest(StubRecordedRequest request)
        {
            return IsHttpPath(request, StubHttpServer.LatestPricesPath);
        }

        private static bool IsDbAdapterRequest(StubRecordedRequest request)
        {
            return string.Equals(
                request.Listener,
                StubHttpServer.GrpcListenerName,
                StringComparison.Ordinal
            );
        }

        private static bool IsHttpPath(StubRecordedRequest request, string path)
        {
            return string.Equals(
                    request.Listener,
                    StubHttpServer.HttpListenerName,
                    StringComparison.Ordinal
                ) && string.Equals(request.Path, path, StringComparison.Ordinal);
        }

        // A traceparent is version-traceid-spanid-flags. Each hop sends its own span id, so only
        // the trace id identifies the trace; anything else, a repeated header included, is null.
        private static string? ReadTraceId(StubRecordedRequest request)
        {
            if (!request.Headers.TryGetValue(TraceparentHeader, out string? traceparent))
            {
                return null;
            }
            string[] segments = traceparent.Split('-');
            return segments.Length == 4 ? segments[1] : null;
        }

        private static string Describe(IReadOnlyList<StubRecordedRequest> requests)
        {
            if (requests.Count == 0)
            {
                return "(none)";
            }
            return string.Join(
                "; ",
                requests.Select(request =>
                {
                    string traceparent = request.Headers.GetValueOrDefault(
                        TraceparentHeader,
                        "none"
                    );
                    return $"{request.Listener} {request.Method} {request.Path}"
                        + $"{request.QueryString} traceparent [{traceparent}]";
                })
            );
        }
    }
}
