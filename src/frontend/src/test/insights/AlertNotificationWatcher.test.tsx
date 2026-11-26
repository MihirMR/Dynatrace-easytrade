import "@testing-library/jest-dom/vitest"
import {
    QueryClient,
    QueryClientProvider,
    defaultScheduler,
    notifyManager,
} from "@tanstack/react-query"
import {
    type RenderResult,
    act,
    cleanup,
    render,
    screen,
    waitFor,
} from "@testing-library/react"
import {
    type ReactElement,
    type ReactNode,
    useLayoutEffect,
    useRef,
} from "react"
import type { Alert, AlertDirection, AlertType } from "../../api/alerts/types"
import { ApiError } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import { AlertNotificationWatcher } from "../../components/insights/AlertNotificationWatcher"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { UserContextProvider } from "../../contexts/UserContext/context"
import { useAlertNotificationsQuery } from "../../hooks/useAlerts"
import { portfolioInsightsFlagQuery } from "../../hooks/useFeatureFlags"
import {
    NOTIFIED_STORAGE_KEY,
    hasBeenShown,
    notificationKey,
} from "../../utils/alertNotificationTracker"
import {
    captureFeatureContext,
    onPortfolioInsightsDisabled,
    recordFeatureResultContext,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    instrumentKeys,
    invalidateOnLogout,
} from "../../utils/queryKeys"
import { ToastWrapper } from "../providers"

/** The account the watcher is rendered for unless a case names another. */
const ACCOUNT_ID = "1"

/** The account an in-place switch moves the tab to, and back from. */
const OTHER_ACCOUNT_ID = "2"

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

/** The notification and flag poll interval on a visible tab. */
const POLL_INTERVAL_MS = 15_000

/** Query-core's default delays before its three retries: 1 s, 2 s, 4 s. */
const DEFAULT_RETRY_BACKOFF_MS = 1_000 + 2_000 + 4_000

const FLAG_ID = "portfolio-insights-enabled"

const FLAG_URL = `${window.location.origin}/feature-flag-service/v1/flags/${FLAG_ID}`

const NOTIFICATIONS_ENDPOINT = `${window.location.origin}/broker-service/v1/alerts/notifications`

const NOTIFICATIONS_URL = `${NOTIFICATIONS_ENDPOINT}?accountId=${ACCOUNT_ID}&unacknowledged=true`

const triggeredAlert: Alert = {
    id: "a0000000-0000-4000-8000-000000000001",
    accountId: ACCOUNT_ID,
    instrumentId: INSTRUMENT_ID,
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: 10,
    enabled: true,
    armingRevision: 1,
    triggeredAt: "2026-01-01T10:00:00Z",
    triggerValue: 10.5,
    acknowledged: false,
    createdAt: "2026-01-01T09:00:00Z",
}

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
            open: 9.5,
            close: 10.5,
            low: 9.25,
            high: 10.75,
        },
        amount: 10,
    },
]

/**
 * One notification poll's answer: a 200 with these notifications, a 200 with
 * exactly this JSON body, an error status, or `"hold"` to keep it pending
 * until released.
 */
type NotificationReply =
    Alert[] | { body: unknown } | { status: number } | "hold"

/** A held notification poll; `release` answers it. */
type HeldPoll = { release: (notifications: Alert[]) => void }

type FetchStub = {
    /** The state the feature-flag-service stub reports for the flag. */
    flagEnabled: boolean
    /** Replies to successive notification polls, used up in order. */
    replies: NotificationReply[]
    /** The reply once `replies` is used up. */
    fallback: NotificationReply
    flagRequests: number
    notificationRequests: number
    /**
     * The `accountId` of every notification poll for an account other than
     * `ACCOUNT_ID`, an empty one included, in order. Each is answered with no
     * notifications.
     */
    otherAccountPolls: string[]
    /** Notification polls still waiting for their response, oldest first. */
    held: HeldPoll[]
    /** Every notification response handed to the app, held ones on release. */
    served: Response[]
}

function jsonResponse(body: unknown): Response {
    return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "Content-Type": "application/json" },
    })
}

function requestUrl(input: RequestInfo | URL): string {
    if (typeof input === "string") return input
    if (input instanceof URL) return input.href
    return input.url
}

/**
 * The account of an unacknowledged-notifications poll for any account but
 * `ACCOUNT_ID`, or `null` for every other request.
 */
