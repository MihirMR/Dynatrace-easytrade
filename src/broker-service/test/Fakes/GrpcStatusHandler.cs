using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using Google.Protobuf;
using Grpc.Core;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// In-process transport for <c>Grpc.Net.Client</c> that answers every call the way db-adapter
    /// would: with a trailers-only status, with one protobuf message and status 0, or by holding
    /// the call until its token is cancelled. It replaces the gRPC transport, not the database, so
    /// the real repositories and <c>GrpcHelper</c> run unchanged above it.
    /// </summary>
    /// <remarks>
    /// The <c>GrpcChannel</c> that owns this handler disposes it together with the channel; the
    /// recorded calls stay readable afterwards.
    /// </remarks>
    /// <param name="status">Status of the initial trailers-only reply.</param>
    public sealed class GrpcStatusHandler(StatusCode status = StatusCode.OK) : HttpMessageHandler
    {
        // gRPC length-prefixed framing: a 1-byte compression flag, then a 4-byte big-endian length.
        private const int MessagePrefixLength = 5;
        private const string GrpcContentType = "application/grpc";
        private const string StatusHeader = "grpc-status";
        private const string MessageHeader = "grpc-message";
        private const string StatusOk = "0";

        // Never completes, so a held call ends only through its cancellation token.
        private static readonly Task<HttpResponseMessage> NeverAnswered =
            new TaskCompletionSource<HttpResponseMessage>().Task;

        private readonly Lock _gate = new();
        private readonly List<string> _requestPaths = [];
        private readonly List<byte[]> _requestMessages = [];
        private int _callCount;
        private bool _observedCancellation;
        private TaskCompletionSource _callReceived = NewSignal();

        // Immutable reply, swapped whole so a call in flight never sees a half-changed mode.
        private volatile Reply _reply = new StatusReply(status, null);

        /// <summary>Calls received since creation or the last <see cref="Clear"/>.</summary>
        public int CallCount
        {
            get
            {
                lock (_gate)
                {
                    return _callCount;
                }
            }
        }

        /// <summary>
        /// Request path of each received call in arrival order, for example
        /// <c>/easytrade.dbadapter.alert.AlertService/GetAlert</c>.
        /// </summary>
        public IReadOnlyList<string> RequestPaths
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requestPaths];
                }
            }
        }

        /// <summary>
        /// Serialized request message of each received call without its 5-byte gRPC prefix, ready
        /// for <c>Parser.ParseFrom</c>; same order as <see cref="RequestPaths"/>.
        /// </summary>
        public IReadOnlyList<byte[]> RequestMessages
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requestMessages];
                }
            }
        }

        /// <summary>
        /// Whether the token of a call being served was cancelled. Grpc.Net.Client links the
        /// caller's <c>CallOptions.CancellationToken</c> and the call deadline into that token.
        /// </summary>
        public bool ObservedCancellation
        {
            get
            {
                lock (_gate)
                {
                    return _observedCancellation;
                }
            }
        }

        /// <summary>
        /// Completes once the first call since creation or the last <see cref="Clear"/> has been
        /// recorded, before it is answered. Await it with a bound, for example
        /// <c>WaitAsync(TimeSpan)</c>, to cancel a held call only after it has arrived.
        /// </summary>
        public Task CallReceived
        {
            get
            {
                lock (_gate)
                {
                    return _callReceived.Task;
                }
            }
        }

        /// <summary>
        /// Answers every later call with a trailers-only reply carrying <paramref name="status"/>
        /// and, when given, <paramref name="message"/> as its detail. A unary call answered with
        /// <see cref="StatusCode.OK"/> and no message fails on the client with
        /// <see cref="StatusCode.Internal"/>, as it would against a real server.
        /// </summary>
        public void ReplyWithStatus(StatusCode status, string? message = null)
        {
            _reply = new StatusReply(status, message);
        }

        /// <summary>Answers every later call with <paramref name="message"/>, status 0.</summary>
        public void ReplyWithMessage(IMessage message)
        {
            ArgumentNullException.ThrowIfNull(message);
            _reply = new MessageReply(Frame(message.ToByteArray()));
        }

        /// <summary>
        /// Holds every later call unanswered until its token is cancelled, which then sets
        /// <see cref="ObservedCancellation"/>.
        /// </summary>
        public void Hold()
        {
            _reply = new HoldReply();
        }

        /// <summary>Forgets the recorded calls and cancellation; the reply mode is kept.</summary>
        public void Clear()
        {
            lock (_gate)
            {
                _callCount = 0;
                _requestPaths.Clear();
                _requestMessages.Clear();
                _observedCancellation = false;
                if (_callReceived.Task.IsCompleted)
                {
                    _callReceived = NewSignal();
                }
            }
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken
        )
        {
            ArgumentNullException.ThrowIfNull(request);
            Reply reply = _reply;
            try
            {
                // Reading the body drives the client's push content and captures the sent message.
                byte[] body = request.Content is null
                    ? []
                    : await request.Content.ReadAsByteArrayAsync(cancellationToken);
                Record(request, body);
                return await reply.AnswerAsync(request, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                lock (_gate)
                {
                    _observedCancellation = true;
                }
                throw;
            }
        }

        private static TaskCompletionSource NewSignal()
        {
            return new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private static byte[] Frame(byte[] payload)
        {
            byte[] frame = new byte[MessagePrefixLength + payload.Length];
            // frame[0] stays 0: the message is not compressed.
            BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(1, 4), (uint)payload.Length);
            payload.CopyTo(frame, MessagePrefixLength);
            return frame;
        }

        private static HttpResponseMessage NewResponse(HttpRequestMessage request, byte[] body)
        {
            ByteArrayContent content = new(body);
            content.Headers.ContentType = new MediaTypeHeaderValue(GrpcContentType);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Version = HttpVersion.Version20,
                Content = content,
                RequestMessage = request,
            };
        }

        private void Record(HttpRequestMessage request, byte[] body)
        {
            string path = request.RequestUri?.AbsolutePath ?? string.Empty;
            byte[] message = body.Length >= MessagePrefixLength ? body[MessagePrefixLength..] : [];
            TaskCompletionSource received;
            lock (_gate)
            {
                _callCount++;
                _requestPaths.Add(path);
                _requestMessages.Add(message);
                received = _callReceived;
            }
            received.TrySetResult();
        }

        private abstract class Reply
        {
            public abstract Task<HttpResponseMessage> AnswerAsync(
                HttpRequestMessage request,
                CancellationToken cancellationToken
            );
        }

        // Grpc.Net.Client reads grpc-status from the response headers before any other check, so
        // a status without a message travels there, with an empty body.
        private sealed class StatusReply(StatusCode status, string? message) : Reply
        {
            public override Task<HttpResponseMessage> AnswerAsync(
                HttpRequestMessage request,
                CancellationToken cancellationToken
            )
            {
                HttpResponseMessage response = NewResponse(request, []);
                response.Headers.Add(
                    StatusHeader,
                    ((int)status).ToString(CultureInfo.InvariantCulture)
                );
                if (message is not null)
                {
                    // gRPC percent-encodes the detail; the client unescapes it.
                    response.Headers.Add(MessageHeader, Uri.EscapeDataString(message));
                }
                return Task.FromResult(response);
            }
        }

        // A message reply carries its status in the trailers, read after the body.
        private sealed class MessageReply(byte[] frame) : Reply
        {
            public override Task<HttpResponseMessage> AnswerAsync(
                HttpRequestMessage request,
                CancellationToken cancellationToken
            )
            {
                HttpResponseMessage response = NewResponse(request, frame);
                response.TrailingHeaders.Add(StatusHeader, StatusOk);
                return Task.FromResult(response);
            }
        }

        private sealed class HoldReply : Reply
        {
            public override Task<HttpResponseMessage> AnswerAsync(
                HttpRequestMessage request,
                CancellationToken cancellationToken
            )
            {
                return NeverAnswered.WaitAsync(cancellationToken);
            }
        }
    }
}
