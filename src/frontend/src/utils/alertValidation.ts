import type {
    AlertDirection,
    AlertFormInput,
    AlertType,
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
 * Mirrors the broker's 400 rules for a new alert and returns the first
 * failing message, or `null` when the input may be sent. The broker stays
 * authoritative; this only gives feedback before the request.
 */
export function validateAlertInput(
    input: AlertFormInput,
    instruments: Instrument[]
): string | null {
    if (input.instrumentId.trim() === "") return MESSAGE_INSTRUMENT
    const instrument = instruments.find(
        (candidate) => candidate.id === input.instrumentId
    )
    if (instrument === undefined) return MESSAGE_INSTRUMENT

    if (!ALERT_TYPES.has(input.type)) return MESSAGE_TYPE
    if (!ALERT_DIRECTIONS.has(input.direction)) return MESSAGE_DIRECTION

    if (input.threshold.trim() === "") return MESSAGE_THRESHOLD_MISSING
    const token = normalizeThresholdText(input.threshold)
    if (token === null) return MESSAGE_THRESHOLD_NOT_NUMBER
    if (exceedsThresholdDomain(token)) return MESSAGE_THRESHOLD_DOMAIN

    if (
        input.type === "TARGET_PRICE" &&
        (token === "0" || token.startsWith("-"))
    ) {
        return MESSAGE_TARGET_PRICE_NOT_POSITIVE
    }
    if (input.type === "PROFIT_LOSS" && !(instrument.amount > 0)) {
        return MESSAGE_PROFIT_LOSS_NOT_HELD
    }
    return null
}

/**
 * Display text for a threshold or trigger value, with at most 8 fractional
 * digits. Display only: the server's value is the record.
 */
export function formatAlertNumber(value: number): string {
    return alertNumberFormatter.format(value)
}
