import type {
    AlertDirection,
    AlertFormInput,
    AlertType,
    ValidatedAlertInput,
} from "../api/alerts/types"
import type { Instrument } from "../api/instrument/types"

// Plain decimal only: no exponent, sign "+", leading zeros or bare ".5",
// which the broker's exact-token rule rejects as well.
const THRESHOLD_PATTERN = /^-?(0|[1-9][0-9]*)(\.[0-9]*)?$/

// The threshold column is DECIMAL(18, 8): 10 integer and 8 fractional digits.
const MAX_INTEGER_DIGITS = 10
const MAX_FRACTION_DIGITS = 8

const ALERT_TYPES: ReadonlySet<string> = new Set<AlertType>([
    "TARGET_PRICE",
    "PROFIT_LOSS",
])
const ALERT_DIRECTIONS: ReadonlySet<string> = new Set<AlertDirection>([
    "ABOVE",
    "BELOW",
])

const MESSAGE_INSTRUMENT = "Select an instrument."
const MESSAGE_TYPE = "Select an alert type."
const MESSAGE_DIRECTION = "Select a direction."
const MESSAGE_THRESHOLD_MISSING = "Enter a threshold."
const MESSAGE_THRESHOLD_NOT_NUMBER = "Threshold must be a number."
const MESSAGE_THRESHOLD_DOMAIN =
    "Threshold allows at most 10 integer and 8 decimal digits."
const MESSAGE_TARGET_PRICE_NOT_POSITIVE = "Target price must be greater than 0."
const MESSAGE_PROFIT_LOSS_NOT_HELD =
    "Profit/loss alerts need an instrument you hold."

const alertNumberFormatter = new Intl.NumberFormat("en-US", {
    maximumFractionDigits: MAX_FRACTION_DIGITS,
})

// One id → name index per instruments array. Query data is replaced, never
// mutated, so an array's index stays valid for as long as the array lives,
// and the WeakMap lets both go together.
const instrumentNameIndexes = new WeakMap<
    readonly Instrument[],
    ReadonlyMap<string, string>
>()

/** The first failing rule of an alert form input and the field it concerns. */
export type AlertInputError = {
    field: keyof AlertFormInput
    message: string
}

/** Outcome of `validateThreshold`. */
export type ThresholdValidation =
    { ok: true; token: string } | { ok: false; message: string }

/** Outcome of `parseAlertInput`. */
export type AlertInputParse =
    | { ok: true; value: ValidatedAlertInput }
    | { ok: false; error: AlertInputError }

/**
 * Whether the value is an alert type name, exact and case-sensitive. Takes
 * any value, so a response decoder can check an unknown field with it too.
 */
export function isAlertType(value: unknown): value is AlertType {
    return typeof value === "string" && ALERT_TYPES.has(value)
}

/**
 * Whether the value is an alert direction name, exact and case-sensitive.
 * Takes any value, so a response decoder can check an unknown field with it.
 */
export function isAlertDirection(value: unknown): value is AlertDirection {
    return typeof value === "string" && ALERT_DIRECTIONS.has(value)
}

/**
 * Returns the exact JSON number token for a threshold the user typed, with
 * trailing fractional zeros and a trailing point removed, or `null` when the
 * text is not a plain decimal. Works on text only: a `Number` would turn
 * `9999999999.99999999` into `10000000000`.
 */
export function normalizeThresholdText(text: string): string | null {
    const trimmed = text.trim()
    if (!THRESHOLD_PATTERN.test(trimmed)) return null
    const token = trimmed.includes(".")
        ? trimmed.replace(/0+$/, "").replace(/\.$/, "")
        : trimmed
    return token === "-0" ? "0" : token
}

function exceedsThresholdDomain(token: string): boolean {
    const unsigned = token.startsWith("-") ? token.slice(1) : token
    const [integerDigits, fractionDigits = ""] = unsigned.split(".")
    return (
        integerDigits.length > MAX_INTEGER_DIGITS ||
        fractionDigits.length > MAX_FRACTION_DIGITS
    )
}

