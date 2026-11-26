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
    waitFor,
} from "@testing-library/react"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { AlertNotificationWatcher } from "../../components/insights/AlertNotificationWatcher"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import { portfolioInsightsFlagQuery } from "../../hooks/useFeatureFlags"
import { NOTIFIED_STORAGE_KEY } from "../../utils/alertNotificationTracker"
import { onPortfolioInsightsDisabled } from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    instrumentKeys,
    invalidateOnLogout,
} from "../../utils/queryKeys"
import { ToastWrapper, UserContextWrapper } from "../providers"

/** The account `UserContextWrapper` provides. */
const ACCOUNT_ID = "1"

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

/** The notification and flag poll interval on a visible tab. */
const POLL_INTERVAL_MS = 15_000

/** Query-core's default delays before its three retries: 1 s, 2 s, 4 s. */
const DEFAULT_RETRY_BACKOFF_MS = 1_000 + 2_000 + 4_000

const FLAG_ID = "portfolio-insights-enabled"

const FLAG_URL = `${window.location.origin}/feature-flag-service/v1/flags/${FLAG_ID}`

const NOTIFICATIONS_URL = `${window.location.origin}/broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`

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
 * One notification poll's answer: a 200 with these notifications, an error
 * status, or `"hold"` to keep it pending until released.
 */
type NotificationReply = Alert[] | { status: number } | "hold"

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
 * Answers the two requests the watcher makes, the flag read and the
 * notification poll, through `window.fetch`, which `api/http.ts` calls.
 * Anything else is rejected, so an unexpected request fails loudly.
 */
function stubFetch(): FetchStub {
    const stub: FetchStub = {
        flagEnabled: true,
        replies: [],
        fallback: [],
        flagRequests: 0,
        notificationRequests: 0,
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

function renderWatcher(client: QueryClient): RenderResult {
    return render(
        <QueryClientProvider client={client}>
            <UserContextWrapper>
                <ToastWrapper>
                    <AlertNotificationWatcher />
                </ToastWrapper>
            </UserContextWrapper>
        </QueryClientProvider>
    )
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
            // An identical poll keeps the cached data reference, so the first
            // row never reaches the shown-notification record. A reload starts
            // from an empty cache, so only the tab's sessionStorage record
            // keeps the same notification from toasting again.
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
            transition: "after an account switch away and back",
            run: (target) => {
                sessionStorage.setItem(SESSION_KEY, "2")
                invalidateOnLogout(target)
                sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
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
