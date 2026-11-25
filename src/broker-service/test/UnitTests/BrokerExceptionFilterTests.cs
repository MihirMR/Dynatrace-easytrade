using System.Text.Json;
using EasyTrade.BrokerService.ExceptionHandling;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using EasyTrade.BrokerService.Test.Fakes;
using Grpc.Core;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Logging;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class BrokerExceptionFilterTests
    {
        // The wire form MVC writes for an ObjectResult: System.Text.Json with web defaults.
        private static readonly JsonSerializerOptions WireOptions = new(JsonSerializerDefaults.Web);

        // Public, not private: xUnit passes it to the public theory, and a public method cannot
        // take a parameter of a less accessible type.
        public enum Endpoint
        {
            // The insights action: the gate on the action, the exception filter on the controller.
            InsightsAction,

            // An alert action: the gate and the exception filter on the controller.
            AlertController,

            // An existing action such as portfolio history: the exception filter only.
            UngatedController,

            // An action with no filter at all.
            NoFilters,

            // An action whose [ServiceFilter] names another type than the gate.
            OtherServiceFilter,
        }

        [Theory]
        [InlineData(Endpoint.InsightsAction)]
        [InlineData(Endpoint.AlertController)]
        public async Task OnException_DbExceptionOnFeatureEndpoint_ShouldReturnStableMessage(
            Endpoint endpoint
        )
        {
            // Arrange
            string marker = UniqueMarker();
            DbException exception = await CaptureDbExceptionAsync(marker);
            RecordingLogger<BrokerExceptionFilter> logger = new();
            BrokerExceptionFilter filter = new(logger);
            ExceptionContext context = CreateContext(endpoint, exception);

            // Act
            filter.OnException(context);

            // Assert
            ObjectResult result = Assert.IsType<ObjectResult>(context.Result);
            string body = JsonSerializer.Serialize(result.Value, WireOptions);
            Assert.Equal(StatusCodes.Status503ServiceUnavailable, result.StatusCode);
            Assert.Equal("{\"statusCode\":503,\"message\":\"Database is unavailable\"}", body);
            Assert.DoesNotContain(marker, body, StringComparison.Ordinal);
            Assert.DoesNotContain(nameof(CallDbAdapterAsync), body, StringComparison.Ordinal);
            Assert.True(context.ExceptionHandled);
            // The server log keeps the full diagnostic the body leaves out.
            LogEntry entry = Assert.Single(logger.Entries);
            Assert.Equal(LogLevel.Information, entry.Level);
            Assert.Equal(
                $"Exception handled with status [503]: (DbException: {exception.Message})",
                entry.Message
            );
            Assert.Contains(marker, entry.Message, StringComparison.Ordinal);
            Assert.Contains(nameof(CallDbAdapterAsync), entry.Message, StringComparison.Ordinal);
        }

        [Theory]
        [InlineData(Endpoint.UngatedController)]
        [InlineData(Endpoint.NoFilters)]
        [InlineData(Endpoint.OtherServiceFilter)]
        public async Task OnException_DbExceptionOnOtherEndpoint_ShouldReturnExceptionMessage(
            Endpoint endpoint
        )
        {
            // Arrange
            DbException exception = await CaptureDbExceptionAsync(UniqueMarker());
            BrokerExceptionFilter filter = new(new RecordingLogger<BrokerExceptionFilter>());
            ExceptionContext context = CreateContext(endpoint, exception);

            // Act
            filter.OnException(context);

            // Assert
            ObjectResult result = Assert.IsType<ObjectResult>(context.Result);
            ErrorResponse response = Assert.IsType<ErrorResponse>(result.Value);
            Assert.Equal(StatusCodes.Status503ServiceUnavailable, result.StatusCode);
            Assert.Equal(StatusCodes.Status503ServiceUnavailable, response.StatusCode);
            Assert.Equal(exception.Message, response.Message);
            Assert.True(context.ExceptionHandled);
        }

        [Theory]
        [InlineData(
            typeof(AlertNotFoundException),
            Endpoint.AlertController,
            StatusCodes.Status404NotFound
        )]
        [InlineData(
            typeof(InvalidAlertException),
            Endpoint.AlertController,
            StatusCodes.Status400BadRequest
        )]
        [InlineData(
            typeof(BalanceNotFoundException),
            Endpoint.AlertController,
            StatusCodes.Status404NotFound
        )]
        [InlineData(
            typeof(BalanceNotFoundException),
            Endpoint.InsightsAction,
            StatusCodes.Status404NotFound
        )]
        [InlineData(
            typeof(PricingUnavailableException),
            Endpoint.InsightsAction,
            StatusCodes.Status503ServiceUnavailable
        )]
        public void OnException_DomainExceptionOnFeatureEndpoint_ShouldKeepOwnMessage(
            Type exceptionType,
            Endpoint endpoint,
            int expectedStatus
        )
        {
            // Arrange
            string message = $"{exceptionType.Name} {UniqueMarker()}";
            Exception exception = (Exception)Activator.CreateInstance(exceptionType, message)!;
            BrokerExceptionFilter filter = new(new RecordingLogger<BrokerExceptionFilter>());
            ExceptionContext context = CreateContext(endpoint, exception);

            // Act
            filter.OnException(context);

            // Assert
            ObjectResult result = Assert.IsType<ObjectResult>(context.Result);
            ErrorResponse response = Assert.IsType<ErrorResponse>(result.Value);
            Assert.Equal(expectedStatus, result.StatusCode);
            Assert.Equal(expectedStatus, response.StatusCode);
            Assert.Equal(message, response.Message);
            Assert.True(context.ExceptionHandled);
        }

        private static string UniqueMarker()
        {
            return $"upstream-diagnostic-{Guid.NewGuid():N}";
        }

        private static Task<DbException> CaptureDbExceptionAsync(string marker)
        {
            return Assert.ThrowsAsync<DbException>(() => CallDbAdapterAsync(marker));
        }

        // Fails the way a db-adapter call fails: GrpcHelper wraps the transport error in a
        // DbException whose message names this method and embeds the upstream detail.
        private static Task<int> CallDbAdapterAsync(string marker)
        {
            RpcException transportError = new(new Status(StatusCode.Unavailable, marker));
            return GrpcHelper.ExecuteAsync(() => Task.FromException<int>(transportError));
        }

        private static ExceptionContext CreateContext(Endpoint endpoint, Exception exception)
        {
            ActionDescriptor actionDescriptor = new() { FilterDescriptors = FiltersOf(endpoint) };
            ActionContext actionContext = new(
                new DefaultHttpContext(),
                new RouteData(),
                actionDescriptor
            );
            return new ExceptionContext(actionContext, []) { Exception = exception };
        }

        // The descriptors MVC builds from the attributes the controllers carry.
        private static List<FilterDescriptor> FiltersOf(Endpoint endpoint)
        {
            FilterDescriptor exceptionFilter = new(
                new TypeFilterAttribute(typeof(BrokerExceptionFilter)),
                FilterScope.Controller
            );
            ServiceFilterAttribute gate = new(typeof(PortfolioInsightsFeatureGate));
            ServiceFilterAttribute other = new(typeof(BrokerExceptionFilter));
            return endpoint switch
            {
                Endpoint.InsightsAction => [exceptionFilter, new(gate, FilterScope.Action)],
                Endpoint.AlertController => [exceptionFilter, new(gate, FilterScope.Controller)],
                Endpoint.UngatedController => [exceptionFilter],
                Endpoint.NoFilters => [],
                Endpoint.OtherServiceFilter => [exceptionFilter, new(other, FilterScope.Action)],
                _ => throw new ArgumentOutOfRangeException(nameof(endpoint), endpoint, null),
            };
        }
    }
}
