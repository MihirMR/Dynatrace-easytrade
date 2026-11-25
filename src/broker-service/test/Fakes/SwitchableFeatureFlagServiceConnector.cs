using System.Text.Json;
using EasyTrade.BrokerService.Helpers;
using EasyTrade.BrokerService.ProblemPatterns.OpenFeature.Providers.FeatureFlagService;

namespace EasyTrade.BrokerService.Test.Fakes
{
    /// <summary>
    /// Outcome a <see cref="SwitchableFeatureFlagServiceConnector"/> gives each call.
    /// </summary>
    public enum SwitchableFlagMode
    {
        /// <summary>The configured flag is returned with <c>Enabled = true</c>.</summary>
        Enabled,

        /// <summary>The configured flag is returned with <c>Enabled = false</c>.</summary>
        Disabled,

        /// <summary><c>null</c>, as the real connector returns for any non-200 response.</summary>
        ReturnNull,

        /// <summary>An <see cref="HttpRequestException"/>, as for a transport failure.</summary>
        ThrowHttpRequest,

        /// <summary>A <see cref="JsonException"/>, as for an unreadable response body.</summary>
        ThrowJson,

        /// <summary>The call ends only when its token or <c>Reset()</c> cancels it.</summary>
        Hang,
    }

    /// <summary>
    /// One finished call to a <see cref="SwitchableFeatureFlagServiceConnector"/>.
    /// </summary>
    /// <param name="Id">Requested flag id.</param>
    /// <param name="TokenCanBeCanceled">Whether the caller's token could cancel at entry.</param>
    /// <param name="TokenCancelled">Whether the caller's token was cancelled at the end.</param>
    public sealed record FlagConnectorCall(string Id, bool TokenCanBeCanceled, bool TokenCancelled);

