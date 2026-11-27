/**
 * Unit tests of the helpers of portfolio-insights-page-check.mjs: the command
 * line and fixture parsers, the flag body, response classification and
 * recording, Toast attribution and counting, the insights shape and
 * formatting, wait timeouts turned into problems, the check records, and the
 * entry guard that keeps an import from running the check. The bounded waits,
 * redaction, insights comparison and one-Toast-per-arming rule have suites of
 * their own beside this file. The Puppeteer-driven checks need a running stack
 * and are exercised by scripts/portfolio-insights/e2e.sh instead.
 *
 * Run from src/loadgen, with the other verification suites, as:
 *
 *     node --test "verification/*.test.mjs"
 *
 * `npm test` runs only the compiled TypeScript tests under build/, so it does
 * not pick this file up. Time is mocked with `mock.timers`; no test sleeps.
 */
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import process from "node:process"
import { test } from "node:test"
import { fileURLToPath, pathToFileURL } from "node:url"
import {
    HELP,
    UsageError,
    WaitTimeoutError,
    armingKey,
    attributeToasts,
    classifyResponse,
    expectEqual,
    fixtureAlertOf,
    formatInPage,
    idOf,
    insightsShapeProblem,
    isTriggered,
    parseAccount,
    parseAlert,
    parseAlerts,
    parseBaseUrl,
    parseFlagBody,
    parseOptions,
    readFixture,
    recordCheck,
    recordResponse,
    resultsOf,
    runCheck,
    toastCounts,
    triggeredArmings,
    waitOrReport,
} from "./portfolio-insights-page-check.mjs"

const MODULE_PATH = fileURLToPath(
    new URL("./portfolio-insights-page-check.mjs", import.meta.url)
)
const LOADGEN_DIR = path.dirname(path.dirname(MODULE_PATH))
const USAGE =
    "Usage: node verification/portfolio-insights-page-check.mjs --base-url URL --mode flag-off|flag-on --fixture FILE --evidence-dir DIR"

const BASE_URL = "http://localhost:20000"
const FIXTURE_PATH = "/run/fixture.json"
const EPOCH_ISO = "1970-01-01T00:00:00.000Z"

const HOLDER_ID = "6f1c2b8e-3d4a-4b5c-9d6e-7f8091a2b3c4"
const EMPTY_ID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
const OTHER_ACCOUNT_ID = "5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9"
const TP_ABOVE_ID = "a1b2c3d4-0001-4000-8000-00000000000a"
const TP_BELOW_ID = "a1b2c3d4-0002-4000-8000-00000000000b"
const PL_ABOVE_ID = "a1b2c3d4-0003-4000-8000-00000000000c"
const PL_BELOW_ID = "a1b2c3d4-0004-4000-8000-00000000000d"
const FOREIGN_ALERT_ID = "f0e1d2c3-b4a5-4968-8776-655443322110"

/** The fixture alerts as readFixture returns them: by pair, then direction. */
const FIXTURE_ALERTS = [
    {
        id: TP_ABOVE_ID,
        pair: "target_price",
        type: "TARGET_PRICE",
        direction: "ABOVE",
        threshold: "1234.49999999",
        armingRevision: 1,
    },
    {
        id: TP_BELOW_ID,
        pair: "target_price",
        type: "TARGET_PRICE",
        direction: "BELOW",
        threshold: "1234.50000001",
        armingRevision: 1,
    },
    {
        id: PL_ABOVE_ID,
        pair: "profit_loss",
        type: "PROFIT_LOSS",
        direction: "ABOVE",
        threshold: "-0.00000001",
        armingRevision: 1,
    },
    {
        id: PL_BELOW_ID,
        pair: "profit_loss",
        type: "PROFIT_LOSS",
        direction: "BELOW",
        threshold: "0.00000001",
        armingRevision: 2,
    },
]
const [TP_ABOVE] = FIXTURE_ALERTS

/** The fixture alerts as e2e.sh may write them: any order and id case. */
function rawAlerts() {
    return FIXTURE_ALERTS.map((alert) => ({
        ...alert,
        id: alert.id.toUpperCase(),
    })).reverse()
}

const RAW_HOLDER = {
    username: "pi-holder",
    password: "Pi-holder-secret-1",
    accountId: HOLDER_ID.toUpperCase(),
}
const HOLDER = { ...RAW_HOLDER, accountId: HOLDER_ID }
const EMPTY = {
    username: "pi-empty",
    password: "Pi-empty-secret-2",
    accountId: EMPTY_ID,
}

/** Toast texts as the frontend's AlertNotificationWatcher writes them. */
const TOAST_TP_ABOVE =
    "Alert triggered: Apple Price above 1,234.49999999 (now 1,240.1)"
const TOAST_TP_BELOW =
    "Alert triggered: Apple Price below 1,234.50000001 (now 1,201)"
const TOAST_PL_ABOVE = "Alert triggered: Apple P/L above -0.00000001 (now 3.25)"
const TOAST_PL_BELOW =
    "Alert triggered: instrument 3d0c7c9a P/L below 0.00000001 (now -1.5)"
const TOAST_OTHER = "Bought 5 shares of Apple"

const T1 = "2026-11-25T10:00:00.000Z"
const T2 = "2026-11-25T10:01:00.000Z"
/** Arrival time of sequence number 0 in the sessions the tests build. */
const AT0 = Date.UTC(2026, 10, 25, 10, 0, 0)

function kindOf(error) {
    if (error instanceof UsageError) {
        return "UsageError"
    }
    if (error instanceof WaitTimeoutError) {
        return "WaitTimeoutError"
    }
    return error instanceof Error ? error.name : `not an error: ${error}`
}

function usageError(message) {
    return { threw: "UsageError", message }
}

/** What `call` returns, or the kind and message of what it throws. */
function outcomeOf(call) {
    try {
        return { returned: call() }
    } catch (error) {
        return { threw: kindOf(error), message: error.message }
    }
}

async function asyncOutcomeOf(call) {
    try {
        return { returned: await call() }
    } catch (error) {
        return { threw: kindOf(error), message: error.message }
    }
}

/** A directory of its own for the test, removed when the test ends. */
async function tempDir(t) {
    const dir = await mkdtemp(path.join(os.tmpdir(), "pi-page-check-test-"))
    t.after(() => rm(dir, { recursive: true, force: true }))
    return dir
}

/** Replaces console.log and console.error for the test and records calls. */
function captureConsole(t) {
    const log = t.mock.method(console, "log", () => undefined)
    const error = t.mock.method(console, "error", () => undefined)
    return {
        lines: () => log.mock.calls.map((call) => call.arguments.join(" ")),
        errors: () => error.mock.calls.map((call) => call.arguments[0]),
    }
}

/** A notification response entry as recordResponse leaves it once read. */
function notifications(seq, items, overrides = {}) {
    return {
        kind: "notifications",
        accountId: HOLDER_ID,
        alertId: null,
        method: "GET",
        status: 200,
        accepted: true,
        rejection: null,
        at: AT0 + seq * 1000,
        seq,
        parsed: true,
        body: { results: items },
        ...overrides,
    }
}

function seenAt(seq) {
    return new Date(AT0 + seq * 1000).toISOString()
}

function triggered(id, armingRevision, triggeredAt = T1) {
    return {
        id,
        armingRevision,
        triggeredAt,
        triggerValue: 1240.1,
        acknowledged: false,
    }
}

function armed(id, armingRevision) {
    return {
        id,
        armingRevision,
        triggeredAt: null,
        triggerValue: null,
        acknowledged: false,
    }
}

/** A Toast as the check's recorder stores it, before attribution. */
function toastAt(seq, text) {
    return {
        account: "holder",
        text,
        className: "toast toast-info",
        url: "/insights",
        at: seenAt(seq),
        seq,
        alertId: null,
        armingRevision: null,
        key: null,
    }
}

function holderSession(responses, toasts = []) {
    return {
        label: "holder",
        account: { ...HOLDER },
        responses,
        toasts,
        pendingBodies: new Set(),
    }
}

function attribution(alertId, armingRevision) {
    return {
        alertId,
        armingRevision,
        key: armingRevision === null ? null : `${alertId}:${armingRevision}`,
    }
}

const UNATTRIBUTED = { alertId: null, armingRevision: null, key: null }

