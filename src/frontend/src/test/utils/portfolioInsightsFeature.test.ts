import { CancelledError, QueryClient, QueryKey } from "@tanstack/react-query"
import { ApiError } from "../../api/http"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { alertNotificationsQuery, alertsQuery } from "../../hooks/useAlerts"
import { portfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    type FeatureContext,
    StaleFeatureWriteError,
    captureFeatureContext,
    currentActivation,
    dispatchFeatureWrite,
    featureQueryRetry,
    featureResultContext,
    isCurrentFeatureContext,
    isDiscardedFeatureWrite,
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
    recordFeatureResultContext,
    shareFeatureResult,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    balanceKeys,
    creditCardKeys,
    currentLogoutCount,
    featureFlagKeys,
    instrumentKeys,
    invalidateOnLogout,
    onLogout,
    portfolioKeys,
    priceKeys,
    transactionKeys,
    userKeys,
    versionKeys,
} from "../../utils/queryKeys"

const ACCOUNT = "a0000000-0000-4000-8000-000000000000"
const ALERTS_URL = "http://localhost/broker-service/v1/alerts"

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

/**
 * Starts a fetch that stays in flight until `read` resolves. `settled` never
 * rejects: it resolves with the fetch's value or its rejection reason.
 */
function startRead<T>(
    client: QueryClient,
    queryKey: QueryKey,
    read: Deferred<T>
) {
    const signals: AbortSignal[] = []
    const settled = client
        .query({
            queryKey,
            queryFn: ({ signal }) => {
                signals.push(signal)
                return read.promise
            },
        })
        .then(
            (value) => value,
            (error: unknown) => error
        )
    return { settled, signal: () => signals[0] }
}

beforeEach(() => {
    sessionStorage.setItem(SESSION_KEY, "user-1")
})

afterEach(() => {
    sessionStorage.clear()
    vi.restoreAllMocks()
})

it("onPortfolioInsightsDisabled_inFlightTrueRead_flagSettlesFalse", async () => {
    const client = newClient()
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    const read = deferred<boolean>()
    const flagRead = startRead(client, featureFlagKeys.portfolioInsights, read)

    onPortfolioInsightsDisabled(client)
    read.resolve(true)

    expect({
        settled: await flagRead.settled,
        cached: client.getQueryData(featureFlagKeys.portfolioInsights),
        aborted: flagRead.signal().aborted,
    }).toEqual({ settled: false, cached: false, aborted: true })
})

it.each([
    { caller: "other caller", options: undefined, aborted: true },
    { caller: "flag read", options: { fromFlagRead: true }, aborted: false },
])(
    "onPortfolioInsightsDisabled_caller_cancelsFlagReadUnlessFromIt ($caller)",
    ({ options, aborted }) => {
        const client = newClient()
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
        const flagRead = startRead(
            client,
            featureFlagKeys.portfolioInsights,
            deferred<boolean>()
        )

        onPortfolioInsightsDisabled(client, options)

        expect({
            cached: client.getQueryData(featureFlagKeys.portfolioInsights),
            aborted: flagRead.signal().aborted,
        }).toEqual({ cached: false, aborted })
    }
)

it("onPortfolioInsightsDisabled_cache_dropsOnlyFeatureQueries", () => {
    const client = newClient()
    const kept: [QueryKey, unknown][] = [
        [featureFlagKeys.problemPatterns, [{ id: "db_not_responding" }]],
        [featureFlagKeys.config, { frontendFeatureFlagManagement: true }],
        [portfolioKeys.history(ACCOUNT), { results: [] }],
        [balanceKeys.byId(ACCOUNT), { accountId: ACCOUNT, value: 10 }],
        [instrumentKeys.byUser(ACCOUNT), []],
    ]
    kept.forEach(([key, data]) => client.setQueryData(key, data))
    client.setQueryData(alertKeys.list(ACCOUNT), [])
    client.setQueryData(alertKeys.notifications(ACCOUNT), [])
    const insightsRead = startRead(
        client,
        portfolioKeys.insights(ACCOUNT),
        deferred<object>()
    )

    onPortfolioInsightsDisabled(client)

    expect({
        insightsAborted: insightsRead.signal().aborted,
        featureQueries: [
            ...client
                .getQueryCache()
                .findAll({ queryKey: portfolioKeys.insightsAll }),
            ...client.getQueryCache().findAll({ queryKey: alertKeys.all }),
        ].length,
        kept: kept.map(([key]) => client.getQueryData(key)),
    }).toEqual({
        insightsAborted: true,
        featureQueries: 0,
        kept: kept.map(([, data]) => data),
    })
})