    /// <summary>
    /// Flag-service connector whose outcome is switched at runtime, so tests drive every outcome
    /// of the flag read (enabled, disabled, non-200, transport failure, unreadable JSON and a hung
    /// request) through the real <c>PluginProvider</c> above it. Safe for concurrent callers.
    /// </summary>
    /// <param name="flagId">The only id answered with a flag while enabled or disabled.</param>
    /// <param name="mode">Initial outcome.</param>
    public sealed class SwitchableFeatureFlagServiceConnector(
        string flagId = Constants.PortfolioInsightsEnabled,
        SwitchableFlagMode mode = SwitchableFlagMode.Disabled
    ) : IFeatureFlagServiceConnector
    {
        private const string FlagName = "Portfolio insights";
        private const string FlagDescription = "Simulated Portfolio Insights demo feature.";
        private const string FlagTag = "feature";

        // Never completes, so a hung call ends only through cancellation.
        private static readonly Task<Flag?> NeverAnswered = new TaskCompletionSource<Flag?>().Task;

        private readonly Lock _gate = new();
        private readonly List<string> _requestedIds = [];
        private readonly List<FlagConnectorCall> _calls = [];
        private SwitchableFlagMode _mode = RequireDefined(mode);
        private int _callCount;
        private bool _observedCancellation;

        // Bumped by Reset(), so a call that started before it never records into the new state.
        private int _generation;
        private CancellationTokenSource _release = new();

        public string FlagId { get; } = RequireFlagId(flagId);

        public SwitchableFlagMode Mode
        {
            get
            {
                lock (_gate)
                {
                    return _mode;
                }
            }
        }

        /// <summary>Calls started since construction or the last <see cref="Reset"/>.</summary>
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

        /// <summary>Ids requested, in call order, recorded when each call starts.</summary>
        public IReadOnlyList<string> RequestedIds
        {
            get
            {
                lock (_gate)
                {
                    return _requestedIds.ToArray();
                }
            }
        }

        /// <summary>Finished calls, in completion order.</summary>
        public IReadOnlyList<FlagConnectorCall> Calls
        {
            get
            {
                lock (_gate)
                {
                    return _calls.ToArray();
                }
            }
        }

        /// <summary>
        /// Whether a hung call ended because the caller's token was cancelled; a release by
        /// <see cref="Reset"/> does not count.
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

        public void SetEnabled(bool enabled)
        {
            SetMode(enabled ? SwitchableFlagMode.Enabled : SwitchableFlagMode.Disabled);
        }

        public void SetMode(SwitchableFlagMode mode)
        {
            SwitchableFlagMode checkedMode = RequireDefined(mode);
            lock (_gate)
            {
                _mode = checkedMode;
            }
        }

        /// <summary>
        /// Restores the disabled mode, clears every record and releases any hung call, which then
        /// ends with an <see cref="OperationCanceledException"/>.
        /// </summary>
        public void Reset()
        {
            CancellationTokenSource released;
            lock (_gate)
            {
                _mode = SwitchableFlagMode.Disabled;
                _callCount = 0;
                _requestedIds.Clear();
                _calls.Clear();
                _observedCancellation = false;
                _generation++;
                released = _release;
                _release = new CancellationTokenSource();
            }

            // Cancelled outside the lock, because released calls continue inline on this thread.
            // Not disposed: it owns no timer or wait handle, and a released call may still be
            // unregistering its linked source from it.
            released.Cancel();
        }

        public Task<Flag?> GetFlag(string id)
        {
            return GetFlag(id, CancellationToken.None);
        }

        public async Task<Flag?> GetFlag(string id, CancellationToken cancellationToken)
        {
            ArgumentNullException.ThrowIfNull(id);
            CallStart start = BeginCall(id, cancellationToken);
            try
            {
                return start.Mode switch
                {
                    SwitchableFlagMode.Enabled => FlagFor(id, true),
                    SwitchableFlagMode.Disabled => FlagFor(id, false),
                    SwitchableFlagMode.ReturnNull => null,
                    SwitchableFlagMode.ThrowHttpRequest => throw new HttpRequestException(
                        "Simulated flag service transport failure"
                    ),
                    SwitchableFlagMode.ThrowJson => throw new JsonException(
                        "Simulated unreadable flag JSON"
                    ),
                    SwitchableFlagMode.Hang => await HangAsync(start, cancellationToken),
                    _ => throw new InvalidOperationException($"Unknown flag mode [{start.Mode}]."),
                };
            }
            finally
            {
                EndCall(start, id, cancellationToken);
            }
        }

        private Flag? FlagFor(string id, bool enabled)
        {
            return string.Equals(id, FlagId, StringComparison.Ordinal)
                ? new Flag(id, enabled, FlagName, FlagDescription, true, FlagTag)
                : null;
        }

        private async Task<Flag?> HangAsync(CallStart start, CancellationToken cancellationToken)
        {
            using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                start.ReleaseToken
            );
            try
            {
                return await NeverAnswered.WaitAsync(linked.Token);
            }
            catch (OperationCanceledException exception)
                when (cancellationToken.IsCancellationRequested)
            {
                lock (_gate)
                {
                    if (start.Generation == _generation)
                    {
                        _observedCancellation = true;
                    }
                }
                // Carries the caller's token, as HttpClient does when its request is cancelled.
                throw new TaskCanceledException(exception.Message, exception, cancellationToken);
            }
        }

        private CallStart BeginCall(string id, CancellationToken cancellationToken)
        {
            lock (_gate)
            {
                _callCount++;
                _requestedIds.Add(id);
                return new CallStart(
                    _mode,
                    _generation,
                    _release.Token,
                    cancellationToken.CanBeCanceled
                );
            }
        }

        private void EndCall(CallStart start, string id, CancellationToken cancellationToken)
        {
            lock (_gate)
            {
                if (start.Generation == _generation)
                {
                    _calls.Add(
                        new FlagConnectorCall(
                            id,
                            start.TokenCanBeCanceled,
                            cancellationToken.IsCancellationRequested
                        )
                    );
                }
            }
        }

        private static string RequireFlagId(string flagId)
        {
            ArgumentException.ThrowIfNullOrEmpty(flagId);
            return flagId;
        }

        private static SwitchableFlagMode RequireDefined(SwitchableFlagMode mode)
        {
            if (!Enum.IsDefined(mode))
            {
                throw new ArgumentOutOfRangeException(nameof(mode), mode, "Unknown flag mode.");
            }
            return mode;
        }

        // State a call captures at entry: the mode is read once, so switching mid-call has no
        // effect on it.
        private readonly record struct CallStart(
            SwitchableFlagMode Mode,
            int Generation,
            CancellationToken ReleaseToken,
            bool TokenCanBeCanceled
        );
    }
}