function otherAccountPoll(url: string): string | null {
    const parsed = new URL(url, window.location.origin)
    if (
        `${parsed.origin}${parsed.pathname}` !== NOTIFICATIONS_ENDPOINT ||
        parsed.searchParams.get("unacknowledged") !== "true"
    ) {
        return null
    }
    const accountId = parsed.searchParams.get("accountId") ?? ""
    return accountId === ACCOUNT_ID ? null : accountId
}

/**
 * Answers the two requests the watcher makes, the flag read and the
 * notification poll, through `window.fetch`, which `api/http.ts` calls. A
 * poll for any account other than `ACCOUNT_ID` answers no notifications and
 * is recorded in `otherAccountPolls`. Anything else is rejected, so an
 * unexpected request fails loudly.
 */
function stubFetch(): FetchStub {
    const stub: FetchStub = {
        flagEnabled: true,
        replies: [],
        fallback: [],
        flagRequests: 0,
        notificationRequests: 0,
        otherAccountPolls: [],
        held: [],
        served: [],
    }
    const serve = (notifications: Alert[]): Response => {
        const response = jsonResponse({ results: notifications })
        stub.served.push(response)
        return response
    }
    vi.spyOn(window, "fetch").mockImplementation(
        (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
            const url = requestUrl(input)
            const method = init?.method ?? "GET"
            if (method === "GET" && url === FLAG_URL) {
                stub.flagRequests += 1
                return Promise.resolve(
                    jsonResponse({
                        id: FLAG_ID,
                        enabled: stub.flagEnabled,
                        name: "Portfolio insights",
                        description: "Portfolio Insights demo feature",
                        isModifiable: true,
                        tag: "feature",
                    })
                )
            }
            if (method === "GET" && url === NOTIFICATIONS_URL) {
                stub.notificationRequests += 1
                const reply = stub.replies.shift() ?? stub.fallback
                if (Array.isArray(reply)) {
                    return Promise.resolve(serve(reply))
                }
                if (reply !== "hold" && "body" in reply) {
                    const response = jsonResponse(reply.body)
                    stub.served.push(response)
                    return Promise.resolve(response)
                }
                if (reply !== "hold") {
                    return Promise.resolve(
                        new Response(null, { status: reply.status })
                    )
                }
                return new Promise<Response>((resolve) => {
                    stub.held.push({
                        release: (notifications) =>
                            resolve(serve(notifications)),
                    })
                })
            }
            const otherAccount = otherAccountPoll(url)
            if (method === "GET" && otherAccount !== null) {
                stub.otherAccountPolls.push(otherAccount)
                return Promise.resolve(serve([]))
            }
            return Promise.reject(
                new Error(`Unexpected request ${method} ${url}`)
            )
        }
    )
    return stub
}

/** Answers the oldest held notification poll with `notifications`. */
function releaseHeldPoll(stub: FetchStub, notifications: Alert[]): void {
    const poll = stub.held.shift()
    if (poll === undefined) throw new Error("No notification poll is held")
    poll.release(notifications)
}

// Toasts dismiss themselves after 4 s, and a 15 s poll outlives that, so the
// recorder keeps every Toast ever added instead of counting visible nodes.
let toasts: string[] = []
let toastObserver: MutationObserver | null = null

function collectToasts(records: MutationRecord[]): void {
    for (const record of records) {
        record.addedNodes.forEach((node) => {
            if (!(node instanceof Element)) return
            const added = node.matches(".toast")
                ? [node]
                : Array.from(node.querySelectorAll(".toast"))
            for (const toast of added) {
                toasts.push(
                    toast.querySelector(".toast-message")?.textContent ?? ""
                )
            }
        })
    }
}

function startToastRecorder(): void {
    toasts = []
    toastObserver = new MutationObserver(collectToasts)
    toastObserver.observe(document.body, { childList: true, subtree: true })
}

/** Every Toast message shown so far, dismissed ones included. */
function shownToasts(): string[] {
    // Records not yet delivered to the callback are drained here, so an
    // assertion never depends on when the observer callback runs.
    if (toastObserver !== null) collectToasts(toastObserver.takeRecords())
    return toasts
}

let clients: QueryClient[] = []

/** A client as the app holds it while the flag is on. */
function newClient(): QueryClient {
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false } },
    })
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, true)
    clients.push(client)
    return client
}

function seedInstruments(client: QueryClient): void {
    client.setQueryData<Instrument[]>(
        instrumentKeys.byUser(ACCOUNT_ID),
        instruments
    )
}