test("parseBaseUrl_text_returnsOriginOrRejects", async (t) => {
    const rows = [
        {
            name: "originTrailingSlash_origin",
            text: "http://localhost:20000/",
            expected: { returned: "http://localhost:20000" },
        },
        {
            name: "httpsOriginNoSlash_origin",
            text: "https://easytrade.test",
            expected: { returned: "https://easytrade.test" },
        },
        {
            name: "repeatedTrailingSlashes_origin",
            text: "http://localhost:20000///",
            expected: { returned: "http://localhost:20000" },
        },
        {
            name: "notAUrl_usageError",
            text: "localhost 20000",
            expected: usageError("--base-url is not a URL: Invalid URL"),
        },
        {
            name: "ftpScheme_usageError",
            text: "ftp://localhost/",
            expected: usageError(
                "--base-url must be an http or https URL, not ftp:"
            ),
        },
        {
            name: "userAndPassword_usageError",
            text: "http://admin:secret@localhost/",
            expected: usageError("--base-url must not carry credentials"),
        },
        {
            name: "userOnly_usageError",
            text: "http://admin@localhost/",
            expected: usageError("--base-url must not carry credentials"),
        },
        {
            name: "query_usageError",
            text: "http://localhost/?debug=1",
            expected: usageError(
                "--base-url must not carry a query or fragment"
            ),
        },
        {
            name: "fragment_usageError",
            text: "http://localhost/#top",
            expected: usageError(
                "--base-url must not carry a query or fragment"
            ),
        },
        {
            name: "path_usageError",
            text: "http://localhost/easytrade/",
            expected: usageError(
                "--base-url must be the app's origin, without the path /easytrade/"
            ),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                outcomeOf(() => parseBaseUrl(row.text)),
                row.expected
            )
        })
    }
})

const VALID_ARGS = [
    "--base-url",
    "http://localhost:20000/",
    "--mode",
    "flag-on",
    "--fixture",
    "run/fixture.json",
    "--evidence-dir",
    "run/evidence",
]

/** VALID_ARGS without `--name` and its value. */
function argsWithout(name) {
    const index = VALID_ARGS.indexOf(`--${name}`)
    return VALID_ARGS.filter((_, i) => i !== index && i !== index + 1)
}

/** VALID_ARGS with `--name` set to `value`. */
function argsWith(name, value) {
    return [...argsWithout(name), `--${name}`, value]
}

test("parseOptions_args_returnsOptionsOrRejects", async (t) => {
    const absoluteFixture = path.join(os.tmpdir(), "fixture.json")
    const rows = [
        {
            name: "everyOption_resolvedOptions",
            args: VALID_ARGS,
            expected: {
                returned: {
                    baseUrl: BASE_URL,
                    mode: "flag-on",
                    fixturePath: path.resolve("run/fixture.json"),
                    evidenceDir: path.resolve("run/evidence"),
                },
            },
        },
        {
            name: "flagOffAbsoluteFixture_pathKept",
            args: argsWith("fixture", absoluteFixture).map((arg) =>
                arg === "flag-on" ? "flag-off" : arg
            ),
            expected: {
                returned: {
                    baseUrl: BASE_URL,
                    mode: "flag-off",
                    fixturePath: absoluteFixture,
                    evidenceDir: path.resolve("run/evidence"),
                },
            },
        },
        {
            name: "missingBaseUrl_usageError",
            args: argsWithout("base-url"),
            expected: usageError("--base-url is required"),
        },
        {
            name: "missingFixture_usageError",
            args: argsWithout("fixture"),
            expected: usageError("--fixture is required"),
        },
        {
            name: "missingEvidenceDir_usageError",
            args: argsWithout("evidence-dir"),
            expected: usageError("--evidence-dir is required"),
        },
        {
            name: "emptyMode_usageError",
            args: argsWith("mode", ""),
            expected: usageError("--mode is required"),
        },
        {
            name: "modeWithoutValue_usageError",
            args: [...argsWithout("mode"), "--mode"],
            expected: usageError("Option '--mode <value>' argument missing"),
        },
        {
            name: "unknownOption_usageError",
            args: [...VALID_ARGS, "--verbose"],
            expected: usageError("Unknown option '--verbose'"),
        },
        {
            name: "positionalArgument_usageError",
            args: [...VALID_ARGS, "extra"],
            expected: usageError(
                "Unexpected argument 'extra'. This command does not take positional arguments"
            ),
        },
        {
            name: "unknownMode_usageError",
            args: argsWith("mode", "flag-maybe"),
            expected: usageError(
                '--mode must be flag-off or flag-on, not "flag-maybe"'
            ),
        },
        {
            name: "baseUrlWithCredentials_usageError",
            args: argsWith("base-url", "http://admin:secret@localhost/"),
            expected: usageError("--base-url must not carry credentials"),
        },
        {
            name: "helpAlone_helpRequested",
            args: ["--help"],
            expected: { returned: { help: true } },
        },
        {
            name: "shortHelpAlone_helpRequested",
            args: ["-h"],
            expected: { returned: { help: true } },
        },
        {
            name: "helpWithEveryOption_helpRequested",
            args: [...VALID_ARGS, "--help"],
            expected: { returned: { help: true } },
        },
        {
            name: "helpWithUnknownMode_helpRequested",
            args: ["--mode", "bogus", "--help"],
            expected: { returned: { help: true } },
        },
        {
            name: "shortHelpWithInvalidBaseUrl_helpRequested",
            args: [...argsWith("base-url", "ftp://localhost/"), "-h"],
            expected: { returned: { help: true } },
        },
        {
            name: "helpWithUnknownOption_usageError",
            args: ["--help", "--verbose"],
            expected: usageError("Unknown option '--verbose'"),
        },
        {
            name: "helpWithValue_usageError",
            args: ["--help=yes"],
            expected: usageError(
                "Option '-h, --help' does not take an argument"
            ),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                outcomeOf(() => parseOptions(row.args)),
                row.expected
            )
        })
    }
})

test("parseAccount_value_returnsAccountOrRejects", async (t) => {
    const prefix = `--fixture ${FIXTURE_PATH} needs`
    const rows = [
        {
            name: "validAccount_idLowerCasedExtraDropped",
            value: { ...RAW_HOLDER, role: "holder" },
            expected: { returned: HOLDER },
        },
        {
            name: "null_usageError",
            value: null,
            expected: usageError(`${prefix} an object holder`),
        },
        {
            name: "array_usageError",
            value: [RAW_HOLDER],
            expected: usageError(`${prefix} an object holder`),
        },
        {
            name: "string_usageError",
            value: "pi-holder",
            expected: usageError(`${prefix} an object holder`),
        },
        {
            name: "missingUsername_usageError",
            value: { ...RAW_HOLDER, username: undefined },
            expected: usageError(
                `${prefix} a non-empty string holder.username`
            ),
        },
        {
            name: "emptyUsername_usageError",
            value: { ...RAW_HOLDER, username: "" },
            expected: usageError(
                `${prefix} a non-empty string holder.username`
            ),
        },
        {
            name: "numericPassword_usageError",
            value: { ...RAW_HOLDER, password: 1234 },
            expected: usageError(
                `${prefix} a non-empty string holder.password`
            ),
        },
        {
            name: "emptyPassword_usageError",
            value: { ...RAW_HOLDER, password: "" },
            expected: usageError(
                `${prefix} a non-empty string holder.password`
            ),
        },
        {
            name: "accountIdNotUuid_usageError",
            value: { ...RAW_HOLDER, accountId: "42" },
            expected: usageError(`${prefix} a UUID holder.accountId`),
        },
        {
            name: "accountIdInBraces_usageError",
            value: { ...RAW_HOLDER, accountId: `{${HOLDER_ID}}` },
            expected: usageError(`${prefix} a UUID holder.accountId`),
        },
        {
            name: "numericAccountId_usageError",
            value: { ...RAW_HOLDER, accountId: 42 },
            expected: usageError(`${prefix} a UUID holder.accountId`),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                outcomeOf(() =>
                    parseAccount(FIXTURE_PATH, row.value, "holder")
                ),
                row.expected
            )
        })
    }
})

