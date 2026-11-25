import {
    QueryClient,
    queryOptions,
    useQuery,
    useQueryClient,
} from "@tanstack/react-query"
import {
    Config,
    ConfigDefaults,
    FeatureFlag,
    getConfig,
    getFeatureFlags,
    getPortfolioInsightsFlag,
} from "../api/featureFlags"
import {
    currentActivation,
    onPortfolioInsightsDisabled,
} from "../utils/portfolioInsightsFeature"
import { queryClient } from "../utils/queryClient"
import { featureFlagKeys } from "../utils/queryKeys"

export function problemFlagsQuery() {
    return queryOptions({
        queryKey: featureFlagKeys.problemPatterns,
        queryFn: getFeatureFlags,
    })
}

export function configFlagsQuery() {
    return queryOptions({
        queryKey: featureFlagKeys.config,
        queryFn: getConfig,
    })
}

/**
 * The shared Portfolio Insights flag state, revalidated on every mount, focus
 * and reconnect and every 15 s while the tab is visible. A `false` read shuts
 * the feature down. A `true` read publishes `true` only if no shutdown ran
 * while it was in flight, so a read started before a shutdown never revives
 * the feature.
 */
export function portfolioInsightsFlagQuery(client: QueryClient = queryClient) {
    return queryOptions({
        queryKey: featureFlagKeys.portfolioInsights,
        queryFn: async ({ signal }) => {
            const started = currentActivation()
            const enabled = await getPortfolioInsightsFlag(signal)
            // Cancelled by a shutdown that already ran, by a refetch that
            // replaced this read, or because every observer left: the result
            // is discarded, and shutting down here would advance the
            // activation counter a second time or without cause.
            if (signal.aborted) {
                return false
            }
            if (!enabled) {
                onPortfolioInsightsDisabled(client, { fromFlagRead: true })
                return false
            }
            return currentActivation() === started
        },
        staleTime: 0,
        refetchInterval: 15_000,
        refetchIntervalInBackground: false,
        refetchOnWindowFocus: "always",
        refetchOnReconnect: "always",
    })
}

export function useProblemFlagsQuery(initialData?: FeatureFlag[]) {
    return useQuery({ ...problemFlagsQuery(), initialData })
}

export function useConfigFlagsQuery(initialData?: Config) {
    const result = useQuery({ ...configFlagsQuery(), initialData })
    return { ...result, data: result.data ?? ConfigDefaults }
}

/** `true` only while the shared flag query holds `true`; pending is `false`. */
export function usePortfolioInsightsFlag(): boolean {
    const client = useQueryClient()
    return useQuery(portfolioInsightsFlagQuery(client)).data === true
}
