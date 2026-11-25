import "@testing-library/jest-dom/vitest"
import type { ComponentProps } from "react"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { AlertList } from "../../components/insights/AlertList"
import { AlertNotifications } from "../../components/insights/AlertNotifications"
import { FormatterWrapper } from "../providers"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"

type AlertListProps = ComponentProps<typeof AlertList>
type AlertNotificationsProps = ComponentProps<typeof AlertNotifications>

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

function makeAlert(overrides: Partial<Alert>): Alert {
    return {
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
        ...overrides,
    }
}

const armed = makeAlert({ id: "a1000000-0000-4000-8000-000000000001" })
const triggered = makeAlert({
    id: "a1000000-0000-4000-8000-000000000002",
    triggeredAt: "2026-01-01T10:00:00Z",
    triggerValue: 10.5,
})
const disabled = makeAlert({
    id: "a1000000-0000-4000-8000-000000000003",
    enabled: false,
})
// A trigger survives a disable, and the row still offers only "Enable".
const disabledAfterTrigger = makeAlert({
    id: "a1000000-0000-4000-8000-000000000004",
    enabled: false,
    triggeredAt: "2026-01-01T10:00:00Z",
    triggerValue: 10.5,
})

function renderList(overrides: Partial<AlertListProps> = {}): void {
    render(
        <FormatterWrapper>
            <AlertList
                alerts={[armed, triggered, disabled, disabledAfterTrigger]}
                instruments={instruments}
                onSetEnabled={vi.fn()}
                onDelete={vi.fn()}
                pendingIds={new Set<string>()}
                rowErrors={{}}
                deletedId={null}
                {...overrides}
            />
        </FormatterWrapper>
    )
}

function renderNotifications(
    overrides: Partial<AlertNotificationsProps> = {}
): HTMLElement {
    const { container } = render(
        <FormatterWrapper>
            <AlertNotifications
                notifications={[triggered]}
                instruments={instruments}
                onAcknowledge={vi.fn()}
                pendingIds={new Set<string>()}
                {...overrides}
            />
        </FormatterWrapper>
    )
    return container
}

/** The loadgen row selector `//li[@data-alert-id="<id>"]`, as CSS. */
function row(id: string): HTMLElement {
    const element = document.querySelector<HTMLElement>(
        `li[data-alert-id="${id}"]`
    )
    if (element === null) throw new Error(`No alert row [${id}] rendered`)
    return element
}

afterEach(() => vi.restoreAllMocks())

it.each<{
    state: string
    alert: Alert
    actions: { name: string; className: string }[]
}>([
    {
        state: "armed",
        alert: armed,
        actions: [
            { name: "Disable", className: "alert-toggle" },
            { name: "Delete", className: "alert-delete" },
        ],
    },
    {
        state: "triggered",
        alert: triggered,
        actions: [
            { name: "Re-arm", className: "alert-toggle" },
            { name: "Disable", className: "alert-disable" },
            { name: "Delete", className: "alert-delete" },
        ],
    },
    {
        state: "disabled",
        alert: disabled,
        actions: [
            { name: "Enable", className: "alert-toggle" },
            { name: "Delete", className: "alert-delete" },
        ],
    },
    {
        state: "disabled after trigger",
        alert: disabledAfterTrigger,
        actions: [
            { name: "Enable", className: "alert-toggle" },
            { name: "Delete", className: "alert-delete" },
        ],
    },
])("alertList_rowState_showsActions ($state)", ({ alert, actions }) => {
    renderList()
    const scope = within(row(alert.id))

    // `getByRole` throws on a missing or repeated label, so the lookups and
    // the count together pin the row to exactly these actions.
    for (const { name, className } of actions) {
        expect(scope.getByRole("button", { name })).toHaveClass(className)
    }
    expect(scope.getAllByRole("button")).toHaveLength(actions.length)
})

it.each<{ action: string; alert: Alert; name: string; enabled: boolean }>([
    { action: "armed Disable", alert: armed, name: "Disable", enabled: false },
    {
        action: "triggered Re-arm",
        alert: triggered,
        name: "Re-arm",
        enabled: true,
    },
    {
        action: "triggered Disable",
        alert: triggered,
        name: "Disable",
        enabled: false,
    },
    {
        action: "disabled Enable",
        alert: disabled,
        name: "Enable",
        enabled: true,
    },
])(
    "alertList_action_sendsEnabledValue ($action)",
    async ({ alert, name, enabled }) => {
        const user = userEvent.setup({ delay: null })
        const onSetEnabled = vi.fn<AlertListProps["onSetEnabled"]>()
        renderList({ onSetEnabled })

        await user.click(within(row(alert.id)).getByRole("button", { name }))

        expect(onSetEnabled.mock.calls).toEqual([[alert.id, enabled]])
    }
)

