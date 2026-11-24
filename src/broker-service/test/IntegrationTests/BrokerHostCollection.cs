namespace EasyTrade.BrokerService.Test.IntegrationTests
{
    // Hosts started by these tests set the process-wide OpenFeature Api.Instance provider through
    // PluginManager.InitializeAsync, as OpenFeatureTests does, so this collection runs alone.
    [CollectionDefinition(Name, DisableParallelization = true)]
    public class BrokerHostCollection
    {
        public const string Name = "BrokerHost";
    }
}
