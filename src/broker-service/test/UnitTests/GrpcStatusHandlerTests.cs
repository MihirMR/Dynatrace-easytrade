using System.Buffers.Binary;
using System.Net;
using EasyTrade.BrokerService.Test.Fakes;
using Google.Protobuf;
using Grpc.Core;
// Aliased because the generated namespace declares an AlertService type, which would clash
// with the broker's own alert service.
using AlertGrpc = EasyTrade.DbAdapter.Alert.Grpc;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    // Covers the fake's own recording isolation across Clear(), which no consumer suite exercises.
    public class GrpcStatusHandlerTests
    {
        // Only names the target of the request URIs; no call ever leaves the process.
        private const string Address = "http://localhost";

        // Written out because the method path is db-adapter's contract, not a value to take from
        // the generated client.
        private const string GetAlertPath = "/easytrade.dbadapter.alert.AlertService/GetAlert";

        // gRPC length-prefixed framing: a 1-byte compression flag, then a 4-byte big-endian length.
        private const int MessagePrefixLength = 5;

        // The wire value of StatusCode.NotFound in the grpc-status header.
        private const string NotFoundStatusText = "5";

        // Bounds every await, so a call that never ends fails the test instead of hanging it.
        private static readonly TimeSpan TestBound = TimeSpan.FromSeconds(5);

        [Fact]
        public async Task Clear_HeldCallCancelledAfterClear_ShouldForgetCall()
        {
            // Arrange: a held call that arrived before Clear().
            GrpcStatusHandler handler = new();
            handler.Hold();
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertGrpc.AlertService.AlertServiceClient client = new(connector.GetChannel());
            using CancellationTokenSource cts = new();
            Task<AlertGrpc.AlertMessage> call = client
                .GetAlertAsync(
                    new AlertGrpc.AlertIdRequest { Id = "held" },
                    cancellationToken: cts.Token
                )
                .ResponseAsync;
            await handler.CallReceived.WaitAsync(TestBound);
            handler.Clear();
            Task nextArrival = handler.CallReceived;

            // Act
            cts.Cancel();
            RpcException error = await Assert.ThrowsAsync<RpcException>(
                () => call.WaitAsync(TestBound)
            );

            // Assert: the cancelled call left no trace in the generation Clear() started.
            Assert.Equal(StatusCode.Cancelled, error.StatusCode);
            Assert.Equal(0, handler.CallCount);
            Assert.Empty(handler.RequestPaths);
            Assert.Empty(handler.RequestMessages);
            Assert.Empty(handler.RequestTimeouts);
            Assert.False(nextArrival.IsCompleted);
            Assert.False(handler.ObservedCancellation);
        }

        [Fact]
        public async Task Clear_ContentReadCancelledAfterClear_ShouldNotObserveCancellation()
        {
            // Arrange: a call paused in its content read when Clear() runs.
            using GrpcStatusHandler handler = new();
            using HttpMessageInvoker invoker = new(handler, disposeHandler: false);
            GatedContent content = new(Frame(new AlertGrpc.AlertIdRequest { Id = "reading" }));
            using HttpRequestMessage request = NewGetAlertRequest(content);
            using CancellationTokenSource cts = new();
            Task<HttpResponseMessage> sending = invoker.SendAsync(request, cts.Token);
            await content.Entered.WaitAsync(TestBound);
            handler.Clear();

            // Act
            cts.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => sending.WaitAsync(TestBound)
            );

            // Assert
            Assert.False(handler.ObservedCancellation);
            Assert.Equal(0, handler.CallCount);
        }

        [Fact]
        public async Task Clear_ContentReadInFlight_ShouldAnswerWithoutRecording()
        {
            // Arrange: a call paused in its content read while the reply mode changes and Clear()
            // runs.
            using GrpcStatusHandler handler = new(StatusCode.NotFound);
            using HttpMessageInvoker invoker = new(handler, disposeHandler: false);
            GatedContent content = new(Frame(new AlertGrpc.AlertIdRequest { Id = "reading" }));
            using HttpRequestMessage request = NewGetAlertRequest(content);
            Task<HttpResponseMessage> sending = invoker.SendAsync(request, CancellationToken.None);
            await content.Entered.WaitAsync(TestBound);
            handler.ReplyWithStatus(StatusCode.Unavailable);
            handler.Clear();
            Task nextArrival = handler.CallReceived;

            // Act
            content.Release();
            using HttpResponseMessage response = await sending.WaitAsync(TestBound);

            // Assert: answered with the reply the call started with, yet not recorded.
            Assert.Equal(
                NotFoundStatusText,
                Assert.Single(response.Headers.GetValues("grpc-status"))
            );
            Assert.Equal(0, handler.CallCount);
            Assert.Empty(handler.RequestPaths);
            Assert.Empty(handler.RequestMessages);
            Assert.Empty(handler.RequestTimeouts);
            Assert.False(nextArrival.IsCompleted);
        }

        [Fact]
        public async Task Clear_FreshCallCancelled_ShouldRecordAndObserveCancellation()
        {
            // Arrange: a held call forgotten by Clear() and cancelled, then a fresh held call.
            GrpcStatusHandler handler = new();
            handler.Hold();
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertGrpc.AlertService.AlertServiceClient client = new(connector.GetChannel());
            using CancellationTokenSource staleCts = new();
            Task<AlertGrpc.AlertMessage> staleCall = client
                .GetAlertAsync(
                    new AlertGrpc.AlertIdRequest { Id = "stale" },
                    cancellationToken: staleCts.Token
                )
                .ResponseAsync;
            await handler.CallReceived.WaitAsync(TestBound);
            handler.Clear();
            staleCts.Cancel();
            await Assert.ThrowsAsync<RpcException>(() => staleCall.WaitAsync(TestBound));
            Task arrival = handler.CallReceived;
            AlertGrpc.AlertIdRequest sent = new() { Id = "fresh" };
            using CancellationTokenSource freshCts = new();
            Task<AlertGrpc.AlertMessage> freshCall = client
                .GetAlertAsync(sent, cancellationToken: freshCts.Token)
                .ResponseAsync;
            await arrival.WaitAsync(TestBound);
            bool observedBeforeCancel = handler.ObservedCancellation;

            // Act
            freshCts.Cancel();
            RpcException error = await Assert.ThrowsAsync<RpcException>(
                () => freshCall.WaitAsync(TestBound)
            );

            // Assert: the current generation still records, signals and observes cancellation.
            Assert.Equal(StatusCode.Cancelled, error.StatusCode);
            Assert.False(observedBeforeCancel);
            Assert.True(handler.ObservedCancellation);
            Assert.Equal(1, handler.CallCount);
            Assert.Equal(GetAlertPath, Assert.Single(handler.RequestPaths));
            Assert.Equal(
                sent,
                AlertGrpc.AlertIdRequest.Parser.ParseFrom(Assert.Single(handler.RequestMessages))
            );
        }

        [Fact]
        public async Task RequestMessages_PayloadMutated_ShouldNotChangeLaterSnapshot()
        {
            // Arrange: one recorded call.
            GrpcStatusHandler handler = new(StatusCode.NotFound);
            using FixedChannelDbAdapterConnector connector = new(handler);
            AlertGrpc.AlertService.AlertServiceClient client = new(connector.GetChannel());
            AlertGrpc.AlertIdRequest sent = new() { Id = "recorded" };
            await Assert.ThrowsAsync<RpcException>(
                () => client.GetAlertAsync(sent).ResponseAsync.WaitAsync(TestBound)
            );
            byte[] mutated = Assert.Single(handler.RequestMessages);

            // Act
            Array.Fill(mutated, (byte)0xFF);
            byte[] later = Assert.Single(handler.RequestMessages);

            // Assert
            Assert.NotSame(mutated, later);
            Assert.Equal(sent.ToByteArray(), later);
            Assert.Equal(sent, AlertGrpc.AlertIdRequest.Parser.ParseFrom(later));
        }

        // The body Grpc.Net.Client sends for a unary call: one uncompressed framed message.
        private static byte[] Frame(IMessage message)
        {
            byte[] payload = message.ToByteArray();
            byte[] frame = new byte[MessagePrefixLength + payload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(1, 4), (uint)payload.Length);
            payload.CopyTo(frame, MessagePrefixLength);
            return frame;
        }

        private static HttpRequestMessage NewGetAlertRequest(HttpContent content)
        {
            return new HttpRequestMessage(HttpMethod.Post, Address + GetAlertPath)
            {
                Content = content,
                Version = HttpVersion.Version20,
            };
        }

        // Request content whose serialization, which the handler's content read drives, waits for
        // Release() or the read's token, so a test can act while a call is mid read.
        private sealed class GatedContent(byte[] body) : HttpContent
        {
            private readonly TaskCompletionSource _entered = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );
            private readonly TaskCompletionSource _released = new(
                TaskCreationOptions.RunContinuationsAsynchronously
            );

            // Completes once the handler has started reading the content.
            public Task Entered => _entered.Task;

            public void Release()
            {
                _released.TrySetResult();
            }

            protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context)
            {
                return SerializeToStreamAsync(stream, context, CancellationToken.None);
            }

            protected override async Task SerializeToStreamAsync(
                Stream stream,
                TransportContext? context,
                CancellationToken cancellationToken
            )
            {
                _entered.TrySetResult();
                await _released.Task.WaitAsync(TestBound, cancellationToken);
                await stream.WriteAsync(body, cancellationToken);
            }

            protected override bool TryComputeLength(out long length)
            {
                length = 0;
                return false;
            }
        }
    }
}
