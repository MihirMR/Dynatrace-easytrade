import "@testing-library/jest-dom/vitest"
import type { ComponentProps } from "react"
import { render } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { AlertForm } from "../../components/insights/AlertForm"
import type { AlertFormInput, AlertType } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"

type AlertFormProps = ComponentProps<typeof AlertForm>
type User = ReturnType<typeof userEvent.setup>

const HELD_ID = "c0000000-0000-4000-8000-000000000001"
const NOT_HELD_ID = "c0000000-0000-4000-8000-000000000002"

const instruments: Instrument[] = [
    {
        id: HELD_ID,
        code: "ETRAVE",
        name: "EasyTravel",
        description: "EasyTravel Incorporated",
        productId: 1,
        productName: "Share",
        price: {
            timestamp: "2026-01-01T09:00:00Z",
            open: 137.68958333,
            close: 137.73125,
            low: 136.37064957,
            high: 139.07805518,
        },
        amount: 5,
    },
    {
        id: NOT_HELD_ID,
        code: "EPLANE",
        name: "EasyPlanes",
        description: "EasyPlanes Worldwide",
        productId: 2,
        productName: "ETF",
        price: {
            timestamp: "2026-01-01T09:00:00Z",
            open: 94.86888889,
            close: 94.91333333,
            low: 94.31277586,
            high: 95.44784334,
        },
        amount: 0,
    },
]

/** Renders the form and returns the `onCreate` mock it was given. */
function renderForm(overrides: Partial<Omit<AlertFormProps, "onCreate">> = {}) {
    const onCreate = vi.fn<(input: AlertFormInput) => void>()
    render(
        <AlertForm
            instruments={instruments}
            onCreate={onCreate}
            isPending={false}
            serverError={null}
            created={null}
            {...overrides}
        />
    )
    return onCreate
}

/** Looks up an element by the id loadgen and the browser check bind. */
function byId<T extends HTMLElement = HTMLElement>(id: string): T {
    const element = document.getElementById(id)
    if (element === null) throw new Error(`No element [#${id}] rendered`)
    return element as T
}

/**
 * Fills every field. The instrument is chosen while the type is still the
 * default TARGET_PRICE: PROFIT_LOSS disables the options of instruments the
 * account does not hold, and switching the type afterwards is how a user
 * reaches the not-held state that validation must reject.
 */
async function fillForm(user: User, input: AlertFormInput): Promise<void> {
    await user.selectOptions(
        byId<HTMLSelectElement>("alert-instrument"),
        input.instrumentId
    )
    await user.selectOptions(byId<HTMLSelectElement>("alert-type"), input.type)
    await user.selectOptions(
        byId<HTMLSelectElement>("alert-direction"),
        input.direction
    )
    await user.type(byId<HTMLInputElement>("alert-threshold"), input.threshold)
}

afterEach(() => vi.restoreAllMocks())

describe("AlertForm", () => {
    it.each<AlertFormInput & { scenario: string; message: string }>([
        {
            scenario: "missing instrument",
            type: "TARGET_PRICE",
            instrumentId: "",
            direction: "ABOVE",
            threshold: "10",
            message: "Select an instrument.",
        },
        {
            scenario: "non-numeric threshold",
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "ABOVE",
            threshold: "abc",
            message: "Threshold must be a number.",
        },
        {
            scenario: "target price zero",
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "ABOVE",
            threshold: "0",
            message: "Target price must be greater than 0.",
        },
        {
            scenario: "target price negative",
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "BELOW",
            threshold: "-1",
            message: "Target price must be greater than 0.",
        },
        {
            scenario: "profit/loss on not-held instrument",
            type: "PROFIT_LOSS",
            instrumentId: NOT_HELD_ID,
            direction: "ABOVE",
            threshold: "5",
            message: "Profit/loss alerts need an instrument you hold.",
        },
        {
            scenario: "11 integer digits",
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "ABOVE",
            threshold: "12345678901",
            message:
                "Threshold allows at most 10 integer and 8 decimal digits.",
        },
        {
            scenario: "9 fractional digits",
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "ABOVE",
            threshold: "1.123456789",
            message:
                "Threshold allows at most 10 integer and 8 decimal digits.",
        },
    ])(
        "alertForm_invalidInput_showsError ($scenario)",
        async ({ type, instrumentId, direction, threshold, message }) => {
            const user = userEvent.setup({ delay: null })
            const onCreate = renderForm()

            await fillForm(user, { type, instrumentId, direction, threshold })
            await user.click(byId("alert-submit"))

            // Rejected with exactly this message, and nothing is sent.
            expect(byId("alert-form-error").textContent).toBe(message)
            expect(onCreate).not.toHaveBeenCalled()
        }
    )

    it.each<{ scenario: string; input: AlertFormInput }>([
        {
            scenario: "target price on held instrument",
            input: {
                type: "TARGET_PRICE",
                instrumentId: HELD_ID,
                direction: "ABOVE",
                threshold: "105.5",
            },
        },
        {
            // A negative percentage is a valid profit/loss threshold.
            scenario: "profit/loss on held instrument",
            input: {
                type: "PROFIT_LOSS",
                instrumentId: HELD_ID,
                direction: "BELOW",
                threshold: "-2.5",
            },
        },
    ])("alertForm_validInput_callsHandler ($scenario)", async ({ input }) => {
        const user = userEvent.setup({ delay: null })
        const onCreate = renderForm()

        await fillForm(user, input)
        await user.click(byId("alert-submit"))

        expect(onCreate.mock.calls).toEqual([[input]])
    })

    it("alertForm_maxThreshold_submitsExactText", async () => {
        const user = userEvent.setup({ delay: null })
        const onCreate = renderForm()

        await fillForm(user, {
            type: "TARGET_PRICE",
            instrumentId: HELD_ID,
            direction: "ABOVE",
            threshold: "9999999999.99999999",
        })
        await user.click(byId("alert-submit"))

        // A JavaScript number would read this as 10000000000, so the handler
        // must receive the typed text itself.
        expect(onCreate.mock.calls.map(([input]) => input.threshold)).toEqual([
            "9999999999.99999999",
        ])
    })

    // The validation rows cannot see which options are selectable, so this
    // pins the form's own option-disabling branch.
    it.each<{ type: AlertType; notHeldDisabled: boolean }>([
        { type: "TARGET_PRICE", notHeldDisabled: false },
        { type: "PROFIT_LOSS", notHeldDisabled: true },
    ])(
        "alertForm_alertType_disablesOnlyNotHeldForProfitLoss ($type)",
        async ({ type, notHeldDisabled }) => {
            const user = userEvent.setup({ delay: null })
            renderForm()

            await user.selectOptions(
                byId<HTMLSelectElement>("alert-type"),
                type
            )

            expect(
                Array.from(
                    byId<HTMLSelectElement>("alert-instrument").options,
                    (option) => [option.value, option.disabled]
                )
            ).toEqual([
                ["", false],
                [HELD_ID, false],
                [NOT_HELD_ID, notHeldDisabled],
            ])
        }
    )

    it("alertForm_created_rendersCreatedIdWithThreshold", () => {
        const id = "a0000000-0000-4000-8000-0000000000aa"
        renderForm({ created: { id, threshold: "1000000.40271930" } })

        // Loadgen's `//output[@id="alert-created-id"][@data-threshold=...]`
        // matches attributes and reads the id from `value`, so both
        // attributes are the contract, not the element's text.
        const output = document.querySelector("output#alert-created-id")
        expect(output).toHaveAttribute("value", id)
        expect(output).toHaveAttribute("data-threshold", "1000000.40271930")
    })
})
