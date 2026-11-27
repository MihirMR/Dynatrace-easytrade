import "@testing-library/jest-dom/vitest"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { createMemoryRouter, RouterProvider } from "react-router"
import {
    QueryClient,
    QueryClientProvider,
    focusManager,
} from "@tanstack/react-query"
import {
    ALLOCATION_ROWS_STORAGE_KEY,
    MAX_ALLOCATION_ROWS,
    PortfolioInsights,
} from "../../pages/protected/PortfolioInsights"
import { BizEvents } from "../../api/bizEvents"
import { ApiError } from "../../api/http"
import type { PortfolioInsights as InsightsResponse } from "../../api/portfolioInsights/types"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { UserContextProvider } from "../../contexts/UserContext/context"
import { portfolioInsightsFlagQuery } from "../../hooks/useFeatureFlags"
import { portfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    captureFeatureContext,
    onPortfolioInsightsDisabled,
    recordFeatureResultContext,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    instrumentKeys,
    portfolioKeys,
} from "../../utils/queryKeys"
import { FormatterWrapper, ToastWrapper } from "../providers"

// Covers the page's own branches: loading, with the allocation rows its
// placeholder reserves from the tab's record, the cached instruments or, with
// neither, the instruments once they settle, before which it shows neither
// the placeholder nor the alerts panel; error, which keeps a reserved
// footprint hidden under its message; disclaimer, and the view event, sent
// once per mount for the first
// result that is current for the
// request that produced it: after an in-place account change, only for the
// new account, and after a shutdown and resume while the page stays mounted,
// for the result loaded afresh. The 403 case checks that the shared shutdown, which the
// insights query runs, sets the flag false and that the page then leaves for
// /home; the page runs no shutdown itself. The figures, the alerts panel and
// the flag query have their own suites.

/** The account the page opens with, also stored as the tab's session user. */
const ACCOUNT_ID = "1"

/** The account the tab switches to in place while the page stays mounted. */
const OTHER_ACCOUNT_ID = "2"

const TRAVEL_ID = "c0000000-0000-4000-8000-000000000001"
const HEALTH_ID = "c0000000-0000-4000-8000-000000000002"

/** Query-core's default delays before its three retries: 1 s, 2 s, 4 s. */
const DEFAULT_RETRY_BACKOFF_MS = 1_000 + 2_000 + 4_000

const FLAG_KEY = "GET /feature-flag-service/v1/flags/portfolio-insights-enabled"
const INSIGHTS_KEY = `GET /broker-service/v1/portfolio/insights/${ACCOUNT_ID}`
const INSTRUMENTS_KEY = `GET /broker-service/v1/instrument?accountId=${ACCOUNT_ID}`
const ALERTS_KEY = `GET /broker-service/v1/alerts?accountId=${ACCOUNT_ID}`
const NOTIFICATIONS_KEY = `GET /broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`
const OTHER_INSIGHTS_KEY = `GET /broker-service/v1/portfolio/insights/${OTHER_ACCOUNT_ID}`
const OTHER_INSTRUMENTS_KEY = `GET /broker-service/v1/instrument?accountId=${OTHER_ACCOUNT_ID}`
const OTHER_ALERTS_KEY = `GET /broker-service/v1/alerts?accountId=${OTHER_ACCOUNT_ID}`
const OTHER_NOTIFICATIONS_KEY = `GET /broker-service/v1/alerts/notifications?accountId=${OTHER_ACCOUNT_ID}&unacknowledged=true`

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

/**
 * The portfolio of `OTHER_ACCOUNT_ID`: two equal positions, so the largest
 * (EasyTravel, the lower id) holds exactly 50% and the risk is MEDIUM.
 */
const otherTravelAllocation = {
    instrumentId: TRAVEL_ID,
    name: "EasyTravel",
    quantity: 10,
    value: 100,
    percent: 50,
}

