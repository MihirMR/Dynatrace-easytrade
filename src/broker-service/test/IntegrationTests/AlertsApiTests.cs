using System.Globalization;
using System.Net;
using System.Text.Json;
using EasyTrade.BrokerService.Entities.Alerts;
using EasyTrade.BrokerService.Entities.Balances;
using EasyTrade.BrokerService.Entities.Balances.Repository;
using EasyTrade.BrokerService.Entities.Instruments;
using EasyTrade.BrokerService.ExceptionHandling;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Test.Fakes;
using Grpc.Core;
using Microsoft.Extensions.DependencyInjection;

namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    /// <summary>
    /// The six <c>/v1/alerts</c> endpoints over real HTTP on a composed host: the feature gate,
    /// model binding with the exact threshold token, the CRUD rules, the error mapping and the
    /// <c>{"results": [...]}</c> list shape. Every body is sent as raw JSON text, so threshold
    /// tokens reach the converter byte for byte.
    /// </summary>
    [Collection(BrokerHostCollection.Name)]
    public class AlertsApiTests
    {
        /// <summary>One of the six alert endpoints.</summary>
        public enum AlertEndpoint
        {
            Create,
            List,
            Notifications,
            UpdateEnabled,
            Delete,
            Acknowledge,
        }

        /// <summary>A request model binding cannot accept.</summary>
        public enum UnbindableRequest
        {
            MalformedJsonBody,
            QuotedThreshold,
            OverPrecisionThreshold,
            MissingAccountIdQuery,
            NonGuidAccountIdQuery,
        }

        /// <summary>A create request one rule of <c>POST /v1/alerts</c> rejects with 400.</summary>
        public enum InvalidCreateCase
        {
            ThresholdExponent,
            ThresholdElevenIntegerDigits,
            ThresholdNineFractionalDigits,
            MissingAccountId,
            MissingInstrumentId,
            LowercaseType,
            UnknownType,
            MissingType,
            LowercaseDirection,
            MissingDirection,
            MissingThreshold,
            TargetPriceZeroThreshold,
            TargetPriceNegativeThreshold,
            ProfitLossUnheldInstrument,
            ProfitLossZeroQuantityHolding,
        }

        /// <summary>Which layer answers a rejected create request.</summary>
        public enum CreateRejection
        {
            /// <summary>Model binding: the automatic <c>[ApiController]</c> 400 problem.</summary>
            Binding,

            /// <summary>The alert service: an <c>ErrorResponse</c> body.</summary>
            Rule,
        }

        /// <summary>The reference a create request names that does not exist.</summary>
        public enum UnknownReference
        {
            Account,
            Instrument,
        }

        private const string AlertsPath = "v1/alerts";
        private const string TargetPrice = "TARGET_PRICE";
        private const string ProfitLoss = "PROFIT_LOSS";
        private const string Above = "ABOVE";
        private const string EnableBody = """{"enabled":true}""";
        private const string DisableBody = """{"enabled":false}""";
        private const string EmptyResultsBody = """{"results":[]}""";
        private const decimal HeldQuantity = 5m;

        private static readonly Guid ProductId = new("b2000000-0000-4000-8000-000000000001");

        // Older than every time the fake's default clock stamps.
        private static readonly DateTimeOffset CreatedTime = FakeAlertRepository.BaseTime.AddDays(
            -1
        );

        private static readonly string[] AlertFieldNames =
        [
            "id",
            "accountId",
            "instrumentId",
            "type",
            "direction",
            "threshold",
            "enabled",
            "armingRevision",
            "triggeredAt",
            "triggerValue",
            "acknowledged",
            "createdAt",
        ];

        [Theory]
        [InlineData(AlertEndpoint.Create)]
        [InlineData(AlertEndpoint.List)]
        [InlineData(AlertEndpoint.Notifications)]
        [InlineData(AlertEndpoint.UpdateEnabled)]
        [InlineData(AlertEndpoint.Delete)]
        [InlineData(AlertEndpoint.Acknowledge)]
        public async Task AlertEndpoints_FlagDisabled_ShouldReturn403FeatureDisabled(
            AlertEndpoint endpoint
        )
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(false);

            // Act
            using HttpResponseMessage response = await SendToEndpointAsync(
                host,
                endpoint,
                Guid.NewGuid(),
                Guid.NewGuid(),
                Guid.NewGuid()
            );

            // Assert: the gate read the flag once and answered before any db-adapter call.
            await BrokerTestHost.AssertFeatureDisabledAsync(response);
            Assert.Equal([host.Flag.FlagId], host.Flag.RequestedIds);
            Assert.Equal(0, TotalAlertCalls(host.Alerts));
        }

        [Theory]
        [InlineData(UnbindableRequest.MalformedJsonBody, false)]
        [InlineData(UnbindableRequest.MalformedJsonBody, true)]
        [InlineData(UnbindableRequest.QuotedThreshold, false)]
        [InlineData(UnbindableRequest.QuotedThreshold, true)]
        [InlineData(UnbindableRequest.OverPrecisionThreshold, false)]
        [InlineData(UnbindableRequest.OverPrecisionThreshold, true)]
        [InlineData(UnbindableRequest.MissingAccountIdQuery, false)]
        [InlineData(UnbindableRequest.MissingAccountIdQuery, true)]
        [InlineData(UnbindableRequest.NonGuidAccountIdQuery, false)]
        [InlineData(UnbindableRequest.NonGuidAccountIdQuery, true)]
        public async Task AlertEndpoints_UnbindableRequest_ShouldMatchFlagState(
            UnbindableRequest request,
            bool featureEnabled
        )
        {
            // Arrange: a known account and a held instrument, so only binding can reject.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(featureEnabled);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            AlertRequest unbindable = request switch
            {
                UnbindableRequest.MalformedJsonBody => new(
                    HttpMethod.Post,
                    AlertsPath,
                    """{"accountId":"""
                ),
                UnbindableRequest.QuotedThreshold => new(
                    HttpMethod.Post,
                    AlertsPath,
                    CreateBody(fixture.AccountId, fixture.InstrumentId, thresholdToken: "\"100\"")
                ),
                // A plain decimal conversion would round this token to the valid 0.00000001.
                UnbindableRequest.OverPrecisionThreshold => new(
                    HttpMethod.Post,
                    AlertsPath,
                    CreateBody(
                        fixture.AccountId,
                        fixture.InstrumentId,
                        thresholdToken: "0.000000010000000000000000000001"
                    )
                ),
                UnbindableRequest.MissingAccountIdQuery => new(HttpMethod.Get, AlertsPath, null),
                UnbindableRequest.NonGuidAccountIdQuery => new(
                    HttpMethod.Get,
                    $"{AlertsPath}?accountId=not-a-guid",
                    null
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(request), request, null),
            };

            // Act
            using HttpResponseMessage response = await SendAsync(host, unbindable);

            // Assert: off, the gate answers before binding; on, binding answers, not a rule.
            if (featureEnabled)
            {
                await AssertBindingProblemAsync(response);
            }
            else
            {
                await BrokerTestHost.AssertFeatureDisabledAsync(response);
            }
            Assert.Equal(0, TotalAlertCalls(host.Alerts));
            Assert.Empty(host.Alerts.All());
        }

        [Theory]
        [InlineData("PATCH", "v1/alerts/not-a-guid", false)]
        [InlineData("PATCH", "v1/alerts/not-a-guid", true)]
        [InlineData("DELETE", "v1/alerts/not-a-guid", false)]
        [InlineData("DELETE", "v1/alerts/not-a-guid", true)]
        [InlineData("POST", "v1/alerts/not-a-guid/acknowledge", false)]
        [InlineData("POST", "v1/alerts/not-a-guid/acknowledge", true)]
        public async Task AlertEndpoints_NonGuidPath_ShouldReturn404(
            string method,
            string path,
            bool featureEnabled
        )
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(featureEnabled);
            HttpMethod httpMethod = new(method);
            string? body = httpMethod == HttpMethod.Patch ? EnableBody : null;

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(httpMethod, path, body)
            );

            // Assert: no route matches, so neither the gate nor data access runs.
            await AssertStatusAsync(response, HttpStatusCode.NotFound);
            Assert.Equal(0, host.Flag.CallCount);
            Assert.Equal(0, TotalAlertCalls(host.Alerts));
        }

        [Theory]
        [InlineData(TargetPrice)]
        [InlineData(ProfitLoss)]
        public async Task AlertLifecycle_BothTypes_ShouldCreateListDisableRearmDelete(string type)
        {
            // Arrange: the holding a PROFIT_LOSS alert needs; a TARGET_PRICE alert ignores it.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            string listPath = $"{AlertsPath}?accountId={fixture.AccountId}";

            // Act & Assert 1: create answers 201 with the armed alert and no Location header.
            using HttpResponseMessage created = await SendAsync(
                host,
                new AlertRequest(
                    HttpMethod.Post,
                    AlertsPath,
                    CreateBody(fixture.AccountId, fixture.InstrumentId, type, Above, "12.5")
                )
            );
            await AssertStatusAsync(created, HttpStatusCode.Created);
            Assert.Null(created.Headers.Location);
            JsonElement createdJson = await BrokerTestHost.ReadJsonAsync(created);
            Alert stored = Assert.Single(host.Alerts.All());
            Alert expected = new(
                Id: stored.Id,
                AccountId: fixture.AccountId,
                InstrumentId: fixture.InstrumentId,
                Type: Enum.Parse<AlertType>(type),
                Direction: AlertDirection.ABOVE,
                Threshold: 12.5m,
                Enabled: true,
                ArmingRevision: 1,
                TriggeredAt: null,
                TriggerValue: null,
                Acknowledged: false,
                CreatedAt: stored.CreatedAt
            );
            Assert.Equal(expected, stored);
            Assert.Equal(type, createdJson.GetProperty("type").GetString());
            AssertAlertJson(expected, createdJson);
            Guid id = createdJson.GetProperty("id").GetGuid();

            // Act & Assert 2: the list holds exactly that alert.
            using HttpResponseMessage listed = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Get, listPath, null)
            );
            JsonElement[] results = await ReadResultsAsync(listed);
            Assert.Equal([id], results.Select(alert => alert.GetProperty("id").GetGuid()));

            // Act & Assert 3: disabling keeps the arming and answers with the stored snapshot.
            using HttpResponseMessage disabled = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Patch, $"{AlertsPath}/{id}", DisableBody)
            );
            await AssertStatusAsync(disabled, HttpStatusCode.OK);
            Alert disabledRow = Assert.IsType<Alert>(host.Alerts.Get(id));
            Assert.Equal(expected with { Enabled = false }, disabledRow);
            AssertAlertJson(disabledRow, await BrokerTestHost.ReadJsonAsync(disabled));

            // Act & Assert 4: enabling re-arms the alert under the next revision.
            using HttpResponseMessage rearmed = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Patch, $"{AlertsPath}/{id}", EnableBody)
            );
            await AssertStatusAsync(rearmed, HttpStatusCode.OK);
            Alert rearmedRow = Assert.IsType<Alert>(host.Alerts.Get(id));
            Assert.Equal(expected with { ArmingRevision = 2 }, rearmedRow);
            AssertAlertJson(rearmedRow, await BrokerTestHost.ReadJsonAsync(rearmed));

            // Act & Assert 5: delete answers 204 with no body.
            using HttpResponseMessage deleted = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Delete, $"{AlertsPath}/{id}", null)
            );
            await AssertStatusAsync(deleted, HttpStatusCode.NoContent);
            Assert.Empty(await deleted.Content.ReadAsStringAsync());
            Assert.Null(host.Alerts.Get(id));

            // Act & Assert 6: the emptied list is the bare envelope.
            using HttpResponseMessage emptied = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Get, listPath, null)
            );
            Assert.Empty(await ReadResultsAsync(emptied));
            Assert.Equal(EmptyResultsBody, await emptied.Content.ReadAsStringAsync());

            // Act & Assert 7: a second delete finds nothing.
            using HttpResponseMessage deletedAgain = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Delete, $"{AlertsPath}/{id}", null)
            );
            await BrokerTestHost.AssertErrorResponseAsync(deletedAgain, HttpStatusCode.NotFound);
        }

        [Theory]
        [InlineData(TargetPrice, "0.00000001")]
        [InlineData(TargetPrice, "9999999999.99999999")]
        [InlineData(ProfitLoss, "-9999999999.99999999")]
        public async Task CreateAlert_BoundaryThreshold_ShouldRoundTripExactly(
            string type,
            string thresholdToken
        )
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            decimal expected = decimal.Parse(thresholdToken, CultureInfo.InvariantCulture);

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(
                    HttpMethod.Post,
                    AlertsPath,
                    CreateBody(fixture.AccountId, fixture.InstrumentId, type, Above, thresholdToken)
                )
            );

            // Assert: the token comes back verbatim and is stored without rounding.
            await AssertStatusAsync(response, HttpStatusCode.Created);
            JsonElement threshold = (await BrokerTestHost.ReadJsonAsync(response)).GetProperty(
                "threshold"
            );
            Assert.Equal(thresholdToken, threshold.GetRawText());
            Assert.Equal(expected, threshold.GetDecimal());
            Assert.Equal(expected, Assert.Single(host.Alerts.All()).Threshold);
        }

        [Theory]
        [InlineData(InvalidCreateCase.ThresholdExponent, CreateRejection.Binding)]
        [InlineData(InvalidCreateCase.ThresholdElevenIntegerDigits, CreateRejection.Binding)]
        [InlineData(InvalidCreateCase.ThresholdNineFractionalDigits, CreateRejection.Binding)]
        [InlineData(InvalidCreateCase.MissingAccountId, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.MissingInstrumentId, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.LowercaseType, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.UnknownType, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.MissingType, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.LowercaseDirection, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.MissingDirection, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.MissingThreshold, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.TargetPriceZeroThreshold, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.TargetPriceNegativeThreshold, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.ProfitLossUnheldInstrument, CreateRejection.Rule)]
        [InlineData(InvalidCreateCase.ProfitLossZeroQuantityHolding, CreateRejection.Rule)]
        public async Task CreateAlert_InvalidInput_ShouldReturn400(
            InvalidCreateCase invalidCase,
            CreateRejection rejection
        )
        {
            // Arrange: the account and instrument exist, so only the row's rule can reject.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            decimal? heldQuantity = invalidCase switch
            {
                InvalidCreateCase.ProfitLossUnheldInstrument => null,
                InvalidCreateCase.ProfitLossZeroQuantityHolding => 0m,
                _ => HeldQuantity,
            };
            AccountFixture fixture = SeedAccount(host, heldQuantity);

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(
                    HttpMethod.Post,
                    AlertsPath,
                    InvalidCreateBody(invalidCase, fixture)
                )
            );

            // Assert
            if (rejection == CreateRejection.Binding)
            {
                await AssertBindingProblemAsync(response);
            }
            else
            {
                await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.BadRequest);
            }
            Assert.Equal(0, host.Alerts.CallCount(FakeAlertRepositoryMethod.Create));
            Assert.Empty(host.Alerts.All());
        }

        [Theory]
        [InlineData(UnknownReference.Account)]
        [InlineData(UnknownReference.Instrument)]
        public async Task CreateAlert_UnknownReference_ShouldReturn404(UnknownReference reference)
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            Guid accountId =
                reference == UnknownReference.Account ? Guid.NewGuid() : fixture.AccountId;
            Guid instrumentId =
                reference == UnknownReference.Instrument ? Guid.NewGuid() : fixture.InstrumentId;

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Post, AlertsPath, CreateBody(accountId, instrumentId))
            );

            // Assert
            await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.NotFound);
            Assert.Equal(0, host.Alerts.CallCount(FakeAlertRepositoryMethod.Create));
            Assert.Empty(host.Alerts.All());
        }

        [Theory]
        [InlineData(AlertEndpoint.List)]
        [InlineData(AlertEndpoint.Notifications)]
        public async Task ListEndpoints_UnknownAccount_ShouldReturn404(AlertEndpoint endpoint)
        {
            // Arrange: an alert under an id with no balance row, which makes it unknown.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            Guid unknownAccountId = Guid.NewGuid();
            host.Alerts.Seed(ArmedAlert(unknownAccountId, Guid.NewGuid(), CreatedTime));

            // Act
            using HttpResponseMessage response = await SendToEndpointAsync(
                host,
                endpoint,
                unknownAccountId,
                Guid.NewGuid(),
                Guid.NewGuid()
            );

            // Assert: the account check answers before any alert is listed.
            await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.NotFound);
            Assert.Equal(0, host.Alerts.ListCallCount);
        }

        [Theory]
        [InlineData("{}")]
        [InlineData("""{"enabled":null}""")]
        public async Task UpdateAlert_MissingEnabled_ShouldReturn400(string body)
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            Alert seeded = ArmedAlert(fixture.AccountId, fixture.InstrumentId, CreatedTime);
            host.Alerts.Seed(seeded);

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Patch, $"{AlertsPath}/{seeded.Id}", body)
            );

            // Assert: a missing value never defaults to false, so the row is untouched.
            await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.BadRequest);
            Assert.Equal(seeded, host.Alerts.Get(seeded.Id));
            Assert.Equal(0, host.Alerts.CallCount(FakeAlertRepositoryMethod.UpdateEnabled));
        }

        [Theory]
        [InlineData(AlertEndpoint.UpdateEnabled)]
        [InlineData(AlertEndpoint.Delete)]
        [InlineData(AlertEndpoint.Acknowledge)]
        public async Task AlertById_UnknownAlert_ShouldReturn404(AlertEndpoint endpoint)
        {
            // Arrange: a stored alert that the random id does not name.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            Alert seeded = ArmedAlert(fixture.AccountId, fixture.InstrumentId, CreatedTime);
            host.Alerts.Seed(seeded);

            // Act
            using HttpResponseMessage response = await SendToEndpointAsync(
                host,
                endpoint,
                fixture.AccountId,
                fixture.InstrumentId,
                Guid.NewGuid()
            );

            // Assert
            await BrokerTestHost.AssertErrorResponseAsync(response, HttpStatusCode.NotFound);
            Assert.Equal([seeded], host.Alerts.All());
        }

        [Theory]
        [InlineData(AlertEndpoint.Create, FakeAlertRepositoryMethod.Create)]
        [InlineData(AlertEndpoint.List, FakeAlertRepositoryMethod.List)]
        [InlineData(AlertEndpoint.Notifications, FakeAlertRepositoryMethod.List)]
        [InlineData(AlertEndpoint.UpdateEnabled, FakeAlertRepositoryMethod.UpdateEnabled)]
        [InlineData(AlertEndpoint.Delete, FakeAlertRepositoryMethod.Get)]
        [InlineData(AlertEndpoint.Delete, FakeAlertRepositoryMethod.Delete)]
        [InlineData(AlertEndpoint.Acknowledge, FakeAlertRepositoryMethod.Get)]
        [InlineData(AlertEndpoint.Acknowledge, FakeAlertRepositoryMethod.Acknowledge)]
        public async Task AlertEndpoints_DbAdapterFails_ShouldReturn503(
            AlertEndpoint endpoint,
            FakeAlertRepositoryMethod failingMethod
        )
        {
            // Arrange: every reference exists, so the injected failure is the only fault.
            const string diagnostic = "Db Adapter call error: simulated outage";
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            Alert seeded = ArmedAlert(fixture.AccountId, fixture.InstrumentId, CreatedTime);
            host.Alerts.Seed(seeded);
            host.Alerts.ThrowOnNext(failingMethod, new DbException(diagnostic));

            // Act
            using HttpResponseMessage response = await SendToEndpointAsync(
                host,
                endpoint,
                fixture.AccountId,
                fixture.InstrumentId,
                seeded.Id
            );

            // Assert: the failure reached the call it was injected into, and its diagnostic
            // text stays in the server log rather than the response.
            await BrokerTestHost.AssertErrorResponseAsync(
                response,
                HttpStatusCode.ServiceUnavailable
            );
            Assert.DoesNotContain(diagnostic, await response.Content.ReadAsStringAsync());
            Assert.Equal(1, host.Alerts.CallCount(failingMethod));
        }

        [Fact]
        public async Task CreateAlert_BalanceReadFails_ShouldReturn503WithoutLoggingDriverDetail()
        {
            // Arrange: the existing balance read, the create's account check, fails as
            // GrpcHelper reports it, with a driver diagnostic that names a database login.
            string marker = $"driver-diagnostic-{Guid.NewGuid():N}";
            RpcException driverError = new(
                new Status(
                    StatusCode.Unknown,
                    $"login error: Login failed for user '{marker}' at db:1433"
                )
            );
            Mock<IBalanceRepository> balances = new();
            balances
                .Setup(repository => repository.GetBalanceOfAccountAsync(It.IsAny<Guid>()))
                .Returns(
                    () =>
                        GrpcHelper.ExecuteAsync(
                            () => Task.FromException<Balance?>(driverError),
                            nameof(IBalanceRepository.GetBalanceOfAccountAsync)
                        )
                );
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync(options =>
                options.ConfigureServices = services => services.AddSingleton(balances.Object)
            );
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);

            // Act
            using HttpResponseMessage response = await SendToEndpointAsync(
                host,
                AlertEndpoint.Create,
                fixture.AccountId,
                fixture.InstrumentId,
                Guid.NewGuid()
            );

            // Assert: nothing is stored; the body and the log line name no driver detail, and
            // the line keeps the failing call and its gRPC status.
            await BrokerTestHost.AssertErrorResponseAsync(
                response,
                HttpStatusCode.ServiceUnavailable
            );
            JsonElement body = await BrokerTestHost.ReadJsonAsync(response);
            Assert.Equal("Database is unavailable", body.GetProperty("message").GetString());
            Assert.Empty(host.Alerts.All());
            LogEntry handled = Assert.Single(host.Logs.ByCategory<BrokerExceptionFilter>());
            Assert.Equal(
                "Exception handled with status [503]: (DbException: db-adapter call "
                    + "[GetBalanceOfAccountAsync] failed with status [Unknown])",
                handled.Message
            );
            Assert.All(
                host.Logs.Entries,
                entry =>
                {
                    Assert.DoesNotContain(marker, entry.Message, StringComparison.Ordinal);
                    Assert.All(
                        entry.State,
                        pair =>
                            Assert.DoesNotContain(
                                marker,
                                pair.Value?.ToString() ?? string.Empty,
                                StringComparison.Ordinal
                            )
                    );
                }
            );
        }

        [Fact]
        public async Task ListAlerts_TwoAlerts_ShouldReturnNewestFirst()
        {
            // Arrange: the older alert is stored first and has the greater id, so neither
            // insertion order nor id order matches newest-first.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            AccountFixture emptyAccount = SeedAccount(host, null);
            Alert older = ArmedAlert(
                fixture.AccountId,
                fixture.InstrumentId,
                CreatedTime,
                new Guid("e2000000-0000-4000-8000-000000000002")
            );
            Alert newer = ArmedAlert(
                fixture.AccountId,
                fixture.InstrumentId,
                CreatedTime.AddMinutes(1),
                new Guid("e2000000-0000-4000-8000-000000000001")
            );
            host.Alerts.Seed(older).Seed(newer);

            // Act
            using HttpResponseMessage listed = await SendAsync(
                host,
                new AlertRequest(
                    HttpMethod.Get,
                    $"{AlertsPath}?accountId={fixture.AccountId}",
                    null
                )
            );
            using HttpResponseMessage emptied = await SendAsync(
                host,
                new AlertRequest(
                    HttpMethod.Get,
                    $"{AlertsPath}?accountId={emptyAccount.AccountId}",
                    null
                )
            );

            // Assert
            JsonElement[] results = await ReadResultsAsync(listed);
            Assert.Equal(2, results.Length);
            AssertAlertJson(newer, results[0]);
            AssertAlertJson(older, results[1]);
            Assert.Empty(await ReadResultsAsync(emptied));
            Assert.Equal(EmptyResultsBody, await emptied.Content.ReadAsStringAsync());
        }

        [Theory]
        [InlineData("true", false)]
        [InlineData("false", true)]
        [InlineData(null, true)]
        public async Task ListNotifications_UnacknowledgedFilter_ShouldApply(
            string? unacknowledged,
            bool includesAcknowledged
        )
        {
            // Arrange: A was created before B but triggered after it, so only trigger order
            // lists A first; C has never triggered and is no notification.
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            DateTimeOffset firstTrigger = CreatedTime.AddHours(1);
            Alert unacknowledgedAlert = ArmedAlert(
                fixture.AccountId,
                fixture.InstrumentId,
                CreatedTime
            ) with
            {
                ArmingRevision = 2,
                TriggeredAt = firstTrigger.AddMinutes(1),
                TriggerValue = 110m,
            };
            Alert acknowledgedAlert = ArmedAlert(
                fixture.AccountId,
                fixture.InstrumentId,
                CreatedTime.AddMinutes(1)
            ) with
            {
                TriggeredAt = firstTrigger,
                TriggerValue = 105.5m,
                Acknowledged = true,
            };
            Alert armedAlert = ArmedAlert(
                fixture.AccountId,
                fixture.InstrumentId,
                CreatedTime.AddMinutes(2)
            );
            host.Alerts.Seed(unacknowledgedAlert).Seed(acknowledgedAlert).Seed(armedAlert);
            string path = $"{AlertsPath}/notifications?accountId={fixture.AccountId}";
            if (unacknowledged is not null)
            {
                path += $"&unacknowledged={unacknowledged}";
            }
            Alert[] expected = includesAcknowledged
                ? [unacknowledgedAlert, acknowledgedAlert]
                : [unacknowledgedAlert];

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Get, path, null)
            );

            // Assert: each item carries its trigger data and its arming revision.
            JsonElement[] results = await ReadResultsAsync(response);
            Assert.Equal(expected.Length, results.Length);
            for (int index = 0; index < expected.Length; index++)
            {
                AssertAlertJson(expected[index], results[index]);
            }
        }

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public async Task AcknowledgeAlert_State_ShouldReturn204(bool triggered)
        {
            // Arrange
            await using BrokerTestHost host = await BrokerTestHost.StartComposedAsync();
            host.Flag.SetEnabled(true);
            AccountFixture fixture = SeedAccount(host, HeldQuantity);
            Alert armed = ArmedAlert(fixture.AccountId, fixture.InstrumentId, CreatedTime);
            Alert seeded = triggered
                ? armed with
                {
                    TriggeredAt = CreatedTime.AddHours(1),
                    TriggerValue = 101.25m,
                }
                : armed;
            host.Alerts.Seed(seeded);

            // Act
            using HttpResponseMessage response = await SendAsync(
                host,
                new AlertRequest(HttpMethod.Post, $"{AlertsPath}/{seeded.Id}/acknowledge", null)
            );

            // Assert: an arming that has not triggered is left as it was, so a future trigger
            // is never acknowledged in advance.
            await AssertStatusAsync(response, HttpStatusCode.NoContent);
            Assert.Empty(await response.Content.ReadAsStringAsync());
            Alert expected = triggered ? seeded with { Acknowledged = true } : seeded;
            Assert.Equal(expected, host.Alerts.Get(seeded.Id));
        }

        private static AccountFixture SeedAccount(BrokerTestHost host, decimal? heldQuantity)
        {
            Guid accountId = Guid.NewGuid();
            Guid instrumentId = Guid.NewGuid();
            host.Balances.AddBalance(new Balance(accountId, 1000));
            host.Instruments.AddInstrument(
                new Instrument(instrumentId, ProductId, "C1", "Alpha", "d")
            );
            if (heldQuantity is decimal quantity)
            {
                host.Instruments.AddOwned(new OwnedInstrument(accountId, instrumentId, quantity));
            }
            return new AccountFixture(accountId, instrumentId);
        }

        private static Alert ArmedAlert(
            Guid accountId,
            Guid instrumentId,
            DateTimeOffset createdAt,
            Guid? id = null
        )
        {
            return new Alert(
                Id: id ?? Guid.NewGuid(),
                AccountId: accountId,
                InstrumentId: instrumentId,
                Type: AlertType.TARGET_PRICE,
                Direction: AlertDirection.ABOVE,
                Threshold: 100m,
                Enabled: true,
                ArmingRevision: 1,
                TriggeredAt: null,
                TriggerValue: null,
                Acknowledged: false,
                CreatedAt: createdAt
            );
        }

        /// <summary>
        /// A create body in which every <c>null</c> argument omits its member. The threshold is
        /// written verbatim as the JSON token, so a row controls the exact bytes bound.
        /// </summary>
        private static string CreateBody(
            Guid? accountId,
            Guid? instrumentId,
            string? type = TargetPrice,
            string? direction = Above,
            string? thresholdToken = "100"
        )
        {
            List<string> members = [];
            if (accountId is Guid account)
            {
                members.Add($"\"accountId\":\"{account}\"");
            }
            if (instrumentId is Guid instrument)
            {
                members.Add($"\"instrumentId\":\"{instrument}\"");
            }
            if (type is not null)
            {
                members.Add($"\"type\":{JsonSerializer.Serialize(type)}");
            }
            if (direction is not null)
            {
                members.Add($"\"direction\":{JsonSerializer.Serialize(direction)}");
            }
            if (thresholdToken is not null)
            {
                members.Add($"\"threshold\":{thresholdToken}");
            }
            return "{" + string.Join(",", members) + "}";
        }

        private static string InvalidCreateBody(
            InvalidCreateCase invalidCase,
            AccountFixture fixture
        )
        {
            Guid account = fixture.AccountId;
            Guid instrument = fixture.InstrumentId;
            return invalidCase switch
            {
                InvalidCreateCase.ThresholdExponent => CreateBody(
                    account,
                    instrument,
                    thresholdToken: "1e5"
                ),
                InvalidCreateCase.ThresholdElevenIntegerDigits => CreateBody(
                    account,
                    instrument,
                    thresholdToken: "10000000000"
                ),
                InvalidCreateCase.ThresholdNineFractionalDigits => CreateBody(
                    account,
                    instrument,
                    thresholdToken: "0.000000001"
                ),
                InvalidCreateCase.MissingAccountId => CreateBody(null, instrument),
                InvalidCreateCase.MissingInstrumentId => CreateBody(account, null),
                InvalidCreateCase.LowercaseType => CreateBody(account, instrument, "target_price"),
                InvalidCreateCase.UnknownType => CreateBody(account, instrument, "FOO"),
                InvalidCreateCase.MissingType => CreateBody(account, instrument, type: null),
                InvalidCreateCase.LowercaseDirection => CreateBody(
                    account,
                    instrument,
                    direction: "above"
                ),
                InvalidCreateCase.MissingDirection => CreateBody(
                    account,
                    instrument,
                    direction: null
                ),
                InvalidCreateCase.MissingThreshold => CreateBody(
                    account,
                    instrument,
                    thresholdToken: null
                ),
                InvalidCreateCase.TargetPriceZeroThreshold => CreateBody(
                    account,
                    instrument,
                    thresholdToken: "0"
                ),
                InvalidCreateCase.TargetPriceNegativeThreshold => CreateBody(
                    account,
                    instrument,
                    thresholdToken: "-1"
                ),
                InvalidCreateCase.ProfitLossUnheldInstrument
                or InvalidCreateCase.ProfitLossZeroQuantityHolding => CreateBody(
                    account,
                    instrument,
                    ProfitLoss
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(invalidCase), invalidCase, null),
            };
        }

        private static Task<HttpResponseMessage> SendToEndpointAsync(
            BrokerTestHost host,
            AlertEndpoint endpoint,
            Guid accountId,
            Guid instrumentId,
            Guid alertId
        )
        {
            AlertRequest request = endpoint switch
            {
                AlertEndpoint.Create => new(
                    HttpMethod.Post,
                    AlertsPath,
                    CreateBody(accountId, instrumentId)
                ),
                AlertEndpoint.List => new(
                    HttpMethod.Get,
                    $"{AlertsPath}?accountId={accountId}",
                    null
                ),
                AlertEndpoint.Notifications => new(
                    HttpMethod.Get,
                    $"{AlertsPath}/notifications?accountId={accountId}&unacknowledged=true",
                    null
                ),
                AlertEndpoint.UpdateEnabled => new(
                    HttpMethod.Patch,
                    $"{AlertsPath}/{alertId}",
                    EnableBody
                ),
                AlertEndpoint.Delete => new(HttpMethod.Delete, $"{AlertsPath}/{alertId}", null),
                AlertEndpoint.Acknowledge => new(
                    HttpMethod.Post,
                    $"{AlertsPath}/{alertId}/acknowledge",
                    null
                ),
                _ => throw new ArgumentOutOfRangeException(nameof(endpoint), endpoint, null),
            };
            return SendAsync(host, request);
        }

        private static Task<HttpResponseMessage> SendAsync(
            BrokerTestHost host,
            AlertRequest request
        )
        {
            return BrokerTestHost.SendJsonAsync(
                host.Client,
                request.Method,
                request.Path,
                request.Body
            );
        }

        private static int TotalAlertCalls(FakeAlertRepository alerts)
        {
            return Enum.GetValues<FakeAlertRepositoryMethod>().Sum(alerts.CallCount);
        }

        private static async Task AssertStatusAsync(
            HttpResponseMessage response,
            HttpStatusCode expected
        )
        {
            if (response.StatusCode != expected)
            {
                string body = await response.Content.ReadAsStringAsync();
                Assert.Fail(
                    $"Expected {(int)expected} {expected}, got {(int)response.StatusCode} "
                        + $"{response.StatusCode} with body [{body}]."
                );
            }
        }

        // The automatic [ApiController] answer to a binding failure, never an ErrorResponse.
        private static async Task AssertBindingProblemAsync(HttpResponseMessage response)
        {
            await AssertStatusAsync(response, HttpStatusCode.BadRequest);
            Assert.Equal(
                "application/problem+json",
                response.Content.Headers.ContentType?.MediaType
            );
            JsonElement problem = await BrokerTestHost.ReadJsonAsync(response);
            Assert.Equal((int)HttpStatusCode.BadRequest, problem.GetProperty("status").GetInt32());
            Assert.Equal(JsonValueKind.Object, problem.GetProperty("errors").ValueKind);
            Assert.False(problem.TryGetProperty("statusCode", out _));
        }

        // A 200 list body: an object whose only member is the results array.
        private static async Task<JsonElement[]> ReadResultsAsync(HttpResponseMessage response)
        {
            await AssertStatusAsync(response, HttpStatusCode.OK);
            JsonElement body = await BrokerTestHost.ReadJsonAsync(response);
            Assert.Equal(["results"], body.EnumerateObject().Select(member => member.Name));
            JsonElement results = body.GetProperty("results");
            Assert.Equal(JsonValueKind.Array, results.ValueKind);
            return [.. results.EnumerateArray()];
        }

        // The response alert carries exactly the twelve camelCase members, each equal to the row.
        private static void AssertAlertJson(Alert expected, JsonElement actual)
        {
            Assert.Equal(
                AlertFieldNames.Order(StringComparer.Ordinal),
                actual.EnumerateObject().Select(member => member.Name).Order(StringComparer.Ordinal)
            );
            Assert.Equal(expected.Id, actual.GetProperty("id").GetGuid());
            Assert.Equal(expected.AccountId, actual.GetProperty("accountId").GetGuid());
            Assert.Equal(expected.InstrumentId, actual.GetProperty("instrumentId").GetGuid());
            Assert.Equal(expected.Type.ToString(), actual.GetProperty("type").GetString());
            Assert.Equal(
                expected.Direction.ToString(),
                actual.GetProperty("direction").GetString()
            );
            Assert.Equal(expected.Threshold, actual.GetProperty("threshold").GetDecimal());
            Assert.Equal(expected.Enabled, actual.GetProperty("enabled").GetBoolean());
            Assert.Equal(expected.ArmingRevision, actual.GetProperty("armingRevision").GetInt32());
            JsonElement triggeredAt = actual.GetProperty("triggeredAt");
            if (expected.TriggeredAt is DateTimeOffset expectedTriggeredAt)
            {
                Assert.Equal(expectedTriggeredAt, triggeredAt.GetDateTimeOffset());
            }
            else
            {
                Assert.Equal(JsonValueKind.Null, triggeredAt.ValueKind);
            }
            JsonElement triggerValue = actual.GetProperty("triggerValue");
            if (expected.TriggerValue is decimal expectedTriggerValue)
            {
                Assert.Equal(expectedTriggerValue, triggerValue.GetDecimal());
            }
            else
            {
                Assert.Equal(JsonValueKind.Null, triggerValue.ValueKind);
            }
            Assert.Equal(expected.Acknowledged, actual.GetProperty("acknowledged").GetBoolean());
            Assert.Equal(expected.CreatedAt, actual.GetProperty("createdAt").GetDateTimeOffset());
        }

        private sealed record AccountFixture(Guid AccountId, Guid InstrumentId);

        private sealed record AlertRequest(HttpMethod Method, string Path, string? Body);
    }
}
