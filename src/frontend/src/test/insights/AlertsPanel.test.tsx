import "@testing-library/jest-dom/vitest"
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import { FormatterWrapper } from "../providers"
import { ApiError } from "../../api/http"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { featureFlagKeys } from "../../utils/queryKeys"

// Covers the panel's own wiring: its two queries' loading, error and 403
// states, and how mutation results reach the form, rows and notifications.
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

const BROKER = `${window.location.origin}/broker-service/v1`
const LIST_URL = `${BROKER}/alerts?accountId=1`
const NOTIFICATIONS_URL = `${BROKER}/alerts/notifications?accountId=1&unacknowledged=true`

type StubResponse = { status: number; body?: unknown }
type Handler = () => StubResponse | Promise<StubResponse>

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
    const held = hold()
    releaseHeld.push(held.release)
    return async () => {
        await held.promise
        return response
    }
}

function renderPanel() {
    return render(
        <QueryClientProvider client={client}>
            <FormatterWrapper>
                <AlertsPanel accountId="1" instruments={instruments} />
            </FormatterWrapper>
        </QueryClientProvider>
    )
}

function rowOf(alertId: string): HTMLElement {
    const row = document.querySelector<HTMLElement>(
        `li[data-alert-id="${alertId}"]`
    )
    if (row === null) throw new Error(`No row for alert ${alertId}`)
    return row
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

    afterEach(() => {
        releaseHeld.forEach((release) => release())
        releaseHeld = []
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

        expect(screen.getByText("Loading alerts\u2026")).toHaveClass(
            "empty-state"
        )
    })

    it.each([
        ["list", LIST_URL, "Could not load alerts. Please try again later."],
        [
            "notifications",
            NOTIFICATIONS_URL,
            "Could not load notifications. Please try again later.",
        ],
    ])(
        "alertsPanel_%sQueryFails_showsRegionError",
        async (_name, url, message) => {
            stubFetch({ [`GET ${url}`]: () => ({ status: 500 }) })
            renderPanel()

            expect(await screen.findByText(message)).toHaveClass(
                "status-message",
                "status-error"
            )
        }
    )

    it("alertsPanel_listQueryFails_logsFullError", async () => {
        stubFetch({ [`GET ${LIST_URL}`]: () => ({ status: 500 }) })
        renderPanel()

        await waitFor(() =>
            expect(console.error).toHaveBeenCalledWith(
                "[AlertsPanel] could not load alerts",
                expect.any(ApiError)
            )
        )
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

    it("alertsPanel_acknowledgeNotFound_showsMessageBesideListRow", async () => {
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
            await within(rowOf(triggeredAlert.id)).findByText(
                "This alert no longer exists."
            )
        ).toHaveClass("field-error")
    })

    it("alertsPanel_created_reportsSubmittedThresholdText", async () => {
        stubFetch({
            [`POST ${BROKER}/alerts`]: () => ({
                status: 201,
                body: createdAlert,
            }),
        })
        const user = userEvent.setup({ delay: null })
        const { container } = renderPanel()
        await screen.findByText("Armed")

        await user.selectOptions(
            screen.getByLabelText("Instrument"),
            INSTRUMENT_ID
        )
        await user.type(screen.getByLabelText("Threshold"), "105.500")
        await user.click(screen.getByRole("button", { name: "Create alert" }))

        await waitFor(() =>
            expect(
                container.querySelector("output#alert-created-id")
            ).toHaveAttribute("data-threshold", "105.500")
        )
    })
})
