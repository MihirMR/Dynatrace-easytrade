import { PropsWithChildren } from "react"
import {
    QueryClient,
    QueryClientProvider,
    defaultScheduler,
    focusManager,
    notifyManager,
    onlineManager,
} from "@tanstack/react-query"
import { act, cleanup, renderHook } from "@testing-library/react"
import { PortfolioInsightsFlagId } from "../../api/featureFlags"
import {
    portfolioInsightsFlagQuery,
    usePortfolioInsightsFlag,
} from "../../hooks/useFeatureFlags"
import { onPortfolioInsightsDisabled } from "../../utils/portfolioInsightsFeature"
import { featureFlagKeys } from "../../utils/queryKeys"

type Deferred<T> = { promise: Promise<T>; resolve: (value: T) => void }

function deferred<T>(): Deferred<T> {
    let resolve: (value: T) => void = () => undefined
    const promise = new Promise<T>((settle) => {
        resolve = settle
    })
    return { promise, resolve }
}

function newClient(): QueryClient {
    return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function flagResponse(enabled: boolean): Response {
    return new Response(
        JSON.stringify({ id: PortfolioInsightsFlagId, enabled }),
        {
            status: 200,
            headers: { "Content-Type": "application/json" },
        }
    )
}

async function microtaskHops(count: number): Promise<void> {
    for (let hop = 0; hop < count; hop += 1) {
        await Promise.resolve()
    }
}

/** Observes the shared flag query the way `Navigation` does. */
function renderFlag(client: QueryClient) {
    const wrapper = ({ children }: PropsWithChildren) => (
        <QueryClientProvider client={client}>{children}</QueryClientProvider>
    )
    return renderHook(() => usePortfolioInsightsFlag(), { wrapper })
}

/**
 * Mounts `observers` separate hook instances, as `Navigation`, the page and
 * the notification watcher do, and returns the first one's.
 */
function renderFlags(client: QueryClient, observers: number) {
    const first = renderFlag(client)
    for (let mounted = 1; mounted < observers; mounted += 1) {
        renderFlag(client)
    }
    return first
}

/** Each row once with one mounted hook instance and once with two. */
function withObserverCounts<Row extends object>(
    rows: Row[]
): (Row & { observers: number })[] {
    return rows.flatMap((row) =>
        [1, 2].map((observers) => ({ ...row, observers }))
    )
}

/** Advances the fake clock and lets the reads it started settle and render. */
async function advance(ms: number): Promise<void> {
    await act(async () => {
        await vi.advanceTimersByTimeAsync(ms)
    })
}

beforeEach(() => {
    // Query-core delivers notifications through a zero-delay timer, which
    // fake timers defer by 1 ms when it is scheduled during a tick. Delivering
    // them as microtasks keeps every assertion on the exact fake instant.
    notifyManager.setScheduler(queueMicrotask)
})

afterEach(() => {
    // Unmount first, so restoring focus and connectivity below starts no read.
    cleanup()
    notifyManager.setScheduler(defaultScheduler)
    focusManager.setFocused(undefined)
    onlineManager.setOnline(true)
    vi.useRealTimers()
    vi.restoreAllMocks()
    sessionStorage.clear()
})

/**
 * Microtask hops between the held flag response resolving and a shutdown.
 * The early rows land while the read is still pending, so the shutdown
 * cancels it; one row lands after it returned but before its retryer settled,
 * leaving an aborted pending publication; one row lands after the retryer
 * settled but before the cache write, which no cancellation reaches; the late
 * rows land after the write. The sweep is wider than the read's microtask
 * path so every one of those gaps stays covered if that path changes length.
 */
const HOPS = Array.from({ length: 20 }, (_, hops) => hops)

/**
 * Caches `true`, starts a flag read held until its `true` response is
 * released, releases it, and runs a 403-style shutdown `hops` microtasks
 * later. Resolves once the read has settled.
 *
 * With `loaderWriteFirst`, the `/insights` loader's manual `true` write runs
 * in its own continuation `hops` microtasks after the release, queued just
 * ahead of the shutdown's, so the shutdown is the very next microtask. Both
 * then land together in every gap of the read, including the one between
 * its retryer settling and its cache write, which a shutdown queued by the
 * write's own continuation would always miss.
 */
async function shutdownDuringTrueRead(
    client: QueryClient,
    hops: number,
    loaderWriteFirst = false
): Promise<void> {
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    const response = deferred<Response>()
    vi.spyOn(window, "fetch").mockReturnValue(response.promise)
    const read = client.query(portfolioInsightsFlagQuery(client))

    response.resolve(flagResponse(true))
    const loaderWrite = loaderWriteFirst
        ? microtaskHops(hops).then(() => {
              client.setQueryData<boolean>(
                  featureFlagKeys.portfolioInsights,
                  true
              )
          })
        : Promise.resolve()
    await microtaskHops(hops)
    onPortfolioInsightsDisabled(client)
    await loaderWrite
    await read
}

it.each(
    [false, true].flatMap((loaderWriteFirst) =>
        HOPS.map((hops) => ({ hops, loaderWriteFirst }))
    )
)(
    "portfolioInsightsFlagQuery_shutdownDuringTrueRead_cacheEndsFalse ($hops hops, loader write first: $loaderWriteFirst)",
    async ({ hops, loaderWriteFirst }) => {
        const client = newClient()

        await shutdownDuringTrueRead(client, hops, loaderWriteFirst)

        expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
            false
        )
    }
)