it("alertList_delete_callsHandler", async () => {
    const user = userEvent.setup({ delay: null })
    const onDelete = vi.fn<AlertListProps["onDelete"]>()
    renderList({ onDelete })

    await user.click(
        within(row(triggered.id)).getByRole("button", { name: "Delete" })
    )

    expect(onDelete.mock.calls).toEqual([[triggered.id]])
})

it.each<{ scenario: string; alerts: Alert[] }>([
    { scenario: "rows remain", alerts: [triggered, disabled] },
    { scenario: "last row deleted", alerts: [] },
])("alertList_deleted_rendersDeletedIdOutput ($scenario)", ({ alerts }) => {
    renderList({ alerts, deletedId: armed.id })

    // Loadgen's `//output[@id="alert-deleted-id"][@value="<id>"]` reads the
    // attribute, not the element's text.
    expect(document.querySelector("output#alert-deleted-id")).toHaveAttribute(
        "value",
        armed.id
    )
})

it("alertList_noAlerts_showsEmpty", () => {
    renderList({ alerts: [] })

    expect(document.querySelector("p#alerts-empty")).toHaveTextContent(
        /^No alerts yet\.$/
    )
})

it.each<{ state: string; alert: Alert; status: string | RegExp }>([
    { state: "armed", alert: armed, status: "Armed" },
    {
        state: "triggered",
        alert: triggered,
        // en-US short date and time; the hour depends on the host time zone.
        status: /^Triggered at \d{1,2}\/\d{1,2}\/\d{2}, \d{1,2}:\d{2} [AP]M \(10\.5\)$/,
    },
    {
        state: "triggered, unparsable time",
        alert: makeAlert({
            id: "a1000000-0000-4000-8000-000000000005",
            triggeredAt: "not-a-date",
            triggerValue: 10.5,
        }),
        status: "Triggered at not-a-date (10.5)",
    },
    { state: "disabled", alert: disabled, status: "Disabled" },
    {
        state: "disabled after trigger",
        alert: disabledAfterTrigger,
        status: "Disabled",
    },
])("alertList_rowState_showsStatus ($state)", ({ alert, status }) => {
    renderList({ alerts: [alert] })

    expect(within(row(alert.id)).getByText(status)).toBeInTheDocument()
})

it.each<{ scenario: string; alert: Alert; name: string }>([
    { scenario: "listed instrument", alert: armed, name: "EasyTravel" },
    {
        scenario: "unlisted instrument",
        alert: makeAlert({
            id: "a1000000-0000-4000-8000-000000000006",
            instrumentId: "9f3c2b1a-0000-4000-8000-000000000009",
        }),
        name: "9f3c2b1a",
    },
])("alertList_row_showsInstrumentName ($scenario)", ({ alert, name }) => {
    renderList({ alerts: [alert] })

    expect(within(row(alert.id)).getByText(name)).toBeInTheDocument()
})

it("alertNotifications_acknowledge_callsHandler", async () => {
    const user = userEvent.setup({ delay: null })
    const onAcknowledge = vi.fn<AlertNotificationsProps["onAcknowledge"]>()
    renderNotifications({ onAcknowledge })

    await user.click(screen.getByRole("button", { name: "Acknowledge" }))

    expect(onAcknowledge.mock.calls).toEqual([[triggered.id]])
})

it("alertNotifications_item_hasNoAlertRowAttribute", () => {
    renderNotifications()

    // Loadgen's row selectors match `data-alert-id`; a notification for the
    // same alert must never be taken for its row.
    const items = Array.from(
        document.querySelectorAll(
            "ul#alert-notifications > li.alert-notification"
        )
    )
    expect(
        items.map((item) => ({
            alertRow: item.hasAttribute("data-alert-id"),
            acknowledge:
                item.querySelector("button.alert-acknowledge") !== null,
        }))
    ).toEqual([{ alertRow: false, acknowledge: true }])
})

it("alertNotifications_none_rendersNothing", () => {
    const container = renderNotifications({ notifications: [] })

    expect(container).toBeEmptyDOMElement()
})