/**
 * The watcher under the providers `ProtectedLayout` gives it, signed in as
 * `userId`, with `probe`, when given, just before it. Passing the tree with
 * another `userId` to `rerender` switches the account the way the auth
 * provider does, without remounting anything.
 */
function watcherTree(
    client: QueryClient,
    userId: string,
    probe?: ReactNode
): ReactElement {
    return (
        <QueryClientProvider client={client}>
            <UserContextProvider userId={userId} logoutHandler={vi.fn()}>
                <ToastWrapper>
                    {probe}
                    <AlertNotificationWatcher />
                </ToastWrapper>
            </UserContextProvider>
        </QueryClientProvider>
    )
}

/** Renders the watcher for `ACCOUNT_ID`, with `probe`, when given, just before it. */
function renderWatcher(client: QueryClient, probe?: ReactNode): RenderResult {
    return render(watcherTree(client, ACCOUNT_ID, probe))
}

/**
 * Renders the watcher for `ACCOUNT_ID`, with `probe` just before it.
 * `switchAccount` moves the tab to another account in place, as
 * `AuthProvider` does: it stores the id as the session user, then re-renders
 * the user provider with it.
 */
function renderSwitchableWatcher(
    client: QueryClient,
    probe: ReactNode
): { switchAccount: (userId: string) => void } {
    const { rerender } = render(watcherTree(client, ACCOUNT_ID, probe))
    return {
        switchAccount: (userId) => {
            sessionStorage.setItem(SESSION_KEY, userId)
            rerender(watcherTree(client, userId, probe))
        },
    }
}

/** A change of the tab's account, session, activation or shared flag state. */
type Transition = (target: QueryClient) => void

/**
 * Runs `transition` once, from a layout effect of the commit that first
 * renders a triggered notification. React runs every layout effect of a
 * commit before any of its passive effects, so the transition lands after
 * the watcher rendered that poll and before its Toast effect runs.
 */
function TransitionBeforeToastEffect({
    client,
    transition,
}: {
    client: QueryClient
    transition: Transition
}): null {
    // Observes the watcher's cache entry without polling it.
    const { data } = useAlertNotificationsQuery(ACCOUNT_ID, false)
    const landed = useRef(false)
    useLayoutEffect(() => {
        if (landed.current) return
        if (data?.some((alert) => alert.triggeredAt !== null) !== true) return
        landed.current = true
        transition(client)
    }, [client, data, transition])
    return null
}

/** Advances the fake clock and lets the work it starts settle and render. */
async function advance(ms: number): Promise<void> {
    await act(async () => {
        await vi.advanceTimersByTimeAsync(ms)
    })
}

/**
 * Lets work already started settle without moving the clock to a poll: the
 * advance yields one real macrotask, which drains every pending response
 * chain, and `act` flushes the renders and effects it causes.
 */
async function settle(): Promise<void> {
    await advance(0)
}

/**
 * Waits until the app has read every notification response handed out so
 * far, then lets their outcome settle, so a Toast still absent afterwards was
 * never going to be shown.
 */
async function servedPollsSettled(stub: FetchStub): Promise<void> {
    await waitFor(() =>
        expect(stub.served.every((response) => response.bodyUsed)).toBe(true)
    )
    await settle()
}