test("parseAlert_value_returnsAlertOrRejects", async (t) => {
    const raw = {
        id: TP_ABOVE_ID.toUpperCase(),
        pair: "target_price",
        type: "TARGET_PRICE",
        direction: "ABOVE",
        threshold: "1234.49999999",
        armingRevision: 1,
    }
    const invalid = (reason) =>
        usageError(`--fixture ${FIXTURE_PATH}: alerts[2] ${reason}`)
    const badThreshold = invalid("needs a plain decimal string threshold")
    const outOfDomain = invalid(
        "needs a threshold of at most 10 integer and 8 fractional digits, not counting trailing fractional zeros"
    )
    const notPositive = invalid(
        "of type TARGET_PRICE needs a threshold above 0"
    )
    const badRevision = invalid(
        "needs an integer armingRevision from 1 to 2147483647"
    )
    const rawProfitLoss = {
        id: PL_ABOVE_ID,
        pair: "profit_loss",
        type: "PROFIT_LOSS",
        direction: "ABOVE",
        threshold: "-0.00000001",
        armingRevision: 1,
    }
    const rows = [
        {
            name: "validAlert_idLowerCasedExtraDropped",
            value: { ...raw, instrumentId: "ignored" },
            expected: { returned: TP_ABOVE },
        },
        {
            name: "negativeProfitLossLaterRevision_alert",
            value: {
                id: PL_ABOVE_ID,
                pair: "profit_loss",
                type: "PROFIT_LOSS",
                direction: "BELOW",
                threshold: "-12.5",
                armingRevision: 3,
            },
            expected: {
                returned: {
                    id: PL_ABOVE_ID,
                    pair: "profit_loss",
                    type: "PROFIT_LOSS",
                    direction: "BELOW",
                    threshold: "-12.5",
                    armingRevision: 3,
                },
            },
        },
        {
            name: "targetPriceDomainMaximum_alert",
            value: { ...raw, threshold: "9999999999.99999999" },
            expected: {
                returned: { ...TP_ABOVE, threshold: "9999999999.99999999" },
            },
        },
        {
            name: "targetPriceSmallestThreshold_alert",
            value: { ...raw, threshold: "0.00000001" },
            expected: { returned: { ...TP_ABOVE, threshold: "0.00000001" } },
        },
        {
            name: "trailingZerosBeyondEightPlaces_alertKeepsText",
            value: { ...raw, threshold: "1.500000000000" },
            expected: {
                returned: { ...TP_ABOVE, threshold: "1.500000000000" },
            },
        },
        {
            name: "profitLossZeroThreshold_alert",
            value: { ...rawProfitLoss, threshold: "0" },
            expected: { returned: { ...rawProfitLoss, threshold: "0" } },
        },
        {
            name: "profitLossNegativeDomainMinimum_alert",
            value: { ...rawProfitLoss, threshold: "-9999999999.99999999" },
            expected: {
                returned: {
                    ...rawProfitLoss,
                    threshold: "-9999999999.99999999",
                },
            },
        },
        {
            name: "maximumRevision_alert",
            value: { ...raw, armingRevision: 2147483647 },
            expected: { returned: { ...TP_ABOVE, armingRevision: 2147483647 } },
        },
        {
            name: "elevenIntegerDigits_usageError",
            value: { ...raw, threshold: "12345678901" },
            expected: outOfDomain,
        },
        {
            name: "negativeElevenIntegerDigits_usageError",
            value: { ...rawProfitLoss, threshold: "-10000000000" },
            expected: outOfDomain,
        },
        {
            name: "nineFractionalDigits_usageError",
            value: { ...raw, threshold: "0.000000001" },
            expected: outOfDomain,
        },
        {
            name: "nineFractionalDigitsBeforeTrailingZeros_usageError",
            value: { ...raw, threshold: "1.0000000010" },
            expected: outOfDomain,
        },
        {
            name: "overPrecisionNearSmallest_usageError",
            value: { ...raw, threshold: "0.000000010000000000000000000001" },
            expected: outOfDomain,
        },
        {
            name: "targetPriceZeroThreshold_usageError",
            value: { ...raw, threshold: "0" },
            expected: notPositive,
        },
        {
            name: "targetPriceZeroWithFraction_usageError",
            value: { ...raw, threshold: "0.000" },
            expected: notPositive,
        },
        {
            name: "targetPriceNegativeZero_usageError",
            value: { ...raw, threshold: "-0" },
            expected: notPositive,
        },
        {
            name: "targetPriceNegativeThreshold_usageError",
            value: { ...raw, threshold: "-0.00000001" },
            expected: notPositive,
        },
        {
            name: "null_usageError",
            value: null,
            expected: invalid("must be an object"),
        },
        {
            name: "array_usageError",
            value: [raw],
            expected: invalid("must be an object"),
        },
        {
            name: "idNotUuid_usageError",
            value: { ...raw, id: "alert-1" },
            expected: invalid("needs a UUID id"),
        },
        {
            name: "missingId_usageError",
            value: { ...raw, id: undefined },
            expected: invalid("needs a UUID id"),
        },
        {
            name: "unknownPair_usageError",
            value: { ...raw, pair: "price" },
            expected: invalid("needs a pair of target_price or profit_loss"),
        },
        {
            name: "prototypeMemberPair_usageError",
            value: { ...raw, pair: "toString" },
            expected: invalid("needs a pair of target_price or profit_loss"),
        },
        {
            name: "otherPairsType_usageError",
            value: { ...raw, pair: "profit_loss" },
            expected: invalid("of pair profit_loss needs type PROFIT_LOSS"),
        },
        {
            name: "lowerCaseDirection_usageError",
            value: { ...raw, direction: "above" },
            expected: invalid("needs a direction of ABOVE or BELOW"),
        },
        {
            name: "missingDirection_usageError",
            value: { ...raw, direction: undefined },
            expected: invalid("needs a direction of ABOVE or BELOW"),
        },
        {
            name: "exponentThreshold_usageError",
            value: { ...raw, threshold: "1e5" },
            expected: badThreshold,
        },
        {
            name: "leadingZeroThreshold_usageError",
            value: { ...raw, threshold: "01" },
            expected: badThreshold,
        },
        {
            name: "plusSignedThreshold_usageError",
            value: { ...raw, threshold: "+5" },
            expected: badThreshold,
        },
        {
            name: "trailingPointThreshold_usageError",
            value: { ...raw, threshold: "1." },
            expected: badThreshold,
        },
        {
            name: "leadingPointThreshold_usageError",
            value: { ...raw, threshold: ".5" },
            expected: badThreshold,
        },
        {
            name: "emptyThreshold_usageError",
            value: { ...raw, threshold: "" },
            expected: badThreshold,
        },
        {
            name: "numericThreshold_usageError",
            value: { ...raw, threshold: 1234.5 },
            expected: badThreshold,
        },
        {
            name: "revisionZero_usageError",
            value: { ...raw, armingRevision: 0 },
            expected: badRevision,
        },
        {
            name: "revisionAboveInt32_usageError",
            value: { ...raw, armingRevision: 2147483648 },
            expected: badRevision,
        },
        {
            name: "fractionalRevision_usageError",
            value: { ...raw, armingRevision: 1.5 },
            expected: badRevision,
        },
        {
            name: "stringRevision_usageError",
            value: { ...raw, armingRevision: "1" },
            expected: badRevision,
        },
        {
            name: "missingRevision_usageError",
            value: { ...raw, armingRevision: undefined },
            expected: badRevision,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                outcomeOf(() => parseAlert(FIXTURE_PATH, row.value, 2)),
                row.expected
            )
        })
    }
})

test("parseAlerts_value_returnsOrderedPairsOrRejects", async (t) => {
    const prefix = `--fixture ${FIXTURE_PATH} needs`
    const notFour = usageError(`${prefix} exactly four alerts for flag-on`)
    const replaced = (index, changes) =>
        rawAlerts().map((alert, i) =>
            i === index ? { ...alert, ...changes } : alert
        )
    const rows = [
        {
            name: "anyOrderAndIdCase_orderedLowerCase",
            value: rawAlerts(),
            expected: { returned: FIXTURE_ALERTS },
        },
        { name: "missing_usageError", value: undefined, expected: notFour },
        {
            name: "objectNotList_usageError",
            value: { 0: FIXTURE_ALERTS[0] },
            expected: notFour,
        },
        {
            name: "threeAlerts_usageError",
            value: rawAlerts().slice(1),
            expected: notFour,
        },
        {
            name: "fiveAlerts_usageError",
            value: [...rawAlerts(), { ...TP_ABOVE, id: FOREIGN_ALERT_ID }],
            expected: notFour,
        },
        {
            name: "idRepeatedInOtherCase_usageError",
            value: replaced(0, { id: TP_ABOVE_ID }),
            expected: usageError(`${prefix} four distinct alert ids`),
        },
        {
            name: "twoTargetPriceAbove_usageError",
            value: replaced(2, { direction: "ABOVE" }),
            expected: usageError(
                `${prefix} exactly one target_price ABOVE alert, not 2`
            ),
        },
        {
            name: "noTargetPriceAbove_usageError",
            value: replaced(3, {
                pair: "profit_loss",
                type: "PROFIT_LOSS",
                direction: "BELOW",
            }),
            expected: usageError(
                `${prefix} exactly one target_price ABOVE alert, not 0`
            ),
        },
        {
            name: "invalidMember_usageErrorNamesIndex",
            value: replaced(1, { threshold: "1e5" }),
            expected: usageError(
                `--fixture ${FIXTURE_PATH}: alerts[1] needs a plain decimal string threshold`
            ),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                outcomeOf(() => parseAlerts(FIXTURE_PATH, row.value)),
                row.expected
            )
        })
    }
})

