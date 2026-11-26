import "@testing-library/jest-dom/vitest"
import type { ComponentProps } from "react"
import { render } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { AlertForm } from "../../components/insights/AlertForm"
import type {
    AlertFormInput,
    AlertType,
    ValidatedAlertInput,
} from "../../api/alerts/types"
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
    const onCreate = vi.fn<(input: ValidatedAlertInput) => void>()
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

/** Looks up an element by its stable id. */
function byId<T extends HTMLElement = HTMLElement>(id: string): T {
    const element = document.getElementById(id)
    if (element === null) throw new Error(`No element [#${id}] rendered`)
    return element as T
}

/**
 * Fills every field. The instrument is chosen while the type is still the
 * default TARGET_PRICE: PROFIT_LOSS disables the options of instruments the
 * account does not hold, and switching the type afterwards is how a user
 * reaches the not-held state that validation must reject. An empty threshold
 * leaves the field untouched, as user-event cannot type an empty string.
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
    if (input.threshold !== "") {
        await user.type(
            byId<HTMLInputElement>("alert-threshold"),
            input.threshold
        )
    }
}

const CONTROL_IDS = [
    "alert-type",
    "alert-instrument",
    "alert-direction",
    "alert-threshold",
]

/** How each form control is tied to the validation message, by control id. */
function controlMarks() {
    return CONTROL_IDS.map((id) => {
        const control = byId(id)
        return {
            id,
            ariaInvalid: control.getAttribute("aria-invalid"),
            describedBy: control.getAttribute("aria-describedby"),
            errorOutline: control.classList.contains("error"),
        }
    })
}

/** The marks `controlMarks` reads when only `markedId` holds the error. */
function expectedMarks(markedId: string | null) {
    return CONTROL_IDS.map((id) =>
        id === markedId
            ? {
                  id,
                  ariaInvalid: "true",
                  describedBy: "alert-form-error",
                  errorOutline: true,
              }
            : { id, ariaInvalid: null, describedBy: null, errorOutline: false }
    )
}

const MISSING_INSTRUMENT: AlertFormInput = {
    type: "TARGET_PRICE",
    instrumentId: "",
    direction: "ABOVE",
    threshold: "10",
}

const NON_NUMERIC: AlertFormInput = {
    type: "TARGET_PRICE",
    instrumentId: HELD_ID,
    direction: "ABOVE",
    threshold: "abc",
}

