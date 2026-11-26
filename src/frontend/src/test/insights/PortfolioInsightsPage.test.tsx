import "@testing-library/jest-dom/vitest"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { createMemoryRouter, RouterProvider } from "react-router"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { PortfolioInsights } from "../../pages/protected/PortfolioInsights"
import { BizEvents } from "../../api/bizEvents"
import type { PortfolioInsights as InsightsResponse } from "../../api/portfolioInsights/types"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { featureFlagKeys, portfolioKeys } from "../../utils/queryKeys"
import {
    FormatterWrapper,
    ToastWrapper,
    UserContextWrapper,
} from "../providers"

// Covers the page's own branches: loading, error, 403 shutdown, disclaimer
// and the once-per-mount view event. The figures, the alerts panel and the
// flag query have their own suites.

/** The account `UserContextWrapper` provides. */
const ACCOUNT_ID = "1"

const TRAVEL_ID = "c0000000-0000-4000-8000-000000000001"
const HEALTH_ID = "c0000000-0000-4000-8000-000000000002"

/** Query-core's default delays before its three retries: 1 s, 2 s, 4 s. */
const DEFAULT_RETRY_BACKOFF_MS = 1_000 + 2_000 + 4_000

const FLAG_KEY = "GET /feature-flag-service/v1/flags/portfolio-insights-enabled"
const INSIGHTS_KEY = `GET /broker-service/v1/portfolio/insights/${ACCOUNT_ID}`
const INSTRUMENTS_KEY = `GET /broker-service/v1/instrument?accountId=${ACCOUNT_ID}`
const ALERTS_KEY = `GET /broker-service/v1/alerts?accountId=${ACCOUNT_ID}`
const NOTIFICATIONS_KEY = `GET /broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`

const instruments: Instrument[] = [
    {
        id: TRAVEL_ID,
        code: "ETRAVE",
        name: "EasyTravel",
        description: "EasyTravel Incorporated",
        productId: 1,
        productName: "Share",
        price: {
            timestamp: "2026-01-01T09:00:00Z",
            open: 9.5,
            close: 10,
            low: 9.25,
            high: 10.25,
        },
        amount: 30,
    },
    {
        id: HEALTH_ID,
        code: "EHEALT",
        name: "EasyHealth",
        description: "EasyHealth Incorporated",
        productId: 1,
        productName: "Share",
        price: {
            timestamp: "2026-01-01T09:00:00Z",
            open: 19.5,
            close: 20,
            low: 19.25,
            high: 20.25,
        },
        amount: 5,
    },
]

const travelAllocation = {
    instrumentId: TRAVEL_ID,
    name: "EasyTravel",
    quantity: 30,
    value: 300,
    percent: 75,
}

const insights: InsightsResponse = {
    totalValue: 400,
    totalInvested: 350,
    unrealizedPnl: 50,
    unrealizedPnlPercent: 14.285714285714286,
    allocations: [
        travelAllocation,
        {
            instrumentId: HEALTH_ID,
            name: "EasyHealth",
            quantity: 5,
            value: 100,
            percent: 25,
        },
    ],
    largestPosition: travelAllocation,
    riskLevel: "HIGH",
}

/** The same holdings after the EasyTravel close moved from 10 to 11. */
const refreshedTravelAllocation = {
    ...travelAllocation,
    value: 330,
    percent: 76.74418604651163,
}

const refreshedInsights: InsightsResponse = {
    totalValue: 430,
    totalInvested: 350,
    unrealizedPnl: 80,
    unrealizedPnlPercent: 22.857142857142858,
    allocations: [
        refreshedTravelAllocation,
        {
            instrumentId: HEALTH_ID,
            name: "EasyHealth",
            quantity: 5,
            value: 100,
            percent: 23.25581395348837,
        },
    ],
    largestPosition: refreshedTravelAllocation,
    riskLevel: "HIGH",
}

const noAlerts: Alert[] = []

type StubResponse = { status: number; body?: unknown }
type Handler = () => StubResponse | Promise<StubResponse>

