using EasyTrade.BrokerService.Test.Fakes;

namespace EasyTrade.BrokerService.Test.UnitTests
{
    public class RecordingHttpClientFactoryTests
    {
        private const string HeaderName = "X-Test";
        private static readonly string[] HeaderValues = ["a", "b"];
        private static readonly Uri RequestUri = new("http://localhost/recorded");

        // Bounds every wait on a signal, so a broken fake fails the test instead of hanging it.
        private static readonly TimeSpan WaitBound = TimeSpan.FromSeconds(5);

        public enum KeyChange
        {
            Add,
            Remove,
        }

        [Fact]
        public async Task Requests_SnapshotHeaderValueEdited_ShouldKeepLaterRead()
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            await SendAsync(factory);
            string[] snapshotValues = factory.Handler.Requests[0].Headers[HeaderName];

            // Act
            snapshotValues[0] = "edited";

            // Assert
            Assert.Equal(HeaderValues, factory.Handler.Requests[0].Headers[HeaderName]);
        }

        [Theory]
        [InlineData(KeyChange.Add)]
        [InlineData(KeyChange.Remove)]
        public async Task Requests_SnapshotKeysChanged_ShouldKeepLaterRead(KeyChange change)
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            await SendAsync(factory);
            Dictionary<string, string[]> snapshot =
                (Dictionary<string, string[]>)factory.Handler.Requests[0].Headers;
            string[] expectedKeys = [HeaderName];

            // Act
            if (change == KeyChange.Add)
            {
                snapshot.Add("X-Extra", ["z"]);
            }
            else
            {
                snapshot.Remove(HeaderName);
            }

            // Assert
            Assert.Equal(expectedKeys, factory.Handler.Requests[0].Headers.Keys);
        }

        [Theory]
        [InlineData("x-test")]
        [InlineData("X-TEST")]
        public async Task Requests_HeaderCopyLookedUpInOtherCase_ShouldFindHeader(string name)
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            await SendAsync(factory);

            // Act
            IReadOnlyDictionary<string, string[]> copy = factory.Handler.Requests[0].Headers;

            // Assert
            Assert.Equal(HeaderValues, copy[name]);
        }

        [Fact]
        public async Task Requests_HeldRequestCancelledByCaller_ShouldListCancelledWithHeaders()
        {
            // Arrange
            RecordingHttpClientFactory factory = new();
            factory.Handler.Hold();
            using HttpClient client = factory.CreateClient(string.Empty);
            using CancellationTokenSource caller = new();
            using HttpRequestMessage request = NewRequest();
            Task<HttpResponseMessage> send = client.SendAsync(request, caller.Token);
            await factory.Handler.RequestReceived.WaitAsync(WaitBound);
            // Cancellation rewrites the stored record, which a snapshot edited meanwhile must
            // not reach.
            factory.Handler.Requests[0].Headers[HeaderName][0] = "edited";

            // Act
            await caller.CancelAsync();
            _ = await Record.ExceptionAsync(() => send.WaitAsync(WaitBound));
            RecordedHttpRequest recorded = Assert.Single(factory.Handler.Requests);

            // Assert
            Assert.True(recorded.CancelledDuringCall);
            Assert.Equal(HeaderValues, recorded.Headers[HeaderName]);
        }

        private static async Task SendAsync(RecordingHttpClientFactory factory)
        {
            using HttpClient client = factory.CreateClient(string.Empty);
            using HttpRequestMessage request = NewRequest();
            using HttpResponseMessage response = await client
                .SendAsync(request)
                .WaitAsync(WaitBound);
        }

        private static HttpRequestMessage NewRequest()
        {
            HttpRequestMessage request = new(HttpMethod.Get, RequestUri);
            request.Headers.Add(HeaderName, HeaderValues);
            return request;
        }
    }
}
