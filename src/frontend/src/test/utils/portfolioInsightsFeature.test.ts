import { CancelledError, QueryClient, QueryKey } from "@tanstack/react-query"
import { ApiError } from "../../api/http"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import {
    captureFeatureContext,
    currentActivation,
    featureQueryRetry,
    isCurrentFeatureContext,
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    balanceKeys,
    featureFlagKeys,
    instrumentKeys,
    portfolioKeys,
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