/**
 * Checks threshold text, in order, for presence, plain decimal grammar, the
 * 10 integer and 8 fractional digit domain and, for `TARGET_PRICE`, a value
 * above 0. On success `token` is exactly `normalizeThresholdText(text)`: the
 * token the create request body carries.
 */
export function validateThreshold(
    type: AlertType,
    text: string
): ThresholdValidation {
    if (text.trim() === "") {
        return { ok: false, message: MESSAGE_THRESHOLD_MISSING }
    }
    const token = normalizeThresholdText(text)
    if (token === null) {
        return { ok: false, message: MESSAGE_THRESHOLD_NOT_NUMBER }
    }
    if (exceedsThresholdDomain(token)) {
        return { ok: false, message: MESSAGE_THRESHOLD_DOMAIN }
    }
    if (type === "TARGET_PRICE" && (token === "0" || token.startsWith("-"))) {
        return { ok: false, message: MESSAGE_TARGET_PRICE_NOT_POSITIVE }
    }
    return { ok: true, token }
}

function inputError(
    field: keyof AlertFormInput,
    message: string
): AlertInputParse {
    return { ok: false, error: { field, message } }
}

/**
 * Mirrors the broker's 400 rules for a new alert. Returns the first failing
 * rule with the field it concerns, or the input narrowed to exact enum names
 * with the normalised threshold token. The broker stays authoritative; this
 * only gives feedback before the request.
 */
export function parseAlertInput(
    input: AlertFormInput,
    instruments: Instrument[]
): AlertInputParse {
    const { type, instrumentId, direction } = input
    if (instrumentId.trim() === "") {
        return inputError("instrumentId", MESSAGE_INSTRUMENT)
    }
    const instrument = instruments.find(
        (candidate) => candidate.id === instrumentId
    )
    if (instrument === undefined) {
        return inputError("instrumentId", MESSAGE_INSTRUMENT)
    }

    if (!isAlertType(type)) return inputError("type", MESSAGE_TYPE)
    if (!isAlertDirection(direction)) {
        return inputError("direction", MESSAGE_DIRECTION)
    }

    const threshold = validateThreshold(type, input.threshold)
    if (!threshold.ok) return inputError("threshold", threshold.message)

    if (type === "PROFIT_LOSS" && !(instrument.amount > 0)) {
        return inputError("instrumentId", MESSAGE_PROFIT_LOSS_NOT_HELD)
    }
    return {
        ok: true,
        value: { type, instrumentId, direction, threshold: threshold.token },
    }
}

/**
 * Returns the first failing message of `parseAlertInput`, or `null` when the
 * input may be sent.
 */
export function validateAlertInput(
    input: AlertFormInput,
    instruments: Instrument[]
): string | null {
    const result = parseAlertInput(input, instruments)
    return result.ok ? null : result.error.message
}

/**
 * Display text for a threshold or trigger value, with at most 8 fractional
 * digits. Display only: the server's value is the record.
 */
export function formatAlertNumber(value: number): string {
    return alertNumberFormatter.format(value)
}

/**
 * The name the instruments catalog gives `instrumentId`, or `undefined` when
 * there is no catalog or it does not list the id, so each caller keeps its
 * own fallback label. The alert list, the notifications and the
 * triggered-alert Toast share this lookup. The index is built once per
 * catalog array, which TanStack Query keeps until the instruments data
 * changes, so later lookups are constant time and a new catalog is indexed
 * afresh. The first entry wins if an id is listed twice.
 */
export function findInstrumentName(
    instruments: readonly Instrument[] | undefined,
    instrumentId: string
): string | undefined {
    // Empty catalogs are not indexed: a caller's `?? []` fallback is a new
    // array on every render.
    if (instruments === undefined || instruments.length === 0) return undefined
    let index = instrumentNameIndexes.get(instruments)
    if (index === undefined) {
        const names = new Map<string, string>()
        for (const instrument of instruments) {
            if (!names.has(instrument.id)) {
                names.set(instrument.id, instrument.name)
            }
        }
        instrumentNameIndexes.set(instruments, names)
        index = names
    }
    return index.get(instrumentId)
}
