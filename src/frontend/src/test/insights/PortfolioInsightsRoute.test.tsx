import "@testing-library/jest-dom/vitest"
import { useEffect } from "react"
import {
    QueryClient,
    QueryClientProvider,
    focusManager,
} from "@tanstack/react-query"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { RouterProvider, createMemoryRouter } from "react-router"
import type { Alert } from "../../api/alerts/types"
import { PortfolioInsightsFlagId } from "../../api/featureFlags"
import { services } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import type { PortfolioInsights as InsightsResponse } from "../../api/portfolioInsights/types"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import {
    portfolioInsightsFlagQuery,
    usePortfolioInsightsFlag,
} from "../../hooks/useFeatureFlags"
import { createPortfolioInsightsLoader } from "../../hooks/usePortfolioInsights"
import { PortfolioInsights } from "../../pages/protected/PortfolioInsights"
import {
    currentActivation,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    portfolioKeys,
} from "../../utils/queryKeys"
import {
    FormatterWrapper,
    ToastWrapper,
    UserContextWrapper,
} from "../providers"

// Covers the blocking flag decision of the `/insights` entry loader and the
// activation check of the shared flag query, through a memory router that
// mounts the real loader and page. How the flag read maps each response is
// covered by portfolioInsightsApi.test.ts.

/** The account `UserContextWrapper` provides. */
const ACCOUNT_ID = "1"

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

/** What the root route's error element shows if a loader rejects. */
const ROOT_ERROR_TEXT = "Oops! There was an error!"

const HOME_MARKER = "home marker"

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

type StubResponse = { status: number; body?: unknown }

type AppRouter = ReturnType<typeof createMemoryRouter>

/** What the router shows: its location and the screen rendered for it. */
type Landing = {
    path: string
    screen: "home" | "insights" | "root error" | "pending"
}

const HOME: Landing = { path: "/home", screen: "home" }
const INSIGHTS: Landing = { path: "/insights", screen: "insights" }

/** Where an `/insights` entry ends, and what it left in the flag cache. */
type EntryOutcome = Landing & {
    /** Whether the loader let the page mount at all, even briefly. */
    pageEntered: boolean
    flag: boolean | undefined
}

const REFUSED: EntryOutcome = { ...HOME, pageEntered: false, flag: false }
const ACCEPTED: EntryOutcome = { ...INSIGHTS, pageEntered: true, flag: true }

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
            return new Promise<Response>((_resolve, reject) => {
                const abort = (): void => reject(abortError())
                openFlagReadAborts.push(abort)
                signal?.addEventListener("abort", abort, { once: true })
            })
        case "held":
            return new Promise<Response>((resolve, reject) => {
                heldFlagReads.push(resolve)
                openFlagReadAborts.push(() => reject(abortError()))
            })
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

function buildRouter(target: QueryClient): AppRouter {
    return createMemoryRouter(
        [
            {
                path: "/",
                errorElement: <p>{ROOT_ERROR_TEXT}</p>,
                hydrateFallbackElement: <p>route loading</p>,
                children: [
                    { path: "home", element: <p>{HOME_MARKER}</p> },
                    {
                        path: "insights",
                        loader: createPortfolioInsightsLoader(target),
                        element: <CountedPage />,
                    },
                ],
            },
        ],
        { initialEntries: ["/insights"] }
    )
}

/** Enters `/insights` with the loader, page and cache sharing `client`. */
function renderRoute(): AppRouter {
    const built = buildRouter(client)
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
    /** Fake time advanced after entry, set only where the read deadline decides. */
    advanceMs?: number
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
        scenario: "hung read aborted at 2 s",
        setup: () => {
            muteExpectedErrors()
            flagMode = "hung"
        },
        advanceMs: 2000,
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
        async ({ setup, advanceMs, expected }) => {
            if (advanceMs !== undefined) {
                vi.useFakeTimers({ shouldAdvanceTime: true })
            }
            setup()

            const entered = renderRoute()
            if (advanceMs !== undefined) {
                await advance(advanceMs)
            }

            await waitFor(() => expect(entryOutcome(entered)).toEqual(expected))
        }
    )

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
        // The flag service keeps answering `true`, so only the 403 can end
        // the visit.
        insightsResponse = { status: 403, body: { error: "feature_disabled" } }

        const entered = renderRoute()

        await waitFor(() =>
            expect({
                ...landing(entered),
                flag: client.getQueryData(featureFlagKeys.portfolioInsights),
            }).toEqual({ ...HOME, flag: false })
        )
    })

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
