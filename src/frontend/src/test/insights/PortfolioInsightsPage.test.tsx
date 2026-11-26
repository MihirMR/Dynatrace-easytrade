import "@testing-library/jest-dom/vitest"
import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { createMemoryRouter, RouterProvider } from "react-router"
import {
    QueryClient,
    QueryClientProvider,
    focusManager,
} from "@tanstack/react-query"
import { PortfolioInsights } from "../../pages/protected/PortfolioInsights"
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
import { featureFlagKeys, portfolioKeys } from "../../utils/queryKeys"
import { FormatterWrapper, ToastWrapper } from "../providers"

// Covers the page's own branches: loading, error, disclaimer, and the view
// event, sent once per mount for the first result that is current for the
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