describe("AlertNotificationWatcher", () => {
    let client: QueryClient
    let stub: FetchStub

    beforeEach(() => {
        // Query-core delivers notifications through a zero-delay timer, which
        // fake timers would defer; microtasks keep delivery on the same tick.
        notifyManager.setScheduler(queueMicrotask)
        vi.useFakeTimers({ shouldAdvanceTime: true })
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        stub = stubFetch()
        client = newClient()
        startToastRecorder()
    })

    afterEach(() => {
        // Unmount first, so nothing below starts a poll.
        cleanup()
        while (stub.held.length > 0) releaseHeldPoll(stub, [])
        toastObserver?.disconnect()
        toastObserver = null
        notifyManager.setScheduler(defaultScheduler)
        vi.useRealTimers()
        vi.restoreAllMocks()
        // Also drops the tracker's stored record of shown notifications. Keys
        // whose write failed stay in the page's memory, hence the unique ids
        // in the failed-write case.
        sessionStorage.clear()
        for (const used of clients) used.clear()
        clients = []
    })

    it.each<{
        repeat: string
        pollAgain: (first: RenderResult) => Promise<void>
    }>([
        {
            repeat: "on the next poll",
            pollAgain: () => advance(POLL_INTERVAL_MS),
        },
        {
            // An identical poll keeps the cached data reference, but its new
            // `dataUpdatedAt` runs delivery again, so the first row is held
            // back by the shown-notification record too. A reload starts from
            // an empty cache, so only the tab's sessionStorage record keeps
            // the same notification from toasting again.
            repeat: "after a tab reload",
            pollAgain: (first) => {
                first.unmount()
                const reloaded = newClient()
                seedInstruments(reloaded)
                renderWatcher(reloaded)
                return settle()
            },
        },
    ])(
        "watcher_sameNotificationPolledTwice_toastsOnce ($repeat)",
        async ({ pollAgain }) => {
            stub.replies = [[triggeredAlert], [triggeredAlert]]
            seedInstruments(client)
            const first = renderWatcher(client)
            await waitFor(() => expect(shownToasts()).toHaveLength(1))

            await pollAgain(first)
            await waitFor(() => expect(stub.notificationRequests).toBe(2))
            await servedPollsSettled(stub)

            expect(shownToasts()).toHaveLength(1)
        }
    )

    it("watcher_newArmingRevision_toastsAgain", async () => {
        stub.replies = [
            [triggeredAlert],
            [
                {
                    ...triggeredAlert,
                    armingRevision: 2,
                    triggeredAt: "2026-01-01T11:00:00Z",
                },
            ],
        ]
        renderWatcher(client)
        await waitFor(() => expect(shownToasts()).toHaveLength(1))

        await advance(POLL_INTERVAL_MS)

        await waitFor(() => expect(shownToasts()).toHaveLength(2))
    })

    // A notification without its trigger time and value breaks the read's
    // contract, so the whole poll fails: no row toasts, not even a triggered
    // one beside it, and nothing is recorded as shown, so a valid poll later
    // still toasts it.
    it.each<{ poll: string; beside: Alert[]; field: string }>([
        { poll: "alone", beside: [], field: "results[0].triggeredAt" },
        {
            poll: "after a triggered row",
            beside: [triggeredAlert],
            field: "results[1].triggeredAt",
        },
    ])(
        "watcher_untriggeredNotification_showsNoToast ($poll)",
        async ({ beside, field }) => {
            const consoleError = vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined)
            const untriggered: Alert = {
                ...triggeredAlert,
                id: "a0000000-0000-4000-8000-000000000002",
                triggeredAt: null,
                triggerValue: null,
            }
            const polled = [...beside, untriggered]
            stub.fallback = polled
            seedInstruments(client)
            renderWatcher(client, <p>protected content</p>)

            // Ordinary failures keep query-core's default three retries.
            await advance(DEFAULT_RETRY_BACKOFF_MS)
            await waitFor(() =>
                expect(consoleError).toHaveBeenCalledWith(
                    "[AlertNotificationWatcher] notification poll failed",
                    expect.objectContaining({
                        name: "InvalidResponseError",
                        field,
                    })
                )
            )

            expect({
                content: screen.queryByText("protected content") !== null,
                toasts: shownToasts(),
                recorded: polled.filter((notification) =>
                    hasBeenShown(notificationKey(notification))
                ),
            }).toEqual({ content: true, toasts: [], recorded: [] })
        }
    )

    it("watcher_flagDisabled_doesNotFetch", async () => {
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        stub.flagEnabled = false
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, false)
        renderWatcher(client)

        await advance(POLL_INTERVAL_MS)
        await advance(POLL_INTERVAL_MS)
        // The mount read and both polls ran, so the watcher was observing.
        await waitFor(() => expect(stub.flagRequests).toBeGreaterThanOrEqual(3))

        expect(stub.notificationRequests).toBe(0)
    })

    it("watcher_noAccount_doesNotFetch", async () => {
        // An empty stored id still counts as logged in, so `ProtectedLayout`
        // mounts the watcher with it.
        sessionStorage.setItem(SESSION_KEY, "")
        render(watcherTree(client, ""))

        await advance(POLL_INTERVAL_MS)
        await advance(POLL_INTERVAL_MS)
        // The mount read and both polls ran and kept the flag on, so the
        // watcher was observing and only the missing account stopped polls.
        await waitFor(() => expect(stub.flagRequests).toBeGreaterThanOrEqual(3))
        expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
            true
        )

        // No poll for any account, the empty one included.
        expect(stub.otherAccountPolls).toEqual([])
    })

    it("watcher_flagDisabledWithCachedNotifications_showsNoToast", async () => {
        vi.spyOn(console, "info").mockImplementation(() => undefined)
        stub.flagEnabled = false
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, false)
        // A disabled query still hands its cached data to the watcher.
        client.setQueryData<Alert[]>(alertKeys.notifications(ACCOUNT_ID), [
            triggeredAlert,
        ])
        renderWatcher(client)
        await waitFor(() => expect(stub.flagRequests).toBe(1))
        await settle()

        expect(shownToasts()).toEqual([])
    })

    it("watcher_pollForbidden_shutsDownFeature", async () => {
        // The flag service still answers `true`, so only the 403 can turn the
        // shared flag state off.
        stub.fallback = { status: 403 }
        renderWatcher(client)

        await waitFor(() =>
            expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
                false
            )
        )
    })

    // A malformed 200 must fail the poll, not the watcher's effect, which
    // would otherwise take the protected route down with it.
    it.each<{ variant: string; body: unknown; field: string }>([
        {
            variant: "results not an array",
            body: { results: {} },
            field: "results",
        },
        {
            variant: "null entry",
            body: { results: [triggeredAlert, null] },
            field: "results[1]",
        },
    ])(
        "watcher_malformedPoll_logsPollErrorKeepsContent ($variant)",
        async ({ body, field }) => {
            const consoleError = vi
                .spyOn(console, "error")
                .mockImplementation(() => undefined)
            stub.fallback = { body }
            seedInstruments(client)
            renderWatcher(client, <p>protected content</p>)

            // Ordinary failures keep query-core's default three retries.
            await advance(DEFAULT_RETRY_BACKOFF_MS)
            await waitFor(() =>
                expect(consoleError).toHaveBeenCalledWith(
                    "[AlertNotificationWatcher] notification poll failed",
                    expect.objectContaining({
                        name: "InvalidResponseError",
                        field,
                    })
                )
            )

            expect({
                content: screen.queryByText("protected content") !== null,
                toasts: shownToasts(),
            }).toEqual({ content: true, toasts: [] })
        }
    )

    // The parser's error for a body that is not JSON quotes the body; only the
    // content-safe error of the parse boundary may reach the console.
    it("watcher_malformedJsonPoll_logsNeitherBodyNorAccountId", async () => {
        const marker = "LEAK5c9e"
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
        const answer = vi.mocked(window).fetch.getMockImplementation()
        vi.mocked(window).fetch.mockImplementation((input, init) =>
            requestUrl(input) === NOTIFICATIONS_URL
                ? Promise.resolve(
                      new Response(`<${marker}>`, {
                          status: 200,
                          headers: { "Content-Type": "application/json" },
                      })
                  )
                : answer === undefined
                  ? Promise.reject(new Error("fetch is not stubbed"))
                  : answer(input, init)
        )
        renderWatcher(client)

        // Ordinary failures keep query-core's default three retries.
        await advance(DEFAULT_RETRY_BACKOFF_MS)
        await waitFor(() =>
            expect(spies.error).toHaveBeenCalledWith(
                "[AlertNotificationWatcher] notification poll failed",
                expect.anything()
            )
        )

        const logged = spies.error.mock.calls.find(
            ([message]) =>
                message ===
                "[AlertNotificationWatcher] notification poll failed"
        )?.[1] as Error
        const shown = Object.values(spies)
            .flatMap((spy): unknown[] => spy.mock.calls.flat())
            .map(consoleText)
            .join("\n")
        expect({
            loggedName: logged.name,
            leaked: [marker, `accountId=${ACCOUNT_ID}`].filter((part) =>
                shown.includes(part)
            ),
        }).toEqual({ loggedName: "MalformedJsonError", leaked: [] })
    })

    it("watcher_pollFailed_logsFullError", async () => {
        const consoleError = vi
            .spyOn(console, "error")
            .mockImplementation(() => undefined)
        stub.fallback = { status: 500 }
        renderWatcher(client)

        // Ordinary failures keep query-core's default three retries.
        await advance(DEFAULT_RETRY_BACKOFF_MS)

        await waitFor(() =>
            expect(consoleError).toHaveBeenCalledWith(
                "[AlertNotificationWatcher] notification poll failed",
                expect.objectContaining({ name: "ApiError", status: 500 })
            )
        )
    })

    it("watcher_pollFailed_logsEndpointTemplateWithoutAccountId", async () => {
        const consoleError = vi
            .spyOn(console, "error")
            .mockImplementation(() => undefined)
        stub.fallback = { status: 500 }
        renderWatcher(client)
        await advance(DEFAULT_RETRY_BACKOFF_MS)
        await waitFor(() =>
            expect(consoleError).toHaveBeenCalledWith(
                "[AlertNotificationWatcher] notification poll failed",
                expect.anything()
            )
        )

        const logged = consoleError.mock.calls.find(
            ([message]) =>
                message ===
                "[AlertNotificationWatcher] notification poll failed"
        )?.[1] as Error & { status?: number; endpoint?: string }
        const queryError = client.getQueryState(
            alertKeys.notifications(ACCOUNT_ID)
        )?.error

        expect({
            logged: {
                name: logged.name,
                status: logged.status,
                endpoint: logged.endpoint,
                message: logged.message,
                stackHasAccountId: (logged.stack ?? "").includes(
                    `accountId=${ACCOUNT_ID}`
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
                endpoint:
                    "/broker-service/v1/alerts/notifications?accountId={value}&unacknowledged={value}",
                message:
                    "HTTP 500 for /broker-service/v1/alerts/notifications?accountId={value}&unacknowledged={value}",
                stackHasAccountId: false,
            },
            queryError: { isApiError: true, url: NOTIFICATIONS_URL },
        })
    })

    it.each<{
        transition: string
        run: (target: QueryClient) => Promise<unknown>
    }>([
        {
            transition: "after flag off",
            run: (target) => {
                onPortfolioInsightsDisabled(target)
                return Promise.resolve()
            },
        },
        {
            transition: "after logout",
            run: (target) => {
                sessionStorage.removeItem(SESSION_KEY)
                invalidateOnLogout(target)
                return Promise.resolve()
            },
        },
        {
            // The fresh read starts after the shutdown, so it publishes
            // `true` and the watcher polls again; that poll answers `[]`.
            transition: "after a quick off and on",
            run: (target) => {
                onPortfolioInsightsDisabled(target)
                return target.query(portfolioInsightsFlagQuery(target))
            },
        },
    ])("watcher_lateResponse_discarded ($transition)", async ({ run }) => {
        stub.replies = ["hold"]
        renderWatcher(client)
        await waitFor(() => expect(stub.held).toHaveLength(1))

        await act(async () => {
            await run(client)
        })
        releaseHeldPoll(stub, [triggeredAlert])
        await servedPollsSettled(stub)

        expect(shownToasts()).toEqual([])
    })

    it("watcher_lateResponse_discarded (after an account switch away and back)", async () => {
        stub.replies = ["hold"]
        const view = renderWatcher(client)
        await waitFor(() => expect(stub.held).toHaveLength(1))

        // The auth provider stores the account, then renders it.
        sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
        view.rerender(watcherTree(client, OTHER_ACCOUNT_ID))
        // The watcher observes the other account: its poll ran and applied.
        await waitFor(() =>
            expect(
                client.getQueryData(alertKeys.notifications(OTHER_ACCOUNT_ID))
            ).toEqual([])
        )
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        view.rerender(watcherTree(client, ACCOUNT_ID))
        // No logout and no shutdown ran, so the cache still holds the first
        // account's poll and only the session check can discard its result.
        releaseHeldPoll(stub, [triggeredAlert])
        // The discarded fetch is re-run for the account the tab is signed in
        // to again, so the cache ends with that current poll, which answers
        // no notifications.
        await waitFor(() => expect(stub.notificationRequests).toBe(2))
        await servedPollsSettled(stub)

        expect({
            toasts: shownToasts(),
            notifications: client.getQueryData(
                alertKeys.notifications(ACCOUNT_ID)
            ),
        }).toEqual({ toasts: [], notifications: [] })
    })

    it.each<{ transition: string; run: Transition }>([
        {
            transition: "flag off",
            run: (target) => onPortfolioInsightsDisabled(target),
        },
        {
            // The activation is unchanged, so only the shared flag state
            // shows that the feature is off.
            transition: "the shared flag state turning false",
            run: (target) =>
                target.setQueryData<boolean>(
                    featureFlagKeys.portfolioInsights,
                    false
                ),
        },
        {
            transition: "logout",
            run: (target) => {
                sessionStorage.removeItem(SESSION_KEY)
                invalidateOnLogout(target)
            },
        },
        {
            transition: "an account switch away and back",
            run: (target) => {
                sessionStorage.setItem(SESSION_KEY, "2")
                invalidateOnLogout(target)
                sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
            },
        },
    ])(
        "watcher_transitionBeforeToastEffect_deliversNothing ($transition)",
        async ({ run }) => {
            stub.replies = [[triggeredAlert]]
            const transition = vi.fn(run)
            renderWatcher(
                client,
                <TransitionBeforeToastEffect
                    client={client}
                    transition={transition}
                />
            )
            await waitFor(() => expect(transition).toHaveBeenCalledTimes(1))
            await servedPollsSettled(stub)

            // No Toast, and no record that would hold this arming back once
            // the feature or the account returns.
            expect({
                toasts: shownToasts(),
                recorded: hasBeenShown(notificationKey(triggeredAlert)),
            }).toEqual({ toasts: [], recorded: false })
        }
    )

    it("watcher_shutdownBeforeToastEffectThenResume_toastsArmingOnce", async () => {
        // Every poll answers the same arming.
        stub.fallback = [triggeredAlert]
        seedInstruments(client)
        const shutdown = vi.fn(onPortfolioInsightsDisabled)
        renderWatcher(
            client,
            <TransitionBeforeToastEffect
                client={client}
                transition={shutdown}
            />
        )
        await waitFor(() => expect(shutdown).toHaveBeenCalledTimes(1))
        await servedPollsSettled(stub)
        const toastsBeforeResume = shownToasts().length
        const pollsBeforeResume = stub.notificationRequests

        // A flag read that starts after the shutdown publishes `true`, so the
        // watcher polls again.
        await act(async () => {
            await client.query(portfolioInsightsFlagQuery(client))
        })
        await waitFor(() =>
            expect(stub.notificationRequests).toBeGreaterThan(pollsBeforeResume)
        )
        await servedPollsSettled(stub)

        expect(shownToasts().slice(toastsBeforeResume)).toEqual([
            "Alert triggered: EasyTravel Price above 10 (now 10.5)",
        ])
    })

    it.each<{ cache: string; seed: (notifications: Alert[]) => void }>([
        {
            // The session has moved to another account before the watcher
            // re-renders, so its own poll sends nothing, and the entry of the
            // account it still shows holds a poll that a current request for
            // the other account produced.
            cache: "produced for another account",
            seed: (notifications) => {
                sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
                recordFeatureResultContext(
                    notifications,
                    captureFeatureContext()
                )
            },
        },
        {
            // Written into the cache by no request at all; the watcher's own
            // poll is held, so the written entry stays.
            cache: "written without a request",
            seed: () => {
                stub.replies = ["hold"]
            },
        },
    ])(
        "watcher_cachedPollNotProducedForAccountShown_showsNoToast ($cache)",
        async ({ seed }) => {
            const notifications = [triggeredAlert]
            seed(notifications)
            client.setQueryData<Alert[]>(
                alertKeys.notifications(ACCOUNT_ID),
                notifications
            )
            renderWatcher(client)
            await waitFor(() => expect(stub.flagRequests).toBe(1))
            await settle()

            expect({
                toasts: shownToasts(),
                recorded: hasBeenShown(notificationKey(triggeredAlert)),
            }).toEqual({ toasts: [], recorded: false })
        }
    )

    it("watcher_cachedPollAfterSwitchAwayAndBack_toastsOnlyOnFreshPoll", async () => {
        // The first poll answers the arming; the poll the return to the
        // account starts is held, then answers the same arming.
        stub.replies = [[triggeredAlert], "hold"]
        seedInstruments(client)
        // The tab stores the other account as its session user before it
        // re-renders with it, as `AuthProvider` does, so the first poll is
        // not delivered.
        const storeOtherAccount = vi.fn(() => {
            sessionStorage.setItem(SESSION_KEY, OTHER_ACCOUNT_ID)
        })
        const { switchAccount } = renderSwitchableWatcher(
            client,
            <TransitionBeforeToastEffect
                client={client}
                transition={storeOtherAccount}
            />
        )
        await waitFor(() => expect(storeOtherAccount).toHaveBeenCalledTimes(1))
        await servedPollsSettled(stub)

        // Away and back in place, while the first poll stays cached.
        switchAccount(OTHER_ACCOUNT_ID)
        await servedPollsSettled(stub)
        switchAccount(ACCOUNT_ID)
        await waitFor(() => expect(stub.held).toHaveLength(1))
        await settle()
        const beforeFreshPoll = {
            toasts: [...shownToasts()],
            recorded: hasBeenShown(notificationKey(triggeredAlert)),
        }

        releaseHeldPoll(stub, [triggeredAlert])
        await servedPollsSettled(stub)

        expect({ beforeFreshPoll, afterFreshPoll: shownToasts() }).toEqual({
            beforeFreshPoll: { toasts: [], recorded: false },
            afterFreshPoll: [
                "Alert triggered: EasyTravel Price above 10 (now 10.5)",
            ],
        })
    })

    it.each<{
        cache: string
        seedCache: (target: QueryClient) => void
        expected: string
    }>([
        {
            cache: "seeded",
            seedCache: seedInstruments,
            expected: "Alert triggered: EasyTravel Price above 10 (now 10.5)",
        },
        {
            // The watcher never requests instruments itself.
            cache: "empty",
            seedCache: () => undefined,
            expected:
                "Alert triggered: instrument c0000000 Price above 10 (now 10.5)",
        },
    ])(
        "watcher_instrumentName_resolved ($cache instruments cache)",
        async ({ seedCache, expected }) => {
            stub.replies = [[triggeredAlert]]
            seedCache(client)
            renderWatcher(client)

            await waitFor(() => expect(shownToasts()).toEqual([expected]))
        }
    )

    // TARGET_PRICE above is the fixture of the cases above.
    it.each<{
        type: AlertType
        direction: AlertDirection
        threshold: number
        triggerValue: number
        expected: string
    }>([
        {
            type: "PROFIT_LOSS",
            direction: "ABOVE",
            threshold: 5,
            triggerValue: 5.25,
            expected: "Alert triggered: EasyTravel P/L above 5 (now 5.25)",
        },
        {
            type: "TARGET_PRICE",
            direction: "BELOW",
            threshold: 10,
            triggerValue: 9.75,
            expected: "Alert triggered: EasyTravel Price below 10 (now 9.75)",
        },
        {
            type: "PROFIT_LOSS",
            direction: "BELOW",
            threshold: -2.5,
            triggerValue: -3,
            expected: "Alert triggered: EasyTravel P/L below -2.5 (now -3)",
        },
    ])(
        "watcher_typeAndDirection_toastsMatchingMessage ($type $direction)",
        async ({ expected, ...condition }) => {
            stub.replies = [[{ ...triggeredAlert, ...condition }]]
            seedInstruments(client)
            renderWatcher(client)

            await waitFor(() => expect(shownToasts()).toEqual([expected]))
        }
    )

    it("watcher_storageWriteFails_changedPollDoesNotRepeatToast", async () => {
        // Ids no other case uses: a key whose write failed stays in the
        // tracker's memory for the rest of this file.
        const alertX: Alert = {
            ...triggeredAlert,
            id: "a0000000-0000-4000-8000-0000000000f1",
        }
        const alertY: Alert = {
            ...triggeredAlert,
            id: "a0000000-0000-4000-8000-0000000000f2",
            direction: "BELOW",
            threshold: 11,
            triggerValue: 10.75,
        }
        vi.spyOn(console, "error").mockImplementation(() => undefined)
        // Bound before the spy replaces it; the app writes only sessionStorage.
        const storeItem = Storage.prototype.setItem.bind(sessionStorage)
        vi.spyOn(Storage.prototype, "setItem").mockImplementation(
            (key, value) => {
                if (key === NOTIFIED_STORAGE_KEY) {
                    throw new DOMException("quota", "QuotaExceededError")
                }
                storeItem(key, value)
            }
        )
        // The second poll changes the data, so the Toast effect runs again.
        stub.replies = [[alertX], [alertX, alertY]]
        seedInstruments(client)
        renderWatcher(client)
        await waitFor(() => expect(shownToasts()).toHaveLength(1))

        await advance(POLL_INTERVAL_MS)
        await waitFor(() => expect(stub.notificationRequests).toBe(2))
        await servedPollsSettled(stub)

        expect(shownToasts()).toEqual([
            "Alert triggered: EasyTravel Price above 10 (now 10.5)",
            "Alert triggered: EasyTravel Price below 11 (now 10.75)",
        ])
    })
})
