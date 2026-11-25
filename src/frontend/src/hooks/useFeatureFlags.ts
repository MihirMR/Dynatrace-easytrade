import { useEffect } from "react"
import {
    QueryClient,
    focusManager,
    matchQuery,
    onlineManager,
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
 * A flag read that returned `true` and is waiting for query-core to write it
 * into the cache: the activation it started under, and its abort signal.
 */
type PendingTruePublication = { started: number; signal: AbortSignal }

/**
 * At most one per client. Query-core writes a read's result a few microtasks
 * after the read returns, and a cancellation in that gap no longer reaches
 * the read, so the activation is checked again at the write itself.
 *
 * An entry lives until query-core has written that read's own result, which
 * `trackFlagReadPublications` observes. Manual writes never remove it: they
 * pass through the same check, and one landing in the gap must not take the
 * check away from the read's write that follows it. An entry whose read was
 * aborted stays behind harmlessly, because an aborted read never publishes
 * and the check ignores it.
 */
const pendingTruePublications = new WeakMap<
    QueryClient,
    PendingTruePublication
>()

/** Clients whose query cache removes the entry once a read has published. */
const clientsTrackingFlagPublication = new WeakSet<QueryClient>()

/**
 * Subscribes once per client to its query cache and removes the pending
 * entry when query-core writes a flag read's result, the fetch's `success`
 * update. `setQueryData` dispatches the same update marked `manual`, so the
 * loader's and the shutdown's writes leave the entry in place. The
 * subscription is synchronous and follows `structuralSharing` within the
 * same write, so that write is checked before its entry is removed.
 */
function trackFlagReadPublications(client: QueryClient): void {
    if (clientsTrackingFlagPublication.has(client)) {
        return
    }
    clientsTrackingFlagPublication.add(client)
    client.getQueryCache().subscribe((event) => {
        if (
            event.type === "updated" &&
            event.action.type === "success" &&
            event.action.manual !== true &&
            matchQuery(
                { queryKey: featureFlagKeys.portfolioInsights, exact: true },
                event.query
            )
        ) {
            pendingTruePublications.delete(client)
        }
    })
}

/**
 * The value written into the flag cache, called by query-core synchronously
 * at every write (`structuralSharing`), whether a read publishes its result
 * or `setQueryData` writes one. While a read that returned `true` waits to
 * publish and its activation has changed since it started, every `true`
 * becomes `false`: the stale read's own write, and a manual `true` landing
 * in that gap after a shutdown, which is therefore rejected to fail closed
 * (the next poll publishes a current `true`). Every other write passes
 * unchanged: `false`, any `true` while no read waits to publish (the
 * `/insights` loader's write after its own check), a `true` while the
 * waiting read is still current, and a `true` while the waiting read was
 * aborted, which therefore never publishes. The check never consumes the
 * pending entry; only the read's own publication removes it.
 */
function publishedFlagValue(client: QueryClient, next: unknown): unknown {
    if (next !== true) {
        return next
    }
    const pending = pendingTruePublications.get(client)
    if (
        pending !== undefined &&
        !pending.signal.aborted &&
        pending.started !== currentActivation()
    ) {
        return false
    }
    return next
}

/** Time between the starts of consecutive flag polls on a visible tab. */
const FLAG_POLL_INTERVAL_MS = 15_000

/** The pending next poll per client, armed when a flag read starts. */
const nextFlagPolls = new WeakMap<QueryClient, ReturnType<typeof setTimeout>>()

/**
 * Re-arms the next poll for `FLAG_POLL_INTERVAL_MS` after the read starting
 * now. When it fires on a visible tab it refetches the flag query while an
 * observer is mounted; on a hidden tab it does nothing, and the focus
 * refetch revalidates once the tab is visible again. The release of the last
 * mounted `usePortfolioInsightsFlag` cancels it.
 */
function scheduleNextFlagPoll(client: QueryClient): void {
    clearTimeout(nextFlagPolls.get(client))
    nextFlagPolls.set(
        client,
        setTimeout(() => {
            nextFlagPolls.delete(client)
            if (focusManager.isFocused()) {
                void client.refetchQueries({
                    queryKey: featureFlagKeys.portfolioInsights,
                    exact: true,
                    type: "active",
                })
            }
        }, FLAG_POLL_INTERVAL_MS)
    )
}

/**
 * Starts a flag read when the tab regains focus or the browser reconnects,
 * so the answer comes from a read that started after the event. A read in
 * flight started before it, so it is cancelled first (default
 * `revert: true`); a query without data would otherwise join that read.
 *
 * Query-core's own focus and reconnect refetch is not relied on, because it
 * first awaits `resumePausedMutations()`: a resumed mutation that is slow or
 * never settles would delay or block it. When it does run, it joins the read
 * started here while that is in flight, or else starts one more read after
 * the event.
 */
function revalidateFlagAfterEvent(client: QueryClient): void {
    const state = client.getQueryState(featureFlagKeys.portfolioInsights)
    if (state !== undefined && state.fetchStatus !== "idle") {
        void client.cancelQueries({
            queryKey: featureFlagKeys.portfolioInsights,
            exact: true,
        })
    }
    void client.refetchQueries({
        queryKey: featureFlagKeys.portfolioInsights,
        exact: true,
        type: "active",
    })
}

/** One focus and reconnect listener pair per client, and its mounted hooks. */
type FlagRevalidationListeners = { hooks: number; unsubscribe: () => void }

const flagRevalidationListeners = new WeakMap<
    QueryClient,
    FlagRevalidationListeners
>()

/**
 * Registers one focus and one reconnect listener per client, however many
 * `usePortfolioInsightsFlag` instances are mounted, so every event starts
 * one read: with a listener per instance, the second would cancel the read
 * the first had just started. Returns the calling instance's release; the
 * last release removes the listeners and cancels the client's next poll, so
 * nothing polls once nothing observes the flag, as after logout.
 */
function subscribeFlagRevalidation(client: QueryClient): () => void {
    let listeners = flagRevalidationListeners.get(client)
    if (listeners === undefined) {
        const unsubscribeFocus = focusManager.subscribe((focused) => {
            if (focused) {
                revalidateFlagAfterEvent(client)
            }
        })
        const unsubscribeOnline = onlineManager.subscribe((online) => {
            if (online) {
                revalidateFlagAfterEvent(client)
            }
        })
        listeners = {
            hooks: 0,
            unsubscribe: () => {
                unsubscribeFocus()
                unsubscribeOnline()
            },
        }
        flagRevalidationListeners.set(client, listeners)
    }
    const shared = listeners
    shared.hooks += 1
    return () => {
        shared.hooks -= 1
        if (shared.hooks === 0) {
            shared.unsubscribe()
            flagRevalidationListeners.delete(client)
            clearTimeout(nextFlagPolls.get(client))
            nextFlagPolls.delete(client)
        }
    }
}

/**
 * The shared Portfolio Insights flag state, revalidated on every mount, focus
 * and reconnect and every 15 s while the tab is visible. A `false` read shuts
 * the feature down. A `true` read publishes `true` only if no shutdown ran
 * between its start and its cache write, so a read started before a shutdown
 * never revives the feature: the activation is checked when the read returns
 * and again by `structuralSharing` when query-core writes the result, which a
 * shutdown landing in between can no longer cancel. Until that write, a
 * manual `true` after a shutdown is rejected too.
 *
 * `networkMode: "always"` runs every read while the browser reports offline
 * instead of pausing it: the read fails, `getPortfolioInsightsFlag` answers
 * `false` and the shutdown runs, so an outage fails closed rather than
 * keeping a cached `true`. Reconnecting still revalidates.
 *
 * On focus and reconnect, `usePortfolioInsightsFlag` starts the read itself,
 * replacing one in flight, so the answer comes from a read started after the
 * event, within its 2 s deadline, even while a resumed mutation holds back
 * query-core's own `refetchOnWindowFocus` and `refetchOnReconnect`.
 *
 * Visible polls run start to start: every read arms the next poll 15 s after
 * it starts, however long it takes (at most its 2 s deadline), so a toggle
 * shows within 15 s plus that deadline. `refetchInterval` stays as a
 * backstop: query-core re-arms it on every cache update, the read's start at
 * the earliest, so it never comes due before that poll, and whichever of the
 * two fires starts a read that re-arms the other. A hidden tab polls nothing.
 */
export function portfolioInsightsFlagQuery(client: QueryClient = queryClient) {
    return queryOptions({
        queryKey: featureFlagKeys.portfolioInsights,
        queryFn: async ({ signal }) => {
            trackFlagReadPublications(client)
            scheduleNextFlagPoll(client)
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
            if (currentActivation() !== started) {
                return false
            }
            pendingTruePublications.set(client, { started, signal })
            return true
        },
        structuralSharing: (_previous: unknown, next: unknown) =>
            publishedFlagValue(client, next),
        networkMode: "always",
        staleTime: 0,
        refetchInterval: FLAG_POLL_INTERVAL_MS,
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

/**
 * `true` only while the shared flag query holds `true`; pending is `false`.
 * While any instance is mounted, a focus or reconnect starts one read at
 * once, whatever mutations are pending, and answers from it, never from a
 * read already in flight.
 */
export function usePortfolioInsightsFlag(): boolean {
    const client = useQueryClient()
    const enabled = useQuery(portfolioInsightsFlagQuery(client)).data === true
    useEffect(() => subscribeFlagRevalidation(client), [client])
    return enabled
}
