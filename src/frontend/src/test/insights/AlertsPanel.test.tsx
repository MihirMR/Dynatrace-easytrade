import "@testing-library/jest-dom/vitest"
import {
    act,
    cleanup,
    fireEvent,
    render,
    screen,
    waitFor,
    within,
} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import {
    QueryClient,
    QueryClientProvider,
    defaultScheduler,
    focusManager,
    notifyManager,
    useIsFetching,
    type QueryKey,
} from "@tanstack/react-query"
import { AlertNotificationWatcher } from "../../components/insights/AlertNotificationWatcher"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import {
    FormatterWrapper,
    ToastWrapper,
    UserContextWrapper,
} from "../providers"
import { ApiError } from "../../api/http"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { onPortfolioInsightsDisabled } from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    invalidateOnLogout,
} from "../../utils/queryKeys"

// Covers the panel's own wiring: its two queries' loading, error and 403
// states, how mutation results reach the form, rows and notifications, and
// how pending, failure and confirmation state is kept per row and account,
// that a repeated submit sends one create, and where focus goes when panel
// feedback is dismissed or an action settles.
// Mutation outcomes themselves are covered by AlertMutations.test.tsx.

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

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

const armedAlert: Alert = {
    id: "a1000000-0000-4000-8000-000000000001",
    accountId: "1",
    instrumentId: INSTRUMENT_ID,
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: 10,
    enabled: true,
    armingRevision: 1,
    triggeredAt: null,
    triggerValue: null,
    acknowledged: false,
    createdAt: "2026-01-01T09:00:00Z",
}

const triggeredAlert: Alert = {
    ...armedAlert,
    id: "a1000000-0000-4000-8000-000000000002",
    triggeredAt: "2026-01-01T10:00:00Z",
    triggerValue: 10.5,
}

const createdAlert: Alert = {
    ...armedAlert,
    id: "a1000000-0000-4000-8000-000000000009",
}

/** A second notification, so two acknowledges can run side by side. */
const secondTriggeredAlert: Alert = {
    ...triggeredAlert,
    id: "a1000000-0000-4000-8000-000000000003",
    threshold: 12,
}

/** An alert of the account the panel switches to. */
const otherAccountAlert: Alert = {
    ...armedAlert,
    id: "b2000000-0000-4000-8000-000000000001",
    accountId: "2",
}

const ROW_NOT_FOUND_MESSAGE = "This alert no longer exists."
const GENERIC_MESSAGE = "Something went wrong. Please try again later."

const BROKER = `${window.location.origin}/broker-service/v1`
const LIST_URL = `${BROKER}/alerts?accountId=1`
const NOTIFICATIONS_URL = `${BROKER}/alerts/notifications?accountId=1&unacknowledged=true`
const OTHER_LIST_URL = `${BROKER}/alerts?accountId=2`
const OTHER_NOTIFICATIONS_URL = `${BROKER}/alerts/notifications?accountId=2&unacknowledged=true`

type StubResponse = { status: number; body?: unknown }
type Handler = () => StubResponse | Promise<StubResponse>
type User = ReturnType<typeof userEvent.setup>

