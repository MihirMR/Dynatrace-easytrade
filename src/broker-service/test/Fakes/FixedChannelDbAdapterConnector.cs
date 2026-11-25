using EasyTrade.BrokerService.Connectors;
using Grpc.Net.Client;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// <see cref="IDbAdapterConnector"/> whose channel sends every call to an in-process
    /// <see cref="HttpMessageHandler"/>, such as <see cref="GrpcStatusHandler"/>. The real
    /// db-adapter repositories and <c>GrpcHelper</c> run unchanged on top of it; only the gRPC
    /// transport is replaced, never the database.
    /// </summary>
    /// <remarks>
    /// The connector takes ownership of the handler: disposing the connector disposes the channel,
    /// and the channel disposes the handler with it. A handler's recorded calls stay readable after
    /// that, so tests may assert on them once the connector is gone.
    /// </remarks>
    public sealed class FixedChannelDbAdapterConnector : IDbAdapterConnector, IDisposable
    {
        // Only names the target for the request URIs; no call ever leaves the process.
        private const string Address = "http://localhost";

        private readonly GrpcChannel _channel;

        public FixedChannelDbAdapterConnector(HttpMessageHandler handler)
        {
            ArgumentNullException.ThrowIfNull(handler);
            Handler = handler;
            // A supplied handler is disposed with the channel only when DisposeHttpClient is set.
            _channel = GrpcChannel.ForAddress(
                Address,
                new GrpcChannelOptions { HttpHandler = handler, DisposeHttpClient = true }
            );
        }

        /// <summary>The handler that receives every call made on the channel.</summary>
        public HttpMessageHandler Handler { get; }

        /// <summary>
        /// The same channel on every call, as the production connector returns its shared one.
        /// </summary>
        public GrpcChannel GetChannel()
        {
            return _channel;
        }

        public void Dispose()
        {
            _channel.Dispose();
        }
    }
}