test("readFixture_fileContent_returnsFixtureOrRejects", async (t) => {
    const flagOn = {
        evaluationIntervalSeconds: 30,
        holder: RAW_HOLDER,
        empty: EMPTY,
        alerts: rawAlerts(),
    }
    const json = (value) => JSON.stringify(value)
    const badInterval = (file) =>
        usageError(
            `--fixture ${file} needs an integer evaluationIntervalSeconds from 1 to 4294967`
        )
    const parsedWithInterval = (evaluationIntervalSeconds) => () => ({
        returned: {
            evaluationIntervalSeconds,
            holder: HOLDER,
            empty: EMPTY,
            alerts: FIXTURE_ALERTS,
        },
    })
    const rows = [
        {
            name: "flagOnFixture_parsed",
            text: json(flagOn),
            mode: "flag-on",
            expected: () => ({
                returned: {
                    evaluationIntervalSeconds: 30,
                    holder: HOLDER,
                    empty: EMPTY,
                    alerts: FIXTURE_ALERTS,
                },
            }),
        },
        {
            name: "byteOrderMark_stripped",
            text: `\uFEFF${json(flagOn)}`,
            mode: "flag-on",
            expected: () => ({
                returned: {
                    evaluationIntervalSeconds: 30,
                    holder: HOLDER,
                    empty: EMPTY,
                    alerts: FIXTURE_ALERTS,
                },
            }),
        },
        {
            name: "intervalAbsent_defaults60",
            text: json({ ...flagOn, evaluationIntervalSeconds: undefined }),
            mode: "flag-on",
            expected: () => ({
                returned: {
                    evaluationIntervalSeconds: 60,
                    holder: HOLDER,
                    empty: EMPTY,
                    alerts: FIXTURE_ALERTS,
                },
            }),
        },
        {
            name: "intervalOne_parsed",
            text: json({ ...flagOn, evaluationIntervalSeconds: 1 }),
            mode: "flag-on",
            expected: parsedWithInterval(1),
        },
        {
            name: "intervalBrokerMaximum_parsed",
            text: json({ ...flagOn, evaluationIntervalSeconds: 4294967 }),
            mode: "flag-on",
            expected: parsedWithInterval(4294967),
        },
        {
            name: "intervalZero_usageError",
            text: json({ ...flagOn, evaluationIntervalSeconds: 0 }),
            mode: "flag-on",
            expected: badInterval,
        },
        {
            name: "intervalAboveBrokerMaximum_usageError",
            text: json({ ...flagOn, evaluationIntervalSeconds: 4294968 }),
            mode: "flag-on",
            expected: badInterval,
        },

        {
            name: "fractionalInterval_usageError",
            text: json({ ...flagOn, evaluationIntervalSeconds: 1.5 }),
            mode: "flag-on",
            expected: badInterval,
        },
        {
            name: "stringInterval_usageError",
            text: json({ ...flagOn, evaluationIntervalSeconds: "60" }),
            mode: "flag-on",
            expected: badInterval,
        },
        {
            name: "negativeInterval_usageError",
            text: json({ ...flagOn, evaluationIntervalSeconds: -60 }),
            mode: "flag-off",
            expected: badInterval,
        },
        {
            name: "jsonList_usageError",
            text: json([flagOn]),
            mode: "flag-on",
            expected: (file) =>
                usageError(`--fixture ${file} must hold a JSON object`),
        },
        {
            name: "jsonNull_usageError",
            text: "null",
            mode: "flag-off",
            expected: (file) =>
                usageError(`--fixture ${file} must hold a JSON object`),
        },
        {
            name: "jsonString_usageError",
            text: json("fixture"),
            mode: "flag-off",
            expected: (file) =>
                usageError(`--fixture ${file} must hold a JSON object`),
        },
        {
            name: "flagOffWithoutEmptyOrAlerts_emptyNullNoAlerts",
            text: json({ holder: RAW_HOLDER, alerts: "not a list" }),
            mode: "flag-off",
            expected: () => ({
                returned: {
                    evaluationIntervalSeconds: 60,
                    holder: HOLDER,
                    empty: null,
                    alerts: [],
                },
            }),
        },
        {
            name: "flagOffWithEmpty_emptyParsed",
            text: json({ holder: RAW_HOLDER, empty: EMPTY }),
            mode: "flag-off",
            expected: () => ({
                returned: {
                    evaluationIntervalSeconds: 60,
                    holder: HOLDER,
                    empty: EMPTY,
                    alerts: [],
                },
            }),
        },
        {
            name: "flagOffInvalidEmpty_usageError",
            text: json({ holder: RAW_HOLDER, empty: {} }),
            mode: "flag-off",
            expected: (file) =>
                usageError(
                    `--fixture ${file} needs a non-empty string empty.username`
                ),
        },
        {
            name: "flagOffWithoutHolder_usageError",
            text: json({ empty: EMPTY }),
            mode: "flag-off",
            expected: (file) =>
                usageError(`--fixture ${file} needs an object holder`),
        },
        {
            name: "flagOnWithoutEmpty_usageError",
            text: json({ ...flagOn, empty: undefined }),
            mode: "flag-on",
            expected: (file) =>
                usageError(`--fixture ${file} needs an object empty`),
        },
        {
            name: "flagOnThreeAlerts_usageError",
            text: json({ ...flagOn, alerts: rawAlerts().slice(1) }),
            mode: "flag-on",
            expected: (file) =>
                usageError(
                    `--fixture ${file} needs exactly four alerts for flag-on`
                ),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            const file = path.join(await tempDir(st), "fixture.json")
            await writeFile(file, row.text)

            assert.deepEqual(
                await asyncOutcomeOf(() => readFixture(file, row.mode)),
                row.expected(file)
            )
        })
    }
})

test("readFixture_invalidJson_messageQuotesNoFixtureText", async (t) => {
    const file = path.join(await tempDir(t), "fixture.json")
    // Cut off after the password, where JSON.parse quotes the text around it.
    await writeFile(
        file,
        `{"holder": {"username": "pi-holder", "password": "${RAW_HOLDER.password}",`
    )

    assert.deepEqual(
        await asyncOutcomeOf(() => readFixture(file, "flag-on")),
        usageError(`--fixture ${file} is not valid JSON`)
    )
})

test("readFixture_unreadablePath_rejectsWithReadError", async (t) => {
    const file = path.join(await tempDir(t), "missing.json")

    const outcome = await asyncOutcomeOf(() => readFixture(file, "flag-off"))

    assert.deepEqual(
        {
            threw: outcome.threw,
            readError: outcome.message.startsWith(
                "cannot read --fixture: ENOENT"
            ),
        },
        { threw: "UsageError", readError: true }
    )
})

test("parseFlagBody_text_returnsProjectedFlagOrProblem", async (t) => {
    const flag = {
        id: "portfolio-insights-enabled",
        name: "Portfolio insights",
        enabled: false,
        isModifiable: true,
        tag: "feature",
    }
    const noFlag = {
        flag: null,
        problem: 'without "portfolio-insights-enabled" and a boolean "enabled"',
    }
    const rows = [
        {
            name: "disabledFlag_idAndEnabledOnly",
            text: JSON.stringify(flag),
            expected: {
                flag: { id: "portfolio-insights-enabled", enabled: false },
                problem: null,
            },
        },
        {
            name: "emptyBody_notJsonProblem",
            text: "",
            expected: { flag: null, problem: "with a body that is not JSON" },
        },
        { name: "jsonNull_noFlagProblem", text: "null", expected: noFlag },
        {
            name: "jsonList_noFlagProblem",
            text: JSON.stringify([flag]),
            expected: noFlag,
        },
        {
            name: "otherFlag_noFlagProblem",
            text: JSON.stringify({ ...flag, id: "db_not_responding" }),
            expected: noFlag,
        },
        {
            name: "missingEnabled_noFlagProblem",
            text: JSON.stringify({ ...flag, enabled: undefined }),
            expected: noFlag,
        },
        {
            name: "numericEnabled_noFlagProblem",
            text: JSON.stringify({ ...flag, enabled: 1 }),
            expected: noFlag,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(parseFlagBody(row.text), row.expected)
        })
    }
})

