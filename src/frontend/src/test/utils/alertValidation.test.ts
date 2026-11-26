import "@testing-library/jest-dom/vitest"
import {
    findInstrumentName,
    formatAlertNumber,
    isAlertDirection,
    isAlertType,
    normalizeThresholdText,
    parseAlertInput,
    validateAlertInput,
} from "../../utils/alertValidation"
import type {
    AlertFormInput,
    ValidatedAlertInput,
} from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"

const SELECT_INSTRUMENT = "Select an instrument."
const SELECT_TYPE = "Select an alert type."
const SELECT_DIRECTION = "Select a direction."
const ENTER_THRESHOLD = "Enter a threshold."
const NOT_A_NUMBER = "Threshold must be a number."
const OUTSIDE_DOMAIN =
    "Threshold allows at most 10 integer and 8 decimal digits."
const TARGET_PRICE_NOT_POSITIVE = "Target price must be greater than 0."
const PROFIT_LOSS_NOT_HELD = "Profit/loss alerts need an instrument you hold."

const HELD: Instrument = {
    id: "c0000000-0000-4000-8000-000000000001",
    code: "ETRAVE",
    name: "EasyTravel",
    description: "EasyTravel Incorporated",
    productId: 1,
    productName: "Share",
    price: {
        timestamp: "2023-04-04T13:05:00Z",
        open: 137.68958333,
        close: 137.73125,
        low: 136.37064957,
        high: 139.07805518,
    },
    amount: 10,
}

const NOT_HELD: Instrument = {
    id: "c0000000-0000-4000-8000-000000000002",
    code: "EPLANE",
    name: "EasyPlanes",
    description: "EasyPlanes Worldwide",
    productId: 2,
    productName: "ETF",
    price: {
        timestamp: "2023-04-04T13:05:00Z",
        open: 94.86888889,
        close: 94.91333333,
        low: 94.31277586,
        high: 95.44784334,
    },
    amount: 0,
}

const UNLISTED_INSTRUMENT_ID = "c0000000-0000-4000-8000-000000000099"

const instruments: Instrument[] = [HELD, NOT_HELD]

const VALID_INPUT: AlertFormInput = {
    type: "TARGET_PRICE",
    instrumentId: HELD.id,
    direction: "ABOVE",
    threshold: "100",
}

function inputWith(overrides: Partial<AlertFormInput>): AlertFormInput {
    return { ...VALID_INPUT, ...overrides }
}

const VALID_VALUE: ValidatedAlertInput = {
    type: "TARGET_PRICE",
    instrumentId: HELD.id,
    direction: "ABOVE",
    threshold: "100",
}

function valueWith(
    overrides: Partial<ValidatedAlertInput>
): ValidatedAlertInput {
    return { ...VALID_VALUE, ...overrides }
}

type RuleRow = {
    scenario: string
    input: AlertFormInput
    field: keyof AlertFormInput
    expected: string
}
type ValidRow = {
    scenario: string
    input: AlertFormInput
    value: ValidatedAlertInput
}
type NormalizeRow = { text: string; expected: string | null }
type FormatRow = { value: number; expected: string }
type FindNameRow = {
    scenario: string
    // Looked up in order, so later lookups reuse or replace earlier indexes.
    catalogs: (readonly Instrument[] | undefined)[]
    instrumentId: string
    expected: (string | undefined)[]
}
type GuardRow = { value: string; expected: boolean }