// The real query factories, so the query's signal must travel through the
// feature API and the shared transport to reach `fetch`.
it.each<{ read: string; start: (client: QueryClient) => Promise<unknown> }>([
    {
        read: "insights",
        start: (client) => client.query(portfolioInsightsQuery(ACCOUNT)),
    },
    {
        read: "alert list",
        start: (client) => client.query(alertsQuery(ACCOUNT)),
    },
    {
        read: "notifications",
        start: (client) => client.query(alertNotificationsQuery(ACCOUNT)),
    },
])(
    "onPortfolioInsightsDisabled_featureReadInFlight_abortsHttpRequest ($read)",
    async ({ start }) => {
        // The tab is signed in to the account read, and the feature is on as
        // the `/insights` loader publishes it, so the request is sent.
        sessionStorage.setItem(SESSION_KEY, ACCOUNT)
        const sent: (AbortSignal | null | undefined)[] = []
        vi.spyOn(window, "fetch").mockImplementation((_input, init) => {
            sent.push(init?.signal)
            return new Promise<Response>((_, reject) => {
                init?.signal?.addEventListener("abort", () =>
                    reject(new DOMException("Aborted", "AbortError"))
                )
            })
        })
        const client = newClient()
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
        const settled = start(client).catch((error: unknown) => error)

        onPortfolioInsightsDisabled(client)

        expect({
            requests: sent.length,
            aborted: sent[0]?.aborted,
            outcome: await settled,
        }).toEqual({
            requests: 1,
            aborted: true,
            outcome: expect.any(CancelledError),
        })
    }
)

it("onPortfolioInsightsDisabled_repeated_advancesActivationKeepsCache", () => {
    const client = newClient()
    client.setQueryData(alertKeys.list(ACCOUNT), [])
    const before = currentActivation()

    onPortfolioInsightsDisabled(client)
    onPortfolioInsightsDisabled(client)

    expect({
        activation: currentActivation() - before,
        cached: client.getQueryData(featureFlagKeys.portfolioInsights),
        alerts: client.getQueryCache().findAll({ queryKey: alertKeys.all })
            .length,
    }).toEqual({ activation: 2, cached: false, alerts: 0 })
})

it.each([
    { error: new ApiError(403, ALERTS_URL), disabled: true },
    { error: new ApiError(404, ALERTS_URL), disabled: false },
    { error: new ApiError(500, ALERTS_URL), disabled: false },
    { error: new Error("HTTP 403"), disabled: false },
    { error: { status: 403 }, disabled: false },
    { error: new CancelledError(), disabled: false },
    { error: undefined, disabled: false },
])(
    "isFeatureDisabledError_error_isTrueOnlyForApiError403 (%#)",
    ({ error, disabled }) => {
        expect(isFeatureDisabledError(error)).toBe(disabled)
    }
)

it.each([
    { failureCount: 0, error: new Error("boom"), retry: true },
    { failureCount: 2, error: new ApiError(500, ALERTS_URL), retry: true },
    { failureCount: 3, error: new Error("boom"), retry: false },
    { failureCount: 0, error: new ApiError(403, ALERTS_URL), retry: false },
    {
        failureCount: 0,
        error: new CancelledError({ revert: true }),
        retry: false,
    },
])(
    "featureQueryRetry_failure_retriesOnlyOrdinaryFailuresThreeTimes (%#)",
    ({ failureCount, error, retry }) => {
        expect(featureQueryRetry(failureCount, error)).toBe(retry)
    }
)

it.each([
    { stored: "user-2", userId: "user-2" },
    { stored: "", userId: null },
    { stored: null, userId: null },
])(
    "captureFeatureContext_storedUser_readsUserAndActivation ($stored)",
    ({ stored, userId }) => {
        if (stored === null) {
            sessionStorage.removeItem(SESSION_KEY)
        } else {
            sessionStorage.setItem(SESSION_KEY, stored)
        }

        const ctx = captureFeatureContext()

        expect({ userId: ctx.userId, activation: ctx.activation }).toEqual({
            userId,
            activation: currentActivation(),
        })
    }
)

