import "@testing-library/jest-dom/vitest"
import { useEffect } from "react"
import {
    QueryClient,
    QueryClientProvider,
    type QueryKey,
    focusManager,
    matchQuery,
} from "@tanstack/react-query"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import {
    type LoaderFunctionArgs,
    NavigationType,
    type RouteObject,
    RouterProvider,
    createBrowserRouter,
    createMemoryRouter,
} from "react-router"
import type { Alert } from "../../api/alerts/types"
import { PortfolioInsightsFlagId } from "../../api/featureFlags"
import { ApiError, services } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import type { PortfolioInsights as InsightsResponse } from "../../api/portfolioInsights/types"
import { AlertNotificationWatcher } from "../../components/insights/AlertNotificationWatcher"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { UserContextProvider } from "../../contexts/UserContext/context"
import { alertNotificationsQuery, alertsQuery } from "../../hooks/useAlerts"
import {
    portfolioInsightsFlagQuery,
    usePortfolioInsightsFlag,
} from "../../hooks/useFeatureFlags"
import {
    createPortfolioInsightsLoader,
    portfolioInsightsQuery,
    usePortfolioInsightsQuery,
} from "../../hooks/usePortfolioInsights"
import { PortfolioInsights } from "../../pages/protected/PortfolioInsights"
import {
    captureFeatureContext,
    currentActivation,
    featureResultContext,
    isCurrentFeatureContext,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    instrumentKeys,
    invalidateOnLogout,
    portfolioKeys,
} from "../../utils/queryKeys"
import {
    FormatterWrapper,
    ToastWrapper,
    UserContextWrapper,
} from "../providers"

// Covers the blocking flag decision of the `/insights` entry loader and the
// activation check of the shared flag query, through a memory router that
// mounts the real loader and page, and, in its own block, the request guard
// every insights and alert query runs. How the flag read maps each response
// is covered by portfolioInsightsApi.test.ts.

/** The account `UserContextWrapper` provides. */
const ACCOUNT_ID = "1"

/** The account a switch during the entry read moves the tab to. */
const OTHER_ACCOUNT_ID = "2"

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

/** What the root route's error element shows if a loader rejects. */
const ROOT_ERROR_TEXT = "Oops! There was an error!"

const HOME_MARKER = "home marker"

/** What the page before an `/insights` entry in the tab's history shows. */
const PREVIOUS_MARKER = "previous page marker"

/** What a page other than `/home` that links to `/insights` shows. */
const OTHER_MARKER = "other page marker"

/** `totalValue` of each insights response, as `FormatterWrapper` shows it. */
const TOTAL_A = "$1,111.11"
const TOTAL_B = "$2,222.22"

const BROKER = services.broker()

/** Requests, keyed as `METHOD url`. */
const FLAG_REQUEST = `GET ${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`
const INSIGHTS_REQUEST = `GET ${BROKER}/portfolio/insights/${ACCOUNT_ID}`
const INSTRUMENTS_REQUEST = `GET ${BROKER}/instrument?accountId=${ACCOUNT_ID}`
const ALERTS_REQUEST = `GET ${BROKER}/alerts?accountId=${ACCOUNT_ID}`
const NOTIFICATIONS_REQUEST = `GET ${BROKER}/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`

const instruments: Instrument[] = [
    {
        id: INSTRUMENT_ID,
        code: "ETRAVE",
        name: "EasyTravel",
        description: "EasyTravel Incorporated",
        productId: 1,
        productName: "Share",
        price: {
            timestamp: "2026-01-01T09:00:00Z",
            open: 110,
            close: 111.111,
            low: 109,
            high: 112,
        },
        amount: 10,
    },
]

const noAlerts: Alert[] = []

/** One holding worth `value`, the whole portfolio. */
function insightsWorth(value: number, quantity: number): InsightsResponse {
    const allocation = {
        instrumentId: INSTRUMENT_ID,
        name: "EasyTravel",
        quantity,
        value,
        percent: 100,
    }
    return {
        totalValue: value,
        totalInvested: value - value / 10,
        unrealizedPnl: value / 10,
        unrealizedPnlPercent: 11.111,
        allocations: [allocation],
        largestPosition: allocation,
        riskLevel: "HIGH",
    }
}

const insightsA = insightsWorth(1111.11, 10)
const insightsB = insightsWorth(2222.22, 20)

/** How the stub answers the flag read. */
type FlagMode =
    | "enabled"
    | "disabled"
    | "status500"
    | "networkError"
    /** Never answers, and rejects with `AbortError` once the read aborts. */
    | "hung"
    /** Answers only through `releaseHeldFlagReads`, whatever aborts it. */
    | "held"
    /** Answers the first read `true`, then leaves every later one `hung`. */
    | "enabledOnce"

type StubResponse = { status: number; body?: unknown }

type AppRouter = ReturnType<typeof createMemoryRouter>

/** What the router shows: its location and the screen rendered for it. */
type Landing = {
    path: string
    screen:
        "home" | "previous" | "other" | "insights" | "root error" | "pending"
}

const HOME: Landing = { path: "/home", screen: "home" }
const PREVIOUS: Landing = { path: "/previous", screen: "previous" }
const OTHER: Landing = { path: "/other", screen: "other" }
const INSIGHTS: Landing = { path: "/insights", screen: "insights" }

/** The paths of the tab's history entries, oldest first. */
type TabHistory = [string, ...string[]]

/** Where an `/insights` entry ends, and what it left in the flag cache. */
type EntryOutcome = Landing & {
    /** Whether the loader let the page mount at all, even briefly. */
    pageEntered: boolean
    flag: boolean | undefined
}

const REFUSED: EntryOutcome = { ...HOME, pageEntered: false, flag: false }
const ACCEPTED: EntryOutcome = { ...INSIGHTS, pageEntered: true, flag: true }
/** A cold `/insights` entry whose flag read has not been decided yet. */
const UNDECIDED: EntryOutcome = {
    path: "/insights",
    screen: "pending",
    pageEntered: false,
    flag: undefined,
}

let client: QueryClient
let router: AppRouter | undefined
/** How often the `/insights` route element has mounted in this case. */
let pageMounts: number
let flagMode: FlagMode
let insightsResponse: StubResponse
/** Every request sent in the current case, in order. */
let requests: string[]
/** Requests the stub has no answer for; `afterEach` requires there be none. */
let unexpectedRequests: string[]
/** Resolvers of the flag reads `held` keeps open, oldest first. */
let heldFlagReads: ((response: Response) => void)[]
/** Rejects a flag read still open, so none outlives its case. */
let openFlagReadAborts: (() => void)[]
/** The abort signal each flag request was sent with, oldest first. */
let flagReadSignals: (AbortSignal | null | undefined)[]
/** Every entry decision the `/insights` loader started, settled or not. */
let entryDecisions: Promise<unknown>[]
let textWatchers: MutationObserver[]

