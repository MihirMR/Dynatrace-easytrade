import {
    CancelledError,
    type QueryClient,
    type QueryFunctionContext,
    queryOptions,
    useQuery,
} from "@tanstack/react-query"
import {
    type LoaderFunctionArgs,
    redirect,
    replace,
    resolvePath,
} from "react-router"
import { getPortfolioInsightsFlag } from "../api/featureFlags"
import { getPortfolioInsights } from "../api/portfolioInsights"
import {
    captureFeatureContext,
    featureQueryRetry,
    isCurrentFeatureContext,
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
    recordFeatureResultContext,
    shareFeatureResult,
} from "../utils/portfolioInsightsFeature"
import { queryClient } from "../utils/queryClient"
import { featureFlagKeys, portfolioKeys } from "../utils/queryKeys"
import { instrumentsQuery } from "./useInstruments"
import { requireUser } from "./useUser"

/** The parts of a feature query's function context the guard works with. */
type FeatureQueryContext = Pick<
    QueryFunctionContext,
    "client" | "queryKey" | "signal"
>

/**
 * Ends the feature query fetch `context` belongs to without publishing data
 * or an error.
 *
 * A query function that rejects never runs query-core's own cancellation, so
 * a `CancelledError` thrown on its own would leave the entry `fetching` with
 * neither. The fetch is therefore cancelled through the client, which
 * restores the state from before it started, with `fetchStatus: "idle"`, so
 * the next fetch starts a request of its own.
 *
 * An aborted signal means a replacement fetch, a removal or a shutdown has
 * already ended this fetch, and cancelling again would end the replacement.
 * The feature reads also hand the signal to `fetch`. Reading it marks it
 * consumed, which makes query-core cancel the fetch, not just its retries,
 * once the last observer unmounts, and that cancellation aborts the HTTP
 * read.
 *
 * `reloadFor` is passed only for an outcome that came back stale, and names
 * the account its request was made for. An observer can still be waiting on
 * that fetch: one that moved to another account and back before the response
 * joins the superseded fetch instead of starting its own. Once the tab is
 * signed in to `reloadFor` again, the cancelled entry is therefore refetched
 * for its active observers, which get a request of the current context; an
 * entry no enabled observer holds, such as a loader prefetch, stays idle
 * until something fetches it. This cannot loop: the replacement captures its
 * own context when it starts and is judged against that alone, so it is
 * discarded only if the context changes again while it runs, and an attempt
 * for an account the tab is not signed in to, or one that starts while the
 * feature is off, is discarded before any request and never reloads.
 */
function discardFeatureFetch(
    context: FeatureQueryContext,
    reloadFor?: string
): never {
    if (!context.signal.aborted) {
        void context.client.cancelQueries({
            queryKey: context.queryKey,
            exact: true,
        })
        if (
            reloadFor !== undefined &&
            captureFeatureContext().userId === reloadFor
        ) {
            void context.client.refetchQueries({
                queryKey: context.queryKey,
                exact: true,
                type: "active",
            })
        }
    }
    // The fetch's retryer has already settled, so it ignores this rejection.
    throw new CancelledError({ revert: true })
}

/**
 * Runs the request a Portfolio Insights or alert query makes for
 * `accountId`, and hands back its outcome only while the tab's account,
 * session and activation still match those it started under.
 *
 * - An attempt, a retry included, for an account other than the tab's makes
 *   no request, so a delayed retry or a prefetch never fetches for an
 *   account that has logged out or been switched away from.
 * - An attempt, a retry included, that starts while the shared flag state
 *   holds anything but `true` makes no request either. A shutdown writes
 *   `false` before it removes the feature queries, so an observer still
 *   mounted that builds a removed entry again, before it renders with the
 *   flag off, never reaches broker-service, and no 403 runs the shutdown a
 *   second time. Every legitimate attempt starts while the state is `true`:
 *   the `/insights` loader writes it before its prefetch, the page and the
 *   watcher enable their queries only while it holds, and a resume publishes
 *   it, so the entries the shutdown removed load afresh.
 * - A current 403 runs the feature shutdown here, at the query boundary, so
 *   it takes effect whether or not any component observes the query, as for
 *   a loader prefetch. The shutdown cancels and removes the query first, so
 *   the 403 never reaches `error`.
 * - Any other current failure passes through unchanged and stays local to
 *   its query; `featureQueryRetry` decides whether it is retried.
 * - An outcome that arrives after a logout, an account switch or a shutdown
 *   is discarded through `discardFeatureFetch`, even if the user or the
 *   feature has come back since, so it is never rendered or toasted and a
 *   stale 403 runs no shutdown. An observer of the account the tab is signed
 *   in to again that still waits on the entry gets a current request instead.
 * - A current result is handed back with the context it was requested under
 *   recorded on it, which `shareFeatureResult` keeps on the cached value, so
 *   whatever later acts on the cached data checks the request that produced
 *   it.
 */
export async function guardFeatureRequest<T>(
    context: FeatureQueryContext,
    accountId: string,
    request: () => Promise<T>
): Promise<T> {
    const ctx = captureFeatureContext()
    if (
        ctx.userId !== accountId ||
        context.client.getQueryData<boolean>(
            featureFlagKeys.portfolioInsights
        ) !== true
    ) {
        discardFeatureFetch(context)
    }
    let result: T
    try {
        result = await request()
    } catch (error) {
        if (!isCurrentFeatureContext(ctx)) {
            discardFeatureFetch(context, accountId)
        }
        if (isFeatureDisabledError(error)) {
            onPortfolioInsightsDisabled(context.client)
        }
        throw error
    }
    if (!isCurrentFeatureContext(ctx)) {
        discardFeatureFetch(context, accountId)
    }
    recordFeatureResultContext(result, ctx)
    return result
}