it("captureFeatureContext_storageThrows_logsFullErrorAndReturnsNoUser", () => {
    const failure = new DOMException("Storage disabled", "SecurityError")
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
        throw failure
    })
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined)

    const ctx = captureFeatureContext()

    expect({ userId: ctx.userId, logged: log.mock.calls }).toEqual({
        userId: null,
        logged: [
            [
                "[captureFeatureContext] could not read the session user",
                failure,
            ],
        ],
    })
})

it.each([
    { change: "nothing", apply: () => undefined, current: true },
    {
        change: "logout",
        apply: () => sessionStorage.removeItem(SESSION_KEY),
        current: false,
    },
    {
        change: "account switch",
        apply: () => sessionStorage.setItem(SESSION_KEY, "user-2"),
        current: false,
    },
    {
        change: "switch away and back",
        apply: () => {
            sessionStorage.setItem(SESSION_KEY, "user-2")
            captureFeatureContext()
            sessionStorage.setItem(SESSION_KEY, "user-1")
        },
        current: false,
    },
    {
        change: "logout and login again",
        apply: () => {
            sessionStorage.removeItem(SESSION_KEY)
            captureFeatureContext()
            sessionStorage.setItem(SESSION_KEY, "user-1")
        },
        current: false,
    },
    {
        change: "logout and same-account login with no capture between",
        apply: () => {
            sessionStorage.removeItem(SESSION_KEY)
            invalidateOnLogout(newClient())
            sessionStorage.setItem(SESSION_KEY, "user-1")
        },
        current: false,
    },
    {
        change: "shutdown",
        apply: () => onPortfolioInsightsDisabled(newClient()),
        current: false,
    },
])(
    "isCurrentFeatureContext_changeSinceCapture_isCurrentOnlyWithoutChange ($change)",
    ({ apply, current }) => {
        const ctx = captureFeatureContext()

        apply()

        expect(isCurrentFeatureContext(ctx)).toBe(current)
    }
)

it("isCurrentFeatureContext_captureAfterSameAccountRelogin_isCurrent", () => {
    captureFeatureContext()
    sessionStorage.removeItem(SESSION_KEY)
    invalidateOnLogout(newClient())
    sessionStorage.setItem(SESSION_KEY, "user-1")

    const ctx = captureFeatureContext()

    expect(isCurrentFeatureContext(ctx)).toBe(true)
})

/** The contexts of two requests, the second in a later session. */
const EARLIER_REQUEST: FeatureContext = {
    userId: "user-1",
    activation: 0,
    session: 1,
}
const LATER_REQUEST: FeatureContext = {
    userId: "user-1",
    activation: 0,
    session: 2,
}

// `record` says whether the context is recorded for the value; only an
// object or array can carry it.
it.each([
    { result: "object", value: { id: 1 }, record: true, carries: true },
    { result: "array", value: [{ id: 1 }], record: true, carries: true },
    {
        result: "unrecorded object",
        value: { id: 1 },
        record: false,
        carries: false,
    },
    { result: "string", value: "user-1", record: true, carries: false },
    { result: "null", value: null, record: true, carries: false },
    { result: "undefined", value: undefined, record: true, carries: false },
])(
    "featureResultContext_result_returnsContextRecordedOnlyForObjects ($result)",
    ({ value, record, carries }) => {
        if (record) {
            recordFeatureResultContext(value, EARLIER_REQUEST)
        }

        expect(featureResultContext(value)).toEqual(
            carries ? EARLIER_REQUEST : undefined
        )
    }
)

it.each([
    {
        write: "equal refetch",
        previous: { value: { id: 1 }, ctx: EARLIER_REQUEST },
        next: { value: { id: 1 }, ctx: LATER_REQUEST },
        expected: { kept: "previous", ctx: LATER_REQUEST },
    },
    {
        write: "changed refetch",
        previous: { value: { id: 1, items: [1] }, ctx: EARLIER_REQUEST },
        next: { value: { id: 2, items: [1] }, ctx: LATER_REQUEST },
        expected: { kept: "copy", ctx: LATER_REQUEST },
    },
    {
        write: "first result",
        previous: { value: undefined, ctx: undefined },
        next: { value: { id: 1 }, ctx: LATER_REQUEST },
        expected: { kept: "next", ctx: LATER_REQUEST },
    },
    {
        write: "equal manual write",
        previous: { value: { id: 1 }, ctx: EARLIER_REQUEST },
        next: { value: { id: 1 }, ctx: undefined },
        expected: { kept: "previous", ctx: EARLIER_REQUEST },
    },
    {
        write: "changed manual write",
        previous: { value: { id: 1 }, ctx: EARLIER_REQUEST },
        next: { value: { id: 2 }, ctx: undefined },
        expected: { kept: "copy", ctx: undefined },
    },
])(
    "shareFeatureResult_write_sharesDataAndCarriesNextContext ($write)",
    ({ previous, next, expected }) => {
        if (previous.ctx !== undefined) {
            recordFeatureResultContext(previous.value, previous.ctx)
        }
        if (next.ctx !== undefined) {
            recordFeatureResultContext(next.value, next.ctx)
        }

        const shared = shareFeatureResult(previous.value, next.value)

        expect({
            kept:
                shared === previous.value
                    ? "previous"
                    : shared === next.value
                      ? "next"
                      : "copy",
            data: shared,
            ctx: featureResultContext(shared),
        }).toEqual({ ...expected, data: next.value })
    }
)