test("classifyResponse_methodAndUrl_returnsKindOrNull", async (t) => {
    const broker = `${BASE_URL}/broker-service/v1`
    const rows = [
        {
            name: "flagRead_flag",
            method: "GET",
            url: `${BASE_URL}/feature-flag-service/v1/flags/portfolio-insights-enabled`,
            expected: { kind: "flag", accountId: null, alertId: null },
        },
        {
            name: "flagWrite_flag",
            method: "PUT",
            url: `${BASE_URL}/feature-flag-service/v1/flags/portfolio-insights-enabled`,
            expected: { kind: "flag", accountId: null, alertId: null },
        },
        {
            name: "otherFlag_null",
            method: "GET",
            url: `${BASE_URL}/feature-flag-service/v1/flags/db_not_responding`,
            expected: null,
        },
        {
            name: "insightsUpperCaseAccount_insightsLowerCase",
            method: "GET",
            url: `${broker}/portfolio/insights/${HOLDER_ID.toUpperCase()}`,
            expected: {
                kind: "insights",
                accountId: HOLDER_ID,
                alertId: null,
            },
        },
        {
            name: "notifications_notificationsLowerCase",
            method: "GET",
            url: `${broker}/alerts/notifications?accountId=${HOLDER_ID.toUpperCase()}&unacknowledged=true`,
            expected: {
                kind: "notifications",
                accountId: HOLDER_ID,
                alertId: null,
            },
        },
        {
            name: "notificationsWithoutAccount_emptyAccount",
            method: "GET",
            url: `${broker}/alerts/notifications`,
            expected: { kind: "notifications", accountId: "", alertId: null },
        },
        {
            name: "alertsList_alertsList",
            method: "GET",
            url: `${broker}/alerts?accountId=${HOLDER_ID}`,
            expected: {
                kind: "alertsList",
                accountId: HOLDER_ID,
                alertId: null,
            },
        },
        {
            name: "alertCreate_null",
            method: "POST",
            url: `${broker}/alerts?accountId=${HOLDER_ID}`,
            expected: null,
        },
        {
            name: "alertPatchUpperCaseId_patchLowerCase",
            method: "PATCH",
            url: `${broker}/alerts/${TP_ABOVE_ID.toUpperCase()}`,
            expected: { kind: "patch", accountId: null, alertId: TP_ABOVE_ID },
        },
        {
            name: "alertDelete_null",
            method: "DELETE",
            url: `${broker}/alerts/${TP_ABOVE_ID}`,
            expected: null,
        },
        {
            name: "acknowledge_acknowledge",
            method: "POST",
            url: `${broker}/alerts/${TP_ABOVE_ID}/acknowledge`,
            expected: {
                kind: "acknowledge",
                accountId: null,
                alertId: TP_ABOVE_ID,
            },
        },
        {
            name: "acknowledgePathGet_null",
            method: "GET",
            url: `${broker}/alerts/${TP_ABOVE_ID}/acknowledge`,
            expected: null,
        },
        {
            name: "alertPathWithoutUuid_null",
            method: "PATCH",
            url: `${broker}/alerts/alert-1`,
            expected: null,
        },
        {
            name: "otherBrokerPath_null",
            method: "GET",
            url: `${broker}/instruments`,
            expected: null,
        },
        {
            name: "frontendAsset_null",
            method: "GET",
            url: `${BASE_URL}/assets/index.js`,
            expected: null,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(
                classifyResponse(row.method, new URL(row.url)),
                row.expected
            )
        })
    }
})

/** A Puppeteer HTTPResponse stand-in that counts its body reads. */
function fakeResponse({ method = "GET", url, status = 200, text }) {
    const response = {
        bodyReads: 0,
        url: () => url,
        request: () => ({ method: () => method }),
        status: () => status,
        text: async () => {
            response.bodyReads += 1
            return text
        },
        json: async () => {
            response.bodyReads += 1
            return JSON.parse(text)
        },
    }
    return response
}

/** The recorder's part of a session `openSession` opens on `BASE_URL`. */
function responseSession() {
    return {
        account: HOLDER,
        origin: BASE_URL,
        responses: [],
        pendingBodies: new Set(),
    }
}

const NOTIFICATIONS_URL = `${BASE_URL}/broker-service/v1/alerts/notifications?accountId=${HOLDER_ID}&unacknowledged=true`

test("recordResponse_classifiedResponse_recordsEntryBeforeBody", (t) => {
    t.mock.timers.enable({ apis: ["Date"], now: AT0 })
    const session = responseSession()

    recordResponse(
        session,
        fakeResponse({ url: NOTIFICATIONS_URL, text: '{"results":[]}' })
    )

    const [entry] = session.responses
    assert.deepEqual(
        {
            count: session.responses.length,
            kind: entry.kind,
            accountId: entry.accountId,
            alertId: entry.alertId,
            url: entry.url,
            path: entry.path,
            method: entry.method,
            status: entry.status,
            at: entry.at,
            parsed: entry.parsed,
            body: entry.body,
            pendingBodies: session.pendingBodies.size,
        },
        {
            count: 1,
            kind: "notifications",
            accountId: HOLDER_ID,
            alertId: null,
            url: NOTIFICATIONS_URL,
            path: "/broker-service/v1/alerts/notifications",
            method: "GET",
            status: 200,
            at: AT0,
            parsed: false,
            body: undefined,
            pendingBodies: 1,
        }
    )
})

test("recordResponse_successiveResponses_sequencedInArrivalOrder", () => {
    const session = responseSession()

    for (const url of [
        NOTIFICATIONS_URL,
        `${BASE_URL}/broker-service/v1/portfolio/insights/${HOLDER_ID}`,
        `${BASE_URL}/feature-flag-service/v1/flags/portfolio-insights-enabled`,
    ]) {
        recordResponse(session, fakeResponse({ url, text: "{}" }))
    }

    const seqs = session.responses.map((entry) => entry.seq)
    assert.deepEqual(
        {
            kinds: session.responses.map((entry) => entry.kind),
            increasing: seqs.every(
                (seq, i) =>
                    Number.isInteger(seq) && (i === 0 || seq > seqs[i - 1])
            ),
        },
        { kinds: ["notifications", "insights", "flag"], increasing: true }
    )
})

test("recordResponse_bodyOutcome_settlesEntry", async (t) => {
    const results = { results: [triggered(TP_ABOVE_ID, 1)] }
    const rows = [
        {
            name: "jsonBody_parsed",
            response: { url: NOTIFICATIONS_URL, text: JSON.stringify(results) },
            expected: {
                parsed: true,
                body: results,
                bodyError: undefined,
                bodyReads: 1,
                pendingBodies: 0,
            },
        },
        {
            name: "status204_notRead",
            response: {
                method: "POST",
                url: `${BASE_URL}/broker-service/v1/alerts/${TP_ABOVE_ID}/acknowledge`,
                status: 204,
                text: "",
            },
            expected: {
                parsed: false,
                body: undefined,
                bodyError: undefined,
                bodyReads: 0,
                pendingBodies: 0,
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            const session = responseSession()
            const response = fakeResponse(row.response)

            recordResponse(session, response)
            await Promise.all([...session.pendingBodies])

            const [entry] = session.responses
            assert.deepEqual(
                {
                    parsed: entry.parsed,
                    body: entry.body,
                    bodyError: entry.bodyError,
                    bodyReads: response.bodyReads,
                    pendingBodies: session.pendingBodies.size,
                },
                row.expected
            )
        })
    }
})

test("recordResponse_unclassifiedResponse_recordsNothing", () => {
    const session = responseSession()
    const responses = [
        fakeResponse({
            method: "POST",
            url: `${BASE_URL}/broker-service/v1/alerts?accountId=${HOLDER_ID}`,
            status: 201,
            text: "{}",
        }),
        fakeResponse({ url: `${BASE_URL}/assets/index.js`, text: "" }),
    ]

    for (const response of responses) {
        recordResponse(session, response)
    }

    assert.deepEqual(
        {
            responses: session.responses,
            pendingBodies: session.pendingBodies.size,
            bodyReads: responses.map((response) => response.bodyReads),
        },
        { responses: [], pendingBodies: 0, bodyReads: [0, 0] }
    )
})

test("resultsOf_entryBody_returnsResultsList", async (t) => {
    const items = [triggered(TP_ABOVE_ID, 1)]
    const rows = [
        {
            name: "resultsList_returned",
            body: { results: items },
            expected: items,
        },
        {
            name: "resultsNotList_empty",
            body: { results: "none" },
            expected: [],
        },
        { name: "listBody_empty", body: items, expected: [] },
        { name: "nullBody_empty", body: null, expected: [] },
        { name: "unreadBody_empty", body: undefined, expected: [] },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(resultsOf({ body: row.body }), row.expected)
        })
    }
})

