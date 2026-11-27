import "@testing-library/jest-dom/vitest"
import {
    type MutateOptions,
    QueryClient,
    QueryClientProvider,
    onlineManager,
    skipToken,
    useQuery,
} from "@tanstack/react-query"
import {
    act,
    cleanup,
    render,
    renderHook,
    screen,
    waitFor,
    within,
} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { PropsWithChildren } from "react"
import type { MockInstance } from "vitest"
import type { Alert, CreateAlertRequest } from "../../api/alerts/types"
import { BizEvents } from "../../api/bizEvents"
import { ApiError } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import { SESSION_KEY } from "../../contexts/AuthContext/storage"
import {
    useAcknowledgeAlertMutation,
    useCreateAlertMutation,
    useDeleteAlertMutation,
    useUpdateAlertEnabledMutation,
} from "../../hooks/useAlerts"
import { portfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    type FeatureContext,
    captureFeatureContext,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import {
    alertKeys,
    featureFlagKeys,
    invalidateOnLogout,
    portfolioKeys,
} from "../../utils/queryKeys"
import {
    FormatterWrapper,
    ToastWrapper,
    UserContextWrapper,
} from "../providers"

// Covers the outcomes of the create, update-enabled, delete and acknowledge
// mutations as the alerts panel shows them, and the create receipt at the
// hook itself. The panel's own query states are covered by
// AlertsPanel.test.tsx.

/** The account `UserContextWrapper` provides. */
const ACCOUNT_ID = "1"

const INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000001"

/** Typed into the threshold field; the created alert echoes it back. */
const THRESHOLD_TEXT = "105.5"

const REJECTED_MESSAGE =
    "The alert was rejected. Check the values and try again."
const CREATE_NOT_FOUND_MESSAGE = "The account or instrument no longer exists."
const ROW_NOT_FOUND_MESSAGE = "This alert no longer exists."
const GENERIC_MESSAGE = "Something went wrong. Please try again later."

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
        amount: 5,
    },
]

const armedAlert: Alert = {
    id: "a1000000-0000-4000-8000-000000000001",
    accountId: ACCOUNT_ID,
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

const createdAlert: Alert = {
    ...armedAlert,
    id: "a1000000-0000-4000-8000-000000000009",
    threshold: Number(THRESHOLD_TEXT),
    createdAt: "2026-01-01T09:30:00Z",
}

/** The unacknowledged notification the notifications poll serves. */
const triggeredAlert: Alert = {
    ...armedAlert,
    id: "a1000000-0000-4000-8000-000000000002",
    triggeredAt: "2026-01-01T10:00:00Z",
    triggerValue: 10.75,
}

const BROKER = `${window.location.origin}/broker-service/v1`

/** Requests, keyed as `METHOD url`. */
const LIST = `GET ${BROKER}/alerts?accountId=${ACCOUNT_ID}`
const NOTIFICATIONS = `GET ${BROKER}/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`
const CREATE = `POST ${BROKER}/alerts`
const UPDATE = `PATCH ${BROKER}/alerts/${armedAlert.id}`
const DELETE = `DELETE ${BROKER}/alerts/${armedAlert.id}`
const ACKNOWLEDGE = `POST ${BROKER}/alerts/${triggeredAlert.id}/acknowledge`

/** `text`, when given, is the exact body; otherwise `body` as JSON, if any. */
type StubResponse = { status: number; body?: unknown; text?: string }
type Handler = (init?: RequestInit) => StubResponse | Promise<StubResponse>
type User = ReturnType<typeof userEvent.setup>

/** One mutation as a user starts it, and where the panel shows its state. */
type MutationAction = {
    /** The request the mutation sends. */
    request: string
    /** The broker's answer when the mutation succeeds. */
    success: StubResponse
    start: (user: User) => Promise<void>
    /** The controls disabled while the mutation is pending. */
    controls: () => HTMLElement[]
    /** The element holding the mutation's failure message. */
    errorRegion: () => HTMLElement
}

let client: QueryClient
/** Every request sent in the current case, in order. */
let requests: string[] = []
/** The raw body of every create request sent in the current case, in order. */
let createBodies: unknown[] = []
/** Releases the held responses still waiting. */
let releases: (() => void)[] = []
let createSpy: MockInstance<(typeof BizEvents)["alertCreate"]>

function respond({ status, body, text }: StubResponse): Response {
    return new Response(
        text ?? (body === undefined ? null : JSON.stringify(body)),
        {
            status,
            headers: { "Content-Type": "application/json" },
        }
    )
}

function countOf(request: string): number {
    return requests.filter((sent) => sent === request).length
}

/**
 * Answers broker requests by `METHOD url`: `handlers` first, then a success
 * for every request the panel sends. Any other request fails the call.
 */
function stubFetch(handlers: Partial<Record<string, Handler>> = {}): void {
    const defaults: Partial<Record<string, Handler>> = {
        // The list holds the triggered alert the poll serves, as the broker
        // does, so the panel's trigger check adds no list read of its own.
        [LIST]: () => ({
            status: 200,
            body: { results: [armedAlert, triggeredAlert] },
        }),
        [NOTIFICATIONS]: () => ({
            status: 200,
            body: { results: [triggeredAlert] },
        }),
    }
    for (const action of [
        createAction,
        updateAction,
        deleteAction,
        acknowledgeAction,
    ]) {
        defaults[action.request] = () => action.success
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
            requests.push(key)
            if (key === CREATE) createBodies.push(init?.body)
            const handler = handlers[key] ?? defaults[key]
            if (handler === undefined) {
                throw new Error(`Unexpected request ${key}`)
            }
            return respond(await handler(init))
        }
    )
}