it("invalidateOnLogout_cachedQueries_removesAccountQueriesAndCountsLogout", () => {
    const client = newClient()
    const removed: QueryKey[] = [
        transactionKeys.byUser(ACCOUNT),
        instrumentKeys.byUser(ACCOUNT),
        userKeys.byId(ACCOUNT),
        balanceKeys.byId(ACCOUNT),
        creditCardKeys.status,
        portfolioKeys.history(ACCOUNT),
        portfolioKeys.insights(ACCOUNT),
        alertKeys.list(ACCOUNT),
        alertKeys.notifications(ACCOUNT),
    ]
    const kept: [QueryKey, unknown][] = [
        [userKeys.preset, []],
        [featureFlagKeys.problemPatterns, [{ id: "db_not_responding" }]],
        [priceKeys.byInstrument("1"), []],
        [versionKeys.all, []],
    ]
    removed.forEach((key) => client.setQueryData(key, {}))
    kept.forEach(([key, data]) => client.setQueryData(key, data))
    const before = currentLogoutCount()

    invalidateOnLogout(client)

    expect({
        logouts: currentLogoutCount() - before,
        removed: removed.filter(
            (key) => client.getQueryData(key) !== undefined
        ),
        kept: kept.map(([key]) => client.getQueryData(key)),
    }).toEqual({ logouts: 1, removed: [], kept: kept.map(([, data]) => data) })
})

it("onLogout_listener_runsOnceCountedUntilStopped", () => {
    const counted: number[] = []
    const stop = onLogout(() => counted.push(currentLogoutCount()))
    const before = currentLogoutCount()

    invalidateOnLogout(newClient())
    stop()
    invalidateOnLogout(newClient())

    expect(counted).toEqual([before + 1])
})

it("invalidateOnLogout_listenerThrows_logsFullErrorAndStillRemovesQueries", () => {
    const failure = new Error("listener failed")
    const stop = onLogout(() => {
        throw failure
    })
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const client = newClient()
    client.setQueryData(alertKeys.list(ACCOUNT), [])

    try {
        invalidateOnLogout(client)
    } finally {
        stop()
    }

    expect({
        alerts: client.getQueryData(alertKeys.list(ACCOUNT)),
        logged: log.mock.calls,
    }).toEqual({
        alerts: undefined,
        logged: [["[invalidateOnLogout] logout listener failed", failure]],
    })
})

/** A client whose shared flag state reads `true`, as while the feature is on. */
function enabledClient(): QueryClient {
    const client = newClient()
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    return client
}