test("idOf_item_returnsLowerCaseIdOrNull", async (t) => {
    const rows = [
        {
            name: "upperCaseId_lowerCased",
            item: { id: TP_ABOVE_ID.toUpperCase() },
            expected: TP_ABOVE_ID,
        },
        { name: "numericId_null", item: { id: 7 }, expected: null },
        { name: "missingId_null", item: {}, expected: null },
        { name: "nullItem_null", item: null, expected: null },
        { name: "listItem_null", item: [TP_ABOVE_ID], expected: null },
        { name: "stringItem_null", item: TP_ABOVE_ID, expected: null },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.equal(idOf(row.item), row.expected)
        })
    }
})

test("isTriggered_triggeredAt_tellsWhetherTriggered", async (t) => {
    const rows = [
        { name: "triggerTime_true", item: { triggeredAt: T1 }, expected: true },
        {
            name: "nullTriggerTime_false",
            item: { triggeredAt: null },
            expected: false,
        },
        { name: "missingTriggerTime_false", item: {}, expected: false },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.equal(isTriggered(row.item), row.expected)
        })
    }
})

test("armingKey_idAndRevision_joinsThem", () => {
    assert.equal(armingKey(TP_ABOVE_ID, 3), `${TP_ABOVE_ID}:3`)
})

test("fixtureAlertOf_toastText_returnsNamedFixtureAlert", async (t) => {
    const bigAlert = { ...TP_ABOVE, threshold: "9999999999.5" }
    const negativeAlert = { ...FIXTURE_ALERTS[3], threshold: "-1234.5" }
    const rows = [
        {
            name: "targetPriceAbove_matched",
            text: TOAST_TP_ABOVE,
            alerts: FIXTURE_ALERTS,
            expected: TP_ABOVE_ID,
        },
        {
            name: "targetPriceBelow_matched",
            text: TOAST_TP_BELOW,
            alerts: FIXTURE_ALERTS,
            expected: TP_BELOW_ID,
        },
        {
            name: "negativeProfitLossThreshold_matched",
            text: TOAST_PL_ABOVE,
            alerts: FIXTURE_ALERTS,
            expected: PL_ABOVE_ID,
        },
        {
            name: "instrumentIdPrefix_matched",
            text: TOAST_PL_BELOW,
            alerts: FIXTURE_ALERTS,
            expected: PL_BELOW_ID,
        },
        {
            name: "negativeThousandsSeparators_matched",
            text: "Alert triggered: Apple P/L below -1,234.5 (now -2,000)",
            alerts: [negativeAlert],
            expected: PL_BELOW_ID,
        },
        {
            name: "near1e10WithinTolerance_matched",
            text: "Alert triggered: Apple Price above 9,999,999,999.500002 (now 10,000,000,000)",
            alerts: [bigAlert],
            expected: TP_ABOVE_ID,
        },
        {
            name: "near1e10BeyondTolerance_null",
            text: "Alert triggered: Apple Price above 9,999,999,999.5001 (now 10,000,000,000)",
            alerts: [bigAlert],
            expected: null,
        },
        {
            name: "otherPairMemberThreshold_null",
            text: "Alert triggered: Apple Price above 1,234.50000001 (now 1,240.1)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "typeWithoutThatThreshold_null",
            text: "Alert triggered: Apple P/L above 1,234.49999999 (now 1)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "thresholdOfNoFixtureAlert_null",
            text: "Alert triggered: Apple Price above 99 (now 100)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "thresholdNotNumber_null",
            text: "Alert triggered: Apple Price above 1,234.4x (now 1)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "thresholdMissing_null",
            text: "Alert triggered: Apple Price above (now 1)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "lowerCaseKind_null",
            text: "Alert triggered: Apple price above 1,234.49999999 (now 1)",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "notAlertToast_null",
            text: TOAST_OTHER,
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
        {
            name: "emptyText_null",
            text: "",
            alerts: FIXTURE_ALERTS,
            expected: null,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const alert = fixtureAlertOf(row.text, row.alerts)
            assert.equal(alert === null ? null : alert.id, row.expected)
        })
    }
})

test("triggeredArmings_notificationResponses_collectsFixtureArmings", async (t) => {
    const arming = (id, armingRevision, triggeredAt, seq) => ({
        key: `${id}:${armingRevision}`,
        id,
        armingRevision,
        triggeredAt,
        firstSeenAt: seenAt(seq),
    })
    const rows = [
        {
            name: "armedFixtureAlert_none",
            responses: [notifications(10, [armed(TP_ABOVE_ID, 1)])],
            expected: [],
        },
        {
            name: "noTriggerTime_none",
            responses: [
                notifications(10, [{ id: TP_ABOVE_ID, armingRevision: 1 }]),
            ],
            expected: [],
        },
        {
            name: "nonFixtureAlert_none",
            responses: [notifications(10, [triggered(FOREIGN_ALERT_ID, 1)])],
            expected: [],
        },
        {
            name: "otherAccountResponse_none",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)], {
                    accountId: OTHER_ACCOUNT_ID,
                    accepted: false,
                    rejection: "is for another account",
                }),
            ],
            expected: [],
        },
        {
            name: "bodyNotRead_none",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)], {
                    parsed: false,
                    body: undefined,
                    bodyError: "Target closed",
                }),
            ],
            expected: [],
        },
        {
            name: "alertsListResponse_none",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)], {
                    kind: "alertsList",
                }),
            ],
            expected: [],
        },
        {
            name: "upperCaseId_lowerCaseArming",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID.toUpperCase(), 1)]),
            ],
            expected: [arming(TP_ABOVE_ID, 1, T1, 10)],
        },
        {
            name: "repeatedSighting_firstKept",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1, T1)]),
                notifications(20, [triggered(TP_ABOVE_ID, 1, T2)]),
            ],
            expected: [arming(TP_ABOVE_ID, 1, T1, 10)],
        },
        {
            name: "eachRevision_ownArming",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1, T1)]),
                notifications(20, [armed(TP_ABOVE_ID, 2)]),
                notifications(30, [
                    triggered(PL_BELOW_ID, 2, T1),
                    triggered(TP_ABOVE_ID, 2, T2),
                ]),
            ],
            expected: [
                arming(TP_ABOVE_ID, 1, T1, 10),
                arming(PL_BELOW_ID, 2, T1, 30),
                arming(TP_ABOVE_ID, 2, T2, 30),
            ],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const session = holderSession(row.responses)
            assert.deepEqual(
                [...triggeredArmings(session, FIXTURE_ALERTS).values()],
                row.expected
            )
        })
    }
})

test("attributeToasts_toastsAndResponses_assignsAnnouncedArming", async (t) => {
    const rows = [
        {
            name: "lastTriggeredBeforeToast_itsRevision",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)]),
                notifications(20, [triggered(TP_ABOVE_ID, 2)]),
            ],
            toasts: [toastAt(25, TOAST_TP_ABOVE)],
            expected: [attribution(TP_ABOVE_ID, 2)],
        },
        {
            name: "laterResponse_unexplained",
            responses: [notifications(30, [triggered(TP_ABOVE_ID, 1)])],
            toasts: [toastAt(25, TOAST_TP_ABOVE)],
            expected: [attribution(TP_ABOVE_ID, null)],
        },
        {
            name: "untriggeredSighting_unexplained",
            responses: [notifications(10, [armed(TP_ABOVE_ID, 1)])],
            toasts: [toastAt(25, TOAST_TP_ABOVE)],
            expected: [attribution(TP_ABOVE_ID, null)],
        },
        {
            name: "otherAccountResponse_unexplained",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)], {
                    accountId: OTHER_ACCOUNT_ID,
                    accepted: false,
                    rejection: "is for another account",
                }),
            ],
            toasts: [toastAt(25, TOAST_TP_ABOVE)],
            expected: [attribution(TP_ABOVE_ID, null)],
        },
        {
            name: "nonFixtureToasts_untouched",
            responses: [notifications(10, [triggered(TP_ABOVE_ID, 1)])],
            toasts: [
                toastAt(25, TOAST_OTHER),
                toastAt(26, "Alert triggered: Apple Price above 99 (now 100)"),
            ],
            expected: [UNATTRIBUTED, UNATTRIBUTED],
        },
        {
            name: "twoAlerts_eachMatchedToOwnAlert",
            responses: [
                notifications(10, [
                    triggered(TP_ABOVE_ID, 1),
                    triggered(PL_BELOW_ID, 2),
                ]),
            ],
            toasts: [toastAt(11, TOAST_PL_BELOW), toastAt(12, TOAST_TP_ABOVE)],
            expected: [
                attribution(PL_BELOW_ID, 2),
                attribution(TP_ABOVE_ID, 1),
            ],
        },
        {
            name: "reArmedAlert_newToastNewRevision",
            responses: [
                notifications(10, [triggered(TP_ABOVE_ID, 1)]),
                notifications(15, [armed(TP_ABOVE_ID, 2)]),
                notifications(20, [triggered(TP_ABOVE_ID, 2)]),
            ],
            toasts: [
                toastAt(12, TOAST_TP_ABOVE),
                toastAt(17, TOAST_TP_ABOVE),
                toastAt(22, TOAST_TP_ABOVE),
            ],
            // A Toast before the new trigger repeats the old arming.
            expected: [
                attribution(TP_ABOVE_ID, 1),
                attribution(TP_ABOVE_ID, 1),
                attribution(TP_ABOVE_ID, 2),
            ],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const session = holderSession(row.responses, row.toasts)

            attributeToasts(session, FIXTURE_ALERTS)

            assert.deepEqual(
                session.toasts.map(({ alertId, armingRevision, key }) => ({
                    alertId,
                    armingRevision,
                    key,
                })),
                row.expected
            )
        })
    }
})

