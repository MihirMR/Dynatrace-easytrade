using EasyTrade.BrokerService.Helpers;
using System.Net;

namespace EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;

public class FeatureFlagServiceConnector(
    IConfiguration configuration,
    IHttpClientFactory httpClientFactory,
    ILogger<FeatureFlagServiceConnector> logger
) : IFeatureFlagServiceConnector
{
    private readonly IConfiguration _config = configuration;
    private readonly IHttpClientFactory _httpClientFactory = httpClientFactory;
    private readonly ILogger _logger = logger;
    private string FeatureFlagServiceUrl => $"{_config[Constants.FeatureFlagServiceAddress]}/v1/";

    public Task<Flag?> GetFlag(string id)
    {
        return GetFlag(id, CancellationToken.None);
    }

    public async Task<Flag?> GetFlag(string id, CancellationToken cancellationToken)
    {
        string endpoint = $"flags/{id}";
        using HttpClient client = GetHttpClient();
        using HttpResponseMessage response = await client.GetAsync(endpoint, cancellationToken);
        if (response.StatusCode == HttpStatusCode.OK)
        {
            return await response.Content.ReadFromJsonAsync<Flag>(cancellationToken);
        }
        _logger.LogWarning("Flag with id [{id}] not found", id);
        return null;
    }

    private HttpClient GetHttpClient()
    {
        var client = _httpClientFactory.CreateClient();
        client.BaseAddress = new Uri(FeatureFlagServiceUrl);
        return client;
    }
}