// Listed in the validator's check order. The rows with two violations prove
// that only the earlier check's message is returned, with its own field.
const ruleRows: RuleRow[] = [
    {
        scenario: "instrument not chosen",
        input: inputWith({ instrumentId: "" }),
        field: "instrumentId",
        expected: SELECT_INSTRUMENT,
    },
    {
        scenario: "instrument whitespace only",
        input: inputWith({ instrumentId: "   " }),
        field: "instrumentId",
        expected: SELECT_INSTRUMENT,
    },
    {
        scenario: "instrument not in the list",
        input: inputWith({ instrumentId: UNLISTED_INSTRUMENT_ID }),
        field: "instrumentId",
        expected: SELECT_INSTRUMENT,
    },
    {
        scenario: "instrument and type both missing",
        input: inputWith({ instrumentId: "", type: "" }),
        field: "instrumentId",
        expected: SELECT_INSTRUMENT,
    },
    {
        scenario: "instrument missing and threshold non-numeric",
        input: inputWith({ instrumentId: "", threshold: "abc" }),
        field: "instrumentId",
        expected: SELECT_INSTRUMENT,
    },
    {
        scenario: "type not chosen",
        input: inputWith({ type: "" }),
        field: "type",
        expected: SELECT_TYPE,
    },
    {
        scenario: "type in the wrong case",
        input: inputWith({ type: "target_price" }),
        field: "type",
        expected: SELECT_TYPE,
    },
    {
        scenario: "type and direction both missing",
        input: inputWith({ type: "", direction: "" }),
        field: "type",
        expected: SELECT_TYPE,
    },
    {
        scenario: "direction not chosen",
        input: inputWith({ direction: "" }),
        field: "direction",
        expected: SELECT_DIRECTION,
    },
    {
        scenario: "direction unknown",
        input: inputWith({ direction: "UP" }),
        field: "direction",
        expected: SELECT_DIRECTION,
    },
    {
        scenario: "direction and threshold both missing",
        input: inputWith({ direction: "", threshold: "" }),
        field: "direction",
        expected: SELECT_DIRECTION,
    },
    {
        scenario: "threshold empty",
        input: inputWith({ threshold: "" }),
        field: "threshold",
        expected: ENTER_THRESHOLD,
    },
    {
        scenario: "threshold whitespace only",
        input: inputWith({ threshold: "   " }),
        field: "threshold",
        expected: ENTER_THRESHOLD,
    },
    {
        scenario: "threshold non-numeric",
        input: inputWith({ threshold: "abc" }),
        field: "threshold",
        expected: NOT_A_NUMBER,
    },
    {
        scenario: "threshold with an exponent",
        input: inputWith({ threshold: "1e5" }),
        field: "threshold",
        expected: NOT_A_NUMBER,
    },
    {
        scenario: "threshold with 11 integer digits",
        input: inputWith({ threshold: "10000000000" }),
        field: "threshold",
        expected: OUTSIDE_DOMAIN,
    },
    {
        scenario: "threshold with 9 fractional digits",
        input: inputWith({ threshold: "0.000000001" }),
        field: "threshold",
        expected: OUTSIDE_DOMAIN,
    },
    {
        scenario: "target price negative and beyond the domain",
        input: inputWith({ threshold: "-10000000000" }),
        field: "threshold",
        expected: OUTSIDE_DOMAIN,
    },
    {
        scenario: "target price zero",
        input: inputWith({ threshold: "0" }),
        field: "threshold",
        expected: TARGET_PRICE_NOT_POSITIVE,
    },
    {
        scenario: "target price negative",
        input: inputWith({ threshold: "-1" }),
        field: "threshold",
        expected: TARGET_PRICE_NOT_POSITIVE,
    },
    {
        scenario: "target price negative zero with trailing zeros",
        input: inputWith({ threshold: "-0.00" }),
        field: "threshold",
        expected: TARGET_PRICE_NOT_POSITIVE,
    },
    {
        scenario: "profit/loss on an instrument not held",
        input: inputWith({
            type: "PROFIT_LOSS",
            instrumentId: NOT_HELD.id,
            threshold: "5",
        }),
        field: "instrumentId",
        expected: PROFIT_LOSS_NOT_HELD,
    },
    {
        scenario: "profit/loss not held and threshold non-numeric",
        input: inputWith({
            type: "PROFIT_LOSS",
            instrumentId: NOT_HELD.id,
            threshold: "abc",
        }),
        field: "threshold",
        expected: NOT_A_NUMBER,
    },
]