test("toastCounts_attributedToasts_countsPerArmingKey", () => {
    const keyed = (seq, key) => ({ ...toastAt(seq, TOAST_TP_ABOVE), key })
    const session = holderSession(
        [],
        [
            keyed(1, `${TP_ABOVE_ID}:1`),
            keyed(2, null),
            keyed(3, `${PL_BELOW_ID}:2`),
            keyed(4, `${TP_ABOVE_ID}:1`),
        ]
    )

    assert.deepEqual(
        [...toastCounts(session)],
        [
            [`${TP_ABOVE_ID}:1`, 2],
            [`${PL_BELOW_ID}:2`, 1],
        ]
    )
})

const VALID_INSIGHTS = {
    totalValue: 15234.5,
    totalInvested: 14000,
    unrealizedPnl: 1234.5,
    unrealizedPnlPercent: 8.82,
    allocations: [
        { name: "Apple", quantity: 10, value: 9000, percent: 59.08 },
        { name: "Tesla", quantity: 3, value: 6234.5, percent: 40.92 },
    ],
    largestPosition: {
        name: "Apple",
        quantity: 10,
        value: 9000,
        percent: 59.08,
    },
    riskLevel: "MEDIUM",
}

const EMPTY_INSIGHTS = {
    totalValue: 0,
    totalInvested: 0,
    unrealizedPnl: 0,
    unrealizedPnlPercent: 0,
    allocations: [],
    largestPosition: null,
    riskLevel: null,
}

/** VALID_INSIGHTS with `field` replaced, or removed when `value` is absent. */
function insightsWith(field, value) {
    const body = { ...VALID_INSIGHTS, [field]: value }
    if (value === undefined) {
        delete body[field]
    }
    return body
}

test("insightsShapeProblem_body_namesFirstProblemOrNull", async (t) => {
    const prefix = "the insights response has"
    const badAllocations = `${prefix} no valid allocations list`
    const [apple] = VALID_INSIGHTS.allocations
    const rows = [
        { name: "validResponse_null", body: VALID_INSIGHTS, expected: null },
        {
            name: "emptyAccountResponse_null",
            body: EMPTY_INSIGHTS,
            expected: null,
        },
        {
            name: "null_notObject",
            body: null,
            expected: "the insights response is not a JSON object",
        },
        {
            name: "list_notObject",
            body: [VALID_INSIGHTS],
            expected: "the insights response is not a JSON object",
        },
        {
            name: "missingTotalValue_problem",
            body: insightsWith("totalValue", undefined),
            expected: `${prefix} no numeric totalValue`,
        },
        {
            name: "stringTotalInvested_problem",
            body: insightsWith("totalInvested", "14000"),
            expected: `${prefix} no numeric totalInvested`,
        },
        {
            name: "nullUnrealizedPnl_problem",
            body: insightsWith("unrealizedPnl", null),
            expected: `${prefix} no numeric unrealizedPnl`,
        },
        {
            name: "infiniteUnrealizedPnlPercent_problem",
            body: insightsWith("unrealizedPnlPercent", Infinity),
            expected: `${prefix} no numeric unrealizedPnlPercent`,
        },
        {
            name: "missingAllocations_problem",
            body: insightsWith("allocations", undefined),
            expected: badAllocations,
        },
        {
            name: "allocationWithoutName_problem",
            body: insightsWith("allocations", [{ ...apple, name: 7 }]),
            expected: badAllocations,
        },
        {
            name: "allocationStringPercent_problem",
            body: insightsWith("allocations", [{ ...apple, percent: "59.08" }]),
            expected: badAllocations,
        },
        {
            name: "nullAllocation_problem",
            body: insightsWith("allocations", [null]),
            expected: badAllocations,
        },
        {
            name: "missingLargestPosition_problem",
            body: insightsWith("largestPosition", undefined),
            expected: `${prefix} an invalid largestPosition`,
        },
        {
            name: "largestPositionWithoutFigures_problem",
            body: insightsWith("largestPosition", { name: "Apple" }),
            expected: `${prefix} an invalid largestPosition`,
        },
        {
            name: "unknownRiskLevel_problemDescribesValue",
            body: insightsWith("riskLevel", "EXTREME"),
            expected: `${prefix} an unknown riskLevel, a string of 7 characters`,
        },
        {
            name: "lowerCaseRiskLevel_problemDescribesValue",
            body: insightsWith("riskLevel", "low"),
            expected: `${prefix} an unknown riskLevel, a string of 3 characters`,
        },
        {
            name: "prototypeMemberRiskLevel_problemDescribesValue",
            body: insightsWith("riskLevel", "toString"),
            expected: `${prefix} an unknown riskLevel, a string of 8 characters`,
        },
        {
            name: "missingRiskLevel_problem",
            body: insightsWith("riskLevel", undefined),
            expected: `${prefix} an unknown riskLevel, undefined`,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.equal(insightsShapeProblem(row.body), row.expected)
        })
    }
})

test("formatInPage_values_formatAsFormatterContext", async (t) => {
    const currency = (n, text) => ({
        values: { currency: [n], percent: [] },
        expected: { currency: [text], percent: [] },
    })
    const percent = (n, text) => ({
        values: { currency: [], percent: [n] },
        expected: { currency: [], percent: [text] },
    })
    const rows = [
        {
            name: "currency_twoDecimalsGrouped",
            ...currency(1234.5, "$1,234.50"),
        },
        {
            name: "currencyMillion_twoDecimalsGrouped",
            ...currency(1000000, "$1,000,000.00"),
        },
        { name: "currencyOneCent_twoDecimals", ...currency(0.01, "$0.01") },
        {
            name: "currencyBelowOneCent_significantDigits",
            ...currency(0.005, "$0.005"),
        },
        { name: "zeroCurrency_smallFormat", ...currency(0, "$0") },
        // FormatterContext gives every value below 0.01 the small format.
        { name: "negativeCurrency_smallFormat", ...currency(-12.3, "-$12.3") },
        { name: "positivePercent_signed", ...percent(12.345, "+12.35%") },
        { name: "negativePercent_signed", ...percent(-5, "-5.00%") },
        { name: "zeroPercent_unsigned", ...percent(0, "0.00%") },
        {
            name: "percentRoundingToZero_unsigned",
            ...percent(0.004, "0.00%"),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(formatInPage(row.values), row.expected)
        })
    }
})

test("waitOrReport_waitOutcome_turnsOnlyTimeoutsIntoProblems", async (t) => {
    const timeout = new WaitTimeoutError(
        "timed out after 20000 ms waiting for a fixture alert in #alert-notifications"
    )
    const rows = [
        {
            name: "resolvedWait_value",
            wait: async () => TP_ABOVE_ID,
            expected: { outcome: { returned: TP_ABOVE_ID }, problems: [] },
        },
        {
            name: "timeout_problemAndNull",
            wait: async () => {
                throw timeout
            },
            expected: {
                outcome: { returned: null },
                problems: [timeout.message],
            },
        },
        {
            name: "otherError_rethrown",
            wait: async () => {
                throw new Error("Target closed")
            },
            expected: {
                outcome: { threw: "Error", message: "Target closed" },
                problems: [],
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            const problems = []

            const outcome = await asyncOutcomeOf(() =>
                waitOrReport(problems, row.wait)
            )

            assert.deepEqual({ outcome, problems }, row.expected)
        })
    }
})

