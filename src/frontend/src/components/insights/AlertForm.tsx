import { type FormEvent, useState } from "react"
import type {
    AlertDirection,
    AlertFormInput,
    AlertType,
    ValidatedAlertInput,
} from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import {
    type AlertInputError,
    isAlertDirection,
    isAlertType,
    parseAlertInput,
} from "../../utils/alertValidation"

type AlertFormProps = {
    instruments: Instrument[]
    onCreate: (input: ValidatedAlertInput) => void
    isPending: boolean
    serverError: string | null
    /**
     * The last accepted create: its id and the threshold token the create
     * request sent.
     */
    created: { id: string; threshold: string } | null
}

/**
 * Creates a target-price or profit/loss alert. Presentational only: validation
 * is owned by `utils/alertValidation.ts`, and the parent receives the
 * validated input, its threshold the normalised token, through `onCreate` and
 * sends it. Loadgen's selectors bind `alert-type`, `alert-instrument` and its
 * non-empty options, `alert-direction`, `alert-threshold`, `alert-submit` and
 * `alert-created-id`; `alert-form` and `alert-form-error` are stable ids the
 * unit tests use.
 */
export function AlertForm({
    instruments,
    onCreate,
    isPending,
    serverError,
    created,
}: AlertFormProps) {
    const [type, setType] = useState<AlertType>("TARGET_PRICE")
    const [instrumentId, setInstrumentId] = useState("")
    const [direction, setDirection] = useState<AlertDirection>("ABOVE")
    // Kept as typed text: a JavaScript number would turn
    // `9999999999.99999999` into `10000000000`.
    const [threshold, setThreshold] = useState("")
    // Whether a submit has failed since the last successful one. While it
    // holds, every edit re-checks the input, even after an edit made it valid.
    const [submitFailed, setSubmitFailed] = useState(false)
    // Set only while `submitFailed` holds, so nothing is reported before the
    // first failed submit or after a successful one.
    const [localError, setLocalError] = useState<AlertInputError | null>(null)

    function handleSubmit(e: FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const input: AlertFormInput = {
            type,
            instrumentId,
            direction,
            threshold,
        }
        const result = parseAlertInput(input, instruments)
        if (!result.ok) {
            setSubmitFailed(true)
            setLocalError(result.error)
            return
        }
        // A successful submit ends live checking until a submit fails again.
        setSubmitFailed(false)
        setLocalError(null)
        onCreate(result.value)
    }

    /**
     * After a failed submit, and until a submit succeeds, re-checks the values
     * with one field edited on every edit and shows the current first failure,
     * on whichever field it concerns, so that field's control is the one
     * marked. The message clears only while the whole input passes, and comes
     * back if a later edit makes it invalid again. Before the first failed
     * submit, and after a successful one, edits report nothing.
     */
    function revalidate(edited: Partial<AlertFormInput>) {
        if (!submitFailed) return
        const result = parseAlertInput(
            { type, instrumentId, direction, threshold, ...edited },
            instruments
        )
        setLocalError(result.ok ? null : result.error)
    }

    /**
     * Ties the control of `field` to the message in `#alert-form-error` while
     * it holds the local error. A server error concerns the whole form and
     * marks no control.
     */
    function invalidControlProps(field: keyof AlertFormInput) {
        return localError?.field === field
            ? {
                  "aria-invalid": true,
                  "aria-describedby": "alert-form-error",
                  className: "error",
              }
            : {}
    }

    const errorMessage = localError?.message ?? serverError

    return (
        <form id="alert-form" className="form" onSubmit={handleSubmit}>
            <div className="form-group">
                <label className="form-label" htmlFor="alert-type">
                    Alert type
                </label>
                <select
                    id="alert-type"
                    {...invalidControlProps("type")}
                    value={type}
                    disabled={isPending}
                    onChange={(e) => {
                        const value = e.target.value
                        if (!isAlertType(value)) return
                        setType(value)
                        revalidate({ type: value })
                    }}
                >
                    <option value="TARGET_PRICE">Target price</option>
                    <option value="PROFIT_LOSS">Profit or loss %</option>
                </select>
            </div>
            <div className="form-group">
                <label className="form-label" htmlFor="alert-instrument">
                    Instrument
                </label>
                <select
                    id="alert-instrument"
                    {...invalidControlProps("instrumentId")}
                    value={instrumentId}
                    disabled={isPending}
                    onChange={(e) => {
                        setInstrumentId(e.target.value)
                        revalidate({ instrumentId: e.target.value })
                    }}
                >
                    <option value="">Select instrument</option>
                    {instruments.map((i) => (
                        <option
                            key={i.id}
                            value={i.id}
                            disabled={type === "PROFIT_LOSS" && !(i.amount > 0)}
                        >
                            {i.name}
                        </option>
                    ))}
                </select>
            </div>
            <div className="form-group">
                <label className="form-label" htmlFor="alert-direction">
                    Direction
                </label>
                <select
                    id="alert-direction"
                    {...invalidControlProps("direction")}
                    value={direction}
                    disabled={isPending}
                    onChange={(e) => {
                        const value = e.target.value
                        if (!isAlertDirection(value)) return
                        setDirection(value)
                        revalidate({ direction: value })
                    }}
                >
                    <option value="ABOVE">Above</option>
                    <option value="BELOW">Below</option>
                </select>
            </div>
            <div className="form-group">
                <label className="form-label" htmlFor="alert-threshold">
                    Threshold
                </label>
                <input
                    id="alert-threshold"
                    {...invalidControlProps("threshold")}
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    value={threshold}
                    disabled={isPending}
                    onChange={(e) => {
                        setThreshold(e.target.value)
                        revalidate({ threshold: e.target.value })
                    }}
                />
            </div>
            {errorMessage !== null ? (
                <span
                    id="alert-form-error"
                    className="field-error"
                    role="alert"
                >
                    {errorMessage}
                </span>
            ) : null}
            <div className="form-actions">
                <button
                    id="alert-submit"
                    type="submit"
                    className="btn btn-primary"
                    disabled={isPending}
                >
                    {isPending ? (
                        <span className="spinner" aria-hidden="true" />
                    ) : null}
                    Create alert
                </button>
            </div>
            {created !== null ? (
                <p className="form-hint">
                    Created alert{" "}
                    {/* `@types/react` 18 does not declare `value` on <output>;
                        the spread passes it through, so loadgen can match the
                        attribute and read the id back as the element's value. */}
                    <output
                        id="alert-created-id"
                        {...{ value: created.id }}
                        data-threshold={created.threshold}
                    >
                        {created.id}
                    </output>
                </p>
            ) : null}
        </form>
    )
}