// `value` is what the form hands on: the threshold is the normalised token
// the create request body carries.
const validRows: ValidRow[] = [
    {
        scenario: "smallest target price",
        input: inputWith({ threshold: "0.00000001" }),
        value: valueWith({ threshold: "0.00000001" }),
    },
    {
        scenario: "largest target price",
        input: inputWith({ threshold: "9999999999.99999999" }),
        value: valueWith({ threshold: "9999999999.99999999" }),
    },
    {
        scenario: "target price with trailing zeros past 8 decimals",
        input: inputWith({ threshold: "1.500000000" }),
        value: valueWith({ threshold: "1.5" }),
    },
    {
        scenario: "target price with trailing fractional zeros",
        input: inputWith({ threshold: "1.500" }),
        value: valueWith({ threshold: "1.5" }),
    },
    {
        scenario: "target price with a trailing point",
        input: inputWith({ threshold: "2." }),
        value: valueWith({ threshold: "2" }),
    },
    {
        scenario: "target price with surrounding whitespace",
        input: inputWith({ threshold: " 100 " }),
        value: valueWith({ threshold: "100" }),
    },
    {
        scenario: "target price on an instrument not held",
        input: inputWith({ instrumentId: NOT_HELD.id }),
        value: valueWith({ instrumentId: NOT_HELD.id }),
    },
    {
        scenario: "profit/loss at the negative domain limit",
        input: inputWith({
            type: "PROFIT_LOSS",
            direction: "BELOW",
            threshold: "-9999999999.99999999",
        }),
        value: valueWith({
            type: "PROFIT_LOSS",
            direction: "BELOW",
            threshold: "-9999999999.99999999",
        }),
    },
    {
        scenario: "profit/loss of zero",
        input: inputWith({ type: "PROFIT_LOSS", threshold: "0" }),
        value: valueWith({ type: "PROFIT_LOSS", threshold: "0" }),
    },
    {
        scenario: "profit/loss of negative zero",
        input: inputWith({ type: "PROFIT_LOSS", threshold: "-0.0" }),
        value: valueWith({ type: "PROFIT_LOSS", threshold: "0" }),
    },
]

const alertTypeRows: GuardRow[] = [
    { value: "TARGET_PRICE", expected: true },
    { value: "PROFIT_LOSS", expected: true },
    { value: "target_price", expected: false },
    { value: "TARGET_PRICE ", expected: false },
    { value: "ABOVE", expected: false },
    { value: "", expected: false },
]

const alertDirectionRows: GuardRow[] = [
    { value: "ABOVE", expected: true },
    { value: "BELOW", expected: true },
    { value: "above", expected: false },
    { value: " BELOW", expected: false },
    { value: "UP", expected: false },
    { value: "", expected: false },
]

const normalizeRows: NormalizeRow[] = [
    { text: "1.500", expected: "1.5" },
    { text: "2.", expected: "2" },
    { text: "9999999999.99999999", expected: "9999999999.99999999" },
    { text: "-0.0", expected: "0" },
    { text: "100", expected: "100" },
    { text: "10.0", expected: "10" },
    { text: "0.000", expected: "0" },
    { text: "-0.5", expected: "-0.5" },
    { text: " 3.25 ", expected: "3.25" },
    { text: "abc", expected: null },
    { text: "1e5", expected: null },
    { text: "", expected: null },
    { text: "-", expected: null },
    { text: ".5", expected: null },
    { text: "01", expected: null },
    { text: "+1", expected: null },
    { text: "1,5", expected: null },
]

const formatRows: FormatRow[] = [
    { value: 1.5, expected: "1.5" },
    { value: 0.00000001, expected: "0.00000001" },
    { value: 0.123456789, expected: "0.12345679" },
    { value: 1234567.25, expected: "1,234,567.25" },
    { value: -12.5, expected: "-12.5" },
    { value: 0, expected: "0" },
]

// The refetched catalog TanStack Query hands out after a rename: a new array.
const renamedInstruments: Instrument[] = [
    { ...HELD, name: "EasyTravel Holdings" },
    NOT_HELD,
]