test("recordCheck_outcome_printsLineAndRecordsEntry", async (t) => {
    const name = "flag-on:acknowledge"
    const reason = "the acknowledge status is 404, expected 204"
    const rows = [
        {
            name: "ok_passLineAndEntry",
            ok: true,
            expected: {
                returned: true,
                checks: [
                    {
                        name,
                        status: "PASS",
                        reason: null,
                        details: { status: 204 },
                        at: EPOCH_ISO,
                    },
                ],
                lines: [`PASS ${name}`],
            },
        },
        {
            name: "notOk_failLineWithReason",
            ok: false,
            expected: {
                returned: false,
                checks: [
                    {
                        name,
                        status: "FAIL",
                        reason,
                        details: { status: 204 },
                        at: EPOCH_ISO,
                    },
                ],
                lines: [`FAIL ${name}: ${reason}`],
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, (st) => {
            st.mock.timers.enable({ apis: ["Date"], now: 0 })
            const output = captureConsole(st)
            const report = { checks: [] }

            const returned = recordCheck(report, name, row.ok, reason, {
                status: 204,
            })

            assert.deepEqual(
                { returned, checks: report.checks, lines: output.lines() },
                row.expected
            )
        })
    }
})

test("runCheck_check_recordsProblemsAndErrors", async (t) => {
    const name = "flag-on:page-equals-response"
    const failure = new Error("Node is detached from document")
    const mismatch = '#insights-total-value shows "$1.00", expected "$2.00"'
    const screenshot = "screenshot insights-page.png failed: disk full"
    const entry = (status, reason, details) => ({
        name,
        status,
        reason,
        details,
        at: EPOCH_ISO,
    })
    const rows = [
        {
            name: "noProblem_pass",
            check: (problems, details) => {
                details.compared = 9
            },
            expected: {
                returned: true,
                checks: [entry("PASS", null, { compared: 9 })],
                lines: [`PASS ${name}`],
                errors: [],
            },
        },
        {
            name: "problemsAfterAwait_failJoined",
            check: async (problems) => {
                await Promise.resolve()
                problems.push(mismatch, screenshot)
            },
            expected: {
                returned: false,
                checks: [entry("FAIL", `${mismatch}; ${screenshot}`, {})],
                lines: [`FAIL ${name}: ${mismatch}; ${screenshot}`],
                errors: [],
            },
        },
        {
            name: "thrownError_problemDetailsKept",
            check: async (problems, details) => {
                details.unstableReads = 1
                problems.push(mismatch)
                throw failure
            },
            expected: {
                returned: false,
                checks: [
                    entry("FAIL", `${mismatch}; ${failure.message}`, {
                        unstableReads: 1,
                    }),
                ],
                lines: [`FAIL ${name}: ${mismatch}; ${failure.message}`],
                errors: [`Error: ${failure.message}`],
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["Date"], now: 0 })
            const output = captureConsole(st)
            const report = { checks: [] }

            const returned = await runCheck(report, name, row.check)

            assert.deepEqual(
                {
                    returned,
                    checks: report.checks,
                    lines: output.lines(),
                    errors: output.errors(),
                },
                row.expected
            )
        })
    }
})

test("expectEqual_actualAndExpected_addsProblemOnlyWhenDifferent", async (t) => {
    const rows = [
        {
            name: "equalNumbers_noProblem",
            actual: 0,
            expected: 0,
            problems: [],
        },
        {
            name: "equalBooleans_noProblem",
            actual: false,
            expected: false,
            problems: [],
        },
        {
            name: "equalLists_noProblem",
            actual: [],
            expected: [],
            problems: [],
        },
        {
            name: "equalObjects_noProblem",
            actual: { id: TP_ABOVE_ID, armingRevision: 2 },
            expected: { id: TP_ABOVE_ID, armingRevision: 2 },
            problems: [],
        },
        {
            name: "differentNumbers_problem",
            actual: 1,
            expected: 0,
            problems: ["value is 1, expected 0"],
        },
        {
            name: "stringForNumber_problemDescribesString",
            actual: "0",
            expected: 0,
            problems: ["value is a string of 1 character, expected 0"],
        },
        {
            name: "knownStrings_problemQuotesThem",
            actual: "LOW",
            expected: "HIGH",
            known: ["LOW", "HIGH"],
            problems: ['value is "LOW", expected "HIGH"'],
        },
        {
            name: "nullForList_problem",
            actual: null,
            expected: [],
            problems: ["value is null, expected an empty array"],
        },
        {
            name: "missingForNull_problem",
            actual: undefined,
            expected: null,
            problems: ["value is undefined, expected null"],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const problems = []

            expectEqual(problems, "value", row.actual, row.expected, row.known)

            assert.deepEqual(problems, row.problems)
        })
    }
})

/**
 * Runs node with `args` from src/loadgen, writing `input`, when given, to its
 * stdin; its exit status and output lines.
 */
function runNode(args, input) {
    const result = spawnSync(process.execPath, args, {
        cwd: LOADGEN_DIR,
        encoding: "utf8",
        input,
    })
    const lines = (text) =>
        (text ?? "").split(/\r?\n/).filter((line) => line !== "")
    return {
        status: result.status,
        stdout: lines(result.stdout),
        stderr: lines(result.stderr),
    }
}

/** What the check prints and exits with when started without options. */
const USAGE_RUN = {
    status: 2,
    stdout: [],
    stderr: [USAGE, "--base-url is required"],
}

test("entryGuard_fileStartedByNode_runsTheCheck", async (t) => {
    const rows = [
        {
            name: "modulePath_usageAndExit2",
            scriptPath: async () => MODULE_PATH,
        },
        {
            name: "pathThroughLinkedDirectory_usageAndExit2",
            scriptPath: async (st) => {
                const linked = path.join(await tempDir(st), "verification")
                // A junction on Windows, a directory symlink elsewhere.
                await symlink(path.dirname(MODULE_PATH), linked, "junction")
                return path.join(linked, path.basename(MODULE_PATH))
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            assert.deepEqual(runNode([await row.scriptPath(st)]), USAGE_RUN)
        })
    }
})

test("main_helpOption_printsHelpAndExits0", async (t) => {
    const helpRun = {
        status: 0,
        stdout: HELP.split("\n").filter((line) => line !== ""),
        stderr: [],
    }
    const rows = [
        { name: "longHelp", args: ["--help"] },
        { name: "shortHelp", args: ["-h"] },
        { name: "unknownMode", args: ["--mode", "bogus", "--help"] },
        {
            // A fixture that does not exist and an origin nothing serves:
            // the help reads neither.
            name: "missingFixtureUnservedOrigin",
            args: [
                "--base-url",
                "http://localhost:9",
                "--mode",
                "flag-on",
                "--fixture",
                "missing-fixture.json",
                "--evidence-dir",
                "missing-evidence",
                "-h",
            ],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(runNode([MODULE_PATH, ...row.args]), helpRun)
        })
    }
})

test("HELP_text_namesEveryOptionModeFieldAndExitCode", () => {
    const topics = [
        USAGE,
        "--base-url URL",
        "--mode MODE",
        "--fixture FILE",
        "--evidence-dir DIR",
        "-h, --help",
        "flag-off  The flag must be false.",
        "flag-on   The flag must be true.",
        "evaluationIntervalSeconds  Optional integer from 1 to 4294967",
        "holder, empty",
        "alerts ",
        "threshold ",
        "armingRevision             An integer from 1 to 2147483647.",
        "Exit codes:",
        "Example, from src/loadgen:",
    ]

    assert.deepEqual(
        topics.filter((topic) => !HELP.includes(topic)),
        []
    )
})

test("entryGuard_moduleImported_runsNothing", async (t) => {
    const href = JSON.stringify(pathToFileURL(MODULE_PATH).href)
    const rows = [
        {
            name: "evalImport_noOutput",
            args: ["--input-type=module", "--eval", `await import(${href})`],
            input: undefined,
            expected: { status: 0, stdout: [], stderr: [] },
        },
        {
            // node gets "-" as its start argument, which names no file.
            name: "stdinImport_onlyImporterOutput",
            args: ["--input-type=module", "-"],
            input: `import { parseOptions } from ${href}\nconsole.log(typeof parseOptions)\n`,
            expected: { status: 0, stdout: ["function"], stderr: [] },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.deepEqual(runNode(row.args, row.input), row.expected)
        })
    }
})