/** A response sent only once `release` runs; `afterEach` releases any left. */
function hold(response: StubResponse): {
    handler: Handler
    release: () => void
} {
    let release: () => void = () => undefined
    const released = new Promise<void>((resolve) => {
        release = resolve
    })
    releases.push(release)
    return {
        handler: async () => {
            await released
            return response
        },
        release,
    }
}

/**
 * A request that is never answered: it rejects as `fetch` does once its
 * signal aborts, and records that signal in `signals`.
 */
function heldUntilAborted(signals: (AbortSignal | undefined)[]): Handler {
    return (init) => {
        const signal = init?.signal ?? undefined
        signals.push(signal)
        return new Promise<StubResponse>((_, reject) => {
            const abort = (): void =>
                reject(new DOMException("Aborted", "AbortError"))
            if (signal?.aborted) {
                abort()
                return
            }
            signal?.addEventListener("abort", abort, { once: true })
        })
    }
}

function pausedMutationCount(): number {
    return client
        .getMutationCache()
        .getAll()
        .filter((mutation) => mutation.state.isPaused).length
}

/** The text of every alert message the page shows. */
function shownMessages(): (string | null)[] {
    return screen.queryAllByRole("alert").map((message) => message.textContent)
}

function elementBySelector(selector: string): HTMLElement {
    const element = document.querySelector<HTMLElement>(selector)
    if (element === null) throw new Error(`No element matches ${selector}`)
    return element
}

function armedRow(): HTMLElement {
    return elementBySelector(`li[data-alert-id="${armedAlert.id}"]`)
}

const NOTIFICATION_ITEM = `li.alert-notification[data-notification-id="${triggeredAlert.id}"]`

function notificationItem(): HTMLElement {
    return elementBySelector(NOTIFICATION_ITEM)
}

/**
 * Renders the panel only while the flag entry reads `true`, as the
 * `/insights` page does by leaving for `/home` once it turns `false`. A panel
 * left mounted after a shutdown would rebuild its alert queries on its next
 * render, so the cache could never be seen without them.
 */
function FlagGatedAlertsPanel() {
    const { data: enabled } = useQuery<boolean>({
        queryKey: featureFlagKeys.portfolioInsights,
        queryFn: skipToken,
    })
    return enabled === true ? (
        <AlertsPanel accountId={ACCOUNT_ID} instruments={instruments} />
    ) : null
}

function renderPanel(target: QueryClient) {
    return render(
        <QueryClientProvider client={target}>
            <UserContextWrapper>
                <FormatterWrapper>
                    <ToastWrapper>
                        <FlagGatedAlertsPanel />
                    </ToastWrapper>
                </FormatterWrapper>
            </UserContextWrapper>
        </QueryClientProvider>
    )
}

/** Waits until every control of `action` is disabled, or enabled again. */
async function waitForControls(
    action: MutationAction,
    state: "disabled" | "enabled"
): Promise<void> {
    await waitFor(() => {
        for (const control of action.controls()) {
            if (state === "disabled") expect(control).toBeDisabled()
            else expect(control).toBeEnabled()
        }
    })
}

/** Resolves once the list shows the armed alert and notifications loaded. */
async function waitForInitialLoad(): Promise<void> {
    await screen.findByText("Armed")
    await waitFor(() =>
        expect(
            client.getQueryState(alertKeys.notifications(ACCOUNT_ID))?.status
        ).toBe("success")
    )
}

async function fillAndSubmit(
    user: User,
    thresholdText = THRESHOLD_TEXT
): Promise<void> {
    await user.selectOptions(
        screen.getByLabelText("Alert type"),
        "TARGET_PRICE"
    )
    await user.selectOptions(screen.getByLabelText("Instrument"), INSTRUMENT_ID)
    await user.selectOptions(screen.getByLabelText("Direction"), "ABOVE")
    await user.type(screen.getByLabelText("Threshold"), thresholdText)
    await user.click(screen.getByRole("button", { name: "Create alert" }))
}

/**
 * Makes the `alertCreate` event throw, as it does when the OneAgent call and
 * its `reportError` fallback both throw, and returns the thrown error.
 */
function failAlertCreateEvent(): Error {
    const reportingError = new Error("reportError failed")
    createSpy.mockImplementation(() => {
        throw reportingError
    })
    return reportingError
}

/** The exact body text of a `TARGET_PRICE` `ABOVE` create carrying `token`. */
function createBodyWith(token: string): string {
    return `{"accountId":"${ACCOUNT_ID}","type":"TARGET_PRICE","instrumentId":"${INSTRUMENT_ID}","direction":"ABOVE","threshold":${token}}`
}