function respond({ status, body }: StubResponse): Response {
    return new Response(body === undefined ? null : JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

/**
 * Answers broker requests by `METHOD url`, with defaults for the panel's two
 * queries, and fails the test on any request it does not expect.
 */
function stubFetch(handlers: Record<string, Handler>) {
    const defaults: Record<string, Handler> = {
        [`GET ${LIST_URL}`]: () => ({
            status: 200,
            body: { results: [armedAlert, triggeredAlert] },
        }),
        [`GET ${NOTIFICATIONS_URL}`]: () => ({
            status: 200,
            body: { results: [triggeredAlert] },
        }),
    }
    vi.spyOn(window, "fetch").mockImplementation(
        async (
            input: RequestInfo | URL,
            init?: RequestInit
        ): Promise<Response> => {
            const url =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            const key = `${init?.method ?? "GET"} ${url}`
            const handler = handlers[key] ?? defaults[key]
            if (handler === undefined) {
                throw new Error(`Unexpected request ${key}`)
            }
            return respond(await handler())
        }
    )
}

function hold(): { promise: Promise<void>; release: () => void } {
    let release: () => void = () => undefined
    const promise = new Promise<void>((resolve) => {
        release = resolve
    })
    return { promise, release }
}

let client: QueryClient
let releaseHeld: (() => void)[] = []

function heldHandler(response: StubResponse): Handler {
    return heldResponse(response).handler
}

/** A response sent once `release` runs; `afterEach` releases any left. */
function heldResponse(response: StubResponse): {
    handler: Handler
    release: () => void
} {
    const held = hold()
    releaseHeld.push(held.release)
    return {
        handler: async () => {
            await held.promise
            return response
        },
        release: held.release,
    }
}

function panelFor(accountId: string) {
    return (
        <QueryClientProvider client={client}>
            <FormatterWrapper>
                <AlertsPanel accountId={accountId} instruments={instruments} />
            </FormatterWrapper>
        </QueryClientProvider>
    )
}

function renderPanel() {
    return render(panelFor("1"))
}

function elementBySelector(selector: string): HTMLElement {
    const element = document.querySelector<HTMLElement>(selector)
    if (element === null) throw new Error(`No element matches ${selector}`)
    return element
}

function rowSelector(alertId: string): string {
    return `li[data-alert-id="${alertId}"]`
}

function notificationSelector(alertId: string): string {
    return `li.alert-notification[data-notification-id="${alertId}"]`
}

function rowOf(alertId: string): HTMLElement {
    return elementBySelector(rowSelector(alertId))
}

function notificationOf(alertId: string): HTMLElement {
    return elementBySelector(notificationSelector(alertId))
}

/** Whether every button of `region` is disabled, enabled, or a mix. */
function controlState(region: HTMLElement): "disabled" | "enabled" | "mixed" {
    const disabled = within(region)
        .getAllByRole("button")
        .map((button) => button.matches(":disabled"))
    if (disabled.every(Boolean)) return "disabled"
    return disabled.some(Boolean) ? "mixed" : "enabled"
}

/** The texts of the announced messages inside `region`. */
function messagesIn(region: HTMLElement): (string | null)[] {
    return within(region)
        .queryAllByRole("alert")
        .map((message) => message.textContent)
}

/** The `value` of every `output#alert-deleted-id`, in document order. */
function deletedOutputValues(): (string | null)[] {
    return Array.from(
        document.querySelectorAll("output#alert-deleted-id"),
        (output) => output.getAttribute("value")
    )
}

/**
 * One kind of row action, the two alerts it is run on and where the panel
 * renders that kind's controls and in-place messages.
 */
type RowAction = {
    kind: string
    first: Alert
    second: Alert
    request: (alertId: string) => string
    success: StubResponse
    start: (user: User, alertId: string) => Promise<void>
    selector: (alertId: string) => string
    /** How panel feedback names `first` once its row is gone. */
    firstLabel: string
}

function clickIn(user: User, region: HTMLElement, selector: string) {
    const button = region.querySelector<HTMLElement>(selector)
    if (button === null) throw new Error(`No ${selector} in region`)
    return user.click(button)
}

const updateAction: RowAction = {
    kind: "update-enabled",
    first: armedAlert,
    second: triggeredAlert,
    request: (alertId) => `PATCH ${BROKER}/alerts/${alertId}`,
    success: { status: 200, body: armedAlert },
    start: (user, alertId) =>
        clickIn(user, rowOf(alertId), "button.alert-toggle"),
    selector: rowSelector,
    firstLabel: "EasyTravel Price Above 10",
}

const deleteAction: RowAction = {
    kind: "delete",
    first: armedAlert,
    second: triggeredAlert,
    request: (alertId) => `DELETE ${BROKER}/alerts/${alertId}`,
    success: { status: 204 },
    start: (user, alertId) =>
        clickIn(user, rowOf(alertId), "button.alert-delete"),
    selector: rowSelector,
    firstLabel: "EasyTravel Price Above 10",
}

const acknowledgeAction: RowAction = {
    kind: "acknowledge",
    first: triggeredAlert,
    second: secondTriggeredAlert,
    request: (alertId) => `POST ${BROKER}/alerts/${alertId}/acknowledge`,
    success: { status: 204 },
    start: (user, alertId) =>
        clickIn(user, notificationOf(alertId), "button.alert-acknowledge"),
    selector: notificationSelector,
    firstLabel: "EasyTravel Price Above 10",
}

const rowActions: [string, RowAction][] = [
    [updateAction.kind, updateAction],
    [deleteAction.kind, deleteAction],
    [acknowledgeAction.kind, acknowledgeAction],
]

/**
 * List and notification answers rendering both alerts of every row action,
 * minus the ids in `gone`, so a case can drop a row from the next refetch.
 */
function bothRowsHandlers(gone: ReadonlySet<string> = new Set()) {
    const present = (alerts: Alert[]) =>
        alerts.filter((alert) => !gone.has(alert.id))
    return {
        [`GET ${LIST_URL}`]: () => ({
            status: 200,
            body: { results: present([armedAlert, triggeredAlert]) },
        }),
        [`GET ${NOTIFICATIONS_URL}`]: () => ({
            status: 200,
            body: {
                results: present([triggeredAlert, secondTriggeredAlert]),
            },
        }),
    }
}

async function waitForBothRows(action: RowAction): Promise<void> {
    await waitFor(() => {
        expect(
            document.querySelector(action.selector(action.first.id))
        ).not.toBeNull()
        expect(
            document.querySelector(action.selector(action.second.id))
        ).not.toBeNull()
    })
}

/** Ends the context of a write, as the app does, with no panel mounted. */
type ContextEnd = (target: QueryClient) => void

const contextEnds: [string, ContextEnd][] = [
    [
        "shutdown and resume",
        (target) => {
            onPortfolioInsightsDisabled(target)
            target.setQueryData(featureFlagKeys.portfolioInsights, true)
        },
    ],
    [
        "logout and same-account login",
        (target) => {
            sessionStorage.removeItem("user-id")
            invalidateOnLogout(target)
            sessionStorage.setItem("user-id", "1")
        },
    ],
]

/**
 * Starts `action` on its first alert with the response held, waits until
 * that row's controls are disabled and unmounts the panel.
 */
async function unmountWhileFirstRowPending(action: RowAction): Promise<void> {
    stubFetch({
        ...bothRowsHandlers(),
        [action.request(action.first.id)]: heldHandler(action.success),
    })
    const user = userEvent.setup({ delay: null })
    const { unmount } = renderPanel()
    await waitForBothRows(action)
    await action.start(user, action.first.id)
    await waitFor(() =>
        expect(
            controlState(elementBySelector(action.selector(action.first.id)))
        ).toBe("disabled")
    )
    unmount()
}

/**
 * A 404 for a row action on `alert`, sent once `held` resolves, after which
 * list and notification refreshes leave `alert` out.
 */
function notFoundDroppingRow(
    alert: Alert,
    gone: Set<string>,
    held?: Promise<void>
): Handler {
    return async () => {
        if (held !== undefined) await held
        gone.add(alert.id)
        return { status: 404 }
    }
}

/** Every Dismiss button of the panel's own feedback, in document order. */
function dismissButtons(): HTMLElement[] {
    return screen.queryAllByRole("button", { name: "Dismiss" })
}

/** The Dismiss button of the panel feedback about `alert`. */
function dismissOf(alert: Alert): HTMLElement {
    return elementBySelector(
        `button[aria-describedby^="alert-feedback-"][aria-describedby$="-${alert.id}"]`
    )
}

/**
 * Runs each action on its alert in turn, once that alert's row or
 * notification is shown, and waits until the failure has moved into panel
 * feedback, so the panel shows one entry per step.
 */
async function showPanelFeedback(
    user: User,
    steps: [RowAction, Alert][]
): Promise<void> {
    for (const [action, alert] of steps) {
        const shown = dismissButtons().length
        await waitFor(() =>
            expect(
                document.querySelector(action.selector(alert.id))
            ).not.toBeNull()
        )
        await action.start(user, alert.id)
        await waitFor(() => expect(dismissButtons()).toHaveLength(shown + 1))
    }
}

/** One way a user activates a button. */
type Activation = (user: User, button: HTMLElement) => Promise<void>

/** Pointer and keyboard activation; the keys act on the focused button. */
const dismissActivations: [string, Activation][] = [
    ["click", (user, button) => user.click(button)],
    [
        "Enter key",
        async (user, button) => {
            button.focus()
            await user.keyboard("{Enter}")
        },
    ],
    [
        "Space key",
        async (user, button) => {
            button.focus()
            await user.keyboard(" ")
        },
    ],
]

/**
 * Feedback entries to show, the alert whose entry is dismissed and the alert
 * whose Dismiss should then have focus.
 */
type DismissFocusCase = [string, [RowAction, Alert][], Alert, Alert]

const dismissFocusCases: DismissFocusCase[] = [
    ...rowActions.flatMap(([kind, action]): DismissFocusCase[] => {
        const steps: [RowAction, Alert][] = [
            [action, action.first],
            [action, action.second],
        ]
        return [
            [`${kind}, first of two`, steps, action.first, action.second],
            [`${kind}, last of two`, steps, action.second, action.first],
        ]
    }),
    [
        "middle of three, one per action",
        [
            [updateAction, armedAlert],
            [deleteAction, triggeredAlert],
            [acknowledgeAction, secondTriggeredAlert],
        ],
        triggeredAlert,
        secondTriggeredAlert,
    ],
]

/** Fills the create form with a valid alert, ready to submit. */
async function fillCreateForm(user: User): Promise<void> {
    await user.selectOptions(screen.getByLabelText("Instrument"), INSTRUMENT_ID)
    await user.type(screen.getByLabelText("Threshold"), "105.5")
}

/** One way to submit the filled form, and the id of the control it uses. */
type CreateSubmission = [string, (user: User) => Promise<void>, string]

const createSubmissions: CreateSubmission[] = [
    [
        "Enter in the threshold",
        (user) => user.type(screen.getByLabelText("Threshold"), "{Enter}"),
        "alert-threshold",
    ],
    [
        "Create alert clicked",
        (user) =>
            user.click(screen.getByRole("button", { name: "Create alert" })),
        "alert-submit",
    ],
]

const createOutcomes: [string, StubResponse][] = [
    ["created", { status: 201, body: createdAlert }],
    ["rejected", { status: 400 }],
]

/**
 * Leaves no element focused, as a browser does once the focused control is
 * disabled. jsdom keeps focus on a disabled control and ignores `blur()` on
 * it, so focus moves to a stand-in that is then removed.
 */
function dropFocus(): void {
    const standIn = document.createElement("button")
    document.body.append(standIn)
    act(() => {
        standIn.focus()
        standIn.remove()
    })
}

/**
 * Releases a held write inside `act` and resolves once at most
 * `stillPending` mutations are pending, so every render and effect that the
 * write's settle causes has run.
 */
async function releaseAndSettle(
    release: () => void,
    stillPending = 0
): Promise<void> {
    await act(async () => {
        const settled = new Promise<void>((resolve) => {
            const unsubscribe = client.getMutationCache().subscribe(() => {
                if (client.isMutating() <= stillPending) {
                    unsubscribe()
                    resolve()
                }
            })
        })
        release()
        await settled
    })
}

function panelHeading(): HTMLElement {
    return screen.getByRole("heading", { name: "Price and P/L alerts" })
}

function firstButtonOf(region: HTMLElement): HTMLElement {
    return within(region).getAllByRole("button")[0]
}

function acknowledgeOf(alert: Alert): HTMLElement {
    return within(notificationOf(alert.id)).getByRole("button", {
        name: "Acknowledge",
    })
}

/**
 * A broker serving `listed` and `notified`: a delete drops the alert from
 * both, as its notification goes with it, and an acknowledge from
 * `notified`.
 */
function removingHandlers(
    listed: Alert[],
    notified: Alert[]
): Record<string, Handler> {
    let list = listed
    let notifications = notified
    const without = (alerts: Alert[], id: string) =>
        alerts.filter((alert) => alert.id !== id)
    const handlers: Record<string, Handler> = {
        [`GET ${LIST_URL}`]: () => ({ status: 200, body: { results: list } }),
        [`GET ${NOTIFICATIONS_URL}`]: () => ({
            status: 200,
            body: { results: notifications },
        }),
    }
    for (const { id } of listed) {
        handlers[deleteAction.request(id)] = () => {
            list = without(list, id)
            notifications = without(notifications, id)
            return { status: 204 }
        }
    }
    for (const { id } of notified) {
        handlers[acknowledgeAction.request(id)] = () => {
            notifications = without(notifications, id)
            return { status: 204 }
        }
    }
    return handlers
}

const disabledAlert: Alert = { ...armedAlert, enabled: false }

/**
 * A row's toggle: the case, the row before it, the button pressed, the row
 * the broker then returns, and the name of the button that should then have
 * focus.
 */
type ToggleFocusCase = [string, Alert, string, Alert, string]

const toggleFocusCases: ToggleFocusCase[] = [
    [
        "armed, Disable",
        armedAlert,
        "button.alert-toggle",
        disabledAlert,
        "Enable",
    ],
    [
        "disabled, Enable",
        disabledAlert,
        "button.alert-toggle",
        armedAlert,
        "Disable",
    ],
    [
        "triggered, Re-arm",
        triggeredAlert,
        "button.alert-toggle",
        {
            ...triggeredAlert,
            armingRevision: 2,
            triggeredAt: null,
            triggerValue: null,
        },
        "Disable",
    ],
    [
        "triggered, Disable",
        triggeredAlert,
        "button.alert-disable",
        { ...triggeredAlert, enabled: false },
        "Enable",
    ],
]

/**
 * An action whose success removes its item: the alerts listed and notified
 * before it, the alert it runs on, and the control that should then have
 * focus.
 */
type RemovalFocusCase = {
    removed: string
    action: RowAction
    listed: Alert[]
    notified: Alert[]
    target: Alert
    focused: () => HTMLElement
}

const threeRows = [armedAlert, triggeredAlert, secondTriggeredAlert]
const twoNotifications = [triggeredAlert, secondTriggeredAlert]

const removalFocusCases: RemovalFocusCase[] = [
    {
        removed: "delete, middle of three rows",
        action: deleteAction,
        listed: threeRows,
        notified: [],
        target: triggeredAlert,
        focused: () => firstButtonOf(rowOf(secondTriggeredAlert.id)),
    },
    {
        removed: "delete, last of three rows",
        action: deleteAction,
        listed: threeRows,
        notified: [],
        target: secondTriggeredAlert,
        focused: () => firstButtonOf(rowOf(triggeredAlert.id)),
    },
    {
        removed: "delete, only row",
        action: deleteAction,
        listed: [armedAlert],
        notified: [],
        target: armedAlert,
        focused: panelHeading,
    },
    {
        removed: "acknowledge, first of two notifications",
        action: acknowledgeAction,
        listed: twoNotifications,
        notified: twoNotifications,
        target: triggeredAlert,
        focused: () => acknowledgeOf(secondTriggeredAlert),
    },
    {
        removed: "acknowledge, last of two notifications",
        action: acknowledgeAction,
        listed: twoNotifications,
        notified: twoNotifications,
        target: secondTriggeredAlert,
        focused: () => acknowledgeOf(triggeredAlert),
    },
    {
        removed: "acknowledge, only notification",
        action: acknowledgeAction,
        listed: [triggeredAlert],
        notified: [triggeredAlert],
        target: triggeredAlert,
        focused: panelHeading,
    },
]

/** Resolves once the panel shows the loaded list of account "2". */
async function waitForOtherAccountList(): Promise<void> {
    await waitFor(() => {
        expect(client.getQueryState(alertKeys.list("2"))?.status).toBe(
            "success"
        )
        expect(document.querySelector("ul#alerts-list")).not.toBeNull()
    })
}

/**
 * Shows how many fetches of `queryKey` are in flight. It re-renders in the
 * same batch as the panel's query observers, so once it reads 1 the panel
 * has rendered that fetch's state.
 */
function FetchingProbe({ queryKey }: { queryKey: QueryKey }) {
    const fetching = useIsFetching({ queryKey })
    return <span data-testid="region-fetching">{fetching}</span>
}

describe("AlertsPanel", () => {
    beforeEach(() => {
        sessionStorage.setItem("user-id", "1")
        // Retries keep their count but run without the back-off delay.
        client = new QueryClient({
            defaultOptions: { queries: { retryDelay: 0 } },
        })
        client.setQueryData(featureFlagKeys.portfolioInsights, true)
        vi.spyOn(console, "error").mockImplementation(() => undefined)
    })

    afterEach(async () => {
        // Unmount first, so a released response refetches nothing.
        cleanup()
        releaseHeld.forEach((release) => release())
        releaseHeld = []
        // The spies stay in place until every released mutation has settled.
        await waitFor(() => expect(client.isMutating()).toBe(0))
        sessionStorage.clear()
        vi.restoreAllMocks()
        client.clear()
    })

    it("alertsPanel_listPending_showsLoadingMessage", () => {
        stubFetch({
            [`GET ${LIST_URL}`]: heldHandler({
                status: 200,
                body: { results: [] },
            }),
        })
        renderPanel()

        const loading = screen.getByText("Loading alerts\u2026")
        expect(loading).toHaveClass("empty-state")
        expect(loading).toHaveAttribute("role", "status")
    })

    it("alertsPanel_notificationsPending_showsLoadingStatusUntilEmptyResult", async () => {
        stubFetch({
            [`GET ${NOTIFICATIONS_URL}`]: heldHandler({
                status: 200,
                body: { results: [] },
            }),
        })
        const { container } = renderPanel()
        // Once the list has loaded, the only status left is the
        // notifications region's own.
        await screen.findByText("Armed")
        expect(screen.getByRole("status")).toHaveTextContent(
            "Loading notifications\u2026"
        )

        releaseHeld.forEach((release) => release())

        await waitFor(() => expect(screen.queryByRole("status")).toBeNull())
        expect(container.querySelector("#alert-notifications")).toBeNull()
    })

    // A 200 that breaks the alert contract must fail like a 500, never in
    // render.
    it.each<[string, string, string, StubResponse, string]>([
        [
            "list",
            "status 500",
            LIST_URL,
            { status: 500 },
            "Could not load alerts. Please try again later.",
        ],
        [
            "notifications",
            "status 500",
            NOTIFICATIONS_URL,
            { status: 500 },
            "Could not load notifications. Please try again later.",
        ],
        [
            "list",
            "200 with non-array results",
            LIST_URL,
            { status: 200, body: { results: {} } },
            "Could not load alerts. Please try again later.",
        ],
        [
            "notifications",
            "200 with a null entry",
            NOTIFICATIONS_URL,
            { status: 200, body: { results: [triggeredAlert, null] } },
            "Could not load notifications. Please try again later.",
        ],
    ])(
        "alertsPanel_%sQueryFails_showsRegionError (%s)",
        async (_name, _failure, url, response, message) => {
            stubFetch({ [`GET ${url}`]: () => response })
            renderPanel()

            const error = await screen.findByText(message)
            expect(error).toHaveClass("status-message", "status-error")
            expect(error).toHaveAttribute("role", "alert")
        }
    )

    it.each([
        [
            "list",
            LIST_URL,
            alertKeys.list("1"),
            "Could not load alerts. Please try again later.",
        ],
        [
            "notifications",
            NOTIFICATIONS_URL,
            alertKeys.notifications("1"),
            "Could not load notifications. Please try again later.",
        ],
    ])(
        "alertsPanel_%sRefetchAfterFailure_keepsErrorWithoutLoadingStatus",
        async (_name, url, queryKey, message) => {
            let answer: Handler = () => ({ status: 500 })
            stubFetch({ [`GET ${url}`]: () => answer() })
            render(
                <QueryClientProvider client={client}>
                    <FormatterWrapper>
                        <AlertsPanel accountId="1" instruments={instruments} />
                        <FetchingProbe queryKey={queryKey} />
                    </FormatterWrapper>
                </QueryClientProvider>
            )
            const error = await screen.findByText(message)
            await waitFor(() => expect(client.isFetching()).toBe(0))
            answer = heldHandler({ status: 500 })

            // A query that never loaded is `pending` again while it
            // refetches; the panel keeps the same alert node, so the
            // message is not announced again on every poll.
            void client.refetchQueries({ queryKey })
            await waitFor(() =>
                expect(screen.getByTestId("region-fetching")).toHaveTextContent(
                    "1"
                )
            )

            expect(screen.getByText(message)).toBe(error)
            expect(screen.queryByRole("status")).toBeNull()
        }
    )

    it("alertsPanel_listQueryFails_logsFullError", async () => {
        stubFetch({ [`GET ${LIST_URL}`]: () => ({ status: 500 }) })
        renderPanel()

        await waitFor(() =>
            expect(console.error).toHaveBeenCalledWith(
                "[AlertsPanel] could not load alerts",
                expect.objectContaining({ name: "ApiError", status: 500 })
            )
        )
    })

    it("alertsPanel_listQueryFails_logsEndpointTemplateWithoutAccountId", async () => {
        stubFetch({ [`GET ${LIST_URL}`]: () => ({ status: 500 }) })
        renderPanel()
        await waitFor(() =>
            expect(console.error).toHaveBeenCalledWith(
                "[AlertsPanel] could not load alerts",
                expect.anything()
            )
        )

        const logged = vi
            .mocked(console.error)
            .mock.calls.find(
                ([message]) => message === "[AlertsPanel] could not load alerts"
            )?.[1] as Error & { status?: number; endpoint?: string }
        const queryError = client.getQueryState(alertKeys.list("1"))?.error

        expect({
            logged: {
                name: logged.name,
                status: logged.status,
                endpoint: logged.endpoint,
                message: logged.message,
                stackHasAccountId: (logged.stack ?? "").includes("accountId=1"),
            },
            queryError: {
                isApiError: queryError instanceof ApiError,
                url: queryError instanceof ApiError ? queryError.url : null,
            },
        }).toEqual({
            logged: {
                name: "ApiError",
                status: 500,
                endpoint: "/broker-service/v1/alerts?accountId={value}",
                message:
                    "HTTP 500 for /broker-service/v1/alerts?accountId={value}",
                stackHasAccountId: false,
            },
            queryError: { isApiError: true, url: LIST_URL },
        })
    })

    // The parser's error for a body that is not JSON quotes the body; only the
    // content-safe error of the parse boundary may reach the console.
    it("alertsPanel_listMalformedJsonBody_logsNeitherBodyNorAccountId", async () => {
        const marker = "LEAK7a3f"
        const spies = {
            error: vi.mocked(console.error),
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
        stubFetch({})
        const answer = vi.mocked(window).fetch.getMockImplementation()
        vi.mocked(window).fetch.mockImplementation((input, init) => {
            const url =
                typeof input === "string"
                    ? input
                    : input instanceof URL
                      ? input.href
                      : input.url
            if (`${init?.method ?? "GET"} ${url}` === `GET ${LIST_URL}`) {
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
        renderPanel()
        await waitFor(() =>
            expect(spies.error).toHaveBeenCalledWith(
                "[AlertsPanel] could not load alerts",
                expect.anything()
            )
        )

        const logged = spies.error.mock.calls.find(
            ([message]) => message === "[AlertsPanel] could not load alerts"
        )?.[1] as Error
        const shown = Object.values(spies)
            .flatMap((spy): unknown[] => spy.mock.calls.flat())
            .map(consoleText)
            .join("\n")
        expect({
            loggedName: logged.name,
            errorShown:
                screen.queryByText(
                    "Could not load alerts. Please try again later."
                ) !== null,
            leaked: [marker, "accountId=1"].filter((part) =>
                shown.includes(part)
            ),
        }).toEqual({
            loggedName: "MalformedJsonError",
            errorShown: true,
            leaked: [],
        })
    })

    it.each([
        ["list", LIST_URL],
        ["notifications", NOTIFICATIONS_URL],
    ])("alertsPanel_%sQueryForbidden_shutsDownFeature", async (_name, url) => {
        stubFetch({ [`GET ${url}`]: () => ({ status: 403 }) })
        renderPanel()

        await waitFor(() =>
            expect(client.getQueryData(featureFlagKeys.portfolioInsights)).toBe(
                false
            )
        )
    })

    it("alertsPanel_noNotifications_rendersNoNotificationsRegion", async () => {
        stubFetch({
            [`GET ${NOTIFICATIONS_URL}`]: () => ({
                status: 200,
                body: { results: [] },
            }),
        })
        renderPanel()
        await screen.findByText("Armed")

        expect(
            screen.queryByRole("heading", { name: "Notifications" })
        ).toBeNull()
    })

    it("alertsPanel_acknowledgePending_disablesAcknowledge", async () => {
        stubFetch({
            [`POST ${BROKER}/alerts/${triggeredAlert.id}/acknowledge`]:
                heldHandler({ status: 204 }),
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()
        const acknowledge = await screen.findByRole("button", {
            name: "Acknowledge",
        })

        await user.click(acknowledge)

        await waitFor(() => expect(acknowledge).toBeDisabled())
    })

    it("alertsPanel_acknowledgeNotFound_showsMessageBesideNotification", async () => {
        stubFetch({
            [`POST ${BROKER}/alerts/${triggeredAlert.id}/acknowledge`]: () => ({
                status: 404,
            }),
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()

        await user.click(
            await screen.findByRole("button", { name: "Acknowledge" })
        )

        expect(
            await within(notificationOf(triggeredAlert.id)).findByText(
                ROW_NOT_FOUND_MESSAGE
            )
        ).toHaveClass("field-error")
    })

    it.each(
        rowActions.flatMap(([kind, action]): [string, string, RowAction][] => [
            [kind, "first", action],
            [kind, "second", action],
        ])
    )(
        "alertsPanel_overlappingRowActions_keepEachRowPendingUntilItsOwnResponse (%s, %s settles first)",
        async (_kind, settlesFirst, action) => {
            const firstHeld = heldResponse(action.success)
            const secondHeld = heldResponse(action.success)
            stubFetch({
                ...bothRowsHandlers(),
                [action.request(action.first.id)]: firstHeld.handler,
                [action.request(action.second.id)]: secondHeld.handler,
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            const [settled, other] =
                settlesFirst === "first"
                    ? [
                          { alert: action.first, held: firstHeld },
                          { alert: action.second, held: secondHeld },
                      ]
                    : [
                          { alert: action.second, held: secondHeld },
                          { alert: action.first, held: firstHeld },
                      ]
            const stateOf = (alert: Alert) =>
                controlState(elementBySelector(action.selector(alert.id)))

            await action.start(user, action.first.id)
            await action.start(user, action.second.id)
            await waitFor(() =>
                expect([stateOf(action.first), stateOf(action.second)]).toEqual(
                    ["disabled", "disabled"]
                )
            )
            settled.held.release()
            await waitFor(() => expect(stateOf(settled.alert)).toBe("enabled"))
            const otherWhileSettledDone = stateOf(other.alert)
            other.held.release()
            await waitFor(() => expect(stateOf(other.alert)).toBe("enabled"))

            expect(otherWhileSettledDone).toBe("disabled")
        }
    )

    it.each(
        rowActions.flatMap(([kind, action]) =>
            contextEnds.map(
                ([ending, end]): [string, string, RowAction, ContextEnd] => [
                    kind,
                    ending,
                    action,
                    end,
                ]
            )
        )
    )(
        "alertsPanel_remountedAfterPendingWriteContextEnded_showsControlsEnabled (%s, %s)",
        async (_kind, _ending, action, end) => {
            await unmountWhileFirstRowPending(action)

            end(client)
            renderPanel()

            // The held write is still in flight, and its result is discarded.
            await waitFor(() =>
                expect(
                    controlState(
                        elementBySelector(action.selector(action.first.id))
                    )
                ).toBe("enabled")
            )
        }
    )

    it.each(rowActions)(
        "alertsPanel_remountedWhilePendingWriteContextCurrent_showsControlsDisabled (%s)",
        async (_kind, action) => {
            await unmountWhileFirstRowPending(action)

            renderPanel()
            await waitForBothRows(action)

            expect(
                controlState(
                    elementBySelector(action.selector(action.first.id))
                )
            ).toBe("disabled")
        }
    )

    it.each(rowActions)(
        "alertsPanel_failuresOnTwoRows_showsEachBesideItsRow (%s)",
        async (_kind, action) => {
            const notFound = heldResponse({ status: 404 })
            const failed = heldResponse({ status: 500 })
            stubFetch({
                ...bothRowsHandlers(),
                [action.request(action.first.id)]: notFound.handler,
                [action.request(action.second.id)]: failed.handler,
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)

            // Both requests are in flight before either answers.
            await action.start(user, action.first.id)
            await action.start(user, action.second.id)
            await waitFor(() =>
                expect(
                    [action.first, action.second].map((alert) =>
                        controlState(
                            elementBySelector(action.selector(alert.id))
                        )
                    )
                ).toEqual(["disabled", "disabled"])
            )
            notFound.release()
            failed.release()

            await waitFor(() =>
                expect({
                    first: messagesIn(
                        elementBySelector(action.selector(action.first.id))
                    ),
                    second: messagesIn(
                        elementBySelector(action.selector(action.second.id))
                    ),
                }).toEqual({
                    first: [ROW_NOT_FOUND_MESSAGE],
                    second: [GENERIC_MESSAGE],
                })
            )
        }
    )

    it.each(rowActions)(
        "alertsPanel_sameActionStartsOnOtherRow_keepsFirstRowError (%s)",
        async (_kind, action) => {
            stubFetch({
                ...bothRowsHandlers(),
                [action.request(action.first.id)]: () => ({ status: 500 }),
                [action.request(action.second.id)]: heldHandler(action.success),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            const firstRegion = () =>
                elementBySelector(action.selector(action.first.id))
            await action.start(user, action.first.id)
            await within(firstRegion()).findByText(GENERIC_MESSAGE)

            await action.start(user, action.second.id)
            await waitFor(() =>
                expect(
                    controlState(
                        elementBySelector(action.selector(action.second.id))
                    )
                ).toBe("disabled")
            )

            expect(messagesIn(firstRegion())).toEqual([GENERIC_MESSAGE])
        }
    )

    it.each(rowActions)(
        "alertsPanel_sameActionRestartsOnFailedRow_clearsItsError (%s)",
        async (_kind, action) => {
            const id = action.first.id
            const retry = heldResponse(action.success)
            let failed = false
            stubFetch({
                ...bothRowsHandlers(),
                // Answers 500 first and is held the second time.
                [action.request(id)]: () => {
                    if (failed) return retry.handler()
                    failed = true
                    return { status: 500 }
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            const region = () => elementBySelector(action.selector(id))
            await action.start(user, id)
            await within(region()).findByText(GENERIC_MESSAGE)

            await action.start(user, id)
            await waitFor(() => expect(controlState(region())).toBe("disabled"))

            expect(messagesIn(region())).toEqual([])
        }
    )

    it.each<[string, RowAction, RowAction]>([
        ["update-enabled, then delete", updateAction, deleteAction],
        ["delete, then update-enabled", deleteAction, updateAction],
    ])(
        "alertsPanel_otherListActionStartsOnFailedRow_keepsFirstError (%s)",
        async (_label, failing, next) => {
            const id = failing.first.id
            stubFetch({
                ...bothRowsHandlers(),
                [failing.request(id)]: () => ({ status: 500 }),
                [next.request(id)]: heldHandler(next.success),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(failing)
            const region = () => elementBySelector(failing.selector(id))
            await failing.start(user, id)
            await within(region()).findByText(GENERIC_MESSAGE)

            await next.start(user, id)
            await waitFor(() => expect(controlState(region())).toBe("disabled"))

            expect(messagesIn(region())).toEqual([GENERIC_MESSAGE])
        }
    )

    it.each<[string, RowAction, RowAction, StubResponse, string[]]>([
        [
            "update-enabled 500, then delete 404",
            updateAction,
            deleteAction,
            { status: 404 },
            [GENERIC_MESSAGE, ROW_NOT_FOUND_MESSAGE],
        ],
        [
            "delete 500, then update-enabled 404",
            deleteAction,
            updateAction,
            { status: 404 },
            [ROW_NOT_FOUND_MESSAGE, GENERIC_MESSAGE],
        ],
        [
            "update-enabled 500, then delete 500",
            updateAction,
            deleteAction,
            { status: 500 },
            [GENERIC_MESSAGE],
        ],
        [
            "delete 500, then update-enabled 500",
            deleteAction,
            updateAction,
            { status: 500 },
            [GENERIC_MESSAGE],
        ],
    ])(
        "alertsPanel_bothListActionsFailOnRow_showsEachDistinctMessage (%s)",
        async (_label, failing, next, nextFailure, expected) => {
            const id = failing.first.id
            const nextHeld = heldResponse(nextFailure)
            stubFetch({
                // The row stays listed after a 404's refresh.
                ...bothRowsHandlers(),
                [failing.request(id)]: () => ({ status: 500 }),
                [next.request(id)]: nextHeld.handler,
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(failing)
            const region = () => elementBySelector(failing.selector(id))
            await failing.start(user, id)
            await within(region()).findByText(GENERIC_MESSAGE)
            await next.start(user, id)
            await waitFor(() => expect(controlState(region())).toBe("disabled"))

            nextHeld.release()
            await waitFor(() => expect(controlState(region())).toBe("enabled"))

            expect(messagesIn(region())).toEqual(expected)
        }
    )

    it.each<[string, RowAction]>([
        ["update-enabled", updateAction],
        ["acknowledge", acknowledgeAction],
    ])(
        "alertsPanel_deleteSucceedsAfterOtherActionFailed_showsNoFeedbackForAlert (%s)",
        async (_kind, failing) => {
            // Listed and notified, so both actions can run on it.
            const alert = triggeredAlert
            const gone = new Set<string>()
            stubFetch({
                ...bothRowsHandlers(gone),
                [failing.request(alert.id)]: () => ({ status: 500 }),
                [deleteAction.request(alert.id)]: () => {
                    gone.add(alert.id)
                    return { status: 204 }
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitFor(() => {
                expect(
                    document.querySelector(rowSelector(alert.id))
                ).not.toBeNull()
                expect(
                    document.querySelector(notificationSelector(alert.id))
                ).not.toBeNull()
            })
            await failing.start(user, alert.id)
            await within(
                elementBySelector(failing.selector(alert.id))
            ).findByText(GENERIC_MESSAGE)

            await deleteAction.start(user, alert.id)
            await waitFor(() => {
                expect(deletedOutputValues()).toEqual([alert.id])
                expect(document.querySelector(rowSelector(alert.id))).toBeNull()
                expect(
                    document.querySelector(notificationSelector(alert.id))
                ).toBeNull()
            })

            expect(
                screen
                    .queryAllByRole("alert")
                    .map((message) => message.textContent)
            ).toEqual([])
        }
    )

    it.each(rowActions)(
        "alertsPanel_rowNotFoundAndRefreshDropsRow_showsMessageInPanelFeedback (%s)",
        async (_kind, action) => {
            const gone = new Set<string>()
            stubFetch({
                ...bothRowsHandlers(gone),
                [action.request(action.first.id)]: () => {
                    gone.add(action.first.id)
                    return { status: 404 }
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)

            await action.start(user, action.first.id)
            await waitFor(() =>
                expect(
                    document.querySelector(action.selector(action.first.id))
                ).toBeNull()
            )

            expect(
                screen.getByText(
                    `${action.firstLabel}: ${ROW_NOT_FOUND_MESSAGE}`
                )
            ).toHaveAttribute("role", "alert")
        }
    )

    it.each(rowActions)(
        "alertsPanel_panelFeedbackDismissed_removesMessage (%s)",
        async (_kind, action) => {
            const gone = new Set<string>()
            stubFetch({
                ...bothRowsHandlers(gone),
                [action.request(action.first.id)]: () => {
                    gone.add(action.first.id)
                    return { status: 404 }
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            await action.start(user, action.first.id)
            const dismiss = await screen.findByRole("button", {
                name: "Dismiss",
            })

            await user.click(dismiss)

            expect(
                screen.queryByText(ROW_NOT_FOUND_MESSAGE, { exact: false })
            ).toBeNull()
        }
    )

    it.each(dismissFocusCases)(
        "alertsPanel_panelFeedbackDismissed_focusesAdjacentDismiss (%s)",
        async (_label, steps, dismissedAlert, focusedAlert) => {
            const gone = new Set<string>()
            stubFetch({
                ...bothRowsHandlers(gone),
                ...Object.fromEntries(
                    steps.map(([action, alert]) => [
                        action.request(alert.id),
                        notFoundDroppingRow(alert, gone),
                    ])
                ),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await showPanelFeedback(user, steps)

            await user.click(dismissOf(dismissedAlert))

            await waitFor(() => expect(dismissOf(focusedAlert)).toHaveFocus())
        }
    )

    it.each(
        rowActions.flatMap(([kind, action]) =>
            dismissActivations.map(
                ([how, activate]): [string, string, RowAction, Activation] => [
                    kind,
                    how,
                    action,
                    activate,
                ]
            )
        )
    )(
        "alertsPanel_lastPanelFeedbackDismissed_focusesPanelHeading (%s, %s)",
        async (_kind, _how, action, activate) => {
            const gone = new Set<string>()
            stubFetch({
                ...bothRowsHandlers(gone),
                [action.request(action.first.id)]: notFoundDroppingRow(
                    action.first,
                    gone
                ),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await showPanelFeedback(user, [[action, action.first]])

            await activate(user, dismissOf(action.first))

            await waitFor(() =>
                expect(
                    screen.getByRole("heading", {
                        name: "Price and P/L alerts",
                    })
                ).toHaveFocus()
            )
        }
    )

    it("alertsPanel_tabFromPageStart_skipsPanelHeading", async () => {
        stubFetch({})
        const user = userEvent.setup({ delay: null })
        renderPanel()
        await screen.findByText("Armed")

        await user.tab()

        expect(screen.getByLabelText("Alert type")).toHaveFocus()
    })

    it.each(rowActions)(
        "alertsPanel_panelFeedbackAppearsAfterEarlierDismiss_keepsFocus (%s)",
        async (_kind, action) => {
            const gone = new Set<string>()
            const secondHeld = hold()
            releaseHeld.push(secondHeld.release)
            stubFetch({
                ...bothRowsHandlers(gone),
                [action.request(action.first.id)]: notFoundDroppingRow(
                    action.first,
                    gone
                ),
                [action.request(action.second.id)]: notFoundDroppingRow(
                    action.second,
                    gone,
                    secondHeld.promise
                ),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await showPanelFeedback(user, [[action, action.first]])
            await action.start(user, action.second.id)
            await user.click(dismissOf(action.first))
            await waitFor(() =>
                expect(
                    screen.getByRole("heading", {
                        name: "Price and P/L alerts",
                    })
                ).toHaveFocus()
            )
            const threshold = screen.getByLabelText("Threshold")
            await user.click(threshold)

            secondHeld.release()
            await screen.findByRole("button", { name: "Dismiss" })

            expect(threshold).toHaveFocus()
        }
    )

    it("alertsPanel_doubleSubmit_sendsOneCreate", async () => {
        let creates = 0
        stubFetch({
            [`POST ${BROKER}/alerts`]: () => {
                creates += 1
                return { status: 201, body: createdAlert }
            },
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()
        await screen.findByText("Armed")
        await fillCreateForm(user)
        const submit = screen.getByRole("button", { name: "Create alert" })

        // Both clicks land before the panel renders the pending form, as a
        // fast double-click does.
        act(() => {
            submit.click()
            submit.click()
        })
        await waitFor(() => expect(client.isMutating()).toBe(0))

        expect(creates).toBe(1)
    })

    it.each(createOutcomes)(
        "alertsPanel_submitAfterCreateSettles_sendsNextCreate (%s)",
        async (_outcome, response) => {
            let creates = 0
            stubFetch({
                [`POST ${BROKER}/alerts`]: () => {
                    creates += 1
                    return response
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await screen.findByText("Armed")
            await fillCreateForm(user)
            const submit = screen.getByRole("button", { name: "Create alert" })
            const settledAndEnabled = () =>
                waitFor(() =>
                    expect({
                        mutating: client.isMutating(),
                        disabled: submit.matches(":disabled"),
                    }).toEqual({ mutating: 0, disabled: false })
                )
            await user.click(submit)
            await settledAndEnabled()

            await user.click(submit)
            await settledAndEnabled()

            expect(creates).toBe(2)
        }
    )

    it.each(
        createSubmissions.flatMap(([how, submit, controlId]) =>
            createOutcomes.map(
                ([outcome, response]): [
                    string,
                    string,
                    CreateSubmission[1],
                    string,
                    StubResponse,
                ] => [how, outcome, submit, controlId, response]
            )
        )
    )(
        "alertsPanel_createSettlesAfterFocusLost_focusesSubmittingControl (%s, %s)",
        async (_how, _outcome, submit, controlId, response) => {
            const created = heldResponse(response)
            stubFetch({ [`POST ${BROKER}/alerts`]: created.handler })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await screen.findByText("Armed")
            await fillCreateForm(user)
            await submit(user)
            const control = elementBySelector(`#${controlId}`)
            await waitFor(() => expect(control).toBeDisabled())
            dropFocus()

            created.release()

            await waitFor(() => expect(control).toHaveFocus())
        }
    )

    it("alertsPanel_createSettlesAfterSubmittingControlRemoved_focusesSubmit", async () => {
        let listed = [armedAlert, triggeredAlert]
        stubFetch({
            [`GET ${LIST_URL}`]: () => ({
                status: 200,
                body: { results: listed },
            }),
            [`POST ${BROKER}/alerts`]: () => {
                listed = [createdAlert, triggeredAlert]
                return { status: 201, body: createdAlert }
            },
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()
        await screen.findByText("Armed")
        await fillCreateForm(user)
        // A submit made by script while a row button holds focus; the
        // refresh after the create drops that row.
        within(rowOf(armedAlert.id))
            .getByRole("button", { name: "Disable" })
            .focus()

        fireEvent.submit(elementBySelector("form#alert-form"))

        await waitFor(() =>
            expect(
                screen.getByRole("button", { name: "Create alert" })
            ).toHaveFocus()
        )
    })

    it.each(toggleFocusCases)(
        "alertsPanel_rowToggled_focusesReplacementButton (%s)",
        async (_label, before, pressed, after, focusedName) => {
            let listed = [before]
            stubFetch({
                [`GET ${LIST_URL}`]: () => ({
                    status: 200,
                    body: { results: listed },
                }),
                [`GET ${NOTIFICATIONS_URL}`]: () => ({
                    status: 200,
                    body: { results: [] },
                }),
                [updateAction.request(before.id)]: () => {
                    listed = [after]
                    return { status: 200, body: after }
                },
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitFor(() =>
                expect(
                    document.querySelector(rowSelector(before.id))
                ).not.toBeNull()
            )

            // The pressed button is replaced, which leaves focus on the body.
            await clickIn(user, rowOf(before.id), pressed)

            await waitFor(() =>
                expect(
                    within(rowOf(before.id)).getByRole("button", {
                        name: focusedName,
                    })
                ).toHaveFocus()
            )
        }
    )

    it.each(removalFocusCases)(
        "alertsPanel_actionRemovesItem_focusesNextItemElseHeading ($removed)",
        async ({ action, listed, notified, target, focused }) => {
            stubFetch(removingHandlers(listed, notified))
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitFor(() =>
                expect(
                    document.querySelector(action.selector(target.id))
                ).not.toBeNull()
            )

            // The removed item takes the focused button with it.
            await action.start(user, target.id)

            await waitFor(() => expect(focused()).toHaveFocus())
        }
    )

    it.each(rowActions)(
        "alertsPanel_rowActionFailsAfterFocusLost_focusesStartingButton (%s)",
        async (_kind, action) => {
            const failed = heldResponse({ status: 500 })
            stubFetch({
                ...bothRowsHandlers(),
                [action.request(action.first.id)]: failed.handler,
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            await action.start(user, action.first.id)
            const started = document.activeElement
            await waitFor(() =>
                expect(
                    controlState(
                        elementBySelector(action.selector(action.first.id))
                    )
                ).toBe("disabled")
            )
            dropFocus()

            failed.release()

            await waitFor(() => expect(started).toHaveFocus())
        }
    )

    it.each(rowActions)(
        "alertsPanel_focusMovedWhileRowActionPending_keepsFocus (%s)",
        async (_kind, action) => {
            const held = heldResponse(action.success)
            stubFetch({
                ...bothRowsHandlers(),
                [action.request(action.first.id)]: held.handler,
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await waitForBothRows(action)
            await action.start(user, action.first.id)
            const threshold = screen.getByLabelText("Threshold")
            await user.click(threshold)

            await releaseAndSettle(held.release)

            expect(threshold).toHaveFocus()
        }
    )

    it("alertsPanel_earlierActionSettlesAfterLaterStarted_leavesFocusToLater", async () => {
        let listed = [armedAlert, triggeredAlert]
        const updateHeld = hold()
        const deleteHeld = hold()
        releaseHeld.push(updateHeld.release, deleteHeld.release)
        stubFetch({
            [`GET ${LIST_URL}`]: () => ({
                status: 200,
                body: { results: listed },
            }),
            [`GET ${NOTIFICATIONS_URL}`]: () => ({
                status: 200,
                body: { results: [] },
            }),
            [updateAction.request(armedAlert.id)]: async () => {
                await updateHeld.promise
                listed = [disabledAlert, triggeredAlert]
                return { status: 200, body: disabledAlert }
            },
            [deleteAction.request(triggeredAlert.id)]: async () => {
                await deleteHeld.promise
                listed = [disabledAlert]
                return { status: 204 }
            },
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()
        await screen.findByText("Armed")
        await updateAction.start(user, armedAlert.id)
        await deleteAction.start(user, triggeredAlert.id)
        dropFocus()

        await releaseAndSettle(updateHeld.release, 1)
        const focusedAfterEarlier = document.activeElement
        await releaseAndSettle(deleteHeld.release)

        expect([focusedAfterEarlier, document.activeElement]).toEqual([
            document.body,
            within(rowOf(armedAlert.id)).getByRole("button", {
                name: "Enable",
            }),
        ])
    })

    it("alertsPanel_actionStartedWithFocusOutsidePanel_movesNoFocus", async () => {
        let listed = [armedAlert, triggeredAlert]
        const deleteHeld = hold()
        releaseHeld.push(deleteHeld.release)
        stubFetch({
            [`GET ${LIST_URL}`]: () => ({
                status: 200,
                body: { results: listed },
            }),
            [deleteAction.request(armedAlert.id)]: async () => {
                await deleteHeld.promise
                listed = [triggeredAlert]
                return { status: 204 }
            },
        })
        renderPanel()
        await screen.findByText("Armed")
        const remove = within(rowOf(armedAlert.id)).getByRole("button", {
            name: "Delete",
        })

        // A click that does not move focus, as in browsers whose buttons
        // take no focus on click.
        act(() => remove.click())
        await releaseAndSettle(deleteHeld.release)

        expect(document.body).toHaveFocus()
    })

    it("alertsPanel_rowFailsWhileListUnavailable_showsMessageInPanelFeedback", async () => {
        let listRequests = 0
        stubFetch({
            // The refresh after the 404 fails, so the list shows its error.
            [`GET ${LIST_URL}`]: () => {
                listRequests += 1
                return listRequests === 1
                    ? { status: 200, body: { results: [armedAlert] } }
                    : { status: 500 }
            },
            [updateAction.request(armedAlert.id)]: () => ({ status: 404 }),
        })
        const user = userEvent.setup({ delay: null })
        renderPanel()
        await screen.findByText("Armed")

        await updateAction.start(user, armedAlert.id)
        await screen.findByText(
            "Could not load alerts. Please try again later."
        )

        expect(
            screen.getByText(
                `EasyTravel Price Above 10: ${ROW_NOT_FOUND_MESSAGE}`
            )
        ).toHaveAttribute("role", "alert")
    })

    it.each<[string, () => Handler]>([
        ["pending", () => heldHandler({ status: 200, body: { results: [] } })],
        ["fails", () => () => ({ status: 500 })],
    ])(
        "alertsPanel_listRefetchAfterDelete_keepsDeletedIdOutput (%s)",
        async (outcome, refetch) => {
            let listRequests = 0
            const refetchHandler = refetch()
            stubFetch({
                // The first list holds the triggered alert the default poll
                // serves, so the panel's trigger check reads no extra list.
                [`GET ${LIST_URL}`]: () => {
                    listRequests += 1
                    return listRequests === 1
                        ? {
                              status: 200,
                              body: { results: [armedAlert, triggeredAlert] },
                          }
                        : refetchHandler()
                },
                [deleteAction.request(armedAlert.id)]: () => ({ status: 204 }),
            })
            const user = userEvent.setup({ delay: null })
            renderPanel()
            await screen.findByText("Armed")

            await deleteAction.start(user, armedAlert.id)
            if (outcome === "pending") {
                await waitFor(() => expect(listRequests).toBe(2))
            } else {
                await screen.findByText(
                    "Could not load alerts. Please try again later."
                )
            }

            expect(deletedOutputValues()).toEqual([armedAlert.id])
        }
    )

    it("alertsPanel_accountSwitchedAfterWrites_showsNoPreviousAccountState", async () => {
        stubFetch({
            [`POST ${BROKER}/alerts`]: () => ({
                status: 201,
                body: createdAlert,
            }),
            [deleteAction.request(armedAlert.id)]: () => ({ status: 204 }),
            [updateAction.request(triggeredAlert.id)]: () => ({
                status: 500,
            }),
            [`GET ${OTHER_LIST_URL}`]: () => ({
                status: 200,
                body: { results: [otherAccountAlert] },
            }),
            [`GET ${OTHER_NOTIFICATIONS_URL}`]: () => ({
                status: 200,
                body: { results: [] },
            }),
        })
        const user = userEvent.setup({ delay: null })
        const { container, rerender } = renderPanel()
        await screen.findByText("Armed")
        await user.selectOptions(
            screen.getByLabelText("Instrument"),
            INSTRUMENT_ID
        )
        await user.type(screen.getByLabelText("Threshold"), "105.5")
        await user.click(screen.getByRole("button", { name: "Create alert" }))
        await waitFor(() =>
            expect(
                container.querySelector("output#alert-created-id")
            ).not.toBeNull()
        )
        await deleteAction.start(user, armedAlert.id)
        await waitFor(() =>
            expect(deletedOutputValues()).toEqual([armedAlert.id])
        )
        await updateAction.start(user, triggeredAlert.id)
        await within(rowOf(triggeredAlert.id)).findByText(GENERIC_MESSAGE)

        sessionStorage.setItem("user-id", "2")
        rerender(panelFor("2"))
        await waitForOtherAccountList()

        expect({
            created: container.querySelector("output#alert-created-id"),
            deleted: deletedOutputValues(),
            messages: screen
                .queryAllByRole("alert")
                .map((message) => message.textContent),
            threshold:
                screen.getByLabelText<HTMLInputElement>("Threshold").value,
        }).toEqual({ created: null, deleted: [], messages: [], threshold: "" })
    })

    it("alertsPanel_accountSwitchedWhileWritesPending_showsControlsEnabled", async () => {
        // The other account's list repeats the pending row's id, so pending
        // state carried over from the first account would show on it.
        const sameIdRow: Alert = { ...armedAlert, accountId: "2" }
        stubFetch({
            [`POST ${BROKER}/alerts`]: heldHandler({
                status: 201,
                body: createdAlert,
            }),
            [updateAction.request(armedAlert.id)]: heldHandler(
                updateAction.success
            ),
            [`GET ${OTHER_LIST_URL}`]: () => ({
                status: 200,
                body: { results: [sameIdRow] },
            }),
            [`GET ${OTHER_NOTIFICATIONS_URL}`]: () => ({
                status: 200,
                body: { results: [] },
            }),
        })
        const user = userEvent.setup({ delay: null })
        const { rerender } = renderPanel()
        await screen.findByText("Armed")
        await updateAction.start(user, armedAlert.id)
        await user.selectOptions(
            screen.getByLabelText("Instrument"),
            INSTRUMENT_ID
        )
        await user.type(screen.getByLabelText("Threshold"), "105.5")
        await user.click(screen.getByRole("button", { name: "Create alert" }))
        await waitFor(() =>
            expect({
                row: controlState(rowOf(armedAlert.id)),
                submit: screen
                    .getByRole("button", { name: "Create alert" })
                    .matches(":disabled"),
            }).toEqual({ row: "disabled", submit: true })
        )

        sessionStorage.setItem("user-id", "2")
        rerender(panelFor("2"))
        await waitForOtherAccountList()

        expect({
            row: controlState(rowOf(sameIdRow.id)),
            submit: screen
                .getByRole("button", { name: "Create alert" })
                .matches(":disabled"),
        }).toEqual({ row: "enabled", submit: false })
    })

    /** `armedAlert` at `revision`, triggered in that arming. */
    function triggeredArming(revision: number): Alert {
        return {
            ...armedAlert,
            armingRevision: revision,
            triggeredAt: "2026-01-01T10:00:00Z",
            triggerValue: 10.5,
        }
    }

    it.each<{ listed: string; firstList: Alert[]; notified: Alert }>([
        {
            listed: "the same arming, not yet triggered",
            firstList: [armedAlert],
            notified: triggeredArming(1),
        },
        {
            listed: "an older arming",
            firstList: [{ ...armedAlert, enabled: false }],
            notified: triggeredArming(2),
        },
        {
            listed: "no row for the alert",
            firstList: [],
            notified: triggeredArming(1),
        },
    ])(
        "alertsPanel_notificationShowsUnlistedTrigger_refetchesListToTriggeredRow (list holds $listed)",
        async ({ firstList, notified }) => {
            let listReads = 0
            stubFetch({
                // Only a list read after the trigger returns the triggered row.
                [`GET ${LIST_URL}`]: () => {
                    listReads += 1
                    return {
                        status: 200,
                        body: {
                            results: listReads === 1 ? firstList : [notified],
                        },
                    }
                },
                [`GET ${NOTIFICATIONS_URL}`]: () => ({
                    status: 200,
                    body: { results: [notified] },
                }),
            })
            renderPanel()

            await waitFor(() =>
                expect(
                    within(rowOf(notified.id))
                        .getAllByRole("button")
                        .map((button) => button.textContent)
                ).toEqual(["Re-arm", "Disable", "Delete"])
            )
        }
    )

    it.each<{ listed: string; list: Alert[]; notified: Alert }>([
        {
            listed: "the notified trigger",
            list: [triggeredArming(1)],
            notified: triggeredArming(1),
        },
        {
            // The notifications read predates a re-arm the list already shows.
            listed: "a newer arming",
            list: [{ ...armedAlert, armingRevision: 2 }],
            notified: triggeredArming(1),
        },
    ])(
        "alertsPanel_listReflectsNotification_doesNotRefetchList (list holds $listed)",
        async ({ list, notified }) => {
            let listReads = 0
            stubFetch({
                [`GET ${LIST_URL}`]: () => {
                    listReads += 1
                    return { status: 200, body: { results: list } }
                },
                [`GET ${NOTIFICATIONS_URL}`]: () => ({
                    status: 200,
                    body: { results: [notified] },
                }),
            })
            renderPanel()
            // Both regions show their data, so the panel has compared them;
            // a refetch it started would already have sent its request.
            await screen.findByRole("button", { name: "Acknowledge" })
            await waitFor(() => expect(rowOf(notified.id)).toBeInTheDocument())

            expect(listReads).toBe(1)
        }
    )

    it("alertsPanel_deleteNotifiedTrigger_refetchesListOnce", async () => {
        let deleted = false
        let listReadsAfterDelete = 0
        // The delete refetches both reads at once; the list answers first,
        // while the notifications read still holds the deleted alert.
        const notificationsAfterDelete = heldHandler({
            status: 200,
            body: { results: [] },
        })
        stubFetch({
            [`DELETE ${BROKER}/alerts/${triggeredAlert.id}`]: () => {
                deleted = true
                return { status: 204 }
            },
            [`GET ${LIST_URL}`]: () => {
                if (deleted) listReadsAfterDelete += 1
                return {
                    status: 200,
                    body: {
                        results: deleted
                            ? [armedAlert]
                            : [armedAlert, triggeredAlert],
                    },
                }
            },
            [`GET ${NOTIFICATIONS_URL}`]: () =>
                deleted
                    ? notificationsAfterDelete()
                    : { status: 200, body: { results: [triggeredAlert] } },
        })
        const user = userEvent.setup({ delay: null })
        const { container } = renderPanel()
        await screen.findByRole("button", { name: "Acknowledge" })
        await waitFor(() =>
            expect(rowOf(triggeredAlert.id)).toBeInTheDocument()
        )

        await user.click(
            within(rowOf(triggeredAlert.id)).getByRole("button", {
                name: "Delete",
            })
        )
        await waitFor(() =>
            expect(
                container.querySelector(
                    `li[data-alert-id="${triggeredAlert.id}"]`
                )
            ).toBeNull()
        )
        releaseHeld.forEach((release) => release())
        await waitFor(() =>
            expect(
                screen.queryByRole("button", { name: "Acknowledge" })
            ).toBeNull()
        )
        await waitFor(() => expect(client.isFetching()).toBe(0))

        expect(listReadsAfterDelete).toBe(1)
    })

    it("alertsPanel_refetchedListStillLacksNotifiedTrigger_refetchesListOnce", async () => {
        let listReads = 0
        stubFetch({
            // The alert is deleted elsewhere after the notifications read,
            // so no list read holds it until the notifications change. Each
            // refetch stays in flight until released, as a network read does.
            [`GET ${LIST_URL}`]: () => {
                listReads += 1
                const response = { status: 200, body: { results: [] } }
                return listReads === 1 ? response : heldHandler(response)()
            },
            [`GET ${NOTIFICATIONS_URL}`]: () => ({
                status: 200,
                body: { results: [triggeredAlert] },
            }),
        })
        render(
            <QueryClientProvider client={client}>
                <FormatterWrapper>
                    <AlertsPanel accountId="1" instruments={instruments} />
                    <FetchingProbe queryKey={alertKeys.list("1")} />
                </FormatterWrapper>
            </QueryClientProvider>
        )
        await screen.findByRole("button", { name: "Acknowledge" })
        await waitFor(() =>
            expect(screen.getByTestId("region-fetching")).toHaveTextContent("1")
        )
        releaseHeld.forEach((release) => release())
        await waitFor(() =>
            expect(screen.getByTestId("region-fetching")).toHaveTextContent("0")
        )
        // The settled pair is compared again; the same notifications read
        // refetches nothing more.
        await waitFor(() => expect(client.isFetching()).toBe(0))

        expect(listReads).toBe(2)
    })

    // On `/insights` the panel and `AlertNotificationWatcher` observe the same
    // notifications entry; only the watcher may schedule its poll.
    describe("beside AlertNotificationWatcher", () => {
        const FLAG_URL = `${window.location.origin}/feature-flag-service/v1/flags/portfolio-insights-enabled`

        /** The watcher's notification poll interval on a visible tab. */
        const POLL_INTERVAL_MS = 15_000

        /**
         * Three polls and half an interval more, so a poll re-armed when its
         * read lands, a little after its timer fired, still falls inside.
         */
        const THREE_POLLS_MS = 3 * POLL_INTERVAL_MS + POLL_INTERVAL_MS / 2

        type Reads = { flag: number; list: number; notifications: number }

        /** Requests per endpoint since the stub was installed. */
        let reads: Reads

        /** What the list endpoint answers; a test may replace it. */
        let listAnswer: () => StubResponse

        beforeEach(() => {
            // Query-core delivers notifications through a zero-delay timer,
            // which fake timers would defer; microtasks keep delivery on the
            // same tick.
            notifyManager.setScheduler(queueMicrotask)
            vi.useFakeTimers({ shouldAdvanceTime: true })
            reads = { flag: 0, list: 0, notifications: 0 }
            listAnswer = () => ({
                status: 200,
                body: { results: [armedAlert, triggeredAlert] },
            })
            stubFetch({
                [`GET ${FLAG_URL}`]: () => {
                    reads.flag += 1
                    return {
                        status: 200,
                        body: {
                            id: "portfolio-insights-enabled",
                            enabled: true,
                            name: "Portfolio insights",
                            description: "Portfolio Insights demo feature",
                            isModifiable: true,
                            tag: "feature",
                        },
                    }
                },
                [`GET ${LIST_URL}`]: () => {
                    reads.list += 1
                    return listAnswer()
                },
                [`GET ${NOTIFICATIONS_URL}`]: () => {
                    reads.notifications += 1
                    return { status: 200, body: { results: [triggeredAlert] } }
                },
            })
        })

        afterEach(() => {
            // Unmount first, so restoring focus below starts no read.
            cleanup()
            focusManager.setFocused(undefined)
            notifyManager.setScheduler(defaultScheduler)
            vi.useRealTimers()
        })

        /** Waits until the list and the notifications show their reads. */
        async function regionsLoaded(): Promise<void> {
            await screen.findByRole("button", { name: "Acknowledge" })
            await screen.findByText("Armed")
        }

        /**
         * Mounts the panel beside the watcher, as `/insights` does, and waits
         * for `ready`: by default, until both regions show their reads.
         */
        async function renderWithWatcher(
            ready: () => Promise<void> = regionsLoaded
        ): Promise<void> {
            render(
                <QueryClientProvider client={client}>
                    <UserContextWrapper>
                        <ToastWrapper>
                            <FormatterWrapper>
                                <AlertNotificationWatcher />
                                <AlertsPanel
                                    accountId="1"
                                    instruments={instruments}
                                />
                            </FormatterWrapper>
                        </ToastWrapper>
                    </UserContextWrapper>
                </QueryClientProvider>
            )
            await ready()
        }

        /** Advances the fake clock and lets the work it starts settle. */
        async function advance(ms: number): Promise<void> {
            await act(async () => {
                await vi.advanceTimersByTimeAsync(ms)
            })
        }

        function alertReadsSince(before: Reads) {
            return {
                list: reads.list - before.list,
                notifications: reads.notifications - before.notifications,
            }
        }

        it("notificationsPoll_visibleTab_requestsOncePerInterval", async () => {
            await renderWithWatcher()
            const before = { ...reads }

            await advance(THREE_POLLS_MS)

            expect(alertReadsSince(before)).toEqual({
                list: 0,
                notifications: 3,
            })
        })

        it("notificationsPoll_hiddenTab_requestsNothing", async () => {
            await renderWithWatcher()
            const before = { ...reads }
            act(() => {
                focusManager.setFocused(false)
            })

            await advance(THREE_POLLS_MS)

            expect(alertReadsSince(before)).toEqual({
                list: 0,
                notifications: 0,
            })
        })

        it("alertQueries_windowRefocus_requestNothing", async () => {
            await renderWithWatcher()
            const before = { ...reads }
            // Query-core starts its focus refetches from this call, a few
            // microtasks after the event; it runs them synchronously.
            const queryCoreFocus = vi.spyOn(client.getQueryCache(), "onFocus")

            act(() => {
                focusManager.setFocused(false)
                focusManager.setFocused(true)
            })
            await waitFor(() => expect(queryCoreFocus).toHaveBeenCalled())

            expect(alertReadsSince(before)).toEqual({
                list: 0,
                notifications: 0,
            })
        })

        it("alertsPanel_withoutWatcher_pollsNoNotifications", async () => {
            renderPanel()
            await regionsLoaded()
            const before = { ...reads }

            await advance(THREE_POLLS_MS)

            expect(alertReadsSince(before).notifications).toBe(0)
        })

        it("alertsPanel_triggerRefreshFailedThenRecovers_refetchesListOnNextPoll", async () => {
            // The first list read predates the trigger, so the row is still
            // armed; the read the trigger starts, and its retries, fail.
            listAnswer = () =>
                reads.list === 1
                    ? {
                          status: 200,
                          body: {
                              results: [
                                  {
                                      ...triggeredAlert,
                                      triggeredAt: null,
                                      triggerValue: null,
                                  },
                              ],
                          },
                      }
                    : { status: 503 }
            await renderWithWatcher()
            await screen.findByText(
                "Could not load alerts. Please try again later."
            )
            const before = { ...reads }
            listAnswer = () => ({
                status: 200,
                body: { results: [triggeredAlert] },
            })

            // Every poll returns the same notifications as the one before.
            await advance(THREE_POLLS_MS)

            expect({
                listReads: reads.list - before.list,
                actions: Array.from(
                    document.querySelectorAll(
                        `li[data-alert-id="${triggeredAlert.id}"] button`
                    ),
                    (button) => button.textContent
                ),
            }).toEqual({
                listReads: 1,
                actions: ["Re-arm", "Disable", "Delete"],
            })
        })

        const LIST_ERROR = "Could not load alerts. Please try again later."

        /**
         * Requests per list fetch: its read and the three retries
         * `featureQueryRetry` allows.
         */
        const REQUESTS_PER_LIST_FETCH = 4

        /**
         * Runs the next three polls one at a time, each in its own act scope,
         * and lets the reads each one starts settle. React flushes the work
         * scheduled inside an act scope only when the scope ends, so a single
         * scope over three polls would show the panel the last one alone.
         */
        async function pollThreeTimesOneByOne(): Promise<void> {
            for (let poll = 0; poll < 3; poll += 1) {
                await advance(POLL_INTERVAL_MS)
                await waitFor(() => expect(client.isFetching()).toBe(0))
            }
        }

        /** The ids of the rendered list rows, in list order. */
        function listedRowIds(): (string | null)[] {
            return Array.from(
                document.querySelectorAll("#alerts-list li.alert-item"),
                (row) => row.getAttribute("data-alert-id")
            )
        }

        /** Every read of the list fails from the start, retries included. */
        async function renderWithListNeverLoaded(): Promise<void> {
            listAnswer = () => ({ status: 503 })
            await renderWithWatcher(async () => {
                await screen.findByRole("button", { name: "Acknowledge" })
                await screen.findByText(LIST_ERROR)
            })
        }

        /** The list loads, then a refresh of it fails, retries included. */
        async function renderWithListRefreshFailed(): Promise<void> {
            await renderWithWatcher()
            listAnswer = () => ({ status: 503 })
            await act(async () => {
                await client.invalidateQueries({
                    queryKey: alertKeys.list("1"),
                })
            })
            await screen.findByText(LIST_ERROR)
        }

        const listRecovered: StubResponse = {
            status: 200,
            body: { results: [armedAlert, triggeredAlert] },
        }

        const listStillFailing = {
            reads: { list: 3 * REQUESTS_PER_LIST_FETCH, notifications: 3 },
            listError: true,
            rows: [],
        }

        const listLoadedOnFirstPoll = {
            reads: { list: 1, notifications: 3 },
            listError: false,
            rows: [armedAlert.id, triggeredAlert.id],
        }

        // The notifications show no trigger the list lacks, so only the
        // list's own failure makes a successful poll refetch it: once per
        // poll while it fails, and never again once a read loads.
        it.each<{
            failure: string
            renderFailed: () => Promise<void>
            later: StubResponse
            expected: {
                reads: { list: number; notifications: number }
                listError: boolean
                rows: (string | null)[]
            }
        }>([
            {
                failure: "never loaded",
                renderFailed: renderWithListNeverLoaded,
                later: listRecovered,
                expected: listLoadedOnFirstPoll,
            },
            {
                failure: "never loaded",
                renderFailed: renderWithListNeverLoaded,
                later: { status: 503 },
                expected: listStillFailing,
            },
            {
                failure: "refresh failed",
                renderFailed: renderWithListRefreshFailed,
                later: listRecovered,
                expected: listLoadedOnFirstPoll,
            },
            {
                failure: "refresh failed",
                renderFailed: renderWithListRefreshFailed,
                later: { status: 503 },
                expected: listStillFailing,
            },
        ])(
            "alertsPanel_listFailed_refetchesListOncePerPollUntilLoaded (list $failure, then answers $later.status)",
            async ({ renderFailed, later, expected }) => {
                await renderFailed()
                const before = { ...reads }
                listAnswer = () => later

                await pollThreeTimesOneByOne()

                expect({
                    reads: alertReadsSince(before),
                    listError: screen.queryByText(LIST_ERROR) !== null,
                    rows: listedRowIds(),
                }).toEqual(expected)
            }
        )

        it("alertsPanel_listForbiddenBesidePoll_refetchesNoList", async () => {
            await renderWithWatcher()
            // A forbidden read runs the shutdown, which removes the list
            // before any later poll lands, so the 403 is written to the list
            // directly: only the panel's own rule decides whether it is
            // refetched.
            const list = client
                .getQueryCache()
                .find<Alert[]>({ queryKey: alertKeys.list("1"), exact: true })
            if (list === undefined) throw new Error("No list query")
            act(() => {
                list.setState({
                    ...list.state,
                    status: "error",
                    error: new ApiError(403, LIST_URL),
                    errorUpdateCount: list.state.errorUpdateCount + 1,
                    errorUpdatedAt: Date.now(),
                    fetchStatus: "idle",
                })
            })
            const before = { ...reads }

            await pollThreeTimesOneByOne()

            expect(alertReadsSince(before)).toEqual({
                list: 0,
                notifications: 3,
            })
        })
    })
})