function respond({ status, body }: StubResponse): Response {
    return new Response(body === undefined ? null : JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

function flagResponse(enabled: boolean): Response {
    return respond({
        status: 200,
        body: {
            id: PortfolioInsightsFlagId,
            enabled,
            name: "Portfolio insights",
            description: "Demo feature, not financial advice.",
            isModifiable: true,
            tag: "feature",
        },
    })
}

function abortError(): DOMException {
    return new DOMException("Aborted", "AbortError")
}

function hangFlagRead(
    signal: AbortSignal | null | undefined
): Promise<Response> {
    return new Promise<Response>((_resolve, reject) => {
        const abort = (): void => reject(abortError())
        openFlagReadAborts.push(abort)
        signal?.addEventListener("abort", abort, { once: true })
    })
}

function answerFlagRead(
    signal: AbortSignal | null | undefined
): Promise<Response> {
    switch (flagMode) {
        case "enabled":
            return Promise.resolve(flagResponse(true))
        case "disabled":
            return Promise.resolve(flagResponse(false))
        case "status500":
            return Promise.resolve(respond({ status: 500 }))
        case "networkError":
            return Promise.reject(new TypeError("Failed to fetch"))
        case "hung":
            return hangFlagRead(signal)
        case "held":
            return new Promise<Response>((resolve, reject) => {
                heldFlagReads.push(resolve)
                openFlagReadAborts.push(() => reject(abortError()))
            })
        case "enabledOnce":
            return flagRequestCount() === 1
                ? Promise.resolve(flagResponse(true))
                : hangFlagRead(signal)
    }
}

function answerBrokerRead(key: string): StubResponse | undefined {
    switch (key) {
        case INSIGHTS_REQUEST:
            return insightsResponse
        case INSTRUMENTS_REQUEST:
            return { status: 200, body: { results: instruments } }
        case ALERTS_REQUEST:
        case NOTIFICATIONS_REQUEST:
            return { status: 200, body: { results: noAlerts } }
        default:
            return undefined
    }
}

/**
 * Answers the flag read by `flagMode` and the broker reads of the page from
 * the fixtures above. Any other request rejects and is recorded.
 */
function stubFetch(): void {
    vi.spyOn(window, "fetch").mockImplementation(
        (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
            const url =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            const key = `${init?.method ?? "GET"} ${url}`
            requests.push(key)
            if (key === FLAG_REQUEST) {
                flagReadSignals.push(init?.signal)
                return answerFlagRead(init?.signal)
            }
            const answer = answerBrokerRead(key)
            if (answer === undefined) {
                unexpectedRequests.push(key)
                return Promise.reject(new Error(`Unexpected request ${key}`))
            }
            return Promise.resolve(respond(answer))
        }
    )
}

function flagRequestCount(): number {
    return requests.filter((key) => key === FLAG_REQUEST).length
}

function releaseHeldFlagReads(enabled: boolean): void {
    for (const resolve of heldFlagReads.splice(0)) {
        resolve(flagResponse(enabled))
    }
}

/** Whether each flag request sent so far has had its signal aborted. */
function flagReadsAborted(): boolean[] {
    return flagReadSignals.map((signal) => signal?.aborted === true)
}

/** Every request other than a flag read, which the page or a preload sends. */
function featureRequests(): string[] {
    return requests.filter((key) => key !== FLAG_REQUEST)
}

/** The account's insights and instruments cache entries, loaded or not. */
function featureCacheEntries(): string[] {
    return [
        portfolioKeys.insights(ACCOUNT_ID),
        instrumentKeys.byUser(ACCOUNT_ID),
    ]
        .filter(
            (queryKey) =>
                client.getQueryCache().find({ queryKey, exact: true }) !==
                undefined
        )
        .map((queryKey) => queryKey.join("/"))
}

/** Waits until every entry decision started so far has settled. */
async function settleEntryDecisions(): Promise<void> {
    await act(async () => {
        await Promise.allSettled(entryDecisions)
    })
}

/** For cases whose failures the code under test logs by design. */
function muteExpectedErrors(): void {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
}

/**
 * The page as the `/insights` route renders it. Counting its mounts shows a
 * refused entry never rendered the page: a loader that let it mount would
 * still end on `/home` once the page's own flag read answered `false`.
 */
function CountedPage() {
    useEffect(() => {
        pageMounts += 1
    }, [])
    return <PortfolioInsights />
}

/** The routes every router mounts, with the loader and page sharing `target`. */
function buildRoutes(target: QueryClient): RouteObject[] {
    const loadEntry = createPortfolioInsightsLoader(target)
    // Each decision is recorded, so a case can wait for one whose outcome
    // leaves nothing to observe.
    const recordedLoader = (args: LoaderFunctionArgs) => {
        const decision = loadEntry(args)
        entryDecisions.push(decision)
        return decision
    }
    return [
        {
            path: "/",
            errorElement: <p>{ROOT_ERROR_TEXT}</p>,
            hydrateFallbackElement: <p>route loading</p>,
            children: [
                { path: "previous", element: <p>{PREVIOUS_MARKER}</p> },
                { path: "other", element: <p>{OTHER_MARKER}</p> },
                { path: "home", element: <p>{HOME_MARKER}</p> },
                {
                    path: "insights",
                    loader: recordedLoader,
                    element: <CountedPage />,
                },
            ],
        },
    ]
}

function buildRouter(target: QueryClient): AppRouter {
    return createMemoryRouter(buildRoutes(target), {
        initialEntries: ["/insights"],
    })
}

/**
 * A browser router, as the app runs, on the window's own history once that
 * history is set to `tabHistory`, so it starts on the last entry. Unlike a
 * memory router, it lets the loader see which entry the tab shows while it
 * runs.
 */
function buildBrowserRouter(
    target: QueryClient,
    tabHistory: TabHistory
): AppRouter {
    const [oldest, ...later] = tabHistory
    window.history.replaceState(null, "", oldest)
    for (const path of later) {
        window.history.pushState(null, "", path)
    }
    return createBrowserRouter(buildRoutes(target))
}

/** Enters `/insights` with the loader, page and cache sharing `client`. */
function renderRoute(): AppRouter {
    return mountRouter(buildRouter(client))
}

/**
 * Renders a browser router on `tabHistory`, with the loader, page and cache
 * sharing `client`.
 */
function renderBrowserRoute(tabHistory: TabHistory): AppRouter {
    return mountRouter(buildBrowserRouter(client, tabHistory))
}

/** Renders `built` as the case's router, which `afterEach` disposes. */
function mountRouter(built: AppRouter): AppRouter {
    router = built
    render(
        <QueryClientProvider client={client}>
            <UserContextWrapper>
                <FormatterWrapper>
                    <ToastWrapper>
                        <RouterProvider router={built} />
                    </ToastWrapper>
                </FormatterWrapper>
            </UserContextWrapper>
        </QueryClientProvider>
    )
    return built
}

function landing(target: AppRouter): Landing {
    let shown: Landing["screen"] = "pending"
    if (screen.queryByText(ROOT_ERROR_TEXT) !== null) {
        shown = "root error"
    } else if (screen.queryByText(HOME_MARKER) !== null) {
        shown = "home"
    } else if (screen.queryByText(PREVIOUS_MARKER) !== null) {
        shown = "previous"
    } else if (screen.queryByText(OTHER_MARKER) !== null) {
        shown = "other"
    } else if (document.getElementById("portfolio-insights") !== null) {
        shown = "insights"
    }
    return { path: target.state.location.pathname, screen: shown }
}

function entryOutcome(target: AppRouter): EntryOutcome {
    return {
        ...landing(target),
        pageEntered: pageMounts > 0,
        flag: client.getQueryData<boolean>(featureFlagKeys.portfolioInsights),
    }
}

function totalValueText(): string | null {
    return document.getElementById("insights-total-value")?.textContent ?? null
}

/**
 * Records whether `text` is rendered from now on, including in a node that
 * is added or rewritten and replaced again before anything could query it.
 * Returns the stop function, which reports the result.
 */
function watchForText(text: string): () => boolean {
    let seen = document.body.textContent?.includes(text) ?? false
    const scan = (records: MutationRecord[]): void => {
        for (const record of records) {
            const texts =
                record.type === "characterData"
                    ? [record.oldValue, record.target.textContent]
                    : Array.from(record.addedNodes, (node) => node.textContent)
            if (texts.some((value) => value?.includes(text) === true)) {
                seen = true
            }
        }
    }
    const observer = new MutationObserver(scan)
    observer.observe(document.body, {
        childList: true,
        subtree: true,
        characterData: true,
        characterDataOldValue: true,
    })
    textWatchers.push(observer)
    return () => {
        scan(observer.takeRecords())
        observer.disconnect()
        return seen
    }
}

/** Advances the fake clock and lets the work it releases settle. */
async function advance(ms: number): Promise<void> {
    await act(async () => {
        await vi.advanceTimersByTimeAsync(ms)
    })
}

/** Observes the shared flag query the way `Navigation` does. */
function FlagProbe() {
    const enabled = usePortfolioInsightsFlag()
    return <p>{enabled ? "flag on" : "flag off"}</p>
}

type EntryDecisionRow = {
    scenario: string
    /** Puts the flag service and the cache into the scenario's state. */
    setup: () => void
    expected: EntryOutcome
}

const entryDecisionRows: EntryDecisionRow[] = [
    {
        scenario: "flag false",
        setup: () => {
            flagMode = "disabled"
        },
        expected: REFUSED,
    },
    {
        scenario: "flag read 500",
        setup: () => {
            muteExpectedErrors()
            flagMode = "status500"
        },
        expected: REFUSED,
    },
    {
        scenario: "network error",
        setup: () => {
            muteExpectedErrors()
            flagMode = "networkError"
        },
        expected: REFUSED,
    },
    {
        scenario: "cached true, server false",
        setup: () => {
            client.setQueryData<boolean>(
                featureFlagKeys.portfolioInsights,
                true
            )
            flagMode = "disabled"
        },
        expected: REFUSED,
    },
    {
        scenario: "flag true",
        setup: () => {
            flagMode = "enabled"
        },
        expected: ACCEPTED,
    },
]

type ContextChangeRow = {
    scenario: string
    /** Runs while the loader's own flag read is still open. */
    change: () => void
    /** The flag cache the change itself leaves, which must stay as it is. */
    flag: boolean | undefined
}

const contextChangeRows: ContextChangeRow[] = [
    {
        // The shutdown an insights or alert 403, or a shared read's `false`,
        // runs; it leaves the loader's own read open.
        scenario: "shutdown",
        change: () => {
            onPortfolioInsightsDisabled(client)
        },
        flag: false,
    },
    {
        scenario: "logout",
        change: () => {
            sessionStorage.removeItem(SESSION_KEY)
            invalidateOnLogout(client)
        },
        flag: undefined,
    },
    {
        scenario: "account switch",
        change: () => {
            sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
        },
        flag: undefined,
    },
    {
        scenario: "logout, same account back",
        change: () => {
            sessionStorage.removeItem(SESSION_KEY)
            invalidateOnLogout(client)
            sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        },
        flag: undefined,
    },
]

type RefusalRow = {
    refusal: string
    /** Answers the entry's own flag read, held open, so the loader refuses. */
    refuse: () => void
}

/** The two ways the loader refuses an entry, each ending with a shutdown. */
const refusalRows: RefusalRow[] = [
    {
        refusal: "flag false",
        refuse: () => {
            releaseHeldFlagReads(false)
        },
    },
    {
        // The read answers `true`, but only after a shutdown ran during it.
        refusal: "shutdown during the read",
        refuse: () => {
            onPortfolioInsightsDisabled(client)
            releaseHeldFlagReads(true)
        },
    },
]

/** Renders a tab on `tabHistory` and follows a link to `/insights` from it. */
function followInsightsLink(tabHistory: TabHistory): AppRouter {
    const shown = renderBrowserRoute(tabHistory)
    act(() => {
        void shown.navigate("/insights")
    })
    return shown
}

type EntryPathRow = {
    entry: string
    /**
     * Renders a tab and starts an `/insights` entry in it while the tab's
     * current history entry is that `/insights` address or `/home`, with
     * `/previous` before it.
     */
    enter: () => AppRouter
}

const entryPathRows: EntryPathRow[] = [
    {
        // A typed address, a bookmark or a reload: the router starts there.
        entry: "cold entry",
        enter: () => renderBrowserRoute(["/previous", "/insights"]),
    },
    {
        // Back into an `/insights` entry the tab committed earlier: the
        // window shows it before the loader runs.
        entry: "Back into an earlier entry",
        enter: () => {
            const shown = renderBrowserRoute([
                "/previous",
                "/insights",
                "/other",
            ])
            act(() => {
                void shown.navigate(-1)
            })
            return shown
        },
    },
    {
        // A link followed from `/home`, such as one shown before the flag
        // turned off.
        entry: "link from /home",
        enter: () => followInsightsLink(["/previous", "/home"]),
    },
]

/** Each refusal on each entry path. */
const refusedEntryRows = refusalRows.flatMap((refusal) =>
    entryPathRows.map((path) => ({ ...refusal, ...path }))
)

/** How a refused entry enters the tab's history, and where Back then lands. */
type RefusalHistory = {
    historyAction: NavigationType
    back: Landing
}

/**
 * Starts the `/insights` entry `enter` makes on a held flag read, refuses it
 * with `refuse`, steps Back once from the `/home` it lands on, and waits
 * until both steps end as `expected`, Back with no flag read of its own.
 */
async function expectRefusalHistory(
    enter: () => AppRouter,
    refuse: () => void,
    expected: RefusalHistory
): Promise<void> {
    flagMode = "held"
    const entered = enter()
    await waitFor(() => expect(heldFlagReads).toHaveLength(1))
    refuse()
    await settleEntryDecisions()
    await waitFor(() =>
        expect({
            ...landing(entered),
            navigation: entered.state.navigation.state,
        }).toEqual({ ...HOME, navigation: "idle" })
    )
    const refused = {
        ...entryOutcome(entered),
        historyAction: entered.state.historyAction,
    }
    const flagReadsBeforeBack = flagRequestCount()

    // Not awaited: the window delivers Back later as a popstate, and an
    // `/insights` entry left behind would hold its navigation on the held read.
    act(() => {
        void entered.navigate(-1)
    })

    await waitFor(() =>
        expect({
            refused,
            back: {
                ...landing(entered),
                flagReads: flagRequestCount(),
            },
        }).toEqual({
            refused: { ...REFUSED, historyAction: expected.historyAction },
            back: { ...expected.back, flagReads: flagReadsBeforeBack },
        })
    )
}

describe("Portfolio Insights route and flag query", () => {
    beforeEach(() => {
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        client = new QueryClient({
            defaultOptions: { queries: { retry: false } },
        })
        router = undefined
        pageMounts = 0
        flagMode = "enabled"
        insightsResponse = { status: 200, body: insightsA }
        requests = []
        unexpectedRequests = []
        heldFlagReads = []
        openFlagReadAborts = []
        flagReadSignals = []
        entryDecisions = []
        textWatchers = []
        // The flag read reports a disabled flag or a cancelled read, and
        // BizEvents reports the missing OneAgent; neither is under test here.
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        vi.spyOn(console, "debug").mockImplementation(() => undefined)
        vi.spyOn(console, "log").mockImplementation(() => undefined)
        stubFetch()
    })

    afterEach(() => {
        // Unmount first, so restoring focus below starts no flag read.
        cleanup()
        router?.dispose()
        // A browser router leaves the window on its last page.
        window.history.replaceState(null, "", "/")
        for (const watcher of textWatchers) {
            watcher.disconnect()
        }
        for (const abort of openFlagReadAborts.splice(0)) {
            abort()
        }
        vi.useRealTimers()
        focusManager.setFocused(undefined)
        sessionStorage.clear()
        vi.restoreAllMocks()
        client.clear()
        expect(unexpectedRequests).toEqual([])
    })

    it.each(entryDecisionRows)(
        "portfolioInsightsLoader_entryDecision_routes ($scenario)",
        async ({ setup, expected }) => {
            setup()

            const entered = renderRoute()

            await waitFor(() => expect(entryOutcome(entered)).toEqual(expected))
        }
    )

    // The hung row of the matrix above, on a clock that moves only when
    // advanced, so the deadline is pinned on both sides of 2,000 ms: the read
    // and the entry stay open 1 ms before it and both end at it.
    it("portfolioInsightsLoader_entryDecision_routes (hung read aborted at 2 s)", async () => {
        vi.useFakeTimers()
        muteExpectedErrors()
        flagMode = "hung"

        const entered = renderRoute()
        await advance(1999)
        const beforeDeadline = {
            ...entryOutcome(entered),
            readsAborted: flagReadsAborted(),
        }
        await advance(1)

        expect({
            beforeDeadline,
            atDeadline: {
                ...entryOutcome(entered),
                readsAborted: flagReadsAborted(),
            },
        }).toEqual({
            beforeDeadline: { ...UNDECIDED, readsAborted: [false] },
            atDeadline: { ...REFUSED, readsAborted: [true] },
        })
    })

    it("portfolioInsightsLoader_coldEntryInsightsFails_showsPageError", async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true })
        muteExpectedErrors()
        insightsResponse = { status: 500 }

        renderRoute()
        await waitFor(() => expect(requests).toContain(INSIGHTS_REQUEST))
        // `featureQueryRetry` retries a 500 three times, after 1 s, 2 s and 4 s.
        await advance(8000)

        await waitFor(() =>
            expect({
                pageError: document.getElementById("insights-error") !== null,
                rootError: screen.queryByText(ROOT_ERROR_TEXT) !== null,
            }).toEqual({ pageError: true, rootError: false })
        )
    })

    it("portfolioInsightsLoader_coldEntryInsights403_shutsDownToHome", async () => {
        // The flag service never answers `false`, so only the 403 can end the
        // visit. The 403 can shut the feature down before the page mounts,
        // and a read the page starts after that shutdown would resume the
        // feature if it answered `true`, so every read after the loader's
        // stays unanswered.
        flagMode = "enabledOnce"
        insightsResponse = { status: 403, body: { error: "feature_disabled" } }

        const entered = renderRoute()

        await waitFor(() =>
            expect({
                ...landing(entered),
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
            }).toEqual({ ...HOME, flag: false })
        )
    })

    // The loader's own read answers `true` only after the change, so the entry
    // it started for the earlier context must neither publish nor preload.
    it.each(contextChangeRows)(
        "portfolioInsightsLoader_contextChangedDuringRead_refusesWithoutPreload ($scenario)",
        async ({ change, flag }) => {
            flagMode = "held"
            const entered = renderRoute()
            await waitFor(() => expect(heldFlagReads).toHaveLength(1))

            change()
            releaseHeldFlagReads(true)
            await settleEntryDecisions()

            await waitFor(() =>
                expect({
                    ...entryOutcome(entered),
                    featureRequests: featureRequests(),
                    featureCacheEntries: featureCacheEntries(),
                }).toEqual({
                    ...HOME,
                    pageEntered: false,
                    flag,
                    featureRequests: [],
                    featureCacheEntries: [],
                })
            )
        }
    )

    // Refused while the tab shows the `/insights` entry itself or `/home`,
    // the redirect takes the place of that entry, so Back from `/home`
    // returns to the page before it: it neither enters the loader again nor
    // stops on a second `/home`.
    it.each(refusedEntryRows)(
        "portfolioInsightsLoader_refusedEntry_replacesHistoryEntry ($refusal, $entry)",
        async ({ refuse, enter }) => {
            await expectRefusalHistory(enter, refuse, {
                historyAction: NavigationType.Replace,
                back: PREVIOUS,
            })
        }
    )

    // A link followed from any other page is refused before the router
    // commits `/insights`, while the tab still shows that page, so the
    // redirect goes after it and Back returns there.
    it.each(refusalRows)(
        "portfolioInsightsLoader_refusedEntryFromOtherPage_keepsOriginInHistory ($refusal)",
        async ({ refuse }) => {
            await expectRefusalHistory(
                () => followInsightsLink(["/previous", "/other"]),
                refuse,
                { historyAction: NavigationType.Push, back: OTHER }
            )
        }
    )

    // `requireUser` reads the account, but every later read of the session
    // fails, so the feature context the entry captures holds no account. A
    // `true` then cannot be bound to the account the entry was made for.
    it("portfolioInsightsLoader_sessionUserUnreadable_refusesWithoutPreload", async () => {
        muteExpectedErrors()
        // Only `sessionStorage` is read on this path.
        const readSessionItem = sessionStorage.getItem.bind(sessionStorage)
        let sessionReads = 0
        vi.spyOn(Storage.prototype, "getItem").mockImplementation((key) => {
            if (key === SESSION_KEY) {
                sessionReads += 1
                if (sessionReads > 1) {
                    throw new DOMException("Storage blocked", "SecurityError")
                }
            }
            return readSessionItem(key)
        })

        const entered = renderRoute()

        await waitFor(() =>
            expect({
                ...entryOutcome(entered),
                featureRequests: featureRequests(),
                featureCacheEntries: featureCacheEntries(),
            }).toEqual({
                ...HOME,
                pageEntered: false,
                flag: undefined,
                featureRequests: [],
                featureCacheEntries: [],
            })
        )
    })

    // Leaving before the read answers aborts it, and the abandoned entry then
    // changes nothing: its `false` shuts nothing down and its `true` neither
    // publishes nor preloads.
    it.each([
        { answer: false, seededFlag: true },
        { answer: true, seededFlag: undefined },
    ])(
        "portfolioInsightsLoader_navigationAbandonedDuringRead_changesNothing (read answers $answer)",
        async ({ answer, seededFlag }) => {
            if (seededFlag !== undefined) {
                client.setQueryData<boolean>(
                    featureFlagKeys.portfolioInsights,
                    seededFlag
                )
            }
            flagMode = "held"
            const entered = renderRoute()
            await waitFor(() => expect(heldFlagReads).toHaveLength(1))
            const activation = currentActivation()

            await act(async () => {
                await entered.navigate("/home")
            })
            releaseHeldFlagReads(answer)
            await settleEntryDecisions()

            expect({
                ...entryOutcome(entered),
                readsAborted: flagReadsAborted(),
                activationChanged: currentActivation() !== activation,
                featureRequests: featureRequests(),
                featureCacheEntries: featureCacheEntries(),
            }).toEqual({
                ...HOME,
                pageEntered: false,
                flag: seededFlag,
                readsAborted: [true],
                activationChanged: false,
                featureRequests: [],
                featureCacheEntries: [],
            })
        }
    )

    it("flagQuery_lateTrueAfter403_staysDisabled", async () => {
        flagMode = "held"
        const pending = client.query(portfolioInsightsFlagQuery(client))
        await waitFor(() => expect(heldFlagReads).toHaveLength(1))
        const before = currentActivation()

        // The shutdown an insights or alert 403 runs, landing while the read
        // that started before it is still open; that read then answers `true`.
        onPortfolioInsightsDisabled(client)
        releaseHeldFlagReads(true)
        await pending

        expect({
            flag: client.getQueryData(featureFlagKeys.portfolioInsights),
            activationAdvanced: currentActivation() > before,
        }).toEqual({ flag: false, activationAdvanced: true })
    })

    it("flagQuery_resumeAfterShutdown_loadsFreshData", async () => {
        const entered = renderRoute()
        await waitFor(() => expect(totalValueText()).toBe(TOTAL_A))
        flagMode = "disabled"
        await act(async () => {
            await client.query(portfolioInsightsFlagQuery(client))
        })
        await waitFor(() =>
            expect({
                ...landing(entered),
                insights: client.getQueryData(
                    portfolioKeys.insights(ACCOUNT_ID)
                ),
            }).toEqual({ ...HOME, insights: undefined })
        )

        const staleTotalSeen = watchForText(TOTAL_A)
        flagMode = "enabled"
        insightsResponse = { status: 200, body: insightsB }
        await act(async () => {
            await client.query(portfolioInsightsFlagQuery(client))
        })
        await act(async () => {
            await entered.navigate("/insights")
        })
        await waitFor(() => expect(totalValueText()).toBe(TOTAL_B))

        expect(staleTotalSeen()).toBe(false)
    })

    it("flagQuery_falseOnOtherRoute_removesFeatureQueries", async () => {
        client.setQueryData(portfolioKeys.insights(ACCOUNT_ID), insightsA)
        client.setQueryData(alertKeys.list(ACCOUNT_ID), noAlerts)
        flagMode = "disabled"

        await client.query(portfolioInsightsFlagQuery(client))

        expect([
            client.getQueryData(portfolioKeys.insights(ACCOUNT_ID)),
            client.getQueryData(alertKeys.list(ACCOUNT_ID)),
        ]).toEqual([undefined, undefined])
    })

    it("flagQuery_options_revalidate", () => {
        expect(portfolioInsightsFlagQuery(client)).toMatchObject({
            staleTime: 0,
            refetchInterval: 15_000,
            refetchIntervalInBackground: false,
            refetchOnWindowFocus: "always",
            refetchOnReconnect: "always",
        })
    })

    it("flagQuery_windowRefocus_refetches", async () => {
        render(
            <QueryClientProvider client={client}>
                <FlagProbe />
            </QueryClientProvider>
        )
        await screen.findByText("flag on")
        const before = flagRequestCount()
        // Held, so query-core's own focus refetch, which runs a few
        // microtasks after the event, finds the refocus read still open and
        // joins it instead of sending a request of its own.
        flagMode = "held"
        const queryCoreFocus = vi.spyOn(client.getQueryCache(), "onFocus")

        act(() => {
            focusManager.setFocused(false)
            focusManager.setFocused(true)
        })
        await waitFor(() => expect(queryCoreFocus).toHaveBeenCalled())
        act(() => {
            releaseHeldFlagReads(true)
        })
        await waitFor(() =>
            expect(
                client.getQueryState(featureFlagKeys.portfolioInsights)
                    ?.fetchStatus
            ).toBe("idle")
        )

        expect(flagRequestCount()).toBe(before + 1)
    })
})