const PROFIT_LOSS_NOT_HELD: AlertFormInput = {
    type: "PROFIT_LOSS",
    instrumentId: NOT_HELD_ID,
    direction: "ABOVE",
    threshold: "5",
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

    // The message is tied to the control the first failing rule concerns.
    it.each<{ scenario: string; input: AlertFormInput; markedId: string }>([
        {
            scenario: "missing instrument",
            input: MISSING_INSTRUMENT,
            markedId: "alert-instrument",
        },
        {
            scenario: "non-numeric threshold",
            input: NON_NUMERIC,
            markedId: "alert-threshold",
        },
        {
            scenario: "profit/loss on not-held instrument",
            input: PROFIT_LOSS_NOT_HELD,
            markedId: "alert-instrument",
        },
    ])(
        "alertForm_invalidInput_marksOnlyInvalidControl ($scenario)",
        async ({ input, markedId }) => {
            const user = userEvent.setup({ delay: null })
            renderForm()

            await fillForm(user, input)
            await user.click(byId("alert-submit"))

            expect(controlMarks()).toEqual(expectedMarks(markedId))
        }
    )

    // Each edit leaves the whole input valid, which alone clears the message.
    it.each<{
        scenario: string
        input: AlertFormInput
        edit: (user: User) => Promise<void>
    }>([
        {
            scenario: "instrument chosen",
            input: MISSING_INSTRUMENT,
            edit: (user) =>
                user.selectOptions(
                    byId<HTMLSelectElement>("alert-instrument"),
                    HELD_ID
                ),
        },
        {
            scenario: "threshold corrected",
            input: NON_NUMERIC,
            edit: async (user) => {
                await user.clear(byId<HTMLInputElement>("alert-threshold"))
                await user.type(byId<HTMLInputElement>("alert-threshold"), "10")
            },
        },
        {
            scenario: "type switched to target price",
            input: PROFIT_LOSS_NOT_HELD,
            edit: (user) =>
                user.selectOptions(
                    byId<HTMLSelectElement>("alert-type"),
                    "TARGET_PRICE"
                ),
        },
    ])(
        "alertForm_editAfterFailedSubmit_clearsError ($scenario)",
        async ({ input, edit }) => {
            const user = userEvent.setup({ delay: null })
            renderForm()
            await fillForm(user, input)
            await user.click(byId("alert-submit"))

            await edit(user)

            expect({
                message: document.getElementById("alert-form-error"),
                marks: controlMarks(),
            }).toEqual({ message: null, marks: expectedMarks(null) })
        }
    )

    // The message follows the input's current first failure, so an edit that
    // makes another field fail first moves the message and the mark to it
    // while the field the submit rejected is still invalid.
    it.each<{
        scenario: string
        input: AlertFormInput
        edit: (user: User) => Promise<void>
        message: string
        markedId: string
    }>([
        {
            scenario: "instrument cleared, threshold still non-numeric",
            input: NON_NUMERIC,
            edit: (user) =>
                user.selectOptions(
                    byId<HTMLSelectElement>("alert-instrument"),
                    ""
                ),
            message: "Select an instrument.",
            markedId: "alert-instrument",
        },
        {
            scenario: "instrument chosen, threshold still empty",
            input: { ...MISSING_INSTRUMENT, threshold: "" },
            edit: (user) =>
                user.selectOptions(
                    byId<HTMLSelectElement>("alert-instrument"),
                    HELD_ID
                ),
            message: "Enter a threshold.",
            markedId: "alert-threshold",
        },
    ])(
        "alertForm_editAfterFailedSubmit_showsCurrentFirstFailure ($scenario)",
        async ({ input, edit, message, markedId }) => {
            const user = userEvent.setup({ delay: null })
            renderForm()
            await fillForm(user, input)
            await user.click(byId("alert-submit"))

            await edit(user)

            expect({
                message:
                    document.getElementById("alert-form-error")?.textContent,
                marks: controlMarks(),
            }).toEqual({ message, marks: expectedMarks(markedId) })
        }
    )

    it("alertForm_stillInvalidEdit_updatesMessageOnSameControl", async () => {
        const user = userEvent.setup({ delay: null })
        renderForm()
        await fillForm(user, NON_NUMERIC)
        await user.click(byId("alert-submit"))

        await user.clear(byId<HTMLInputElement>("alert-threshold"))

        expect({
            message: byId("alert-form-error").textContent,
            marks: controlMarks(),
        }).toEqual({
            message: "Enter a threshold.",
            marks: expectedMarks("alert-threshold"),
        })
    })

    // After a failed submit every edit is checked again, even once a keystroke
    // has made the input valid for a moment: here "1" is valid before the
    // digits leave the domain.
    it.each<{ scenario: string; retyped: string }>([
        { scenario: "11 integer digits", retyped: "12345678901" },
        { scenario: "9 fractional digits", retyped: "1.123456789" },
    ])(
        "alertForm_editAfterFailedSubmit_reflagsSameField ($scenario)",
        async ({ retyped }) => {
            const user = userEvent.setup({ delay: null })
            renderForm()
            await fillForm(user, NON_NUMERIC)
            await user.click(byId("alert-submit"))

            await user.clear(byId<HTMLInputElement>("alert-threshold"))
            await user.type(byId<HTMLInputElement>("alert-threshold"), retyped)

            expect({
                message:
                    document.getElementById("alert-form-error")?.textContent,
                marks: controlMarks(),
            }).toEqual({
                message:
                    "Threshold allows at most 10 integer and 8 decimal digits.",
                marks: expectedMarks("alert-threshold"),
            })
        }
    )

    it("alertForm_editBeforeSubmit_showsNoError", async () => {
        const user = userEvent.setup({ delay: null })
        renderForm()

        await fillForm(user, NON_NUMERIC)

        expect({
            message: document.getElementById("alert-form-error"),
            marks: controlMarks(),
        }).toEqual({ message: null, marks: expectedMarks(null) })
    })

    // A successful submit ends the live checking a failed one started, so the
    // form reports nothing again until the next submit fails.
    it("alertForm_editAfterSuccessfulSubmit_showsNoError", async () => {
        const user = userEvent.setup({ delay: null })
        renderForm()
        const threshold = byId<HTMLInputElement>("alert-threshold")
        await fillForm(user, NON_NUMERIC)
        await user.click(byId("alert-submit"))
        await user.clear(threshold)
        await user.type(threshold, "10")
        await user.click(byId("alert-submit"))

        await user.clear(threshold)
        await user.type(threshold, "abc")

        expect({
            message: document.getElementById("alert-form-error"),
            marks: controlMarks(),
        }).toEqual({ message: null, marks: expectedMarks(null) })
    })

    // A server rejection concerns the whole form, not one control.
    it("alertForm_serverError_marksNoControl", () => {
        const serverError =
            "The alert was rejected. Check the values and try again."
        renderForm({ serverError })

        expect({
            message: byId("alert-form-error").textContent,
            marks: controlMarks(),
        }).toEqual({ message: serverError, marks: expectedMarks(null) })
    })

    // The handler receives the validated input, its threshold the normalised
    // token the create request sends.
    it.each<{ scenario: string; input: AlertFormInput; token: string }>([
        {
            scenario: "target price on held instrument",
            input: {
                type: "TARGET_PRICE",
                instrumentId: HELD_ID,
                direction: "ABOVE",
                threshold: "105.5",
            },
            token: "105.5",
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
            token: "-2.5",
        },
        {
            scenario: "trailing fractional zeros",
            input: {
                type: "TARGET_PRICE",
                instrumentId: HELD_ID,
                direction: "ABOVE",
                threshold: "1.500",
            },
            token: "1.5",
        },
        {
            scenario: "trailing point",
            input: {
                type: "TARGET_PRICE",
                instrumentId: HELD_ID,
                direction: "BELOW",
                threshold: "2.",
            },
            token: "2",
        },
    ])(
        "alertForm_validInput_callsHandler ($scenario)",
        async ({ input, token }) => {
            const user = userEvent.setup({ delay: null })
            const onCreate = renderForm()

            await fillForm(user, input)
            await user.click(byId("alert-submit"))

            expect(onCreate.mock.calls).toEqual([
                [{ ...input, threshold: token }],
            ])
        }
    )

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
        // must receive the typed text itself, already the normalised token.
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
        // A normalised token, as the create request sends it: loadgen's
        // markers never end in a fractional zero.
        renderForm({ created: { id, threshold: "1000000.40271936" } })

        // Loadgen's `//output[@id="alert-created-id"][@data-threshold=...]`
        // matches attributes and reads the id from `value`, so both
        // attributes are the contract, not the element's text.
        const output = document.querySelector("output#alert-created-id")
        expect(output).toHaveAttribute("value", id)
        expect(output).toHaveAttribute("data-threshold", "1000000.40271936")
    })
})
