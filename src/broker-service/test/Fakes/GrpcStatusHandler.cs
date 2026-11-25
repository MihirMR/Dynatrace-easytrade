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

        // A deadline travels as its remaining budget: 1 to 8 ASCII digits, then one unit letter.
        private const string TimeoutHeader = "grpc-timeout";
        private const int MaxTimeoutDigits = 8;

        // Never completes, so a held call ends only through its cancellation token.
        private static readonly Task<HttpResponseMessage> NeverAnswered =
            new TaskCompletionSource<HttpResponseMessage>().Task;

        private readonly Lock _gate = new();
        private readonly List<string> _requestPaths = [];
        private readonly List<byte[]> _requestMessages = [];
        private readonly List<TimeSpan?> _requestTimeouts = [];
        private int _callCount;
        private bool _observedCancellation;

        // Bumped by Clear(), so a call in flight when it runs never records into the new state.
        private int _generation;
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
        /// for <c>Parser.ParseFrom</c>; same order as <see cref="RequestPaths"/>. Each snapshot is
        /// a private copy, so changing a returned array never alters what later reads return.
        /// </summary>
        public IReadOnlyList<byte[]> RequestMessages
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requestMessages.Select(static message => message.ToArray())];
                }
            }
        }

        /// <summary>
        /// Deadline budget of each received call, read from its <c>grpc-timeout</c> header, which
        /// Grpc.Net.Client sends only for a call with a deadline; <c>null</c> for a call without
        /// one. Same order as <see cref="RequestPaths"/>. A malformed header fails the call with a
        /// <see cref="FormatException"/> before it is recorded.
        /// </summary>
        public IReadOnlyList<TimeSpan?> RequestTimeouts
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requestTimeouts];
                }
            }
        }

        /// <summary>
        /// Whether the token of a call being served was cancelled. Grpc.Net.Client links the
        /// caller's <c>CallOptions.CancellationToken</c> and the call deadline into that token.
        /// A call in flight when <see cref="Clear"/> runs never sets it.
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
        /// recorded, before it is answered; a call in flight when <see cref="Clear"/> runs never
        /// completes it. Await it with a bound, for example <c>WaitAsync(TimeSpan)</c>, to cancel
        /// a held call only after it has arrived.
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
        /// <see cref="ObservedCancellation"/> unless <see cref="Clear"/> has run since the call
        /// started.
        /// </summary>
        public void Hold()
        {
            _reply = new HoldReply();
        }

        /// <summary>
        /// Forgets the recorded calls and cancellation; the reply mode is kept. A call in flight
        /// when this runs is forgotten too: it keeps the reply it started with, but it is not
        /// recorded, does not complete <see cref="CallReceived"/> and does not set
        /// <see cref="ObservedCancellation"/>.
        /// </summary>
        public void Clear()
        {
            lock (_gate)
            {
                _callCount = 0;
                _requestPaths.Clear();
                _requestMessages.Clear();
                _requestTimeouts.Clear();
                _observedCancellation = false;
                _generation++;
                // An incomplete signal is kept: only a call of the new generation can complete it.
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
            Reply reply;
            int generation;
            // Read together under the lock, so a call recorded after Clear() never answers with a
            // reply that was replaced before Clear() ran.
            lock (_gate)
            {
                reply = _reply;
                generation = _generation;
            }
            try
            {
                // Reading the body drives the client's push content and captures the sent message.
                byte[] body = request.Content is null
                    ? []
                    : await request.Content.ReadAsByteArrayAsync(cancellationToken);
                Record(request, body, generation);
                return await reply.AnswerAsync(request, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                lock (_gate)
                {
                    if (generation == _generation)
                    {
                        _observedCancellation = true;
                    }
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

        private void Record(HttpRequestMessage request, byte[] body, int generation)
        {
            string path = request.RequestUri?.AbsolutePath ?? string.Empty;
            byte[] message = body.Length >= MessagePrefixLength ? body[MessagePrefixLength..] : [];
            TimeSpan? timeout = ReadTimeout(request);
            lock (_gate)
            {
                if (generation != _generation)
                {
                    return;
                }
                _callCount++;
                _requestPaths.Add(path);
                _requestMessages.Add(message);
                _requestTimeouts.Add(timeout);
                // Signalled in the same locked step, so Clear() cannot fall between recording and
                // arrival; safe because the signal runs its continuations asynchronously.
                _callReceived.TrySetResult();
            }
        }

        // Units of the gRPC wire form: H hours, M minutes, S seconds, m milliseconds,
        // u microseconds, n nanoseconds; nanoseconds below one tick are truncated.
        private static TimeSpan? ReadTimeout(HttpRequestMessage request)
        {
            if (!request.Headers.TryGetValues(TimeoutHeader, out IEnumerable<string>? values))
            {
                return null;
            }
            string[] received = [.. values];
            string value = received.Length == 1 ? received[0] : string.Empty;
            int digitCount = value.Length - 1;
            if (
                digitCount is < 1 or > MaxTimeoutDigits
                || !long.TryParse(
                    value.AsSpan(0, digitCount),
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out long amount
                )
            )
            {
                throw MalformedTimeout(received);
            }
            long ticks = value[digitCount] switch
            {
                'H' => amount * TimeSpan.TicksPerHour,
                'M' => amount * TimeSpan.TicksPerMinute,
                'S' => amount * TimeSpan.TicksPerSecond,
                'm' => amount * TimeSpan.TicksPerMillisecond,
                'u' => amount * TimeSpan.TicksPerMicrosecond,
                'n' => amount / TimeSpan.NanosecondsPerTick,
                _ => throw MalformedTimeout(received),
            };
            return TimeSpan.FromTicks(ticks);
        }

        private static FormatException MalformedTimeout(string[] received)
        {
            return new FormatException(
                $"Malformed {TimeoutHeader} header [{string.Join(", ", received)}]."
            );
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