const findNameRows: FindNameRow[] = [
    {
        scenario: "first listed id",
        catalogs: [instruments],
        instrumentId: HELD.id,
        expected: ["EasyTravel"],
    },
    {
        scenario: "last listed id",
        catalogs: [instruments],
        instrumentId: NOT_HELD.id,
        expected: ["EasyPlanes"],
    },
    {
        scenario: "unlisted id",
        catalogs: [instruments],
        instrumentId: UNLISTED_INSTRUMENT_ID,
        expected: [undefined],
    },
    {
        scenario: "no catalog",
        catalogs: [undefined],
        instrumentId: HELD.id,
        expected: [undefined],
    },
    {
        scenario: "empty catalog",
        catalogs: [[]],
        instrumentId: HELD.id,
        expected: [undefined],
    },
    {
        scenario: "same catalog reused",
        catalogs: [instruments, instruments],
        instrumentId: HELD.id,
        expected: ["EasyTravel", "EasyTravel"],
    },
    {
        scenario: "new catalog with a renamed instrument",
        catalogs: [instruments, renamedInstruments],
        instrumentId: HELD.id,
        expected: ["EasyTravel", "EasyTravel Holdings"],
    },
    {
        scenario: "id listed twice",
        catalogs: [[HELD, { ...HELD, name: "EasyTravel Duplicate" }]],
        instrumentId: HELD.id,
        expected: ["EasyTravel"],
    },
]

describe("alertValidation", () => {
    beforeEach(() => sessionStorage.clear())

    afterEach(() => {
        sessionStorage.clear()
        vi.restoreAllMocks()
    })

    it.each(ruleRows)(
        "validateAlertInput_rule_returnsMessage ($scenario)",
        ({ input, expected }) => {
            expect(validateAlertInput(input, instruments)).toBe(expected)
        }
    )

    it.each(validRows)(
        "validateAlertInput_valid_returnsNull ($scenario)",
        ({ input }) => {
            expect(validateAlertInput(input, instruments)).toBeNull()
        }
    )

    it.each(ruleRows)(
        "parseAlertInput_rule_returnsFieldError ($scenario)",
        ({ input, field, expected }) => {
            expect(parseAlertInput(input, instruments)).toEqual({
                ok: false,
                error: { field, message: expected },
            })
        }
    )

    it.each(validRows)(
        "parseAlertInput_valid_returnsNormalisedValue ($scenario)",
        ({ input, value }) => {
            expect(parseAlertInput(input, instruments)).toEqual({
                ok: true,
                value,
            })
        }
    )

    it.each(alertTypeRows)(
        "isAlertType_value_acceptsOnlyExactNames ($value)",
        ({ value, expected }) => {
            expect(isAlertType(value)).toBe(expected)
        }
    )

    it.each(alertDirectionRows)(
        "isAlertDirection_value_acceptsOnlyExactNames ($value)",
        ({ value, expected }) => {
            expect(isAlertDirection(value)).toBe(expected)
        }
    )

    it.each(normalizeRows)(
        "normalizeThresholdText_value_normalizes ($text)",
        ({ text, expected }) => {
            expect(normalizeThresholdText(text)).toBe(expected)
        }
    )

    // formatAlertNumber is the module's display helper for thresholds and
    // trigger values; it is covered here so every export of the module has a
    // unit test.
    it.each(formatRows)(
        "formatAlertNumber_value_formatsDisplayText ($value)",
        ({ value, expected }) => {
            expect(formatAlertNumber(value)).toBe(expected)
        }
    )

    // Response decoders pass the guards values of any type.
    it.each<{ value: unknown }>([
        { value: 1 },
        { value: null },
        { value: undefined },
        { value: { name: "TARGET_PRICE" } },
    ])("alertEnumGuard_nonStringValue_isFalse ($value)", ({ value }) => {
        expect({
            type: isAlertType(value),
            direction: isAlertDirection(value),
        }).toEqual({ type: false, direction: false })
    })

    it.each(findNameRows)(
        "findInstrumentName_catalog_returnsNameOrUndefined ($scenario)",
        ({ catalogs, instrumentId, expected }) => {
            expect(
                catalogs.map((catalog) =>
                    findInstrumentName(catalog, instrumentId)
                )
            ).toStrictEqual(expected)
        }
    )
})