/**
 * The insights of one account, exactly as broker-service computed them. Each
 * attempt sends its request only while that account is signed in and the
 * shared flag state reads `true`; otherwise it ends unfetched. A 403 runs the
 * feature shutdown from the query itself, with or without a mounted page, and
 * is never retried. The cached result keeps the context of the request that
 * produced it. Focus starts no read of it; the flag query is what
 * revalidates the feature on focus. The query's signal reaches `fetch`, so a
 * cancellation, such as the shutdown or the last observer unmounting, aborts
 * the HTTP read.
 */
export function portfolioInsightsQuery(accountId: string) {
    return queryOptions({
        queryKey: portfolioKeys.insights(accountId),
        queryFn: (context) =>
            guardFeatureRequest(context, accountId, () =>
                getPortfolioInsights(accountId, context.signal)
            ),
        retry: featureQueryRetry,
        structuralSharing: shareFeatureResult,
        refetchOnWindowFocus: false,
    })
}

export function usePortfolioInsightsQuery(accountId: string, enabled: boolean) {
    return useQuery({ ...portfolioInsightsQuery(accountId), enabled })
}

/**
 * The redirect to `/home` that refuses the `/insights` entry `request` made.
 *
 * Loader arguments carry no navigation type, but while a loader runs the
 * window still shows the tab's current history entry. That entry is already
 * the refused address after a typed address, a bookmark, a reload or a step
 * Back or Forward into it, and it is `/home` when a link was followed from
 * there; the redirect replaces it in both cases, so Back never enters the
 * loader again and no second `/home` is stacked. Any other page is the origin
 * of a link the router has not committed yet, so the redirect is pushed after
 * it and Back returns there. `/home` is resolved as the sibling of the entry,
 * which keeps the router's basename on both compared paths.
 */
function refuseEntry(request: Request): Response {
    const entryPath = new URL(request.url).pathname
    const homePath = resolvePath("../home", entryPath).pathname
    const shownPath = window.location.pathname
    return shownPath === entryPath || shownPath === homePath
        ? replace("/home")
        : redirect("/home")
}

/**
 * The entry decision of `createPortfolioInsightsLoader` for `userId`, made
 * for the navigation `request`.
 */
async function decidePortfolioInsightsEntry(
    client: QueryClient,
    userId: string,
    request: Request
): Promise<null> {
    const entry = captureFeatureContext()
    // Read directly, not through the shared flag query, so entry never joins
    // a read already in flight and never trusts a cached `true`.
    const enabled = await getPortfolioInsightsFlag(request.signal)
    if (request.signal.aborted) {
        // The router discards an abandoned navigation's result, and the read's
        // `false` may come from that abort alone.
        return null
    }
    if (!enabled) {
        // Not the shared read, so a shared read in flight is cancelled.
        onPortfolioInsightsDisabled(client)
        throw refuseEntry(request)
    }
    if (!isCurrentFeatureContext(entry) || entry.userId !== userId) {
        // A shutdown, a logout or an account switch ran during the read; a
        // shutdown has already done its own work.
        throw refuseEntry(request)
    }
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    // `prefetchQuery` never rejects, so neither call can fail the loader.
    // Query-core 5.105 deprecates it in favour of `query()`; it is kept to
    // match this folder's loaders, which still use the deprecated
    // `ensureQueryData`.
    void client.prefetchQuery(portfolioInsightsQuery(userId))
    void client.prefetchQuery(instrumentsQuery(userId))
    return null
}

/**
 * The `/insights` entry loader for `client`. It blocks only on its own flag
 * read and redirects to `/home` unless that read answers `true` for an entry
 * that is still current. It never rejects with a data error: insights and
 * instruments are only prefetched, so an ordinary failure reaches the mounted
 * page's own error state and a 403 the feature shutdown, never the router's
 * error page.
 *
 * The redirect replaces the tab's current history entry when that entry is
 * already the refused `/insights` address or `/home`, so Back never enters
 * the loader again and no second `/home` is stacked. After a link followed
 * from any other page it is pushed after that page, so Back returns there.
 *
 * The read carries the navigation's abort signal, and the account, its
 * session and the activation are captured before it. When the read returns:
 * - an abandoned navigation (the user left, or a newer navigation replaced
 *   it) ends with no side effect, whatever the read answered: it neither
 *   shuts down a view that is still current nor publishes or prefetches;
 * - a `false` runs the shutdown and redirects;
 * - a `true` publishes the flag and prefetches only while the captured
 *   account, session and activation all still hold. After a logout, an
 *   account switch or a shutdown during the read it redirects instead, so
 *   the read can neither revive the feature nor refill the caches a logout
 *   cleared with the previous account's data.
 */
export function createPortfolioInsightsLoader(client: QueryClient) {
    // `requireUser` passes no router arguments to its callback, so it wraps
    // each call to keep the navigation's request in reach.
    return ({ request }: LoaderFunctionArgs) =>
        requireUser((userId) =>
            decidePortfolioInsightsEntry(client, userId, request)
        )()
}

export const portfolioInsightsLoader =
    createPortfolioInsightsLoader(queryClient)
