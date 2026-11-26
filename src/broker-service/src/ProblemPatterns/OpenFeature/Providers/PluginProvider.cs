using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;
using OpenFeature;
using OpenFeature.Model;

namespace EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers;

public class PluginProvider(IFeatureFlagServiceConnector flagServiceConnector) : FeatureProvider
{
    public static string Name => "Plugin Provider";

    /// <summary>
    /// Flag metadata key under which the resolution of
    /// <see cref="Constants.PortfolioInsightsEnabled"/> reports the id the flag service answered
    /// with, empty when its body carried none. It is present only when the service answered with
    /// a flag, and it is reported rather than checked, so the resolved value is the same whichever
    /// flag answered. Every other flag, the problem patterns included, resolves as before, with
    /// its value and no flag metadata.
    /// </summary>
    public const string FlagIdMetadataKey = "flagId";

    private readonly IFeatureFlagServiceConnector _flagServiceConnector = flagServiceConnector;

    public override Metadata GetMetadata() => new(Name);

    public override async Task<ResolutionDetails<bool>> ResolveBooleanValueAsync(
        string flagKey,
        bool defaultValue,
        EvaluationContext? context = null,
        CancellationToken cancellationToken = default
    )
    {
        Flag? flag = await _flagServiceConnector.GetFlag(flagKey, cancellationToken);
        var value = flag is null ? defaultValue : flag.Enabled;
        // Only the portfolio insights read checks which flag answered, so only its resolution
        // names it; the key comparison is ordinal, as the flag service matches ids.
        if (flagKey == Constants.PortfolioInsightsEnabled)
        {
            return new ResolutionDetails<bool>(flagKey, value, flagMetadata: AnsweredFlag(flag));
        }
        return new ResolutionDetails<bool>(flagKey, value);
    }

    // Names the flag the service answered with. A body without an id still deserializes, with
    // a null id, which is reported as empty rather than left out, so a caller can tell an answer
    // without an id from no answer at all.
    private static ImmutableMetadata? AnsweredFlag(Flag? flag)
    {
        if (flag is null)
        {
            return null;
        }
        string answeredId = flag.Id ?? string.Empty;
        return new ImmutableMetadata(
            new Dictionary<string, object> { [FlagIdMetadataKey] = answeredId }
        );
    }

    public override Task<ResolutionDetails<double>> ResolveDoubleValueAsync(
        string flagKey,
        double defaultValue,
        EvaluationContext? context = null,
        CancellationToken cancellationToken = default
    ) => throw new NotImplementedException();

    public override Task<ResolutionDetails<int>> ResolveIntegerValueAsync(
        string flagKey,
        int defaultValue,
        EvaluationContext? context = null,
        CancellationToken cancellationToken = default
    ) => throw new NotImplementedException();

    public override Task<ResolutionDetails<string>> ResolveStringValueAsync(
        string flagKey,
        string defaultValue,
        EvaluationContext? context = null,
        CancellationToken cancellationToken = default
    ) => throw new NotImplementedException();

    public override Task<ResolutionDetails<Value>> ResolveStructureValueAsync(
        string flagKey,
        Value defaultValue,
        EvaluationContext? context = null,
        CancellationToken cancellationToken = default
    ) => throw new NotImplementedException();
}