const otherAccountInsights: InsightsResponse = {
    totalValue: 200,
    totalInvested: 180,
    unrealizedPnl: 20,
    unrealizedPnlPercent: 11.11111111111111,
    allocations: [
        otherTravelAllocation,
        {
            instrumentId: HEALTH_ID,
            name: "EasyHealth",
            quantity: 5,
            value: 100,
            percent: 50,
        },
    ],
    largestPosition: otherTravelAllocation,
    riskLevel: "MEDIUM",
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

/**
 * A handler whose response waits until the case calls `release`, or until
 * `afterEach` releases it.
 */
function releasableHandler(response: StubResponse): {
    handler: Handler
    release: () => void
} {
    let release: () => void = () => undefined
    const held = new Promise<void>((resolve) => {
        release = resolve
    })
    releaseHeld.push(release)
    return {
        handler: async () => {
            await held
            return response
        },
        release,
    }
}

/** A handler whose response waits until `afterEach` releases it. */
function heldHandler(response: StubResponse): Handler {
    return releasableHandler(response).handler
}

function insightsRequestCount(fetchStub: FetchStub): number {
    return fetchStub.requests.filter((key) => key === INSIGHTS_KEY).length
}

/** The abort signal of every insights request the page sent, in order. */
function insightsRequestSignals(): (AbortSignal | null | undefined)[] {
    return vi
        .mocked(window)
        .fetch.mock.calls.filter(([input, init]) => {
            const href =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            const { pathname, search } = new URL(href)
            return (
                `${init?.method ?? "GET"} ${pathname}${search}` === INSIGHTS_KEY
            )
        })
        .map(([, init]) => init?.signal)
}

/**
 * Renders `/insights` for `ACCOUNT_ID`. `switchAccount` moves the tab to
 * another account in place, as `AuthProvider` does: it stores the id as the
 * session user, then re-renders the user provider with it while the page stays
 * mounted. `homeLoader`, when given, is the `/home` route's loader: the page
 * stays mounted until it settles, as it does while the app's protected
 * loaders run for a navigation.
 */
function renderPage(
    queryClient: QueryClient,
    homeLoader?: () => Promise<null>
) {
    const router = createMemoryRouter(
        [
            { path: "/insights", element: <PortfolioInsights /> },
            {
                path: "/home",
                loader: homeLoader,
                element: <p>home marker</p>,
            },
        ],
        { initialEntries: ["/insights"] }
    )
    const logoutHandler = vi.fn()
    const page = (userId: string) => (
        <QueryClientProvider client={queryClient}>
            <UserContextProvider userId={userId} logoutHandler={logoutHandler}>
                <FormatterWrapper>
                    <ToastWrapper>
                        <RouterProvider router={router} />
                    </ToastWrapper>
                </FormatterWrapper>
            </UserContextProvider>
        </QueryClientProvider>
    )
    const { rerender } = render(page(ACCOUNT_ID))
    function switchAccount(userId: string): void {
        sessionStorage.setItem(SESSION_KEY, userId)
        rerender(page(userId))
    }
    return { router, switchAccount }
}

/** Advances the fake clock and lets the work it starts settle and render. */
async function advance(ms: number): Promise<void> {
    await act(async () => {
        await vi.advanceTimersByTimeAsync(ms)
    })
}

/** Every id the loaded summary of `insights` shows, the figures and the table. */
const SUMMARY_IDS = [
    "insights-total-value",
    "insights-total-invested",
    "insights-unrealized-pnl",
    "insights-unrealized-pnl-percent",
    "insights-largest-position",
    "insights-risk-badge",
    "insights-allocations-heading",
    "insights-allocations",
]

/** What the loading placeholder reserves below its figure cards. */
type ReservedFootprint = { allocationRows: number; emptyStates: number }

/**
 * One reserved row: what the page reserves when it remembers no count, has
 * none of the account's instruments cached, and its instruments request
 * fails.
 */
const DEFAULT_FOOTPRINT: ReservedFootprint = {
    allocationRows: 1,
    emptyStates: 0,
}

/**
 * One reserved row per holding of the stub's instrument listing, EasyTravel
 * and EasyHealth: what the page reserves when it remembers no usable count
 * and has none of the account's instruments cached, once its instruments
 * query loads that listing.
 */
const LISTING_FOOTPRINT: ReservedFootprint = {
    allocationRows: 2,
    emptyStates: 0,
}

/**
 * An instrument listing of `count` instruments, the first `held` of them
 * owned; its ids differ from those of the stub's listing.
 */
function instrumentListing(count: number, held: number): Instrument[] {
    return Array.from({ length: count }, (_, index) => ({
        ...instruments[0],
        id: `d0000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
        code: `EINS${index}`,
        name: `Instrument ${index}`,
        amount: index < held ? index + 1 : 0,
    }))
}

function reservedFootprint(): ReservedFootprint | null {
    const placeholder = document.querySelector(
        '.insights-content[aria-hidden="true"]'
    )
    if (placeholder === null) {
        return null
    }
    return {
        allocationRows: placeholder.querySelectorAll(
            "table.data-table tbody tr"
        ).length,
        emptyStates: placeholder.querySelectorAll("p.empty-state").length,
    }
}

/** The tab's remembered allocation rows record, parsed; `null` when absent. */
function rememberedRecord(): unknown {
    const text = sessionStorage.getItem(ALLOCATION_ROWS_STORAGE_KEY)
    return text === null ? null : JSON.parse(text)
}

/**
 * The summary block's children, each by its id or else its class, the status
 * region's role and text, the reserved footprint, and whether the alerts
 * panel below the block is shown.
 */
function summaryAndPanel() {
    const block = document.querySelector(".insights-summary-block")
    const statusRegion = document.getElementById("insights-status")
    return {
        blockChildren: Array.from(
            block?.children ?? [],
            (child) => child.id || child.className
        ),
        status: {
            role: statusRegion?.getAttribute("role") ?? null,
            text: statusRegion?.textContent ?? null,
        },
        reserved: reservedFootprint(),
        panelShown: document.getElementById("alerts-panel") !== null,
    }
}

/** What `summaryAndPanel` reads while the placeholder of `reserved` shows. */
function reservingState(reserved: ReservedFootprint) {
    return {
        blockChildren: ["insights-status", "insights-content"],
        status: { role: "status", text: "Loading portfolio insights\u2026" },
        reserved,
        panelShown: true,
    }
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
        // Unmount first, so nothing released below reaches a mounted page and
        // restoring focus starts no read.
        cleanup()
        focusManager.setFocused(undefined)
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

    it("portfolioInsightsPage_loading_reservesSummaryWithHiddenPlaceholder", async () => {
        stub = stubFetch({
            [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
        })
        renderPage(client)
        const loading = await screen.findByText(
            "Loading portfolio insights\u2026"
        )

        const placeholder = document.querySelector(".insights-content")
        const statusRegion = document.getElementById("insights-status")
        expect({
            hidden: placeholder?.getAttribute("aria-hidden"),
            labels: Array.from(
                placeholder?.querySelectorAll(
                    ".insights-summary > .insights-figure > .form-label"
                ) ?? [],
                (label) => label.textContent
            ),
            allocationRows: placeholder?.querySelectorAll(
                "table.data-table tbody tr"
            ).length,
            idsInPlaceholder: Array.from(
                placeholder?.querySelectorAll("[id]") ?? [],
                (element) => element.id
            ),
            summaryIdsShown: SUMMARY_IDS.filter(
                (id) => document.getElementById(id) !== null
            ),
            statusHoldsLoading: statusRegion?.contains(loading),
            statusInsidePlaceholder: placeholder?.contains(statusRegion),
        }).toEqual({
            hidden: "true",
            labels: [
                "Total value",
                "Total invested",
                "Unrealized P/L",
                "Unrealized P/L %",
                "Largest position",
                "Risk",
            ],
            allocationRows: LISTING_FOOTPRINT.allocationRows,
            idsInPlaceholder: [],
            summaryIdsShown: [],
            statusHoldsLoading: true,
            statusInsidePlaceholder: false,
        })
    })

    it("portfolioInsightsPage_loaded_replacesPlaceholderWithFigures", async () => {
        const { handler, release } = releasableHandler({
            status: 200,
            body: insights,
        })
        stub = stubFetch({ [INSIGHTS_KEY]: handler })
        renderPage(client)
        await screen.findByText("Loading portfolio insights\u2026")

        release()

        expect(await screen.findByText("$400.00")).toHaveAttribute(
            "id",
            "insights-total-value"
        )
        expect({
            loadingShown:
                screen.queryByText("Loading portfolio insights\u2026") !== null,
            placeholders: document.querySelectorAll(
                '.insights-content[aria-hidden="true"]'
            ).length,
            summaries: document.querySelectorAll(".insights-content").length,
            summaryIdCounts: SUMMARY_IDS.map(
                (id) => document.querySelectorAll(`#${id}`).length
            ),
        }).toEqual({
            loadingShown: false,
            placeholders: 0,
            summaries: 1,
            summaryIdCounts: SUMMARY_IDS.map(() => 1),
        })
    })

    // The placeholder reserves the row count this tab last showed for the
    // account, so a reload keeps the alerts panel in place; with none of the
    // account's instruments cached, anything it cannot use as such a count
    // reserves one row per holding of the listing its instruments query
    // loads.
    it.each<{
        stored: string
        record: string | null
        reserved: ReservedFootprint
    }>([
        {
            stored: "0 rows",
            record: JSON.stringify({ [ACCOUNT_ID]: 0 }),
            reserved: { allocationRows: 0, emptyStates: 1 },
        },
        {
            stored: "1 row",
            record: JSON.stringify({ [ACCOUNT_ID]: 1 }),
            reserved: { allocationRows: 1, emptyStates: 0 },
        },
        {
            stored: "15 rows beside another account's 3",
            record: JSON.stringify({ [ACCOUNT_ID]: 15, [OTHER_ACCOUNT_ID]: 3 }),
            reserved: { allocationRows: 15, emptyStates: 0 },
        },
        {
            stored: "more rows than the cap",
            record: JSON.stringify({ [ACCOUNT_ID]: 1_000_000 }),
            reserved: { allocationRows: MAX_ALLOCATION_ROWS, emptyStates: 0 },
        },
        { stored: "nothing", record: null, reserved: LISTING_FOOTPRINT },
        {
            stored: "only another account's rows",
            record: JSON.stringify({ [OTHER_ACCOUNT_ID]: 15 }),
            reserved: LISTING_FOOTPRINT,
        },
        {
            stored: "text that is not JSON",
            record: "{",
            reserved: LISTING_FOOTPRINT,
        },
        { stored: "a list", record: "[15]", reserved: LISTING_FOOTPRINT },
        { stored: "null", record: "null", reserved: LISTING_FOOTPRINT },
        {
            stored: "a negative count",
            record: JSON.stringify({ [ACCOUNT_ID]: -1 }),
            reserved: LISTING_FOOTPRINT,
        },
        {
            stored: "a fractional count",
            record: JSON.stringify({ [ACCOUNT_ID]: 2.5 }),
            reserved: LISTING_FOOTPRINT,
        },
        {
            stored: "a count as text",
            record: JSON.stringify({ [ACCOUNT_ID]: "15" }),
            reserved: LISTING_FOOTPRINT,
        },
    ])(
        "portfolioInsightsPage_loading_reservesRememberedAllocationRows (stored: $stored)",
        async ({ record, reserved }) => {
            // An unusable record is logged; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            if (record !== null) {
                sessionStorage.setItem(ALLOCATION_ROWS_STORAGE_KEY, record)
            }
            stub = stubFetch({
                [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
            })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")

            expect(reservedFootprint()).toEqual(reserved)
        }
    )

    // Without a usable remembered count, as on a tab's first visit after
    // /home or /instruments cached the account's instruments, the placeholder
    // reserves one row per holding they list, up to the cap. A remembered
    // count still wins, and with neither it reserves once the page's
    // instruments query loads the stub's listing, two holdings. Otherwise
    // that query reloads the listing while the figures load, and the
    // reservation stays as it started.
    it.each<{
        known: string
        record: string | null
        readFails?: boolean
        cached?: { accountId: string; listing: Instrument[] }
        reserved: ReservedFootprint
    }>([
        {
            known: "3 cached instruments, none held",
            record: null,
            cached: { accountId: ACCOUNT_ID, listing: instrumentListing(3, 0) },
            reserved: { allocationRows: 0, emptyStates: 1 },
        },
        {
            known: "4 cached instruments, 2 held",
            record: null,
            cached: { accountId: ACCOUNT_ID, listing: instrumentListing(4, 2) },
            reserved: { allocationRows: 2, emptyStates: 0 },
        },
        {
            known: "16 cached instruments, 15 held",
            record: null,
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: { allocationRows: 15, emptyStates: 0 },
        },
        {
            known: "more cached holdings than the cap",
            record: null,
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(
                    MAX_ALLOCATION_ROWS + 1,
                    MAX_ALLOCATION_ROWS + 1
                ),
            },
            reserved: { allocationRows: MAX_ALLOCATION_ROWS, emptyStates: 0 },
        },
        {
            known: "only another account's rows, 15 cached holdings",
            record: JSON.stringify({ [OTHER_ACCOUNT_ID]: 3 }),
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: { allocationRows: 15, emptyStates: 0 },
        },
        {
            known: "a negative count, 15 cached holdings",
            record: JSON.stringify({ [ACCOUNT_ID]: -1 }),
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: { allocationRows: 15, emptyStates: 0 },
        },
        {
            known: "an unreadable record, 15 cached holdings",
            record: JSON.stringify({ [ACCOUNT_ID]: 3 }),
            readFails: true,
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: { allocationRows: 15, emptyStates: 0 },
        },
        {
            known: "3 remembered rows, 15 cached holdings",
            record: JSON.stringify({ [ACCOUNT_ID]: 3 }),
            cached: {
                accountId: ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: { allocationRows: 3, emptyStates: 0 },
        },
        {
            known: "0 remembered rows, 2 cached holdings",
            record: JSON.stringify({ [ACCOUNT_ID]: 0 }),
            cached: { accountId: ACCOUNT_ID, listing: instrumentListing(4, 2) },
            reserved: { allocationRows: 0, emptyStates: 1 },
        },
        {
            known: "only another account's cached holdings",
            record: null,
            cached: {
                accountId: OTHER_ACCOUNT_ID,
                listing: instrumentListing(16, 15),
            },
            reserved: LISTING_FOOTPRINT,
        },
        { known: "nothing", record: null, reserved: LISTING_FOOTPRINT },
    ])(
        "portfolioInsightsPage_loading_reservesRememberedElseCachedHoldingRows (known: $known)",
        async ({ record, readFails, cached, reserved }) => {
            // An unusable record is logged; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            if (record !== null) {
                sessionStorage.setItem(ALLOCATION_ROWS_STORAGE_KEY, record)
            }
            if (readFails === true) {
                // Bound before the spy replaces it; only the record fails.
                const readItem = Storage.prototype.getItem.bind(sessionStorage)
                vi.spyOn(Storage.prototype, "getItem").mockImplementation(
                    (key) => {
                        if (key === ALLOCATION_ROWS_STORAGE_KEY) {
                            throw new DOMException("denied", "SecurityError")
                        }
                        return readItem(key)
                    }
                )
            }
            if (cached !== undefined) {
                client.setQueryData(
                    instrumentKeys.byUser(cached.accountId),
                    cached.listing
                )
            }
            stub = stubFetch({
                [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
            })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")
            const reservedAtStart = reservedFootprint()

            await waitFor(() =>
                expect(
                    client.getQueryData(instrumentKeys.byUser(ACCOUNT_ID))
                ).toEqual(instruments)
            )

            expect({
                reservedAtStart,
                reservedAfterListing: reservedFootprint(),
            }).toEqual({
                reservedAtStart: reserved,
                reservedAfterListing: reserved,
            })
        }
    )

    // With no usable record and none of the account's instruments cached, as
    // on a document load of /insights in a new tab, the page shows only the
    // empty status region until its instruments query settles. Then the
    // placeholder, the loading message and the alerts panel appear together,
    // so the panel first paints where it stays, and a later listing never
    // resizes the reservation.
    it.each<{
        instruments: string
        response: StubResponse
        reserved: ReservedFootprint
    }>([
        {
            instruments: "4 listed, 3 held",
            response: {
                status: 200,
                body: { results: instrumentListing(4, 3) },
            },
            reserved: { allocationRows: 3, emptyStates: 0 },
        },
        {
            instruments: "3 listed, none held",
            response: {
                status: 200,
                body: { results: instrumentListing(3, 0) },
            },
            reserved: { allocationRows: 0, emptyStates: 1 },
        },
        {
            instruments: "request failed",
            response: { status: 500 },
            reserved: DEFAULT_FOOTPRINT,
        },
    ])(
        "portfolioInsightsPage_nothingKnown_reservesOnceInstrumentsSettle (instruments: $instruments)",
        async ({ response, reserved }) => {
            const firstListing = releasableHandler(response)
            const relisting = instrumentListing(16, 15)
            let listings = 0
            stub = stubFetch({
                [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
                [INSTRUMENTS_KEY]: () => {
                    listings += 1
                    return listings === 1
                        ? firstListing.handler()
                        : { status: 200, body: { results: relisting } }
                },
            })
            renderPage(client)
            // The alerts list has loaded, so the page has rendered what it
            // shows before the instruments settle.
            await waitFor(() =>
                expect(
                    client.getQueryState(alertKeys.list(ACCOUNT_ID))?.status
                ).toBe("success")
            )
            const whileEstimating = summaryAndPanel()

            firstListing.release()
            await screen.findByText("Loading portfolio insights\u2026")
            const onceSettled = summaryAndPanel()
            await act(async () => {
                await client.refetchQueries({
                    queryKey: instrumentKeys.byUser(ACCOUNT_ID),
                })
            })

            expect({
                whileEstimating,
                onceSettled,
                afterRelisting: summaryAndPanel(),
                relisted: client.getQueryData(
                    instrumentKeys.byUser(ACCOUNT_ID)
                ),
            }).toEqual({
                whileEstimating: {
                    blockChildren: ["insights-status"],
                    status: { role: "status", text: "" },
                    reserved: null,
                    panelShown: false,
                },
                onceSettled: reservingState(reserved),
                afterRelisting: reservingState(reserved),
                relisted: relisting,
            })
        }
    )

    // Figures that settle before any estimate, loaded or failed, end the
    // loading period with nothing reserved: the page shows them, or the
    // error message, with the alerts panel, and the instruments that arrive
    // later reserve nothing.
    it.each<{
        figures: string
        response: StubResponse
        shown: string
        blockChildren: string[]
    }>([
        {
            figures: "loaded",
            response: { status: 200, body: insights },
            shown: "$400.00",
            blockChildren: ["insights-status", "insights-content"],
        },
        {
            figures: "failed",
            response: { status: 500 },
            shown: "Could not load portfolio insights. Please try again later.",
            blockChildren: ["insights-status", "insights-error"],
        },
    ])(
        "portfolioInsightsPage_figuresSettleBeforeInstruments_reservesNothing ($figures)",
        async ({ response, shown, blockChildren }) => {
            // The page logs a failure; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            vi.useFakeTimers({ shouldAdvanceTime: true })
            const listing = releasableHandler({
                status: 200,
                body: { results: instruments },
            })
            stub = stubFetch({
                [INSIGHTS_KEY]: () => response,
                [INSTRUMENTS_KEY]: listing.handler,
            })
            renderPage(client)
            // A failure shows once the back-off before its three retries has
            // elapsed.
            for (
                let elapsed = 0;
                elapsed <= DEFAULT_RETRY_BACKOFF_MS;
                elapsed += 1_000
            ) {
                await advance(1_000)
            }
            await screen.findByText(shown)
            const beforeListing = summaryAndPanel()

            listing.release()
            await waitFor(() =>
                expect(
                    client.getQueryData(instrumentKeys.byUser(ACCOUNT_ID))
                ).toEqual(instruments)
            )

            const settled = {
                blockChildren,
                status: { role: "status", text: "" },
                reserved: null,
                panelShown: true,
            }
            expect({
                beforeListing,
                afterListing: summaryAndPanel(),
            }).toEqual({ beforeListing: settled, afterListing: settled })
        }
    )

    // Storage that throws, as with storage disabled or its quota exceeded,
    // reserves the rows of the loaded listing, as when nothing is remembered,
    // and leaves the loaded page in place; each failure is logged with the
    // error itself. A failing read also fails the write, which reads the
    // record first.
    it.each<{ failing: "getItem" | "setItem"; logged: string[] }>([
        {
            failing: "getItem",
            logged: [
                "[PortfolioInsights] could not read the remembered allocation rows",
                "[PortfolioInsights] could not remember the allocation rows",
            ],
        },
        {
            failing: "setItem",
            logged: [
                "[PortfolioInsights] could not remember the allocation rows",
            ],
        },
    ])(
        "portfolioInsightsPage_storageThrows_reservesListedRowsAndLogsError ($failing)",
        async ({ failing, logged }) => {
            const storageError = new DOMException("denied", "SecurityError")
            // Bound before the spies replace them; the page uses only
            // sessionStorage.
            const readItem = Storage.prototype.getItem.bind(sessionStorage)
            const storeItem = Storage.prototype.setItem.bind(sessionStorage)
            vi.spyOn(Storage.prototype, "getItem").mockImplementation((key) => {
                if (
                    failing === "getItem" &&
                    key === ALLOCATION_ROWS_STORAGE_KEY
                ) {
                    throw storageError
                }
                return readItem(key)
            })
            vi.spyOn(Storage.prototype, "setItem").mockImplementation(
                (key, value) => {
                    if (
                        failing === "setItem" &&
                        key === ALLOCATION_ROWS_STORAGE_KEY
                    ) {
                        throw storageError
                    }
                    storeItem(key, value)
                }
            )
            const consoleError = vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined)
            const { handler, release } = releasableHandler({
                status: 200,
                body: insights,
            })
            stub = stubFetch({ [INSIGHTS_KEY]: handler })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")
            const reservedWhileLoading = reservedFootprint()

            release()
            await screen.findByText("$400.00")

            await waitFor(() =>
                expect({
                    reservedWhileLoading,
                    totalValue:
                        document.getElementById("insights-total-value")
                            ?.textContent ?? null,
                    logged: consoleError.mock.calls.filter(
                        ([message]) =>
                            typeof message === "string" &&
                            message.includes("allocation rows")
                    ),
                }).toEqual({
                    reservedWhileLoading: LISTING_FOOTPRINT,
                    totalValue: "$400.00",
                    logged: logged.map((message) => [message, storageError]),
                })
            )
        }
    )

    /** An account id that only the corrupt record below names. */
    const RECORD_ACCOUNT_ID = "e4b7c1d9"

    /**
     * A record keyed by `RECORD_ACCOUNT_ID` whose entry has no JSON value; it
     * is short enough for the parser's message to quote it whole.
     */
    const CORRUPT_RECORD = `{"${RECORD_ACCOUNT_ID}": x`

    // The parser's error quotes the record it rejects, and so the account ids
    // keyed in it. The page logs a SyntaxError with a fixed message instead,
    // carrying the stack frames of the thrown error, or of its own catch when
    // what was thrown is not an Error, which is never logged; the placeholder
    // reserves the rows of the loaded listing, as when nothing is remembered.
    it.each<{ thrown: string; nonError?: unknown; frame: RegExp }>([
        { thrown: "the parser's SyntaxError", frame: /^\s+at JSON\.parse \(/ },
        {
            thrown: "a string holding the record",
            nonError: CORRUPT_RECORD,
            frame: /^\s+at parseAllocationRows \(/,
        },
    ])(
        "portfolioInsightsPage_recordNotJson_logsSyntaxErrorWithoutRecord (thrown: $thrown)",
        async ({ nonError, frame }) => {
            let parserMessage = ""
            try {
                JSON.parse(CORRUPT_RECORD)
            } catch (error) {
                parserMessage = error instanceof Error ? error.message : ""
            }
            if (nonError !== undefined) {
                // Bound before the spy replaces it; only the record's parse
                // throws `nonError`.
                const parse: typeof JSON.parse = JSON.parse.bind(JSON)
                vi.spyOn(JSON, "parse").mockImplementation(
                    (text, reviver): unknown => {
                        if (text === CORRUPT_RECORD) {
                            throw nonError
                        }
                        return parse(text, reviver)
                    }
                )
            }
            const consoleError = vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined)
            sessionStorage.setItem(ALLOCATION_ROWS_STORAGE_KEY, CORRUPT_RECORD)
            stub = stubFetch({
                [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
            })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")

            const logged = consoleError.mock.calls
                .filter(
                    ([message]) =>
                        message ===
                        "[PortfolioInsights] ignoring an allocation rows record that is not valid JSON"
                )
                .map(([, error]: unknown[]) => ({
                    isSyntaxError: error instanceof SyntaxError,
                    name: error instanceof Error ? error.name : null,
                    message: error instanceof Error ? error.message : null,
                    keepsFrame:
                        error instanceof Error &&
                        (error.stack ?? "")
                            .split("\n")
                            .some((line) => frame.test(line)),
                }))
            /** Every console.error argument as text, error stacks included. */
            const shown = consoleError.mock.calls
                .flat()
                .map((argument: unknown) =>
                    argument instanceof Error
                        ? `${argument.name}: ${argument.message}\n${argument.stack ?? ""}`
                        : typeof argument === "string"
                          ? argument
                          : (JSON.stringify(argument) ?? String(argument))
                )
                .join("\n")
            const expectedLog = {
                isSyntaxError: true,
                name: "SyntaxError",
                message: "The allocation rows record is not valid JSON",
                keepsFrame: true,
            }
            expect({
                parserQuotesRecord: parserMessage.includes(CORRUPT_RECORD),
                reserved: reservedFootprint(),
                logged,
                leaked: [RECORD_ACCOUNT_ID, CORRUPT_RECORD].filter((part) =>
                    shown.includes(part)
                ),
            }).toEqual({
                parserQuotesRecord: true,
                reserved: LISTING_FOOTPRINT,
                // The one read of the record while the figures load logs it.
                logged: [expectedLog],
                leaked: [],
            })
        }
    )

    // A record the page cannot use is reported where it is read while the
    // figures load, and only there: once they show, the write replaces it
    // with the loaded row count without logging it again.
    it.each<{ stored: string; record: string; logged: string }>([
        {
            stored: "text that is not JSON",
            record: CORRUPT_RECORD,
            logged: "[PortfolioInsights] ignoring an allocation rows record that is not valid JSON",
        },
        {
            stored: "a list",
            record: "[1]",
            logged: "[PortfolioInsights] ignoring an allocation rows record that is not an object",
        },
        {
            stored: "a string",
            record: '"x"',
            logged: "[PortfolioInsights] ignoring an allocation rows record that is not an object",
        },
    ])(
        "portfolioInsightsPage_unusableRecordThenLoaded_logsRecordOnceAndReplacesIt (stored: $stored)",
        async ({ record, logged }) => {
            const consoleError = vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined)
            sessionStorage.setItem(ALLOCATION_ROWS_STORAGE_KEY, record)
            const { handler, release } = releasableHandler({
                status: 200,
                body: insights,
            })
            stub = stubFetch({ [INSIGHTS_KEY]: handler })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")

            release()
            await screen.findByText("$400.00")

            await waitFor(() =>
                expect({
                    record: rememberedRecord(),
                    totalValue:
                        document.getElementById("insights-total-value")
                            ?.textContent ?? null,
                    // Every log about the record: its storage, its parse and
                    // its entry for the account.
                    logged: consoleError.mock.calls
                        .map(([message]: unknown[]) => message)
                        .filter(
                            (message) =>
                                typeof message === "string" &&
                                message.includes("allocation row")
                        ),
                }).toEqual({
                    record: { [ACCOUNT_ID]: insights.allocations.length },
                    totalValue: "$400.00",
                    logged: [logged],
                })
            )
        }
    )

    // The loaded summary's row count is stored under the account it shows;
    // the entries of other accounts stay, and an unusable record is replaced.
    it.each<{ before: string; record: string | null; after: unknown }>([
        { before: "nothing", record: null, after: { [ACCOUNT_ID]: 2 } },
        {
            before: "another account's rows",
            record: JSON.stringify({ [OTHER_ACCOUNT_ID]: 7 }),
            after: { [ACCOUNT_ID]: 2, [OTHER_ACCOUNT_ID]: 7 },
        },
        {
            before: "an older count of this account",
            record: JSON.stringify({ [ACCOUNT_ID]: 15 }),
            after: { [ACCOUNT_ID]: 2 },
        },
        {
            before: "text that is not JSON",
            record: "{",
            after: { [ACCOUNT_ID]: 2 },
        },
    ])(
        "portfolioInsightsPage_loaded_remembersRowCountForShownAccount (stored before: $before)",
        async ({ record, after }) => {
            // An unusable record is logged; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            if (record !== null) {
                sessionStorage.setItem(ALLOCATION_ROWS_STORAGE_KEY, record)
            }
            stub = stubFetch({})
            renderPage(client)
            await screen.findByText("$400.00")

            await waitFor(() => expect(rememberedRecord()).toEqual(after))
        }
    )

    it("portfolioInsightsPage_accountChangedInPlace_reservesAndRemembersRowsPerAccount", async () => {
        sessionStorage.setItem(
            ALLOCATION_ROWS_STORAGE_KEY,
            JSON.stringify({ [OTHER_ACCOUNT_ID]: 3 })
        )
        const otherAccount = releasableHandler({
            status: 200,
            body: {
                ...otherAccountInsights,
                allocations: [otherTravelAllocation],
            },
        })
        stub = stubFetch({
            [OTHER_INSIGHTS_KEY]: otherAccount.handler,
            [OTHER_INSTRUMENTS_KEY]: () => ({
                status: 200,
                body: { results: instruments },
            }),
            [OTHER_ALERTS_KEY]: () => ({
                status: 200,
                body: { results: noAlerts },
            }),
            [OTHER_NOTIFICATIONS_KEY]: () => ({
                status: 200,
                body: { results: noAlerts },
            }),
        })
        const { switchAccount } = renderPage(client)
        await screen.findByText("$400.00")

        // The first account's two rows were shown; the other account's
        // figures load while the page stays mounted.
        switchAccount(OTHER_ACCOUNT_ID)
        await screen.findByText("Loading portfolio insights\u2026")
        const reservedForOther = reservedFootprint()
        otherAccount.release()
        await screen.findByText("$200.00")

        await waitFor(() =>
            expect({
                reservedForOther,
                record: rememberedRecord(),
            }).toEqual({
                reservedForOther: { allocationRows: 3, emptyStates: 0 },
                record: { [ACCOUNT_ID]: 2, [OTHER_ACCOUNT_ID]: 1 },
            })
        )
    })

    it("portfolioInsightsPage_unmountedWhileLoading_abortsInsightsRequest", async () => {
        const fetchStub = stubFetch({
            [INSIGHTS_KEY]: heldHandler({ status: 200, body: insights }),
        })
        stub = fetchStub
        renderPage(client)
        await waitFor(() => expect(insightsRequestCount(fetchStub)).toBe(1))

        // The page is the insights query's only observer.
        cleanup()

        expect(
            insightsRequestSignals().map((signal) => signal?.aborted)
        ).toEqual([true])
    })

    // A 200 that breaks the contract must fail like a 500, never in render.
    it.each<{ failure: string; response: StubResponse }>([
        { failure: "status 500", response: { status: 500 } },
        {
            failure: "200 without allocations",
            response: {
                status: 200,
                body: { ...insights, allocations: undefined },
            },
        },
        {
            failure: "200 with an unknown risk level",
            response: { status: 200, body: { ...insights, riskLevel: "LOW_" } },
        },
    ])(
        "portfolioInsightsPage_requestFails_showsErrorKeepsLayout ($failure)",
        async ({ response }) => {
            // The page logs the failure; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            vi.useFakeTimers({ shouldAdvanceTime: true })
            stub = stubFetch({ [INSIGHTS_KEY]: () => response })
            renderPage(client)

            // Feature queries keep the default back-off before each of their
            // three retries, so the error shows only once all of it elapsed.
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
        }
    )

    // A failure after the placeholder showed keeps its footprint: the error
    // message sits at the top of the block, in one cell with the same
    // placeholder kept hidden, so the block keeps its height and the same
    // alerts panel stays below it.
    it.each<{ remembered: number; reserved: ReservedFootprint }>([
        { remembered: 15, reserved: { allocationRows: 15, emptyStates: 0 } },
        { remembered: 0, reserved: { allocationRows: 0, emptyStates: 1 } },
    ])(
        "portfolioInsightsPage_requestFailsWithReservedRows_keepsHiddenFootprintUnderError (remembered: $remembered)",
        async ({ remembered, reserved }) => {
            // The page logs the failure; the log itself is not under test.
            vi.spyOn(console, "error").mockImplementation(() => undefined)
            vi.useFakeTimers({ shouldAdvanceTime: true })
            sessionStorage.setItem(
                ALLOCATION_ROWS_STORAGE_KEY,
                JSON.stringify({ [ACCOUNT_ID]: remembered })
            )
            stub = stubFetch({ [INSIGHTS_KEY]: () => ({ status: 503 }) })
            renderPage(client)
            await screen.findByText("Loading portfolio insights\u2026")
            const whileLoading = summaryAndPanel()
            const panelWhileLoading = document.getElementById("alerts-panel")

            for (
                let elapsed = 0;
                elapsed <= DEFAULT_RETRY_BACKOFF_MS;
                elapsed += 1_000
            ) {
                await advance(1_000)
            }
            const message = await screen.findByText(
                "Could not load portfolio insights. Please try again later."
            )
            const footprint = document.querySelector(
                ".insights-summary-block > .insights-error-footprint"
            )

            expect({
                whileLoading,
                failed: summaryAndPanel(),
                footprintChildren: Array.from(
                    footprint?.children ?? [],
                    (child) => child.id || child.className
                ),
                message: {
                    id: message.id,
                    className: message.className,
                    role: message.getAttribute("role"),
                },
                samePanel:
                    document.getElementById("alerts-panel") ===
                    panelWhileLoading,
            }).toEqual({
                whileLoading: reservingState(reserved),
                failed: {
                    blockChildren: [
                        "insights-status",
                        "insights-error-footprint",
                    ],
                    status: { role: "status", text: "" },
                    reserved,
                    panelShown: true,
                },
                footprintChildren: ["insights-error", "insights-content"],
                message: {
                    id: "insights-error",
                    className: "status-message status-error",
                    role: "alert",
                },
                samePanel: true,
            })
        }
    )

    it("portfolioInsightsPage_requestFails_logsEndpointTemplateWithoutAccountId", async () => {
        const consoleError = vi
            .spyOn(console, "error")
            .mockImplementation(() => undefined)
        vi.useFakeTimers({ shouldAdvanceTime: true })
        stub = stubFetch({ [INSIGHTS_KEY]: () => ({ status: 500 }) })
        renderPage(client)
        for (
            let elapsed = 0;
            elapsed <= DEFAULT_RETRY_BACKOFF_MS;
            elapsed += 1_000
        ) {
            await advance(1_000)
        }
        await waitFor(() =>
            expect(consoleError).toHaveBeenCalledWith(
                "Could not load portfolio insights",
                expect.anything()
            )
        )

        const logged = consoleError.mock.calls.find(
            ([message]) => message === "Could not load portfolio insights"
        )?.[1] as Error & { status?: number; endpoint?: string }
        const queryError = client.getQueryState(
            portfolioKeys.insights(ACCOUNT_ID)
        )?.error

        expect({
            logged: {
                name: logged.name,
                status: logged.status,
                endpoint: logged.endpoint,
                message: logged.message,
                stackHasAccountId: (logged.stack ?? "").includes(
                    `/insights/${ACCOUNT_ID}`
                ),
            },
            queryError: {
                isApiError: queryError instanceof ApiError,
                url: queryError instanceof ApiError ? queryError.url : null,
            },
        }).toEqual({
            logged: {
                name: "ApiError",
                status: 500,
                endpoint: "/broker-service/v1/portfolio/insights/{id}",
                message:
                    "HTTP 500 for /broker-service/v1/portfolio/insights/{id}",
                stackHasAccountId: false,
            },
            queryError: {
                isApiError: true,
                url: `${window.location.origin}/broker-service/v1/portfolio/insights/${ACCOUNT_ID}`,
            },
        })
    })

    // The parser's error for a body that is not JSON quotes the body; only the
    // content-safe error of the parse boundary may reach the console.
    it("portfolioInsightsPage_malformedJsonBody_logsNeitherBodyNorAccountId", async () => {
        const marker = "LEAK4d1c"
        const spies = {
            error: vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined),
            warn: vi.spyOn(console, "warn").mockImplementation(() => undefined),
            info: vi.spyOn(console, "info").mockImplementation(() => undefined),
            debug: vi
                .spyOn(console, "debug")
                .mockImplementation(() => undefined),
            log: vi.spyOn(console, "log").mockImplementation(() => undefined),
        }
        /** A console argument as text, error message and stack included. */
        const consoleText = (value: unknown): string =>
            JSON.stringify(value, (_key, item: unknown) =>
                item instanceof Error
                    ? {
                          ...item,
                          name: item.name,
                          message: item.message,
                          stack: item.stack,
                      }
                    : item
            ) ?? String(value)
        vi.useFakeTimers({ shouldAdvanceTime: true })
        stub = stubFetch({})
        const answer = vi.mocked(window).fetch.getMockImplementation()
        vi.mocked(window).fetch.mockImplementation((input, init) => {
            const href =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            const { pathname, search } = new URL(href)
            if (
                `${init?.method ?? "GET"} ${pathname}${search}` === INSIGHTS_KEY
            ) {
                return Promise.resolve(
                    new Response(`<${marker}>`, {
                        status: 200,
                        headers: { "Content-Type": "application/json" },
                    })
                )
            }
            return answer === undefined
                ? Promise.reject(new Error("fetch is not stubbed"))
                : answer(input, init)
        })
        renderPage(client)
        for (
            let elapsed = 0;
            elapsed <= DEFAULT_RETRY_BACKOFF_MS;
            elapsed += 1_000
        ) {
            await advance(1_000)
        }
        await waitFor(() =>
            expect(spies.error).toHaveBeenCalledWith(
                "Could not load portfolio insights",
                expect.anything()
            )
        )

        const logged = spies.error.mock.calls.find(
            ([message]) => message === "Could not load portfolio insights"
        )?.[1] as Error
        const shown = Object.values(spies)
            .flatMap((spy): unknown[] => spy.mock.calls.flat())
            .map(consoleText)
            .join("\n")
        expect({
            loggedName: logged.name,
            errorShown:
                screen.queryByText(
                    "Could not load portfolio insights. Please try again later."
                ) !== null,
            leaked: [marker, `/insights/${ACCOUNT_ID}`].filter((part) =>
                shown.includes(part)
            ),
        }).toEqual({
            loggedName: "MalformedJsonError",
            errorShown: true,
            leaked: [],
        })
    })

    it("portfolioInsightsPage_forbidden_shutsDownAndNavigatesHome", async () => {
        stub = stubFetch({ [INSIGHTS_KEY]: () => ({ status: 403 }) })
        const { router } = renderPage(client)

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

    // The OneAgent call and its `reportError` fallback both throw, so the
    // event call itself throws: the loaded page must stay and log that throw.
    it("portfolioInsightsPage_viewEventReportingFails_keepsPageRendered", async () => {
        const reportingError = new Error("reportError failed")
        const sendBizEvent = vi.fn((): void => {
            throw new Error("sendBizEvent failed")
        })
        window.dynatrace = { sendBizEvent }
        window.dtrum = {
            reportError: () => {
                throw reportingError
            },
        }
        const consoleError = vi
            .spyOn(console, "error")
            .mockImplementation(() => undefined)
        try {
            stub = stubFetch({})
            renderPage(client)
            await waitFor(() => expect(sendBizEvent).toHaveBeenCalled())

            expect({
                totalValue:
                    document.getElementById("insights-total-value")
                        ?.textContent ?? null,
                sends: sendBizEvent.mock.calls,
                loggedFailure: consoleError.mock.calls.some(
                    ([message, error]) =>
                        message ===
                            "[PortfolioInsights] portfolioInsightsView event failed" &&
                        error === reportingError
                ),
            }).toEqual({
                totalValue: "$400.00",
                sends: [
                    [
                        "com.easytrade.portfolio-insights.view",
                        {
                            accountId: ACCOUNT_ID,
                            holdingCount: 2,
                            riskLevel: "HIGH",
                        },
                    ],
                ],
                loggedFailure: true,
            })
        } finally {
            // jsdom defines neither global; no other case expects them.
            delete window.dynatrace
            delete window.dtrum
        }
    })

    it("portfolioInsightsPage_windowRefocus_doesNotRefetchInsights", async () => {
        const fetchStub = stubFetch({})
        stub = fetchStub
        renderPage(client)
        await screen.findByText("$400.00")
        const fetchedBefore = insightsRequestCount(fetchStub)
        // Query-core starts its focus refetches from this call, a few
        // microtasks after the event; it runs them synchronously.
        const queryCoreFocus = vi.spyOn(client.getQueryCache(), "onFocus")

        act(() => {
            focusManager.setFocused(false)
            focusManager.setFocused(true)
        })
        await waitFor(() => expect(queryCoreFocus).toHaveBeenCalled())

        expect(insightsRequestCount(fetchStub)).toBe(fetchedBefore)
    })

    it("portfolioInsightsPage_accountChangedInPlace_sendsViewEventForNewAccountOnly", async () => {
        const viewSpy = vi
            .spyOn(BizEvents, "portfolioInsightsView")
            .mockImplementation(() => undefined)
        const firstAccount = releasableHandler({ status: 200, body: insights })
        const otherAccount = releasableHandler({
            status: 200,
            body: otherAccountInsights,
        })
        const fetchStub = stubFetch({
            [INSIGHTS_KEY]: firstAccount.handler,
            [OTHER_INSIGHTS_KEY]: otherAccount.handler,
            [OTHER_INSTRUMENTS_KEY]: () => ({
                status: 200,
                body: { results: instruments },
            }),
            [OTHER_ALERTS_KEY]: () => ({
                status: 200,
                body: { results: noAlerts },
            }),
            [OTHER_NOTIFICATIONS_KEY]: () => ({
                status: 200,
                body: { results: noAlerts },
            }),
        })
        stub = fetchStub
        const { switchAccount } = renderPage(client)
        await waitFor(() => expect(fetchStub.requests).toContain(INSIGHTS_KEY))

        // The account changes before the page's first result. The first
        // account's response then arrives late and settles before the new
        // account's response is released.
        switchAccount(OTHER_ACCOUNT_ID)
        await waitFor(() =>
            expect(fetchStub.requests).toContain(OTHER_INSIGHTS_KEY)
        )
        const lateFetch = client
            .getQueryCache()
            .find({ queryKey: portfolioKeys.insights(ACCOUNT_ID) })?.promise
        await act(async () => {
            firstAccount.release()
            await Promise.allSettled([lateFetch])
        })
        otherAccount.release()
        // The new account's figures are on screen, so the view effect of the
        // render that showed them has run.
        await screen.findByText("$200.00")

        expect(viewSpy.mock.calls).toEqual([
            [
                {
                    accountId: OTHER_ACCOUNT_ID,
                    holdingCount: 2,
                    riskLevel: "MEDIUM",
                },
            ],
        ])
    })

    it("portfolioInsightsPage_shutdownAndResumeWhileMounted_sendsViewEventForCurrentResult", async () => {
        const viewSpy = vi
            .spyOn(BizEvents, "portfolioInsightsView")
            .mockImplementation(() => undefined)
        const firstRequest = releasableHandler({ status: 200, body: insights })
        let served = 0
        const fetchStub = stubFetch({
            [INSIGHTS_KEY]: () => {
                served += 1
                return served === 1
                    ? firstRequest.handler()
                    : { status: 200, body: refreshedInsights }
            },
        })
        stub = fetchStub
        // The navigation to /home stays pending until `afterEach`, so the page
        // stays mounted after the shutdown.
        const homeHeld = new Promise<void>((resolve) => {
            releaseHeld.push(resolve)
        })
        const { router } = renderPage(client, async () => {
            await homeHeld
            return null
        })
        await waitFor(() => expect(fetchStub.requests).toContain(INSIGHTS_KEY))

        // The shutdown lands before the page's first result. A flag read that
        // starts after it answers `true` before the page has left, and the
        // page loads its figures afresh under the new activation.
        act(() => {
            onPortfolioInsightsDisabled(client)
        })
        await waitFor(() =>
            expect(router.state.navigation.location?.pathname).toBe("/home")
        )
        await act(async () => {
            await client.query(portfolioInsightsFlagQuery(client))
        })
        await screen.findByText("$430.00")

        expect(viewSpy.mock.calls).toEqual([
            [{ accountId: ACCOUNT_ID, holdingCount: 2, riskLevel: "HIGH" }],
        ])
    })

    it.each<{
        cache: string
        seed: (cached: InsightsResponse) => Record<string, Handler>
    }>([
        {
            // The session has moved to another account before the page
            // re-renders, so its own insights request is never sent, and the
            // entry of the account it still shows holds a result that a
            // current request for the other account produced.
            cache: "produced for another account",
            seed: (cached) => {
                sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
                recordFeatureResultContext(cached, captureFeatureContext())
                return {}
            },
        },
        {
            // Written into the cache by no request at all; the page's own
            // request is held, so the written entry stays.
            cache: "written without a request",
            seed: () => ({
                [INSIGHTS_KEY]: heldHandler({
                    status: 200,
                    body: refreshedInsights,
                }),
            }),
        },
    ])(
        "portfolioInsightsPage_cachedResultNotProducedForAccountShown_sendsNoViewEvent ($cache)",
        async ({ seed }) => {
            const viewSpy = vi
                .spyOn(BizEvents, "portfolioInsightsView")
                .mockImplementation(() => undefined)
            const cached: InsightsResponse = { ...insights }
            stub = stubFetch(seed(cached))
            client.setQueryData(portfolioKeys.insights(ACCOUNT_ID), cached)

            renderPage(client)
            // The figures are on screen, so the view effect of the render
            // that showed them has run.
            await screen.findByText("$400.00")

            expect(viewSpy.mock.calls).toEqual([])
        }
    )

    it("portfolioInsightsPage_cachedResultFromEarlierSession_sendsViewEventOnCurrentEqualRefetch", async () => {
        const viewSpy = vi
            .spyOn(BizEvents, "portfolioInsightsView")
            .mockImplementation(() => undefined)
        const mountRefetch = releasableHandler({ status: 200, body: insights })
        let served = 0
        const fetchStub = stubFetch({
            [INSIGHTS_KEY]: () => {
                served += 1
                return served === 1
                    ? { status: 200, body: insights }
                    : mountRefetch.handler()
            },
        })
        stub = fetchStub
        // A preload in an earlier session of the same account, as the entry
        // loader makes before a switch away and back, leaves its result
        // cached; the page's refetch then answers the same figures.
        await client.query(portfolioInsightsQuery(ACCOUNT_ID))
        sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
        captureFeatureContext()
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)

        renderPage(client)
        await waitFor(() => expect(insightsRequestCount(fetchStub)).toBe(2))
        const beforeRefetch = [...viewSpy.mock.calls]
        mountRefetch.release()

        await waitFor(() =>
            expect({ beforeRefetch, afterRefetch: viewSpy.mock.calls }).toEqual(
                {
                    beforeRefetch: [],
                    afterRefetch: [
                        [
                            {
                                accountId: ACCOUNT_ID,
                                holdingCount: 2,
                                riskLevel: "HIGH",
                            },
                        ],
                    ],
                }
            )
        )
    })
})
