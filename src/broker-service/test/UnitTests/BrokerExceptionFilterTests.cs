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

        // More entries than the fifteen DescribeForLog visits after their aggregate, so an entry
        // placed after them is never visited.
        private const int PlainEntriesBeforeDbException = 17;

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

        // The exception a DescribeForLog row renders; built by BuildDescribedExceptionAsync.
        public enum DescribeCase
        {
            Null,
            GrpcHelperDbException,
            DbExceptionWithoutInner,
            DbExceptionWithNonRpcInner,
            DbExceptionWithNonIdentifierOperation,
            BareRpcException,
            AggregateWithDbException,
            AggregateWithRepeatedEntry,
            PlainException,
            PricingUnavailableWithHttpInner,
            MessageWithLineBreaks,
            UnreadableMessage,
            NullMessage,
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
            // The log line names the call and its gRPC status, never the upstream detail.
            LogEntry entry = Assert.Single(logger.Entries);
            Assert.Equal(LogLevel.Information, entry.Level);
            Assert.Equal(
                "Exception handled with status [503]: (DbException: db-adapter call "
                    + $"[{nameof(CallDbAdapterAsync)}] failed with status [Unavailable])",
                entry.Message
            );
            Assert.DoesNotContain(marker, entry.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("Status(", entry.Message, StringComparison.Ordinal);
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
            RecordingLogger<BrokerExceptionFilter> logger = new();
            BrokerExceptionFilter filter = new(logger);
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
            // Existing endpoints keep their log line byte for byte, raw message included.
            LogEntry entry = Assert.Single(logger.Entries);
            Assert.Equal(LogLevel.Information, entry.Level);
            Assert.Equal(
                $"Exception handled with status [503]: (DbException: {exception.Message})",
                entry.Message
            );
        }

        [Theory]
        [InlineData(Endpoint.InsightsAction, true)]
        [InlineData(Endpoint.AlertController, true)]
        [InlineData(Endpoint.UngatedController, false)]
        [InlineData(Endpoint.NoFilters, false)]
        public void OnException_UnmappedExceptionWrappingRpcError_ShouldLogSafelyOnFeatureEndpoint(
            Endpoint endpoint,
            bool featureEndpoint
        )
        {
            // Arrange: an unmapped exception whose message repeats the RPC detail it wraps.
            string marker = UniqueMarker();
            RpcException rpcError = new(new Status(StatusCode.Unknown, marker));
            InvalidOperationException exception = new($"Wrapped: {rpcError.Message}", rpcError);
            RecordingLogger<BrokerExceptionFilter> logger = new();
            BrokerExceptionFilter filter = new(logger);
            ExceptionContext context = CreateContext(endpoint, exception);

            // Act
            filter.OnException(context);

            // Assert: left unhandled with no result on every endpoint, as before.
            Assert.Null(context.Result);
            Assert.False(context.ExceptionHandled);
            LogEntry entry = Assert.Single(logger.Entries);
            Assert.Equal(LogLevel.Error, entry.Level);
            string expected = featureEndpoint
                ? "Exception not handled: (System.InvalidOperationException: message withheld "
                    + "---> RpcException: status [Unknown])"
                : $"Exception not handled: (System.InvalidOperationException: {exception.Message})";
            Assert.Equal(expected, entry.Message);
        }

        [Theory]
        [InlineData(DescribeCase.Null, "")]
        [InlineData(
            DescribeCase.GrpcHelperDbException,
            "DbException: db-adapter call [CallDbAdapterAsync] failed with status [Unavailable]"
        )]
        [InlineData(
            DescribeCase.DbExceptionWithoutInner,
            "DbException: db-adapter call [GetAlertAsync] failed"
        )]
        [InlineData(
            DescribeCase.DbExceptionWithNonRpcInner,
            "DbException: db-adapter call failed with cause [TaskCanceledException]"
        )]
        [InlineData(
            DescribeCase.DbExceptionWithNonIdentifierOperation,
            "DbException: db-adapter call failed with status [Unknown]"
        )]
        [InlineData(DescribeCase.BareRpcException, "RpcException: status [Unknown]")]
        [InlineData(
            DescribeCase.AggregateWithDbException,
            "AggregateException: message withheld ---> InvalidOperationException: message "
                + "withheld ---> DbException: db-adapter call [CallDbAdapterAsync] failed with "
                + "status [Unavailable]"
        )]
        [InlineData(
            DescribeCase.AggregateWithRepeatedEntry,
            "AggregateException: One or more errors occurred. (Repeated failure.) (Repeated "
                + "failure.) ---> InvalidOperationException: Repeated failure."
        )]
        [InlineData(DescribeCase.PlainException, "InvalidOperationException: Plain failure.")]
        [InlineData(
            DescribeCase.PricingUnavailableWithHttpInner,
            "PricingUnavailableException: Latest prices are unavailable ---> "
                + "HttpRequestException: Name does not resolve (pricing-service:8080)"
        )]
        [InlineData(
            DescribeCase.MessageWithLineBreaks,
            "InvalidOperationException: first [12:00:00 | Error] forged line end "
        )]
        [InlineData(DescribeCase.UnreadableMessage, "MessageProbeException: message unavailable")]
        [InlineData(DescribeCase.NullMessage, "MessageProbeException: ")]
        public async Task DescribeForLog_Exception_ShouldRenderSafeSingleLine(
            DescribeCase describeCase,
            string expected
        )
        {
            // Arrange
            string marker = UniqueMarker();
            Exception? exception = await BuildDescribedExceptionAsync(describeCase, marker);

            // Act
            string rendered = BrokerExceptionFilter.DescribeForLog(exception);

            // Assert
            Assert.Equal(expected, rendered);
            Assert.DoesNotContain(marker, rendered, StringComparison.Ordinal);
        }

        [Theory]
        [InlineData(1)]
        [InlineData(16)]
        [InlineData(17)]
        [InlineData(40)]
        public void DescribeForLog_ChainLength_ShouldRenderAtMostSixteen(int length)
        {
            // Arrange: e0 is the outermost exception, e{length - 1} the innermost.
            Exception exception = new InvalidOperationException($"e{length - 1}");
            for (int depth = length - 2; depth >= 0; depth--)
            {
                exception = new InvalidOperationException($"e{depth}", exception);
            }
            // A chain longer than the bound renders no message, because the exceptions past
            // it are never classified.
            bool truncated = length > 16;
            string expected = string.Join(
                " ---> ",
                Enumerable
                    .Range(0, Math.Min(length, 16))
                    .Select(depth =>
                        truncated
                            ? "InvalidOperationException: message withheld"
                            : $"InvalidOperationException: e{depth}"
                    )
            );
            if (truncated)
            {
                expected += " ---> ...";
            }

            // Act
            string rendered = BrokerExceptionFilter.DescribeForLog(exception);

            // Assert
            Assert.Equal(expected, rendered);
        }

        [Fact]
        public async Task DescribeForLog_DbExceptionPastBound_ShouldWithholdEveryMessage()
        {
            // Arrange: the aggregate's own message repeats the unvisited DbException's detail.
            string marker = UniqueMarker();
            AggregateException exception = await BuildAggregatePastBoundAsync(marker);
            Assert.Contains(marker, exception.Message, StringComparison.Ordinal);
            string expected = string.Join(
                " ---> ",
                Enumerable
                    .Repeat("InvalidOperationException: message withheld", 15)
                    .Prepend("AggregateException: message withheld")
                    .Append("...")
            );

            // Act
            string rendered = BrokerExceptionFilter.DescribeForLog(exception);

            // Assert
            Assert.DoesNotContain(marker, rendered, StringComparison.Ordinal);
            Assert.DoesNotContain("Status(", rendered, StringComparison.Ordinal);
            Assert.Contains("message withheld", rendered, StringComparison.Ordinal);
            Assert.EndsWith(" ---> ...", rendered, StringComparison.Ordinal);
            Assert.Equal(expected, rendered);
        }

        [Theory]
        [InlineData(Endpoint.InsightsAction)]
        [InlineData(Endpoint.AlertController)]
        public async Task OnException_DbExceptionPastBound_ShouldLogNoDiagnostic(Endpoint endpoint)
        {
            // Arrange
            string marker = UniqueMarker();
            AggregateException exception = await BuildAggregatePastBoundAsync(marker);
            RecordingLogger<BrokerExceptionFilter> logger = new();
            BrokerExceptionFilter filter = new(logger);
            ExceptionContext context = CreateContext(endpoint, exception);

            // Act
            filter.OnException(context);

            // Assert: unmapped, so it is left unhandled and logged as not handled.
            Assert.Null(context.Result);
            Assert.False(context.ExceptionHandled);
            LogEntry entry = Assert.Single(logger.Entries);
            Assert.Equal(LogLevel.Error, entry.Level);
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
            Assert.StartsWith(
                "Exception not handled: (System.AggregateException: message withheld ---> ",
                entry.Message,
                StringComparison.Ordinal
            );
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

        private static Task<DbException> CaptureDbExceptionAsync(
            string marker,
            StatusCode statusCode = StatusCode.Unavailable
        )
        {
            return Assert.ThrowsAsync<DbException>(() => CallDbAdapterAsync(marker, statusCode));
        }

        // An AggregateException whose own message repeats every entry's, the DbException's
        // upstream detail included, while the DbException sits past the bound of sixteen
        // exceptions DescribeForLog walks: the aggregate and its first fifteen entries.
        private static async Task<AggregateException> BuildAggregatePastBoundAsync(string marker)
        {
            List<Exception> entries = [];
            for (int index = 0; index < PlainEntriesBeforeDbException; index++)
            {
                entries.Add(new InvalidOperationException($"Plain failure {index}."));
            }
            entries.Add(await CaptureDbExceptionAsync(marker, StatusCode.Unknown));
            return new AggregateException(entries);
        }

        // Every db-adapter row carries the marker where a driver or RPC diagnostic would be.
        private static async Task<Exception?> BuildDescribedExceptionAsync(
            DescribeCase describeCase,
            string marker
        )
        {
            RpcException rpcError = new(new Status(StatusCode.Unknown, marker));
            InvalidOperationException repeated = new("Repeated failure.");
            return describeCase switch
            {
                DescribeCase.Null => null,
                DescribeCase.GrpcHelperDbException => await CaptureDbExceptionAsync(marker),
                DescribeCase.DbExceptionWithoutInner => new DbException(
                    $"Db Adapter call error in \"GetAlertAsync\" method: {marker}"
                ),
                DescribeCase.DbExceptionWithNonRpcInner => new DbException(
                    marker,
                    new TaskCanceledException(marker)
                ),
                // Only an identifier passes as the operation, so no forged text reaches the log.
                DescribeCase.DbExceptionWithNonIdentifierOperation => new DbException(
                    $"Db Adapter call error in \"Get\r\n[Error] {marker}\" method: {marker}",
                    rpcError
                ),
                DescribeCase.BareRpcException => rpcError,
                // AggregateException's own message repeats both inner messages.
                DescribeCase.AggregateWithDbException => new AggregateException(
                    new InvalidOperationException(marker),
                    await CaptureDbExceptionAsync(marker)
                ),
                DescribeCase.AggregateWithRepeatedEntry => new AggregateException(
                    repeated,
                    repeated
                ),
                DescribeCase.PlainException => new InvalidOperationException("Plain failure."),
                DescribeCase.PricingUnavailableWithHttpInner => new PricingUnavailableException(
                    "Latest prices are unavailable",
                    new HttpRequestException("Name does not resolve (pricing-service:8080)")
                ),
                DescribeCase.MessageWithLineBreaks => new InvalidOperationException(
                    "first\r\n[12:00:00 | Error] forged\t\tline\u2028end\u0000"
                ),
                DescribeCase.UnreadableMessage => new MessageProbeException(throws: true),
                DescribeCase.NullMessage => new MessageProbeException(throws: false),
                _ => throw new ArgumentOutOfRangeException(
                    nameof(describeCase),
                    describeCase,
                    null
                ),
            };
        }

        // Fails the way a db-adapter call fails: GrpcHelper wraps the transport error in a
        // DbException whose message names this method and embeds the upstream detail.
        private static Task<int> CallDbAdapterAsync(string marker, StatusCode statusCode)
        {
            RpcException transportError = new(new Status(statusCode, marker));
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

        // An exception whose Message throws, or returns null against its annotation.
        private sealed class MessageProbeException(bool throws) : Exception
        {
            public override string Message =>
                throws ? throw new InvalidOperationException("Message is unreadable.") : null!;
        }
    }
}