it.each(HOPS)(
    "portfolioInsightsFlagQuery_loaderWriteAfterShutdown_publishesTrue (%i hops)",
    async (hops) => {
        const client = newClient()
        await shutdownDuringTrueRead(client, hops)

        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)

        expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
            true
        )
    }
)

it("portfolioInsightsFlagQuery_readStartedAfterShutdown_publishesTrue", async () => {
    const client = newClient()
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    onPortfolioInsightsDisabled(client)
    vi.spyOn(window, "fetch").mockResolvedValue(flagResponse(true))

    await client.query(portfolioInsightsFlagQuery(client))

    expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(true)
})

it("usePortfolioInsightsFlag_offlinePoll_readsAndTurnsFalse", async () => {
    vi.useFakeTimers()
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    const client = newClient()
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    const fetchMock = vi
        .spyOn(window, "fetch")
        .mockImplementation(() => Promise.resolve(flagResponse(true)))
    const { result } = renderFlag(client)
    await advance(0)
    fetchMock.mockImplementation(() =>
        Promise.reject(new TypeError("Failed to fetch"))
    )
    onlineManager.setOnline(false)

    await advance(15_000)

    expect({
        reads: fetchMock.mock.calls.length,
        enabled: result.current,
    }).toEqual({ reads: 2, enabled: false })
})

const REVALIDATING_EVENTS = [
    {
        event: "focus",
        fire: () => {
            focusManager.setFocused(false)
            focusManager.setFocused(true)
        },
    },
    {
        event: "reconnect",
        fire: () => {
            onlineManager.setOnline(false)
            onlineManager.setOnline(true)
        },
    },
]

it.each(withObserverCounts(REVALIDATING_EVENTS))(
    "usePortfolioInsightsFlag_eventDuringRead_answersFromPostEventRead ($event, $observers observers)",
    async ({ fire, observers }) => {
        vi.useFakeTimers()
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        const client = newClient()
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
        const preEvent = deferred<Response>()
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementationOnce(() => preEvent.promise)
            .mockImplementation(() => Promise.resolve(flagResponse(false)))
        const { result } = renderFlags(client, observers)
        await advance(0)

        fire()
        await advance(0)
        preEvent.resolve(flagResponse(true))
        await advance(0)

        expect({
            reads: fetchMock.mock.calls.length,
            preEventAborted: fetchMock.mock.calls[0][1]?.signal?.aborted,
            enabled: result.current,
        }).toEqual({ reads: 2, preEventAborted: true, enabled: false })
    }
)

/** Never settles, so a mutation running it stays pending. */
function heldMutationFn(): Promise<void> {
    return new Promise<void>(() => undefined)
}

/**
 * Query-core's own focus and reconnect refetch first awaits
 * `resumePausedMutations()`. Each row leaves a mutation paused until its
 * event; resumed by it, the mutation stays pending, so that refetch never
 * starts and only the hook's own revalidation can read the flag.
 */
const EVENTS_RESUMING_HELD_MUTATION = [
    {
        event: "focus",
        // The first attempt fails while the tab is hidden, so the retry
        // pauses until the tab is visible again.
        park: async (client: QueryClient) => {
            focusManager.setFocused(false)
            let attempts = 0
            void client
                .getMutationCache()
                .build(client, {
                    mutationFn: () => {
                        attempts += 1
                        return attempts === 1
                            ? Promise.reject(new Error("first attempt"))
                            : heldMutationFn()
                    },
                    retry: 1,
                    retryDelay: 0,
                })
                .execute(undefined)
            await advance(0)
        },
        fire: () => focusManager.setFocused(true),
    },
    {
        event: "reconnect",
        // Started offline, the mutation pauses before its first attempt.
        park: async (client: QueryClient) => {
            onlineManager.setOnline(false)
            void client
                .getMutationCache()
                .build(client, { mutationFn: heldMutationFn })
                .execute(undefined)
            await advance(0)
        },
        fire: () => onlineManager.setOnline(true),
    },
]

