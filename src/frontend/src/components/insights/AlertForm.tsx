import { type FormEvent, useState } from "react"
import type {
    AlertDirection,
    AlertFormInput,
    AlertType,
} from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { validateAlertInput } from "../../utils/alertValidation"

type AlertFormProps = {
    instruments: Instrument[]
    onCreate: (input: AlertFormInput) => void
    isPending: boolean
    serverError: string | null
    /** The last accepted create: its id and the threshold text submitted. */
    created: { id: string; threshold: string } | null
}

function toAlertType(value: string): AlertType {
    return value === "PROFIT_LOSS" ? "PROFIT_LOSS" : "TARGET_PRICE"
}

function toAlertDirection(value: string): AlertDirection {
    return value === "BELOW" ? "BELOW" : "ABOVE"
}

/**
 * Creates a target-price or profit/loss alert. Presentational only: the
 * shared `validateAlertInput` decides what may be sent, and the parent sends
 * it through `onCreate`. Every id is bound by loadgen selectors and the
 * browser check.
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
    const [localError, setLocalError] = useState<string | null>(null)

    function handleSubmit(e: FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const input: AlertFormInput = {
            type,
            instrumentId,
            direction,
            threshold,
        }
        const message = validateAlertInput(input, instruments)
        if (message !== null) {
            setLocalError(message)
            return
        }
        setLocalError(null)
        onCreate(input)
    }

    const errorMessage = localError ?? serverError

    return (
        <form id="alert-form" className="form" onSubmit={handleSubmit}>
            <div className="form-group">
                <label className="form-label" htmlFor="alert-type">
                    Alert type
                </label>
                <select
                    id="alert-type"
                    value={type}
                    disabled={isPending}
                    onChange={(e) => setType(toAlertType(e.target.value))}
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
                    value={instrumentId}
                    disabled={isPending}
                    onChange={(e) => setInstrumentId(e.target.value)}
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
                    value={direction}
                    disabled={isPending}
                    onChange={(e) =>
                        setDirection(toAlertDirection(e.target.value))
                    }
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
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    value={threshold}
                    disabled={isPending}
                    onChange={(e) => setThreshold(e.target.value)}
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
