using System.Net;
using System.Text;
using System.Text.Json;
using EasyTrade.BrokerService.Helpers;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// One request seen by <see cref="RecordingHttpMessageHandler"/>, copied when it arrived.
    /// </summary>
    /// <remarks>
    /// <see cref="TokenCanBeCanceled"/> is informational only. <c>HttpClient</c> always links its
    /// own timeout token into the token it hands its handler, so the value is true even when the
    /// caller passed no token. Never use it to prove that a caller's token was forwarded: compare
    /// <see cref="Method"/>, <see cref="RequestUri"/> and <see cref="Headers"/> to show that a
    /// token-less request is unchanged, and prove forwarding by cancelling the caller's token
    /// while the handler holds the request.
    /// </remarks>
    /// <param name="Method">HTTP method of the request.</param>
    /// <param name="RequestUri">Absolute URI, resolved against the client's base address.</param>
    /// <param name="Headers">
    /// Request and content headers keyed case-insensitively, copied on arrival so later changes
    /// to the request cannot alter the record.
    /// </param>
    /// <param name="TokenCanBeCanceled">
    /// Whether the token the handler received could be cancelled; see the remarks.
    /// </param>
    /// <param name="CancelledDuringCall">
    /// Whether that token was cancelled while the handler held the request.
    /// </param>
    public sealed record RecordedHttpRequest(
        HttpMethod Method,
        Uri? RequestUri,
        IReadOnlyDictionary<string, string[]> Headers,
        bool TokenCanBeCanceled,
        bool CancelledDuringCall
    );

    /// <summary>
    /// Primary handler that records every request and answers it with a configured status and
    /// JSON body, or holds it until its token is cancelled. It stands in for the network only, so
    /// the real connectors and <c>HttpClient</c> run unchanged above it.
    /// </summary>
    /// <remarks>
    /// The default reply is 200 with <see cref="DefaultResponseBody"/>. Every reply is a new
    /// <see cref="HttpResponseMessage"/>, because the connectors dispose each response.
    /// </remarks>
    public sealed class RecordingHttpMessageHandler : HttpMessageHandler
    {
        private const string JsonMediaType = "application/json";

        /// <summary>
        /// Body of the default reply: the enabled portfolio insights flag, shaped as
        /// feature-flag-service serializes it.
        /// </summary>
        public static readonly string DefaultResponseBody = JsonSerializer.Serialize(
            new
            {
                Id = Constants.PortfolioInsightsEnabled,
                Enabled = true,
                Name = "Portfolio insights",
                Description = "Simulated demo feature",
                IsModifiable = true,
                Tag = "feature",
            },
            JsonSerializerOptions.Web
        );

        private static readonly Reply DefaultReply = new(
            HttpStatusCode.OK,
            DefaultResponseBody,
            false
        );

        private readonly Lock _gate = new();
        private readonly List<RecordedHttpRequest> _requests = [];
        private bool _observedCancellation;
        private TaskCompletionSource _requestReceived = NewSignal();

        // Immutable reply, swapped whole so a request in flight never sees a half-changed mode.
        private volatile Reply _reply = DefaultReply;

        /// <summary>
        /// Requests recorded since creation, <see cref="Clear"/> or <see cref="Reset"/>, in
        /// arrival order. A held request is listed as soon as it arrives.
        /// </summary>
        public IReadOnlyList<RecordedHttpRequest> Requests
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requests];
                }
            }
        }

        /// <summary>Number of entries in <see cref="Requests"/>.</summary>
        public int Count
        {
            get
            {
                lock (_gate)
                {
                    return _requests.Count;
                }
            }
        }

        /// <summary>
        /// Whether the token of a held request was cancelled since creation, <see cref="Clear"/>
        /// or <see cref="Reset"/>.
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
        /// Completes once the first request since creation, <see cref="Clear"/> or
        /// <see cref="Reset"/> has been recorded, before it is answered or held. Await it with a
        /// bound, for example <c>WaitAsync(TimeSpan)</c>, to cancel a held request only after it
        /// has arrived.
        /// </summary>
        public Task RequestReceived
        {
            get
            {
                lock (_gate)
                {
                    return _requestReceived.Task;
                }
            }
        }

        /// <summary>
        /// Answers every later request with <paramref name="status"/> and, when it is not null,
        /// <paramref name="jsonBody"/> as UTF-8 <c>application/json</c> content. Ends hold mode.
        /// </summary>
        public void RespondWith(HttpStatusCode status, string? jsonBody)
        {
            lock (_gate)
            {
                _reply = new Reply(status, jsonBody, false);
            }
        }

        /// <summary>
        /// Holds every later request unanswered until its token is cancelled, which marks its
        /// record <see cref="RecordedHttpRequest.CancelledDuringCall"/> and sets
        /// <see cref="ObservedCancellation"/>. The configured reply is kept for
        /// <see cref="Release"/>.
        /// </summary>
        public void Hold()
        {
            lock (_gate)
            {
                _reply = _reply with { HoldUntilCancelled = true };
            }
        }

        /// <summary>
        /// Answers every later request with the configured reply again. A request already held
        /// stays held until its token is cancelled.
        /// </summary>
        public void Release()
        {
            lock (_gate)
            {
                _reply = _reply with { HoldUntilCancelled = false };
            }
        }

        /// <summary>Forgets the recorded requests and cancellation; keeps the reply mode.</summary>
        public void Clear()
        {
            lock (_gate)
            {
                ClearRecords();
            }
        }

        /// <summary>
        /// Restores the default reply, ends hold mode and forgets the recorded requests and
        /// cancellation.
        /// </summary>
        public void Reset()
        {
            lock (_gate)
            {
                _reply = DefaultReply;
                ClearRecords();
            }
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken
        )
        {
            ArgumentNullException.ThrowIfNull(request);
            Reply reply = _reply;
            RecordedHttpRequest recorded = new(
                request.Method,
                request.RequestUri,
                CopyHeaders(request),
                cancellationToken.CanBeCanceled,
                CancelledDuringCall: false
            );
            Record(recorded);

            if (reply.HoldUntilCancelled)
            {
                try
                {
                    // Completes only through cancellation, so a held request never sleeps.
                    await Task.Delay(Timeout.Infinite, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    MarkCancelled(recorded);
                    throw;
                }
            }

            return NewResponse(request, reply);
        }

        private static TaskCompletionSource NewSignal()
        {
            return new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private static Dictionary<string, string[]> CopyHeaders(HttpRequestMessage request)
        {
            Dictionary<string, string[]> headers = new(StringComparer.OrdinalIgnoreCase);
            AddHeaders(headers, request.Headers);
            if (request.Content is not null)
            {
                AddHeaders(headers, request.Content.Headers);
            }
            return headers;
        }

        private static void AddHeaders(
            Dictionary<string, string[]> target,
            IEnumerable<KeyValuePair<string, IEnumerable<string>>> source
        )
        {
            foreach (KeyValuePair<string, IEnumerable<string>> header in source)
            {
                string[] values = [.. header.Value];
                target[header.Key] = target.TryGetValue(header.Key, out string[]? existing)
                    ? [.. existing, .. values]
                    : values;
            }
        }

        private static HttpResponseMessage NewResponse(HttpRequestMessage request, Reply reply)
        {
            HttpResponseMessage response = new(reply.Status) { RequestMessage = request };
            if (reply.Body is not null)
            {
                response.Content = new StringContent(reply.Body, Encoding.UTF8, JsonMediaType);
            }
            return response;
        }

        private void Record(RecordedHttpRequest recorded)
        {
            TaskCompletionSource received;
            lock (_gate)
            {
                _requests.Add(recorded);
                received = _requestReceived;
            }
            received.TrySetResult();
        }

        private void MarkCancelled(RecordedHttpRequest recorded)
        {
            lock (_gate)
            {
                _observedCancellation = true;
                // Records compare by value, so the held entry is located by reference.
                int index = _requests.FindIndex(entry => ReferenceEquals(entry, recorded));
                if (index >= 0)
                {
                    _requests[index] = recorded with { CancelledDuringCall = true };
                }
            }
        }

        // Callers hold _gate.
        private void ClearRecords()
        {
            _requests.Clear();
            _observedCancellation = false;
            if (_requestReceived.Task.IsCompleted)
            {
                _requestReceived = NewSignal();
            }
        }

        private sealed record Reply(HttpStatusCode Status, string? Body, bool HoldUntilCancelled);
    }

    /// <summary>
    /// <see cref="IHttpClientFactory"/> whose clients all send through one shared
    /// <see cref="RecordingHttpMessageHandler"/>, so tests drive the real connectors and inspect
    /// what they sent.
    /// </summary>
    /// <param name="handler">Handler shared by every client this factory creates.</param>
    public sealed class RecordingHttpClientFactory(RecordingHttpMessageHandler handler)
        : IHttpClientFactory
    {
        private readonly Lock _gate = new();
        private readonly List<string> _createdClientNames = [];

        /// <summary>Creates a factory over a new handler with the default reply.</summary>
        public RecordingHttpClientFactory()
            : this(new RecordingHttpMessageHandler()) { }

        /// <summary>Handler shared by every client this factory creates.</summary>
        public RecordingHttpMessageHandler Handler { get; } =
            handler ?? throw new ArgumentNullException(nameof(handler));

        /// <summary>
        /// Name passed to each <see cref="CreateClient"/> call, in call order. The parameterless
        /// <c>CreateClient()</c> extension the connectors use passes the empty default name.
        /// </summary>
        public IReadOnlyList<string> CreatedClientNames
        {
            get
            {
                lock (_gate)
                {
                    return [.. _createdClientNames];
                }
            }
        }

        public HttpClient CreateClient(string name)
        {
            lock (_gate)
            {
                _createdClientNames.Add(name);
            }
            // The connectors dispose their client after every call; the shared handler must
            // survive that to serve the next one.
            return new HttpClient(Handler, disposeHandler: false);
        }
    }
}
