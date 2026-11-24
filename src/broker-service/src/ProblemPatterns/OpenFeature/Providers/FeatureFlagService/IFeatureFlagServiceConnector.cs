namespace EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;

public interface IFeatureFlagServiceConnector
{
    public Task<Flag?> GetFlag(string id);
    public Task<Flag?> GetFlag(string id, CancellationToken cancellationToken) => GetFlag(id);
}