it.each(withObserverCounts(EVENTS_RESUMING_HELD_MUTATION))(
    "usePortfolioInsightsFlag_eventWhileMutationResumes_answersFromOnePostEventRead ($event, $observers observers)",
    async ({ park, fire, observers }) => {
        vi.useFakeTimers()
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        const client = newClient()
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementationOnce(() => Promise.resolve(flagResponse(true)))
            .mockImplementation(() => Promise.resolve(flagResponse(false)))
        const { result } = renderFlags(client, observers)
        await advance(0)
        await park(client)

        fire()
        await advance(0)

        expect({
            reads: fetchMock.mock.calls.length,
            enabled: result.current,
        }).toEqual({ reads: 2, enabled: false })
    }
)

it.each(EVENTS_RESUMING_HELD_MUTATION)(
    "usePortfolioInsightsFlag_eventAfterOtherInstanceUnmounts_answersFromPostEventRead ($event)",
    async ({ park, fire }) => {
        vi.useFakeTimers()
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        const client = newClient()
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementationOnce(() => Promise.resolve(flagResponse(true)))
            .mockImplementation(() => Promise.resolve(flagResponse(false)))
        const { unmount } = renderFlag(client)
        const { result } = renderFlag(client)
        await advance(0)
        unmount()
        await park(client)

        fire()
        await advance(0)

        expect({
            reads: fetchMock.mock.calls.length,
            enabled: result.current,
        }).toEqual({ reads: 2, enabled: false })
    }
)

it.each(withObserverCounts(REVALIDATING_EVENTS))(
    "usePortfolioInsightsFlag_eventWhileIdle_startsOneRead ($event, $observers observers)",
    async ({ fire, observers }) => {
        vi.useFakeTimers()
        const client = newClient()
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementation(() => Promise.resolve(flagResponse(true)))
        renderFlags(client, observers)
        await advance(0)

        fire()
        await advance(1_000)

        expect(fetchMock).toHaveBeenCalledTimes(2)
    }
)

it.each(REVALIDATING_EVENTS)(
    "usePortfolioInsightsFlag_eventAfterUnmount_leavesReadInFlight ($event)",
    ({ fire }) => {
        const client = newClient()
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementation(() => new Promise<Response>(() => undefined))
        const { unmount } = renderFlag(client)
        unmount()
        void client.query(portfolioInsightsFlagQuery(client))

        fire()

        expect(fetchMock.mock.calls[1][1]?.signal?.aborted).toBe(false)
    }
)

it("usePortfolioInsightsFlag_slowRead_pollsStartFifteenSecondsApart", async () => {
    vi.useFakeTimers()
    const startedAt = Date.now()
    const starts: number[] = []
    vi.spyOn(window, "fetch").mockImplementation(() => {
        starts.push(Date.now() - startedAt)
        return new Promise<Response>((resolve) => {
            setTimeout(() => resolve(flagResponse(true)), 1_900)
        })
    })
    renderFlag(newClient())

    await advance(31_000)

    expect(starts).toEqual([0, 15_000, 30_000])
})

it("usePortfolioInsightsFlag_tabHidden_startsNoPoll", async () => {
    vi.useFakeTimers()
    const fetchMock = vi
        .spyOn(window, "fetch")
        .mockImplementation(() => Promise.resolve(flagResponse(true)))
    renderFlag(newClient())
    await advance(0)

    focusManager.setFocused(false)
    await advance(45_000)

    expect(fetchMock).toHaveBeenCalledTimes(1)
})

it.each([
    {
        name: "lastInstanceUnmounts_cancelsNextPoll",
        observers: 1,
        expected: { pendingTimers: 0, reads: 1 },
    },
    {
        name: "otherInstanceUnmounts_keepsNextPoll",
        observers: 2,
        expected: { pendingTimers: 1, reads: 2 },
    },
])("usePortfolioInsightsFlag_$name", async ({ observers, expected }) => {
    // Only timeouts are faked and nothing is garbage-collected, so the count
    // holds the next poll alone, not query-core's own refetch interval.
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false, gcTime: Infinity } },
    })
    const fetchMock = vi
        .spyOn(window, "fetch")
        .mockImplementation(() => Promise.resolve(flagResponse(true)))
    const { unmount } = renderFlags(client, observers)
    await advance(0)

    unmount()
    const pendingTimers = vi.getTimerCount()
    await advance(15_000)

    expect({ pendingTimers, reads: fetchMock.mock.calls.length }).toEqual(
        expected
    )
})