/** Provides the case's client to a hook rendered on its own. */
function ClientWrapper({ children }: PropsWithChildren) {
    return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

/** Seeds the insights entry a shutdown must drop together with the alerts. */
function seedInsights(target: QueryClient): void {
    const allocation = {
        instrumentId: INSTRUMENT_ID,
        name: "EasyTravel",
        quantity: 5,
        value: 52.5,
        percent: 100,
    }
    target.setQueryData(portfolioInsightsQuery(ACCOUNT_ID).queryKey, {
        totalValue: 52.5,
        totalInvested: 50,
        unrealizedPnl: 2.5,
        unrealizedPnlPercent: 5,
        allocations: [allocation],
        largestPosition: allocation,
        riskLevel: "HIGH",
    })
}

const createAction: MutationAction = {
    request: CREATE,
    success: { status: 201, body: createdAlert },
    start: fillAndSubmit,
    controls: () => [
        screen.getByLabelText("Alert type"),
        screen.getByLabelText("Instrument"),
        screen.getByLabelText("Direction"),
        screen.getByLabelText("Threshold"),
        screen.getByRole("button", { name: "Create alert" }),
    ],
    errorRegion: () => elementBySelector("form#alert-form"),
}

const updateAction: MutationAction = {
    request: UPDATE,
    success: { status: 200, body: { ...armedAlert, enabled: false } },
    start: (user) =>
        user.click(within(armedRow()).getByRole("button", { name: "Disable" })),
    controls: () => within(armedRow()).getAllByRole("button"),
    errorRegion: armedRow,
}

const deleteAction: MutationAction = {
    request: DELETE,
    success: { status: 204 },
    start: (user) =>
        user.click(within(armedRow()).getByRole("button", { name: "Delete" })),
    controls: () => within(armedRow()).getAllByRole("button"),
    errorRegion: armedRow,
}

const acknowledgeAction: MutationAction = {
    request: ACKNOWLEDGE,
    success: { status: 204 },
    start: (user) =>
        user.click(
            within(notificationItem()).getByRole("button", {
                name: "Acknowledge",
            })
        ),
    controls: () => within(notificationItem()).getAllByRole("button"),
    errorRegion: notificationItem,
}

const mutationActions: [string, MutationAction][] = [
    ["create", createAction],
    ["update-enabled", updateAction],
    ["delete", deleteAction],
    ["acknowledge", acknowledgeAction],
]

/** The ways the context a mutation was started in can end. */
const contextEnds: { boundary: string; end: () => void }[] = [
    {
        boundary: "logout",
        end: () => {
            sessionStorage.removeItem(SESSION_KEY)
            invalidateOnLogout(client)
        },
    },
    {
        boundary: "account switch",
        end: () => sessionStorage.setItem(SESSION_KEY, "2"),
    },
    { boundary: "shutdown", end: () => onPortfolioInsightsDisabled(client) },
]

/** One alert hook called on its own, and what it shows. */
type HookCall = {
    settled: () => boolean
    messages: () => readonly string[]
}

const hookCalls: { hook: string; request: string; call: () => HookCall }[] = [
    {
        hook: "useCreateAlertMutation",
        request: CREATE,
        call: () => {
            const { result } = renderHook(
                () => useCreateAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                result.current.mutate({
                    accountId: ACCOUNT_ID,
                    type: "TARGET_PRICE",
                    instrumentId: INSTRUMENT_ID,
                    direction: "ABOVE",
                    threshold: THRESHOLD_TEXT,
                })
            )
            return {
                settled: () => result.current.isError,
                messages: () =>
                    result.current.errorMessage === null
                        ? []
                        : [result.current.errorMessage],
            }
        },
    },
    {
        hook: "useUpdateAlertEnabledMutation",
        request: UPDATE,
        call: () => {
            const { result } = renderHook(
                () => useUpdateAlertEnabledMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                result.current.mutate({ id: armedAlert.id, enabled: false })
            )
            return {
                settled: () => result.current.isError,
                messages: () => Array.from(result.current.rowErrors.values()),
            }
        },
    },
    {
        hook: "useDeleteAlertMutation",
        request: DELETE,
        call: () => {
            const { result } = renderHook(
                () => useDeleteAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() => result.current.mutate(armedAlert.id))
            return {
                settled: () => result.current.isError,
                messages: () => Array.from(result.current.rowErrors.values()),
            }
        },
    },
    {
        hook: "useAcknowledgeAlertMutation",
        request: ACKNOWLEDGE,
        call: () => {
            const { result } = renderHook(
                () => useAcknowledgeAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() => result.current.mutate(triggeredAlert.id))
            return {
                settled: () => result.current.isError,
                messages: () => Array.from(result.current.rowErrors.values()),
            }
        },
    },
]

/** One per-call callback, with the arguments its caller received. */
type CallbackRecord = {
    callback: "onSuccess" | "onError" | "onSettled"
    data: unknown
    /** The failure's HTTP status; `null` without a failure. */
    status: number | null
    variables: unknown
    onMutateResult: FeatureContext | undefined
    /** Whether the last argument names the case's client. */
    ownClient: boolean
}

function statusOf(error: Error | null): number | null {
    return error instanceof ApiError ? error.status : null
}

/** Per-call options that record every callback into `log`, in order. */
function recordingOptions<TData, TInput>(
    log: CallbackRecord[]
): MutateOptions<TData, Error, TInput, FeatureContext> {
    return {
        onSuccess: (data, variables, onMutateResult, context) => {
            log.push({
                callback: "onSuccess",
                data,
                status: null,
                variables,
                onMutateResult,
                ownClient: context.client === client,
            })
        },
        onError: (error, variables, onMutateResult, context) => {
            log.push({
                callback: "onError",
                data: undefined,
                status: statusOf(error),
                variables,
                onMutateResult,
                ownClient: context.client === client,
            })
        },
        onSettled: (data, error, variables, onMutateResult, context) => {
            log.push({
                callback: "onSettled",
                data,
                status: statusOf(error),
                variables,
                onMutateResult,
                ownClient: context.client === client,
            })
        },
    }
}

const createRequest: CreateAlertRequest = {
    accountId: ACCOUNT_ID,
    type: "TARGET_PRICE",
    instrumentId: INSTRUMENT_ID,
    direction: "ABOVE",
    threshold: THRESHOLD_TEXT,
}

const disableRequest = { id: armedAlert.id, enabled: false }

/** The hook function a call goes through. */
type CallVia = "mutate" | "mutateAsync"

/** The two call functions of an alert mutation hook, in the caller's terms. */
type CallFunctions<TData, TInput> = {
    mutate: (
        input: TInput,
        options?: MutateOptions<TData, Error, TInput, FeatureContext>
    ) => void
    mutateAsync: (
        input: TInput,
        options?: MutateOptions<TData, Error, TInput, FeatureContext>
    ) => Promise<TData>
}

/**
 * Calls `input` through `via` with options recording into `log`. A rejected
 * `mutateAsync` is left to the log, which records its failure.
 */
function callWithRecording<TData, TInput>(
    hook: CallFunctions<TData, TInput>,
    via: CallVia,
    input: TInput,
    log: CallbackRecord[]
): void {
    const options = recordingOptions<TData, TInput>(log)
    if (via === "mutate") {
        hook.mutate(input, options)
        return
    }
    hook.mutateAsync(input, options).catch(() => undefined)
}

/**
 * One alert hook called through `via` with per-call options recording into
 * the log, its caller's input, and the data its call resolves with on
 * success.
 */
type PerCallHook = {
    hook: string
    request: string
    input: unknown
    data: unknown
    call: (log: CallbackRecord[], via: CallVia) => void
}

const perCallHooks: PerCallHook[] = [
    {
        hook: "useCreateAlertMutation",
        request: CREATE,
        input: createRequest,
        data: { alert: createdAlert, threshold: THRESHOLD_TEXT },
        call: (log, via) => {
            const { result } = renderHook(
                () => useCreateAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                callWithRecording(result.current, via, createRequest, log)
            )
        },
    },
    {
        hook: "useUpdateAlertEnabledMutation",
        request: UPDATE,
        input: disableRequest,
        data: updateAction.success.body,
        call: (log, via) => {
            const { result } = renderHook(
                () => useUpdateAlertEnabledMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                callWithRecording(result.current, via, disableRequest, log)
            )
        },
    },
    {
        hook: "useDeleteAlertMutation",
        request: DELETE,
        input: armedAlert.id,
        data: undefined,
        call: (log, via) => {
            const { result } = renderHook(
                () => useDeleteAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                callWithRecording(result.current, via, armedAlert.id, log)
            )
        },
    },
    {
        hook: "useAcknowledgeAlertMutation",
        request: ACKNOWLEDGE,
        input: triggeredAlert.id,
        data: undefined,
        call: (log, via) => {
            const { result } = renderHook(
                () => useAcknowledgeAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            act(() =>
                callWithRecording(result.current, via, triggeredAlert.id, log)
            )
        },
    },
]

describe("Alert mutations", () => {
    beforeEach(() => {
        sessionStorage.setItem(SESSION_KEY, ACCOUNT_ID)
        client = new QueryClient()
        client.setQueryData(featureFlagKeys.portfolioInsights, true)
        requests = []
        createBodies = []
        createSpy = vi
            .spyOn(BizEvents, "alertCreate")
            .mockImplementation(() => undefined)
        // Every failed mutation logs its full error by design, and every
        // discarded one at debug level.
        vi.spyOn(console, "error").mockImplementation(() => undefined)
        vi.spyOn(console, "debug").mockImplementation(() => undefined)
    })

    afterEach(async () => {
        // Back online while still mounted, so a mutation a failed case left
        // paused resumes and settles below.
        act(() => onlineManager.setOnline(true))
        // Unmount first, so a released response refetches nothing.
        cleanup()
        releases.forEach((release) => release())
        releases = []
        // The spies stay in place until every released mutation has settled.
        await waitFor(() => expect(client.isMutating()).toBe(0))
        sessionStorage.clear()
        vi.restoreAllMocks()
        client.clear()
    })

    it("createAlert_success_invalidatesListAndNotifications", async () => {
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()
        const listBefore = countOf(LIST)
        const notificationsBefore = countOf(NOTIFICATIONS)

        await fillAndSubmit(user)

        await waitFor(() =>
            expect([
                countOf(LIST) - listBefore,
                countOf(NOTIFICATIONS) - notificationsBefore,
            ]).toEqual([1, 1])
        )
    })

    it("createAlert_success_sendsAlertCreateEvent", async () => {
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await fillAndSubmit(user)
        await screen.findByText(createdAlert.id, { selector: "output" })

        expect(createSpy).toHaveBeenCalledExactlyOnceWith({
            accountId: ACCOUNT_ID,
            alertId: createdAlert.id,
            type: "TARGET_PRICE",
            instrumentId: INSTRUMENT_ID,
            direction: "ABOVE",
            threshold: createdAlert.threshold,
        })
    })

    // The confirmation reports the token the body carried, not the typed text.
    it("createAlert_nonCanonicalThreshold_reportsSentToken", async () => {
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await fillAndSubmit(user, "105.500")
        const output = await waitFor(() =>
            elementBySelector("output#alert-created-id")
        )

        expect({
            dataThreshold: output.getAttribute("data-threshold"),
            sentBodies: createBodies,
        }).toEqual({
            dataThreshold: "105.5",
            sentBodies: [createBodyWith("105.5")],
        })
    })

    // Called directly, the hook still records the token `createAlert` sent,
    // whatever text the caller passed.
    it.each([
        { input: "1.500", sent: "1.5" },
        { input: "2.", sent: "2" },
    ])(
        "useCreateAlertMutation_nonCanonicalThreshold_recordsSentToken ($input)",
        async ({ input, sent }) => {
            stubFetch()
            const { result } = renderHook(
                () => useCreateAlertMutation(ACCOUNT_ID),
                { wrapper: ClientWrapper }
            )
            const request: CreateAlertRequest = {
                accountId: ACCOUNT_ID,
                type: "TARGET_PRICE",
                instrumentId: INSTRUMENT_ID,
                direction: "ABOVE",
                threshold: input,
            }

            act(() => result.current.mutate(request))
            await waitFor(() => expect(result.current.isSuccess).toBe(true))

            expect({
                recorded: result.current.created?.thresholdText,
                sentBodies: createBodies,
            }).toEqual({ recorded: sent, sentBodies: [createBodyWith(sent)] })
        }
    )

    // The hook's own `mutateAsync` and `variables` speak the caller's input,
    // not the context-carrying shape the mutation runs on.
    it("useCreateAlertMutation_mutateAsync_resolvesCreateWithCallerInput", async () => {
        stubFetch()
        const { result } = renderHook(
            () => useCreateAlertMutation(ACCOUNT_ID),
            { wrapper: ClientWrapper }
        )
        const request: CreateAlertRequest = {
            accountId: ACCOUNT_ID,
            type: "TARGET_PRICE",
            instrumentId: INSTRUMENT_ID,
            direction: "ABOVE",
            threshold: THRESHOLD_TEXT,
        }

        let created: unknown
        await act(async () => {
            created = await result.current.mutateAsync(request)
        })

        expect({ created, variables: result.current.variables }).toEqual({
            created: { alert: createdAlert, threshold: THRESHOLD_TEXT },
            variables: request,
        })
    })

    // A call's own callbacks receive the caller's input, not the write the
    // mutation runs on, the context captured at that call as its
    // `onMutateResult`, and their other arguments unchanged.
    it.each(
        perCallHooks.flatMap((hookCall) =>
            (["mutate", "mutateAsync"] as const).flatMap((via) => [
                { ...hookCall, via, outcome: "success", status: null },
                { ...hookCall, via, outcome: "failure", status: 500 },
            ])
        )
    )(
        "alertMutation_perCallCallbacks_receiveCallerInputAndCallContext ($hook, $via, $outcome)",
        async ({ request, input, data, call, via, status }) => {
            stubFetch(status === null ? {} : { [request]: () => ({ status }) })
            const log: CallbackRecord[] = []
            const ctx = captureFeatureContext()

            call(log, via)
            await waitFor(() =>
                expect(log[log.length - 1]?.callback).toBe("onSettled")
            )

            const received = {
                variables: input,
                onMutateResult: ctx,
                ownClient: true,
            }
            expect(log).toEqual(
                status === null
                    ? [
                          { callback: "onSuccess", data, status, ...received },
                          { callback: "onSettled", data, status, ...received },
                      ]
                    : [
                          {
                              callback: "onError",
                              data: undefined,
                              status,
                              ...received,
                          },
                          {
                              callback: "onSettled",
                              data: undefined,
                              status,
                              ...received,
                          },
                      ]
            )
        }
    )

    it("createAlert_failure_sendsNoEvent", async () => {
        stubFetch({ [CREATE]: () => ({ status: 400 }) })
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await fillAndSubmit(user)
        await within(createAction.errorRegion()).findByText(REJECTED_MESSAGE)

        expect(createSpy).not.toHaveBeenCalled()
    })

    it("createAlert_eventReportingThrows_stillInvalidatesListAndNotifications", async () => {
        failAlertCreateEvent()
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()
        const listBefore = countOf(LIST)
        const notificationsBefore = countOf(NOTIFICATIONS)

        await fillAndSubmit(user)

        await waitFor(() =>
            expect([
                countOf(LIST) - listBefore,
                countOf(NOTIFICATIONS) - notificationsBefore,
            ]).toEqual([1, 1])
        )
    })

    it("createAlert_eventReportingThrows_completesAsSuccess", async () => {
        failAlertCreateEvent()
        stubFetch()
        const user = userEvent.setup({ delay: null })
        const { container } = renderPanel(client)
        await waitForInitialLoad()

        await fillAndSubmit(user)

        await waitFor(() =>
            expect({
                statuses: client
                    .getMutationCache()
                    .getAll()
                    .map((mutation) => mutation.state.status),
                createdId:
                    container.querySelector("output#alert-created-id")
                        ?.textContent ?? null,
                formError:
                    container.querySelector("#alert-form-error")?.textContent ??
                    null,
            }).toEqual({
                statuses: ["success"],
                createdId: createdAlert.id,
                formError: null,
            })
        )
    })

    it("createAlert_eventReportingThrows_logsFullError", async () => {
        const reportingError = failAlertCreateEvent()
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await fillAndSubmit(user)

        await waitFor(() =>
            expect(console.error).toHaveBeenCalledWith(
                "[useCreateAlertMutation] alertCreate event failed",
                reportingError
            )
        )
    })

    it.each<[string, MutationAction]>([
        ["update-enabled", updateAction],
        ["delete", deleteAction],
        ["acknowledge", acknowledgeAction],
    ])(
        "alertMutation_success_invalidatesListAndNotifications (%s)",
        async (_label, action) => {
            stubFetch()
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()
            const listBefore = countOf(LIST)
            const notificationsBefore = countOf(NOTIFICATIONS)

            await action.start(user)
            // A row mutation stays pending until the refetches it starts
            // have settled, so every refetch it causes is counted below.
            await waitFor(() => expect(client.isMutating()).toBe(0))

            expect([
                countOf(LIST) - listBefore,
                countOf(NOTIFICATIONS) - notificationsBefore,
            ]).toEqual([1, 1])
        }
    )

    it("deleteAlert_success_rendersDeletedIdOutput", async () => {
        stubFetch()
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await deleteAction.start(user)

        // Loadgen's `//output[@id="alert-deleted-id"][@value="<id>"]` reads
        // the attribute, so the one output must carry the deleted id there.
        await waitFor(() =>
            expect(
                Array.from(
                    document.querySelectorAll("output#alert-deleted-id"),
                    (output) => output.getAttribute("value")
                )
            ).toEqual([armedAlert.id])
        )
    })

    it("acknowledgeAlert_success_removesNotification", async () => {
        // As the broker does, the poll stops serving the notification once
        // its acknowledge has been answered.
        let acknowledged = false
        stubFetch({
            [ACKNOWLEDGE]: () => {
                acknowledged = true
                return acknowledgeAction.success
            },
            [NOTIFICATIONS]: () => ({
                status: 200,
                body: { results: acknowledged ? [] : [triggeredAlert] },
            }),
        })
        const user = userEvent.setup({ delay: null })
        renderPanel(client)
        await waitForInitialLoad()

        await acknowledgeAction.start(user)

        await waitFor(() =>
            expect(document.querySelector(NOTIFICATION_ITEM)).toBeNull()
        )
    })

    it.each<[string, MutationAction]>([
        ["create", createAction],
        ["update-enabled", updateAction],
        ["delete", deleteAction],
        ["acknowledge", acknowledgeAction],
    ])(
        "alertMutation_pending_disablesControls (%s)",
        async (_label, action) => {
            stubFetch({ [action.request]: hold(action.success).handler })
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()

            await action.start(user)

            await waitForControls(action, "disabled")
        }
    )

    it.each<[string, MutationAction, number, string]>([
        ["create 400", createAction, 400, REJECTED_MESSAGE],
        ["create 404", createAction, 404, CREATE_NOT_FOUND_MESSAGE],
        ["create 500", createAction, 500, GENERIC_MESSAGE],
        ["update-enabled 400", updateAction, 400, GENERIC_MESSAGE],
        ["update-enabled 404", updateAction, 404, ROW_NOT_FOUND_MESSAGE],
        ["update-enabled 500", updateAction, 500, GENERIC_MESSAGE],
        ["delete 404", deleteAction, 404, ROW_NOT_FOUND_MESSAGE],
        ["delete 500", deleteAction, 500, GENERIC_MESSAGE],
        // The refresh after the 404 still serves the notification, so its
        // item keeps the message.
        ["acknowledge 404", acknowledgeAction, 404, ROW_NOT_FOUND_MESSAGE],
        ["acknowledge 500", acknowledgeAction, 500, GENERIC_MESSAGE],
    ])(
        "alertMutation_errorStatus_showsMessage (%s)",
        async (_label, action, status, message) => {
            stubFetch({ [action.request]: () => ({ status }) })
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()

            await action.start(user)

            expect(
                await within(action.errorRegion()).findByText(message)
            ).toHaveAttribute("role", "alert")
        }
    )

    // A 2xx other than the specified 201, 200 or 204 confirms nothing, even
    // with an alert-shaped body, and neither does the specified status with
    // a body that is not a valid alert.
    it.each<[string, MutationAction, StubResponse, string | null]>([
        [
            "create 200",
            createAction,
            { status: 200, body: createdAlert },
            "output#alert-created-id",
        ],
        [
            "create 202",
            createAction,
            { status: 202, body: createdAlert },
            "output#alert-created-id",
        ],
        [
            "create 201 without id",
            createAction,
            { status: 201, body: { ...createdAlert, id: undefined } },
            "output#alert-created-id",
        ],
        [
            "create 201 malformed JSON",
            createAction,
            { status: 201, text: `<${createdAlert.id}` },
            "output#alert-created-id",
        ],
        [
            "update-enabled 202",
            updateAction,
            { status: 202, body: { ...armedAlert, enabled: false } },
            null,
        ],
        ["update-enabled 204", updateAction, { status: 204 }, null],
        [
            "update-enabled 200 without id",
            updateAction,
            { status: 200, body: { ...armedAlert, id: undefined } },
            null,
        ],
        [
            "update-enabled 200 malformed JSON",
            updateAction,
            { status: 200, text: "<not json>" },
            null,
        ],
        [
            "delete 200",
            deleteAction,
            { status: 200, body: armedAlert },
            "output#alert-deleted-id",
        ],
        [
            "delete 202",
            deleteAction,
            { status: 202, body: armedAlert },
            "output#alert-deleted-id",
        ],
        ["acknowledge 200", acknowledgeAction, { status: 200, body: {} }, null],
        ["acknowledge 202", acknowledgeAction, { status: 202 }, null],
    ])(
        "alertMutation_unconfirmedReply_showsGenericMessageWithoutConfirmation (%s)",
        async (_label, action, response, outputSelector) => {
            stubFetch({ [action.request]: () => response })
            const user = userEvent.setup({ delay: null })
            const { container } = renderPanel(client)
            await waitForInitialLoad()
            const readsBefore = countOf(LIST) + countOf(NOTIFICATIONS)

            await action.start(user)
            await within(action.errorRegion()).findByText(GENERIC_MESSAGE)

            expect({
                output:
                    outputSelector === null
                        ? null
                        : container.querySelector(outputSelector),
                events: createSpy.mock.calls.length,
                refetches: countOf(LIST) + countOf(NOTIFICATIONS) - readsBefore,
            }).toEqual({ output: null, events: 0, refetches: 0 })
        }
    )

    it.each<[string, MutationAction]>([
        ["create", createAction],
        ["update-enabled", updateAction],
        ["delete", deleteAction],
        ["acknowledge", acknowledgeAction],
    ])(
        "alertMutation_forbidden_shutsDownFeature (%s)",
        async (_label, action) => {
            // Held until the pending state has rendered, as network latency
            // orders it: a 403 answered within the same task would reach the
            // shutdown before that render, which then rebuilds the queries.
            const held = hold({ status: 403 })
            stubFetch({ [action.request]: held.handler })
            seedInsights(client)
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()
            await action.start(user)
            await waitForControls(action, "disabled")

            held.release()

            await waitFor(() => {
                const cache = client.getQueryCache()
                expect({
                    flag: client.getQueryData(
                        featureFlagKeys.portfolioInsights
                    ),
                    alertQueries: cache.findAll({ queryKey: alertKeys.all })
                        .length,
                    insightsQueries: cache.findAll({
                        queryKey: portfolioKeys.insightsAll,
                    }).length,
                }).toEqual({ flag: false, alertQueries: 0, insightsQueries: 0 })
            })
        }
    )

    it.each<[string, MutationAction, string | null]>([
        ["create", createAction, "output#alert-created-id"],
        ["update-enabled", updateAction, null],
        ["delete", deleteAction, "output#alert-deleted-id"],
        ["acknowledge", acknowledgeAction, null],
    ])(
        "alertMutation_completesAfterAccountSwitch_discarded (%s)",
        async (_label, action, outputSelector) => {
            const held = hold(action.success)
            stubFetch({ [action.request]: held.handler })
            const user = userEvent.setup({ delay: null })
            const { container } = renderPanel(client)
            await waitForInitialLoad()
            await action.start(user)
            await waitFor(() => expect(countOf(action.request)).toBe(1))
            await waitForControls(action, "disabled")
            const listBefore = countOf(LIST)
            const notificationsBefore = countOf(NOTIFICATIONS)

            sessionStorage.setItem(SESSION_KEY, "2")
            held.release()
            await waitForControls(action, "enabled")

            expect({
                output:
                    outputSelector === null
                        ? null
                        : container.querySelector(outputSelector),
                events: createSpy.mock.calls.length,
                listRequests: countOf(LIST) - listBefore,
                notificationsRequests:
                    countOf(NOTIFICATIONS) - notificationsBefore,
            }).toEqual({
                output: null,
                events: 0,
                listRequests: 0,
                notificationsRequests: 0,
            })
        }
    )

    // The logged error names its endpoint by template, while the original,
    // whose URL names the alert, still decides the message shown.
    it.each<[string, MutationAction, number, string, string, string]>([
        [
            "create 500",
            createAction,
            500,
            GENERIC_MESSAGE,
            "[useCreateAlertMutation] failed",
            "/broker-service/v1/alerts",
        ],
        [
            "update-enabled 404",
            updateAction,
            404,
            ROW_NOT_FOUND_MESSAGE,
            "[useUpdateAlertEnabledMutation] failed",
            "/broker-service/v1/alerts/{id}",
        ],
        [
            "delete 404",
            deleteAction,
            404,
            ROW_NOT_FOUND_MESSAGE,
            "[useDeleteAlertMutation] failed",
            "/broker-service/v1/alerts/{id}",
        ],
        [
            "acknowledge 404",
            acknowledgeAction,
            404,
            ROW_NOT_FOUND_MESSAGE,
            "[useAcknowledgeAlertMutation] failed",
            "/broker-service/v1/alerts/{id}/acknowledge",
        ],
    ])(
        "alertMutation_failure_logsEndpointTemplateWithoutAlertId (%s)",
        async (_label, action, status, shown, logLine, endpoint) => {
            stubFetch({ [action.request]: () => ({ status }) })
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()

            await action.start(user)
            await within(action.errorRegion()).findByText(shown)

            const logged = vi
                .mocked(console.error)
                .mock.calls.find(([line]) => line === logLine)?.[1] as Error & {
                status?: number
                endpoint?: string
            }
            const text = `${logged.name}\n${logged.message}\n${logged.stack ?? ""}`
            expect({
                name: logged.name,
                status: logged.status,
                endpoint: logged.endpoint,
                message: logged.message,
                leaked: [armedAlert.id, triggeredAlert.id, BROKER].filter(
                    (part) => text.includes(part)
                ),
            }).toEqual({
                name: "ApiError",
                status,
                endpoint,
                message: `HTTP ${status} for ${endpoint}`,
                leaked: [],
            })
        }
    )

    // A mutation started offline waits, paused, before its request. Once its
    // context has ended, reconnecting must not send it.
    it.each(
        mutationActions.flatMap(([label, action]) =>
            contextEnds.map(({ boundary, end }) => ({
                label,
                action,
                boundary,
                end,
            }))
        )
    )(
        "alertMutation_queuedOfflineThenContextEnds_sendsNothingOnReconnect ($label, $boundary)",
        async ({ action, end }) => {
            stubFetch()
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()
            onlineManager.setOnline(false)
            await action.start(user)
            await waitFor(() => expect(pausedMutationCount()).toBe(1))

            act(() => end())
            act(() => onlineManager.setOnline(true))
            await waitFor(() => expect(client.isMutating()).toBe(0))

            expect({
                writes: countOf(action.request),
                messages: shownMessages(),
            }).toEqual({ writes: 0, messages: [] })
        }
    )

    it.each(mutationActions)(
        "alertMutation_queuedOfflineStillCurrent_sendsOnReconnect (%s)",
        async (_label, action) => {
            stubFetch()
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()
            onlineManager.setOnline(false)
            await action.start(user)
            await waitFor(() => expect(pausedMutationCount()).toBe(1))

            act(() => onlineManager.setOnline(true))
            await waitFor(() => expect(client.isMutating()).toBe(0))

            expect(countOf(action.request)).toBe(1)
        }
    )

    // The request is held until its signal aborts, so only an abort ends it.
    it.each(
        mutationActions.flatMap(([label, action]) =>
            contextEnds
                .filter(({ boundary }) => boundary !== "account switch")
                .map(({ boundary, end }) => ({ label, action, boundary, end }))
        )
    )(
        "alertMutation_inFlightWhenContextEnds_abortsRequestAndShowsNothing ($label, $boundary)",
        async ({ action, end }) => {
            const signals: (AbortSignal | undefined)[] = []
            stubFetch({ [action.request]: heldUntilAborted(signals) })
            const user = userEvent.setup({ delay: null })
            renderPanel(client)
            await waitForInitialLoad()
            await action.start(user)
            await waitFor(() => expect(countOf(action.request)).toBe(1))

            act(() => end())
            await waitFor(() => expect(client.isMutating()).toBe(0))

            expect({
                aborted: signals.map((signal) => signal?.aborted),
                messages: shownMessages(),
                loggedAbort: vi
                    .mocked(console.debug)
                    .mock.calls.some(
                        ([, logged]) =>
                            logged instanceof DOMException &&
                            logged.name === "AbortError"
                    ),
            }).toEqual({ aborted: [true], messages: [], loggedAbort: true })
        }
    )

    // A write for an account other than the tab's is refused before any
    // request, and shows no message: not even the generic one.
    it.each(hookCalls)(
        "alertMutation_otherAccountSignedIn_sendsNothingAndShowsNoMessage ($hook)",
        async ({ request, call }) => {
            stubFetch()
            sessionStorage.setItem(SESSION_KEY, "2")

            const hook = call()
            await waitFor(() => expect(hook.settled()).toBe(true))

            expect({
                writes: countOf(request),
                messages: hook.messages(),
            }).toEqual({ writes: 0, messages: [] })
        }
    )

    // The body names the input's account, while the tab and the hook are
    // signed in to another: the create is refused before any request, as a
    // discarded write that shows, sends and refreshes nothing.
    it("useCreateAlertMutation_inputForOtherAccount_sendsNothingAndShowsNoMessage", async () => {
        stubFetch()
        const { result } = renderHook(
            () => useCreateAlertMutation(ACCOUNT_ID),
            { wrapper: ClientWrapper }
        )

        act(() =>
            result.current.mutate({
                accountId: "2",
                type: "TARGET_PRICE",
                instrumentId: INSTRUMENT_ID,
                direction: "ABOVE",
                threshold: THRESHOLD_TEXT,
            })
        )
        await waitFor(() => expect(result.current.isError).toBe(true))

        expect({
            requests,
            created: result.current.created,
            errorMessage: result.current.errorMessage,
            events: createSpy.mock.calls.length,
        }).toEqual({
            requests: [],
            created: null,
            errorMessage: null,
            events: 0,
        })
    })
})