// The capture is taken for "user-1" first; each row then ends it, or makes
// the write one the tab must not send, before the dispatch.
it.each<{
    change: string
    apply: (client: QueryClient) => void
    accountId: string
}>([
    {
        change: "logout",
        apply: (client) => {
            sessionStorage.removeItem(SESSION_KEY)
            invalidateOnLogout(client)
        },
        accountId: "user-1",
    },
    {
        change: "logout and same-account login",
        apply: (client) => {
            invalidateOnLogout(client)
            sessionStorage.setItem(SESSION_KEY, "user-1")
        },
        accountId: "user-1",
    },
    {
        change: "account switch",
        apply: () => sessionStorage.setItem(SESSION_KEY, "user-2"),
        accountId: "user-1",
    },
    {
        change: "shutdown",
        apply: (client) => onPortfolioInsightsDisabled(client),
        accountId: "user-1",
    },
    {
        change: "shutdown then resume",
        apply: (client) => {
            onPortfolioInsightsDisabled(client)
            client.setQueryData<boolean>(
                featureFlagKeys.portfolioInsights,
                true
            )
        },
        accountId: "user-1",
    },
    { change: "other account", apply: () => undefined, accountId: "user-2" },
    {
        change: "flag state false",
        apply: (client) =>
            client.setQueryData<boolean>(
                featureFlagKeys.portfolioInsights,
                false
            ),
        accountId: "user-1",
    },
    {
        change: "flag state unknown",
        apply: (client) =>
            client.removeQueries({
                queryKey: featureFlagKeys.portfolioInsights,
            }),
        accountId: "user-1",
    },
])(
    "dispatchFeatureWrite_writeNoLongerAllowed_rejectsBeforeSend ($change)",
    async ({ apply, accountId }) => {
        const client = enabledClient()
        const ctx = captureFeatureContext()
        const send = vi.fn(() => Promise.resolve("sent"))
        apply(client)

        const error = await dispatchFeatureWrite(
            client,
            ctx,
            accountId,
            send
        ).catch((rejection: unknown) => rejection)

        expect({
            stale: error instanceof StaleFeatureWriteError,
            discarded: isDiscardedFeatureWrite(error),
            sends: send.mock.calls.length,
        }).toEqual({ stale: true, discarded: true, sends: 0 })
    }
)

it("dispatchFeatureWrite_currentContext_sendsWithLiveSignalAndResolves", async () => {
    const client = enabledClient()
    const signals: AbortSignal[] = []

    const value = await dispatchFeatureWrite(
        client,
        captureFeatureContext(),
        "user-1",
        (signal) => {
            signals.push(signal)
            return Promise.resolve("sent")
        }
    )

    expect({
        value,
        aborted: signals.map((signal) => signal.aborted),
    }).toEqual({ value: "sent", aborted: [false] })
})

/** A write that never answers and rejects as `fetch` does on abort. */
function heldWrite(signals: AbortSignal[]) {
    return (signal: AbortSignal): Promise<never> => {
        signals.push(signal)
        return new Promise<never>((_, reject) => {
            signal.addEventListener(
                "abort",
                () => reject(new DOMException("Aborted", "AbortError")),
                { once: true }
            )
        })
    }
}

it.each<{ boundary: string; end: (client: QueryClient) => void }>([
    {
        boundary: "shutdown",
        end: (client) => onPortfolioInsightsDisabled(client),
    },
    { boundary: "logout", end: (client) => invalidateOnLogout(client) },
])(
    "dispatchFeatureWrite_contextEndsInFlight_abortsAndMarksDiscarded ($boundary)",
    async ({ end }) => {
        const client = enabledClient()
        const signals: AbortSignal[] = []
        const settled = dispatchFeatureWrite(
            client,
            captureFeatureContext(),
            "user-1",
            heldWrite(signals)
        ).catch((rejection: unknown) => rejection)

        end(client)
        const error = await settled

        expect({
            aborted: signals.map((signal) => signal.aborted),
            name: (error as Error).name,
            discarded: isDiscardedFeatureWrite(error),
        }).toEqual({ aborted: [true], name: "AbortError", discarded: true })
    }
)

it("dispatchFeatureWrite_settledWrite_laterShutdownAbortsNothing", async () => {
    const client = enabledClient()
    const signals: AbortSignal[] = []
    await dispatchFeatureWrite(
        client,
        captureFeatureContext(),
        "user-1",
        (signal) => {
            signals.push(signal)
            return Promise.resolve("sent")
        }
    )

    onPortfolioInsightsDisabled(client)

    expect(signals.map((signal) => signal.aborted)).toEqual([false])
})

it.each<{ failure: string; produce: () => Promise<unknown> }>([
    {
        failure: "ApiError",
        produce: () => Promise.resolve(new ApiError(500, ALERTS_URL)),
    },
    {
        failure: "AbortError of another request",
        produce: () =>
            Promise.resolve(new DOMException("Aborted", "AbortError")),
    },
    {
        failure: "failure of a current write",
        produce: () =>
            dispatchFeatureWrite(
                enabledClient(),
                captureFeatureContext(),
                "user-1",
                () => Promise.reject(new ApiError(404, ALERTS_URL))
            ).catch((rejection: unknown) => rejection),
    },
])(
    "isDiscardedFeatureWrite_ordinaryFailure_isFalse ($failure)",
    async ({ produce }) => {
        const error = await produce()

        expect(isDiscardedFeatureWrite(error)).toBe(false)
    }
)
