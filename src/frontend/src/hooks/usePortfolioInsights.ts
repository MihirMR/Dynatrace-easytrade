import {
    CancelledError,
    type QueryClient,
    queryOptions,
    useQuery,
} from "@tanstack/react-query"
import { redirect } from "react-router"
import { getPortfolioInsightsFlag } from "../api/featureFlags"
import { getPortfolioInsights } from "../api/portfolioInsights"
import {
    captureFeatureContext,
    currentActivation,
    featureQueryRetry,
    isCurrentFeatureContext,
    onPortfolioInsightsDisabled,
} from "../utils/portfolioInsightsFeature"
import { queryClient } from "../utils/queryClient"
import { featureFlagKeys, portfolioKeys } from "../utils/queryKeys"
import { instrumentsQuery } from "./useInstruments"
import { requireUser } from "./useUser"

/**
 * Runs a Portfolio Insights or alert request and hands back its outcome only
 * while the account, session and activation it started under still hold.
 *
 * An outcome that arrives after a logout, an account switch or a shutdown is
 * replaced by a silent `CancelledError`, even if the user or the feature has
 * come back since. Query-core settles a silent cancellation without writing
 * data or an error and without notifying observers, and `featureQueryRetry`
 * never re-runs it, so a stale result is never rendered or toasted. An
 * outcome that is still current passes through unchanged, errors included.
 */
export async function guardFeatureRequest<T>(
    request: () => Promise<T>
): Promise<T> {
    const ctx = captureFeatureContext()
    let result: T
    try {
        result = await request()
    } catch (error) {
        if (!isCurrentFeatureContext(ctx)) {
            throw new CancelledError({ revert: true, silent: true })
        }
        throw error
    }
    if (!isCurrentFeatureContext(ctx)) {
        throw new CancelledError({ revert: true, silent: true })
    }
    return result
}

/**
 * The insights of one account, exactly as broker-service computed them. A
 * 403 reaches `error` without a retry; the page that observes it runs the
 * feature shutdown.
 */
export function portfolioInsightsQuery(accountId: string) {
    return queryOptions({
        queryKey: portfolioKeys.insights(accountId),
        queryFn: () =>
            guardFeatureRequest(() => getPortfolioInsights(accountId)),
        retry: featureQueryRetry,
    })
}

export function usePortfolioInsightsQuery(accountId: string, enabled: boolean) {
    return useQuery({ ...portfolioInsightsQuery(accountId), enabled })
}

/**
 * The `/insights` entry loader for `client`. It blocks only on its own flag
 * read and redirects to `/home` unless that read answers `true` with no
 * shutdown in the meantime. It never rejects with a data error: insights and
 * instruments are only prefetched, so their failures, a 403 included, reach
 * the mounted page's own states instead of the router's error page.
 */
export function createPortfolioInsightsLoader(client: QueryClient) {
    return requireUser(async (userId) => {
        const started = currentActivation()
        // Read directly, not through the shared flag query, so entry never
        // joins a read already in flight and never trusts a cached `true`.
        const enabled = await getPortfolioInsightsFlag()
        if (!enabled) {
            // Not the shared read, so a shared read in flight is cancelled.
            onPortfolioInsightsDisabled(client)
            throw redirect("/home")
        }
        if (currentActivation() !== started) {
            // A shutdown ran during the read and has already done its work.
            throw redirect("/home")
        }
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
        // `prefetchQuery` never rejects, so neither call can fail the loader.
        // Query-core 5.105 deprecates it in favour of `query()`; it is kept to
        // match this folder's loaders, which still use the deprecated
        // `ensureQueryData`.
        void client.prefetchQuery(portfolioInsightsQuery(userId))
        void client.prefetchQuery(instrumentsQuery(userId))
        return null
    })
}

export const portfolioInsightsLoader =
    createPortfolioInsightsLoader(queryClient)