// Covers `guardFeatureRequest` through the three feature queries built on it:
// a current 403 shutting the feature down at the query boundary, ordinary
// failures staying local, every attempt's binding to the requested account
// and to the feature being on, including the attempts of observers still
// mounted when a shutdown lands, and how an outcome that arrives after a
// logout, an account switch or a shutdown settles its query.
describe("guardFeatureRequest", () => {
    /** The tab's session user, and the account every query requests. */
    const ACCOUNT = "a0000000-0000-4000-8000-000000000001"

    /** Another account the tab switches to. */
    const OTHER_ACCOUNT = "a0000000-0000-4000-8000-000000000002"

    const TRAVEL_ID = "c0000000-0000-4000-8000-000000000001"

    /** Query-core's default delay before a query's first retry. */
    const FIRST_RETRY_DELAY_MS = 1_000

    /** Query-core's default delays before its three retries: 1 s, 2 s, 4 s. */
    const DEFAULT_RETRY_BACKOFF_MS = 1_000 + 2_000 + 4_000

    const travelAllocation = {
        instrumentId: TRAVEL_ID,
        name: "EasyTravel",
        quantity: 40,
        value: 400,
        percent: 100,
    }

    const insights: InsightsResponse = {
        totalValue: 400,
        totalInvested: 350,
        unrealizedPnl: 50,
        unrealizedPnlPercent: 14.285714285714286,
        allocations: [travelAllocation],
        largestPosition: travelAllocation,
        riskLevel: "HIGH",
    }

    /** The same holding after the EasyTravel close moved from 10 to 11. */
    const refreshedAllocation = { ...travelAllocation, value: 440 }

    const refreshedInsights: InsightsResponse = {
        ...insights,
        totalValue: 440,
        unrealizedPnl: 90,
        unrealizedPnlPercent: 25.714285714285715,
        allocations: [refreshedAllocation],
        largestPosition: refreshedAllocation,
    }

    const triggeredAlert: Alert = {
        id: "b0000000-0000-4000-8000-000000000001",
        accountId: ACCOUNT,
        instrumentId: TRAVEL_ID,
        type: "TARGET_PRICE",
        direction: "ABOVE",
        threshold: 10,
        enabled: true,
        armingRevision: 1,
        triggeredAt: "2026-01-02T10:00:00Z",
        triggerValue: 10.5,
        acknowledged: false,
        createdAt: "2026-01-01T10:00:00Z",
    }

    const FORBIDDEN: StubResponse = {
        status: 403,
        body: { error: "feature_disabled" },
    }

    type Deferred<T> = { promise: Promise<T>; resolve: (value: T) => void }

    function deferred<T>(): Deferred<T> {
        let resolve: (value: T) => void = () => undefined
        const promise = new Promise<T>((settle) => {
            resolve = settle
        })
        return { promise, resolve }
    }

    /** Resolves with the value or the rejection reason; never rejects. */
    function settle(promise: Promise<unknown>): Promise<unknown> {
        return promise.then(
            (value) => value,
            (error: unknown) => error
        )
    }

    /** A feature query, run as a loader prefetch runs it: with no observer. */
    type FeatureQueryRow = {
        name: string
        queryKey: (accountId: string) => QueryKey
        fetch: (target: QueryClient, accountId: string) => Promise<unknown>
        /** A 200 body of the query's endpoint. */
        body: unknown
    }

    const FEATURE_QUERIES: FeatureQueryRow[] = [
        {
            name: "portfolioInsightsQuery",
            queryKey: portfolioKeys.insights,
            fetch: (target, accountId) =>
                target.query(portfolioInsightsQuery(accountId)),
            body: insights,
        },
        {
            name: "alertsQuery",
            queryKey: alertKeys.list,
            fetch: (target, accountId) => target.query(alertsQuery(accountId)),
            body: { results: [triggeredAlert] },
        },
        {
            name: "alertNotificationsQuery",
            queryKey: alertKeys.notifications,
            fetch: (target, accountId) =>
                target.query(alertNotificationsQuery(accountId)),
            body: { results: [triggeredAlert] },
        },
    ]

    /**
     * Settles once the fetch does and ignores its outcome, as the deprecated
     * `prefetchQuery` the `/insights` loader calls does.
     */
    async function prefetch(
        row: FeatureQueryRow,
        target: QueryClient
    ): Promise<void> {
        await row.fetch(target, ACCOUNT).then(
            () => undefined,
            () => undefined
        )
    }

    /** What a cache entry shows its observers, or `undefined` once removed. */
    function published(target: QueryClient, queryKey: QueryKey) {
        const state = target.getQueryState(queryKey)
        if (state === undefined) return undefined
        return {
            status: state.status,
            fetchStatus: state.fetchStatus,
            data: state.data,
            error: state.error,
        }
    }

    /** An entry back in its pre-fetch state: no data, no error, not fetching. */
    const UNFETCHED = {
        status: "pending",
        fetchStatus: "idle",
        data: undefined,
        error: null,
    }

    function featureQueryCount(target: QueryClient): number {
        const cache = target.getQueryCache()
        return (
            cache.findAll({ queryKey: portfolioKeys.insightsAll }).length +
            cache.findAll({ queryKey: alertKeys.all }).length
        )
    }

    /** Lets a released response run through the guard to its outcome. */
    async function settleReleased(): Promise<void> {
        await vi.advanceTimersByTimeAsync(0)
    }

    function insightsUrl(accountId: string): string {
        return `${BROKER}/portfolio/insights/${accountId}`
    }

    /** Observes one account's insights through the page's own hook. */
    function InsightsObserver({ accountId }: { accountId: string }) {
        const { data } = usePortfolioInsightsQuery(accountId, true)
        return <p>{data === undefined ? "loading" : String(data.totalValue)}</p>
    }

    /**
     * Mounts `InsightsObserver` for `accountId`. `switchTo` moves the tab to
     * another account in place, as `AuthProvider` does: it stores the id as
     * the session user, then re-renders the observer with it.
     */
    function renderObserver(accountId: string) {
        const view = (id: string) => (
            <QueryClientProvider client={client}>
                <InsightsObserver accountId={id} />
            </QueryClientProvider>
        )
        const { container, rerender } = render(view(accountId))
        return {
            switchTo: (id: string): void => {
                sessionStorage.setItem(SESSION_KEY, id)
                rerender(view(id))
            },
            shown: (): string | null => container.textContent,
        }
    }

    beforeEach(() => {
        sessionStorage.setItem(SESSION_KEY, ACCOUNT)
        client = new QueryClient()
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    })

    afterEach(() => {
        // Unmount first, so no observer reacts to the cache being cleared.
        cleanup()
        router?.dispose()
        router = undefined
        client.clear()
        vi.useRealTimers()
        vi.restoreAllMocks()
        sessionStorage.clear()
    })

    it.each(FEATURE_QUERIES)(
        "guardFeatureRequest_currentForbiddenWithoutObserver_shutsDownFeature ($name)",
        async (row) => {
            // Entries of the other feature queries, which the shutdown drops
            // too.
            client.setQueryData(portfolioKeys.insights(OTHER_ACCOUNT), insights)
            client.setQueryData(alertKeys.list(OTHER_ACCOUNT), [triggeredAlert])
            client.setQueryData(alertKeys.notifications(OTHER_ACCOUNT), [
                triggeredAlert,
            ])
            vi.spyOn(window, "fetch").mockImplementation(() =>
                Promise.resolve(respond(FORBIDDEN))
            )
            const before = currentActivation()

            await prefetch(row, client)

            expect({
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
                shutdowns: currentActivation() - before,
                featureQueries: featureQueryCount(client),
            }).toEqual({ flag: false, shutdowns: 1, featureQueries: 0 })
        }
    )

    it.each(FEATURE_QUERIES)(
        "guardFeatureRequest_currentServerError_staysLocalToQuery ($name)",
        async (row) => {
            vi.useFakeTimers()
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementation(() =>
                    Promise.resolve(respond({ status: 500 }))
                )
            const before = currentActivation()

            const outcome = settle(row.fetch(client, ACCOUNT))
            await vi.advanceTimersByTimeAsync(DEFAULT_RETRY_BACKOFF_MS)
            await outcome

            const error = client.getQueryState(row.queryKey(ACCOUNT))?.error
            expect({
                errorStatus: error instanceof ApiError ? error.status : error,
                requests: fetchMock.mock.calls.length,
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
                shutdowns: currentActivation() - before,
            }).toEqual({
                errorStatus: 500,
                requests: 4,
                flag: true,
                shutdowns: 0,
            })
        }
    )

    // The refetch answers the same data, so the cache keeps the first
    // result's reference; the context on it must be the refetch's.
    it.each(FEATURE_QUERIES)(
        "guardFeatureRequest_equalRefetchInLaterSession_cachedDataCarriesRefetchContext ($name)",
        async (row) => {
            vi.spyOn(window, "fetch").mockImplementation(() =>
                Promise.resolve(respond({ status: 200, body: row.body }))
            )
            await row.fetch(client, ACCOUNT)
            const first = client.getQueryData(row.queryKey(ACCOUNT))
            // A switch away and back that a capture saw starts a later
            // session of the same account.
            sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)
            captureFeatureContext()
            sessionStorage.setItem(SESSION_KEY, ACCOUNT)

            await row.fetch(client, ACCOUNT)

            const cached = client.getQueryData(row.queryKey(ACCOUNT))
            const produced = featureResultContext(cached)
            expect({
                sameReference: cached === first,
                producedFor: produced?.userId,
                current:
                    produced !== undefined && isCurrentFeatureContext(produced),
            }).toEqual({
                sameReference: true,
                producedFor: ACCOUNT,
                current: true,
            })
        }
    )

    const NOT_THE_REQUESTED_ACCOUNT = [
        { session: "another account", sessionUser: OTHER_ACCOUNT },
        { session: "logged out", sessionUser: null },
    ]

    it.each(
        FEATURE_QUERIES.flatMap((row) =>
            NOT_THE_REQUESTED_ACCOUNT.map((session) => ({ ...row, ...session }))
        )
    )(
        "guardFeatureRequest_accountNotSignedIn_makesNoRequest ($name, $session)",
        async (row) => {
            if (row.sessionUser === null) {
                sessionStorage.removeItem(SESSION_KEY)
            } else {
                sessionStorage.setItem(SESSION_KEY, row.sessionUser)
            }
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementation(() =>
                    Promise.resolve(respond({ status: 200, body: row.body }))
                )

            await settle(row.fetch(client, ACCOUNT))

            expect({
                requests: fetchMock.mock.calls.length,
                entry: published(client, row.queryKey(ACCOUNT)),
            }).toEqual({ requests: 0, entry: UNFETCHED })
        }
    )

    /** Shared flag states other than `true`. */
    const FEATURE_NOT_ON = [
        { flagState: "off", flag: false },
        { flagState: "never read", flag: undefined },
    ]

    it.each(
        FEATURE_QUERIES.flatMap((row) =>
            FEATURE_NOT_ON.map((state) => ({ ...row, ...state }))
        )
    )(
        "guardFeatureRequest_featureNotOn_makesNoRequest ($name, $flagState)",
        async (row) => {
            if (row.flag === undefined) {
                client.removeQueries({
                    queryKey: featureFlagKeys.portfolioInsights,
                    exact: true,
                })
            } else {
                client.setQueryData<boolean>(
                    featureFlagKeys.portfolioInsights,
                    row.flag
                )
            }
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementation(() =>
                    Promise.resolve(respond({ status: 200, body: row.body }))
                )
            const before = currentActivation()

            await settle(row.fetch(client, ACCOUNT))

            expect({
                requests: fetchMock.mock.calls.length,
                entry: published(client, row.queryKey(ACCOUNT)),
                shutdowns: currentActivation() - before,
            }).toEqual({ requests: 0, entry: UNFETCHED, shutdowns: 0 })
        }
    )

    /** A context change landing while the first insights request is held. */
    const TRANSITIONS = [
        {
            transition: "logout and login again",
            run: (target: QueryClient) => {
                sessionStorage.removeItem(SESSION_KEY)
                invalidateOnLogout(target)
                sessionStorage.setItem(SESSION_KEY, ACCOUNT)
            },
            restore: () => undefined,
            // Logout removes the entry, so the next fetch builds a new one.
            entry: undefined,
            shutdowns: 0,
        },
        {
            transition: "account switch",
            run: () => {
                sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)
            },
            restore: () => {
                sessionStorage.setItem(SESSION_KEY, ACCOUNT)
            },
            // Nothing removes the old account's entry, and nothing refetches
            // it.
            entry: UNFETCHED,
            shutdowns: 0,
        },
        {
            transition: "shutdown",
            run: (target: QueryClient) => onPortfolioInsightsDisabled(target),
            // A resume: a flag read started after the shutdown publishes
            // `true` again, and only then does the entry load afresh.
            restore: (target: QueryClient) => {
                target.setQueryData<boolean>(
                    featureFlagKeys.portfolioInsights,
                    true
                )
            },
            // The shutdown removes the entry, and the late 403 runs no second
            // one.
            entry: undefined,
            shutdowns: 1,
        },
    ]

    const LATE_REPLIES = [
        { reply: "success", late: { status: 200, body: insights } },
        { reply: "403", late: FORBIDDEN },
    ]

    it.each(
        TRANSITIONS.flatMap((transition) =>
            LATE_REPLIES.map((reply) => ({ ...transition, ...reply }))
        )
    )(
        "guardFeatureRequest_lateOutcomeAfterTransition_publishesNothingAndSettlesIdle ($transition, $reply)",
        async ({ run, restore, late, entry, shutdowns }) => {
            vi.useFakeTimers()
            const held = deferred<Response>()
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementationOnce(() => held.promise)
                .mockImplementation(() =>
                    Promise.resolve(
                        respond({ status: 200, body: refreshedInsights })
                    )
                )
            const before = currentActivation()
            const first = settle(client.query(portfolioInsightsQuery(ACCOUNT)))
            run(client)

            held.resolve(respond(late))
            await settleReleased()
            await first
            const settled = {
                entry: published(client, portfolioKeys.insights(ACCOUNT)),
                shutdowns: currentActivation() - before,
            }
            restore(client)
            const refetched = await client.query(
                portfolioInsightsQuery(ACCOUNT)
            )

            expect({
                ...settled,
                refetched,
                requests: fetchMock.mock.calls.length,
            }).toEqual({
                entry,
                shutdowns,
                refetched: refreshedInsights,
                requests: 2,
            })
        }
    )

    it("guardFeatureRequest_retryAfterAccountSwitch_requestsNothingForOldAccount", async () => {
        vi.useFakeTimers()
        const fetchMock = vi
            .spyOn(window, "fetch")
            .mockImplementation(() => Promise.resolve(respond({ status: 500 })))
        const outcome = settle(client.query(portfolioInsightsQuery(ACCOUNT)))
        // Halfway through the back-off: the first attempt has failed and its
        // retry is waiting.
        await vi.advanceTimersByTimeAsync(FIRST_RETRY_DELAY_MS / 2)
        sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)

        await vi.advanceTimersByTimeAsync(FIRST_RETRY_DELAY_MS / 2)
        await outcome

        expect({
            requests: fetchMock.mock.calls.length,
            entry: published(client, portfolioKeys.insights(ACCOUNT)),
        }).toEqual({ requests: 1, entry: UNFETCHED })
    })

    it.each(LATE_REPLIES)(
        "guardFeatureRequest_staleOutcomeDuringReplacementFetch_leavesReplacementToPublish ($reply)",
        async ({ late }) => {
            vi.useFakeTimers()
            // A replacement fetch cancels the one in flight only once the
            // entry holds data.
            client.setQueryData(portfolioKeys.insights(ACCOUNT), insights)
            const stale = deferred<Response>()
            const replacement = deferred<Response>()
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementationOnce(() => stale.promise)
                .mockImplementationOnce(() => replacement.promise)
            void settle(client.query(portfolioInsightsQuery(ACCOUNT)))
            // A switch away and back that a capture saw ends the first
            // request's session while the entry stays in the cache.
            sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)
            captureFeatureContext()
            sessionStorage.setItem(SESSION_KEY, ACCOUNT)
            const replaced = client.refetchQueries({
                queryKey: portfolioKeys.insights(ACCOUNT),
            })

            stale.resolve(respond(late))
            await settleReleased()
            replacement.resolve(
                respond({ status: 200, body: refreshedInsights })
            )
            await replaced

            expect({
                requests: fetchMock.mock.calls.length,
                entry: published(client, portfolioKeys.insights(ACCOUNT)),
            }).toEqual({
                requests: 2,
                entry: {
                    status: "success",
                    fetchStatus: "idle",
                    data: refreshedInsights,
                    error: null,
                },
            })
        }
    )

    it.each(LATE_REPLIES)(
        "guardFeatureRequest_observerSwitchesAwayAndBackDuringFirstRequest_loadsCurrentData ($reply)",
        async ({ late }) => {
            const held = deferred<Response>()
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementationOnce(() => held.promise)
                .mockImplementation(() =>
                    Promise.resolve(
                        respond({ status: 200, body: refreshedInsights })
                    )
                )
            const observer = renderObserver(ACCOUNT)
            // The observer leaves for another account and comes back before
            // the first response. That request keeps running, and the
            // observer joins it again instead of starting its own, so it
            // waits on an outcome that is stale by the time it arrives.
            observer.switchTo(OTHER_ACCOUNT)
            observer.switchTo(ACCOUNT)

            held.resolve(respond(late))

            await waitFor(() =>
                expect({
                    requested: fetchMock.mock.calls.map(([input]) => input),
                    shown: observer.shown(),
                }).toEqual({
                    requested: [
                        insightsUrl(ACCOUNT),
                        insightsUrl(OTHER_ACCOUNT),
                        insightsUrl(ACCOUNT),
                    ],
                    shown: String(refreshedInsights.totalValue),
                })
            )
        }
    )

    /** A stale outcome whose entry no current observer waits on. */
    const WITHOUT_CURRENT_OBSERVER = [
        {
            scenario: "observer mounted, session on another account",
            // The observer still shows the account the session has just
            // left, as it does until `AuthProvider` re-renders it.
            start: () => {
                renderObserver(ACCOUNT)
            },
            transition: () => {
                sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)
            },
        },
        {
            scenario: "no observer, session back on the account",
            start: () => {
                void settle(client.query(portfolioInsightsQuery(ACCOUNT)))
            },
            transition: () => {
                sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT)
                captureFeatureContext()
                sessionStorage.setItem(SESSION_KEY, ACCOUNT)
            },
        },
    ]

    it.each(WITHOUT_CURRENT_OBSERVER)(
        "guardFeatureRequest_staleOutcomeWithoutCurrentObserver_startsNoReplacement ($scenario)",
        async ({ start, transition }) => {
            // Cached data, so a refetch would not skip the entry as one that
            // was never fetched.
            client.setQueryData(portfolioKeys.insights(ACCOUNT), insights)
            const held = deferred<Response>()
            const fetchMock = vi
                .spyOn(window, "fetch")
                .mockImplementationOnce(() => held.promise)
                .mockImplementation(() =>
                    Promise.resolve(
                        respond({ status: 200, body: refreshedInsights })
                    )
                )
            // Every fetch the entry starts, whether or not it sends a request.
            let fetchStarts = 0
            client.getQueryCache().subscribe((event) => {
                if (
                    event.type === "updated" &&
                    event.action.type === "fetch" &&
                    matchQuery(
                        {
                            queryKey: portfolioKeys.insights(ACCOUNT),
                            exact: true,
                        },
                        event.query
                    )
                ) {
                    fetchStarts += 1
                }
            })
            start()
            const stale = client
                .getQueryCache()
                .find({ queryKey: portfolioKeys.insights(ACCOUNT) })?.promise
            transition()

            await act(async () => {
                held.resolve(respond({ status: 200, body: refreshedInsights }))
                await Promise.allSettled([stale])
            })

            expect({
                fetchStarts,
                requests: fetchMock.mock.calls.length,
                entry: published(client, portfolioKeys.insights(ACCOUNT)),
            }).toEqual({
                fetchStarts: 1,
                requests: 1,
                entry: {
                    status: "success",
                    fetchStatus: "idle",
                    data: insights,
                    error: null,
                },
            })
        }
    )

    const NOTIFICATIONS_URL = `${BROKER}/alerts/notifications?accountId=${ACCOUNT}&unacknowledged=true`

    /** The broker reads of the three feature queries for `ACCOUNT`. */
    const FEATURE_READ_URLS = [
        insightsUrl(ACCOUNT),
        `${BROKER}/alerts?accountId=${ACCOUNT}`,
        NOTIFICATIONS_URL,
    ]

    /**
     * The flag read logs a disabled flag or a cancelled read, and BizEvents
     * the missing OneAgent; neither is under test here.
     */
    function muteFeatureLogs(): void {
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        vi.spyOn(console, "debug").mockImplementation(() => undefined)
        vi.spyOn(console, "log").mockImplementation(() => undefined)
    }

    /**
     * Stands in for the flag service and broker-service with the feature on
     * for `ACCOUNT`: the flag reads `true`, the insights read and both alert
     * reads answer 200, and the instruments read an empty list. Once
     * `turnOff` runs, the flag reads `false` and every feature read answers
     * 403. `featureRequestsSince(mark)` lists, in order, the feature reads
     * sent after `mark()` was taken.
     */
    function stubFeatureServer() {
        const flagUrl = `${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`
        const instrumentsUrl = `${BROKER}/instrument?accountId=${ACCOUNT}`
        let featureOn = true
        const requested: string[] = []
        const unexpected: string[] = []
        vi.spyOn(window, "fetch").mockImplementation((input) => {
            const url =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            requested.push(url)
            if (url === flagUrl) {
                return Promise.resolve(flagResponse(featureOn))
            }
            if (url === instrumentsUrl) {
                return Promise.resolve(
                    respond({ status: 200, body: { results: [] } })
                )
            }
            if (!FEATURE_READ_URLS.includes(url)) {
                unexpected.push(url)
                return Promise.reject(new Error(`Unexpected request ${url}`))
            }
            if (!featureOn) {
                return Promise.resolve(respond(FORBIDDEN))
            }
            return Promise.resolve(
                respond({
                    status: 200,
                    body:
                        url === insightsUrl(ACCOUNT)
                            ? insights
                            : { results: [triggeredAlert] },
                })
            )
        })
        return {
            turnOff: (): void => {
                featureOn = false
            },
            mark: (): number => requested.length,
            featureRequestsSince: (mark: number): string[] =>
                requested
                    .slice(mark)
                    .filter((url) => FEATURE_READ_URLS.includes(url)),
            unexpected: (): string[] => unexpected,
        }
    }

    /** Waits until the three feature queries hold data and none is fetching. */
    async function waitForLoadedFeatureQueries(): Promise<void> {
        await waitFor(() =>
            expect({
                entries: [
                    portfolioKeys.insights(ACCOUNT),
                    alertKeys.list(ACCOUNT),
                    alertKeys.notifications(ACCOUNT),
                ].map((queryKey) => client.getQueryState(queryKey)?.status),
                fetching: client.isFetching(),
            }).toEqual({
                entries: ["success", "success", "success"],
                fetching: 0,
            })
        )
    }

    /**
     * The two ways a live shutdown reaches the tab once the server has turned
     * the feature off: the flag poll reads `false`, or the notifications poll
     * the watcher's timer starts answers 403 before the next flag poll.
     * `shutdownRequests` are the feature reads the shutdown itself sends.
     */
    const LIVE_SHUTDOWNS = [
        {
            shutdown: "flag read false",
            run: (target: QueryClient) =>
                target.refetchQueries({
                    queryKey: featureFlagKeys.portfolioInsights,
                    exact: true,
                }),
            shutdownRequests: [],
        },
        {
            shutdown: "notifications poll 403",
            run: (target: QueryClient) =>
                target.refetchQueries({
                    queryKey: alertKeys.notifications(ACCOUNT),
                    exact: true,
                }),
            shutdownRequests: [NOTIFICATIONS_URL],
        },
    ]

    // The alerts panel's two queries, and an insights observer, stay enabled
    // for as long as they are mounted: only the page, once it reads the flag
    // off, unmounts them. An observer that renders in between, as the panel
    // does when its own query's update reaches it before the page's flag
    // update, builds the entries the shutdown removed again and fetches them.
    it.each(LIVE_SHUTDOWNS)(
        "guardFeatureRequest_observerRendersAfterShutdown_sendsNoFeatureRequest ($shutdown)",
        async ({ run, shutdownRequests }) => {
            muteFeatureLogs()
            const server = stubFeatureServer()
            const observers = () => (
                <QueryClientProvider client={client}>
                    <UserContextProvider
                        userId={ACCOUNT}
                        logoutHandler={vi.fn()}
                    >
                        <FormatterWrapper>
                            <ToastWrapper>
                                <InsightsObserver accountId={ACCOUNT} />
                                <AlertsPanel
                                    accountId={ACCOUNT}
                                    instruments={[]}
                                />
                                <AlertNotificationWatcher />
                            </ToastWrapper>
                        </FormatterWrapper>
                    </UserContextProvider>
                </QueryClientProvider>
            )
            const { rerender } = render(observers())
            await waitForLoadedFeatureQueries()
            const before = currentActivation()
            const mark = server.mark()

            server.turnOff()
            await act(async () => {
                await run(client)
            })
            rerender(observers())
            await waitFor(() => expect(client.isFetching()).toBe(0))

            expect({
                featureRequests: server.featureRequestsSince(mark),
                shutdowns: currentActivation() - before,
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
                // Built again by the observers, and left unfetched.
                entries: [
                    portfolioKeys.insights(ACCOUNT),
                    alertKeys.list(ACCOUNT),
                    alertKeys.notifications(ACCOUNT),
                ].map((queryKey) => published(client, queryKey)),
                unexpected: server.unexpected(),
            }).toEqual({
                featureRequests: shutdownRequests,
                shutdowns: 1,
                flag: false,
                entries: [UNFETCHED, UNFETCHED, UNFETCHED],
                unexpected: [],
            })
        }
    )

    // The same shutdown on the tab as the app lays it out: the page with its
    // alerts panel, and the watcher beside it, as in `ProtectedLayout`. The
    // shutdown ends on `/home` with no further feature read and no second
    // shutdown.
    it.each(LIVE_SHUTDOWNS)(
        "guardFeatureRequest_liveShutdownOnInsightsPage_sendsNoFeatureRequest ($shutdown)",
        async ({ run, shutdownRequests }) => {
            muteFeatureLogs()
            const server = stubFeatureServer()
            const shown = createMemoryRouter(
                [
                    { path: "/insights", element: <PortfolioInsights /> },
                    { path: "/home", element: <p>{HOME_MARKER}</p> },
                ],
                { initialEntries: ["/insights"] }
            )
            router = shown
            render(
                <QueryClientProvider client={client}>
                    <UserContextProvider
                        userId={ACCOUNT}
                        logoutHandler={vi.fn()}
                    >
                        <FormatterWrapper>
                            <ToastWrapper>
                                <RouterProvider router={shown} />
                                <AlertNotificationWatcher />
                            </ToastWrapper>
                        </FormatterWrapper>
                    </UserContextProvider>
                </QueryClientProvider>
            )
            await waitForLoadedFeatureQueries()
            const before = currentActivation()
            const mark = server.mark()

            server.turnOff()
            await act(async () => {
                await run(client)
            })
            await waitFor(() =>
                expect({
                    path: shown.state.location.pathname,
                    fetching: client.isFetching(),
                }).toEqual({ path: "/home", fetching: 0 })
            )

            expect({
                featureRequests: server.featureRequestsSince(mark),
                shutdowns: currentActivation() - before,
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
                unexpected: server.unexpected(),
            }).toEqual({
                featureRequests: shutdownRequests,
                shutdowns: 1,
                flag: false,
                unexpected: [],
            })
        }
    )
})