/** Every request the page made, and those no handler expected. */
type FetchStub = { requests: string[]; unexpected: string[] }

function respond({ status, body }: StubResponse): Response {
    if (body === undefined) {
        return new Response(null, { status })
    }
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

/**
 * Answers the page's requests by `METHOD path?search`, with defaults for the
 * flag, instrument and alert reads. A request no handler expects is rejected
 * and recorded, and `afterEach` fails the case for it.
 */
function stubFetch(handlers: Record<string, Handler>): FetchStub {
    const defaults: Record<string, Handler> = {
        [FLAG_KEY]: () => ({
            status: 200,
            body: {
                id: "portfolio-insights-enabled",
                enabled: true,
                name: "Portfolio insights",
                description: "d",
                isModifiable: true,
                tag: "feature",
            },
        }),
        [INSIGHTS_KEY]: () => ({ status: 200, body: insights }),
        [INSTRUMENTS_KEY]: () => ({
            status: 200,
            body: { results: instruments },
        }),
        [ALERTS_KEY]: () => ({ status: 200, body: { results: noAlerts } }),
        [NOTIFICATIONS_KEY]: () => ({
            status: 200,
            body: { results: noAlerts },
        }),
    }
    const stub: FetchStub = { requests: [], unexpected: [] }
    vi.spyOn(window, "fetch").mockImplementation(
        async (
            input: RequestInfo | URL,
            init?: RequestInit
        ): Promise<Response> => {
            const href =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            const { pathname, search } = new URL(href)
            const key = `${init?.method ?? "GET"} ${pathname}${search}`
            stub.requests.push(key)
            const handler = handlers[key] ?? defaults[key]
            if (handler === undefined) {
                stub.unexpected.push(key)
                throw new Error(`Unexpected request ${key}`)
            }
            return respond(await handler())
        }
    )
    return stub
}

let client: QueryClient
let stub: FetchStub | undefined
let releaseHeld: (() => void)[] = []

/** A handler whose response waits until `afterEach` releases it. */
function heldHandler(response: StubResponse): Handler {
    let release: () => void = () => undefined
    const held = new Promise<void>((resolve) => {
        release = resolve
    })
    releaseHeld.push(release)
    return async () => {
        await held
        return response
    }
}

function insightsRequestCount(fetchStub: FetchStub): number {
    return fetchStub.requests.filter((key) => key === INSIGHTS_KEY).length
}

function renderPage(queryClient: QueryClient) {
    const router = createMemoryRouter(
        [
            { path: "/insights", element: <PortfolioInsights /> },
            { path: "/home", element: <p>home marker</p> },
        ],
        { initialEntries: ["/insights"] }
    )
    render(
        <QueryClientProvider client={queryClient}>
            <UserContextWrapper>
                <FormatterWrapper>
                    <ToastWrapper>
                        <RouterProvider router={router} />
                    </ToastWrapper>
                </FormatterWrapper>
            </UserContextWrapper>
        </QueryClientProvider>
    )
    return router
}

/** Advances the fake clock and lets the work it starts settle and render. */
async function advance(ms: number): Promise<void> {
    await act(async () => {
        await vi.advanceTimersByTimeAsync(ms)
    })
}

describe("PortfolioInsights page", () => {
    beforeEach(() => {
        // Read by the activation guard every feature request passes through.
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        client = new QueryClient({
            defaultOptions: { queries: { retry: false } },
        })
        client.setQueryData(featureFlagKeys.portfolioInsights, true)
    })

    afterEach(() => {
        // Unmount first, so nothing released below reaches a mounted page.
        cleanup()
        releaseHeld.forEach((release) => release())
        releaseHeld = []
        client.clear()
        vi.useRealTimers()
        vi.restoreAllMocks()
        sessionStorage.clear()
        const unexpected = stub?.unexpected ?? []
        stub = undefined
        expect(unexpected).toEqual([])
    })

    it("portfolioInsightsPage_loading_showsLoadingMessage", async () => {
        stub = stubFetch({
            [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
        })
        renderPage(client)

        const loading = await screen.findByText(
            "Loading portfolio insights\u2026"
        )
        expect(loading).toHaveAttribute("id", "insights-loading")
        // Announced through the summary's persistent status region.
        const statusRegion = document.getElementById("insights-status")
        expect(statusRegion).toHaveAttribute("role", "status")
        expect(statusRegion).toContainElement(loading)
    })

    it("portfolioInsightsPage_requestFails_showsErrorKeepsLayout", async () => {
        // The page logs the failure; the log itself is not under test.
        vi.spyOn(console, "error").mockImplementation(() => undefined)
        vi.useFakeTimers({ shouldAdvanceTime: true })
        stub = stubFetch({ [INSIGHTS_KEY]: () => ({ status: 500 }) })
        renderPage(client)

        // Feature queries keep the default back-off before each of their three
        // retries, so the error shows only once all of it has elapsed.
        for (
            let elapsed = 0;
            elapsed <= DEFAULT_RETRY_BACKOFF_MS;
            elapsed += 1_000
        ) {
            await advance(1_000)
        }

        expect(
            await screen.findByText(
                "Could not load portfolio insights. Please try again later."
            )
        ).toHaveAttribute("id", "insights-error")
        // Other regions of the page may be alert regions too.
        expect(screen.getAllByRole("alert")).toContain(
            screen.getByText(
                "Could not load portfolio insights. Please try again later."
            )
        )
        expect(document.getElementById("alerts-panel")).toBeInTheDocument()
    })

    it("portfolioInsightsPage_forbidden_shutsDownAndNavigatesHome", async () => {
        stub = stubFetch({ [INSIGHTS_KEY]: () => ({ status: 403 }) })
        const router = renderPage(client)

        expect(await screen.findByText("home marker")).toBeInTheDocument()
        expect(router.state.location.pathname).toBe("/home")
        expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
            false
        )
    })

    it("portfolioInsightsPage_loaded_keepsEmptyStatusRegion", async () => {
        stub = stubFetch({})
        renderPage(client)
        // The loaded total value: the summary has replaced the loading state.
        await screen.findByText("$400.00")

        // The region outlives the loading text, so a later loading state is
        // added to a region that is already present and gets announced.
        const statusRegion = document.getElementById("insights-status")
        expect(statusRegion).toHaveAttribute("role", "status")
        expect(statusRegion).toBeEmptyDOMElement()
    })

    it("portfolioInsightsPage_disclaimer_isShown", async () => {
        stub = stubFetch({})
        renderPage(client)

        expect(
            await screen.findByText(
                "Simulated demo data. Portfolio Insights is not financial advice."
            )
        ).toHaveAttribute("id", "insights-disclaimer")
    })

    it("portfolioInsightsPage_loaded_sendsViewEventOnce", async () => {
        const viewSpy = vi
            .spyOn(BizEvents, "portfolioInsightsView")
            .mockImplementation(() => undefined)
        let served = 0
        const fetchStub = stubFetch({
            [INSIGHTS_KEY]: () => {
                served += 1
                return {
                    status: 200,
                    body: served === 1 ? insights : refreshedInsights,
                }
            },
        })
        stub = fetchStub
        renderPage(client)
        await waitFor(() => expect(viewSpy).toHaveBeenCalledTimes(1))
        const fetchedBefore = insightsRequestCount(fetchStub)

        // A refetch with changed figures re-renders the page; the store update
        // renders synchronously and flushes its effects before the new figure
        // is observable, so the view effect has run again by then.
        const refetched = client.invalidateQueries({
            queryKey: portfolioKeys.insights(ACCOUNT_ID),
        })
        await waitFor(() =>
            expect(insightsRequestCount(fetchStub)).toBeGreaterThan(
                fetchedBefore
            )
        )
        expect(await screen.findByText("$430.00")).toHaveAttribute(
            "id",
            "insights-total-value"
        )
        await refetched

        expect(viewSpy).toHaveBeenCalledTimes(1)
        expect(viewSpy).toHaveBeenCalledWith({
            accountId: ACCOUNT_ID,
            holdingCount: 2,
            riskLevel: "HIGH",
        })
    })
})
