// The page check's diagnostics and evidence never repeat a response body, a
// JSON parser message, an unknown response field, the text of any Toast or
// page text outside its defined form, and escape and bound every error
// message and every value they repeat.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites. The flag-service stub
// listens on a free 127.0.0.1 port the system picks, so the suite binds no
// fixed host port.
import assert from "node:assert/strict"
import { once } from "node:events"
import { createServer } from "node:http"
import { after, before, test } from "node:test"

import {
    compareInsights,
    describeError,
    describeTimestamp,
    describeValue,
    flagRequest,
    login,
    projectInsights,
    recordRequest,
    recordResponse,
    runCheck,
    summariseListedIds,
    summariseNotifications,
    summariseToasts,
    transportFailure,
    triggeredArmings,
} from "./portfolio-insights-page-check.mjs"

/** Assembled at run time, so no scanner takes it for a credential. */
const SECRET = ["pi", "redaction", "canary", "7f3a"].join("-")
const FLAG_ID = "portfolio-insights-enabled"
const FLAG_PATH = `/feature-flag-service/v1/flags/${FLAG_ID}`
const ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f"
const EMPTY_ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e70"
const ALERT_ID = "1b2c3d4e-0000-4000-8000-000000000001"
const OTHER_ALERT_ID = "1b2c3d4e-0000-4000-8000-000000000002"
const TRIGGERED_AT = "2026-11-25T22:27:06.011492Z"
const ALERT = {
    id: ALERT_ID,
    pair: "target_price",
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: "123.45",
    armingRevision: 1,
}
/** A triggered-alert Toast whose instrument part carries the canary. */
const ALERT_TOAST_TEXT = `Alert triggered: ${SECRET} Price above 123.45 (now 124)`

/** Listens on a free loopback port the system picks and resolves with it. */
async function listenOnFreePort(server) {
    server.listen(0, "127.0.0.1")
    await once(server, "listening")
    return server.address().port
}

function closeServer(server) {
    return new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()))
        server.closeAllConnections()
    })
}

/** How the flag-service stub answers the current test. */
let answer = { status: 200, body: "" }
const flagService = createServer((request, response) => {
    request.resume()
    response.writeHead(answer.status, { "Content-Type": "application/json" })
    response.end(answer.body)
})
let baseUrl

before(async () => {
    baseUrl = `http://127.0.0.1:${await listenOnFreePort(flagService)}`
})

after(() => closeServer(flagService))

const FLAG_FAILURES = [
    {
        scenario: "serverErrorWithSecretBody",
        status: 500,
        body: JSON.stringify({ error: SECRET }),
        reason: "answered HTTP 500",
    },
    {
        scenario: "okWithSecretTextBody",
        status: 200,
        body: `<html>${SECRET}</html>`,
        reason: "answered HTTP 200 with a body that is not JSON",
    },
    {
        scenario: "okWithJsonThatIsNoFlag",
        status: 200,
        body: JSON.stringify({ id: FLAG_ID, enabled: SECRET }),
        reason: `answered HTTP 200 without "${FLAG_ID}" and a boolean "enabled"`,
    },
]

for (const { scenario, status, body, reason } of FLAG_FAILURES) {
    test(`flagRequest_${scenario}_throwsFixedReasonWithoutBody`, async () => {
        answer = { status, body }
        await assert.rejects(flagRequest(baseUrl, {}), (error) => {
            assert.deepEqual(
                {
                    message: error.message,
                    described: describeError(error).includes(SECRET),
                },
                {
                    message: `GET ${baseUrl}${FLAG_PATH} ${reason}`,
                    described: false,
                }
            )
            return true
        })
    })
}

test("flagRequest_flagWithUnknownSecretField_returnsIdAndEnabledOnly", async () => {
    answer = {
        status: 200,
        body: JSON.stringify({
            id: FLAG_ID,
            enabled: true,
            name: "Portfolio insights",
            token: SECRET,
        }),
    }
    assert.deepEqual(await flagRequest(baseUrl, { method: "PUT" }), {
        id: FLAG_ID,
        enabled: true,
    })
})

test("flagRequest_nothingListening_throwsSystemErrorCodeOnly", async () => {
    const closed = createServer()
    const port = await listenOnFreePort(closed)
    await closeServer(closed)
    const url = `http://127.0.0.1:${port}`
    await assert.rejects(flagRequest(url, {}), {
        message: `GET ${url}${FLAG_PATH} failed: ECONNREFUSED`,
    })
})

const TRANSPORT_FAILURES = [
    {
        scenario: "deadlinePassed",
        error: new DOMException(SECRET, "TimeoutError"),
        expected: "timed out after 10000 ms",
    },
    {
        scenario: "callerDeadlinePassed",
        error: new DOMException(SECRET, "TimeoutError"),
        timeoutMs: 200,
        expected: "timed out after 200 ms",
    },
    {
        scenario: "aborted",
        error: new TypeError("fetch failed", {
            cause: new DOMException(SECRET, "AbortError"),
        }),
        expected: "timed out after 10000 ms",
    },
    {
        scenario: "refusedCause",
        error: new TypeError("fetch failed", {
            cause: Object.assign(new Error(`connect ${SECRET}`), {
                code: "ECONNREFUSED",
            }),
        }),
        expected: "ECONNREFUSED",
    },
    {
        scenario: "aggregateCause",
        error: new TypeError("fetch failed", {
            cause: new AggregateError(
                [Object.assign(new Error(SECRET), { code: "ECONNRESET" })],
                SECRET
            ),
        }),
        expected: "ECONNRESET",
    },
    {
        scenario: "codeOutsideItsForm",
        error: new TypeError("fetch failed", {
            cause: Object.assign(new Error(SECRET), { code: SECRET }),
        }),
        expected: "transport error",
    },
    { scenario: "nonError", error: SECRET, expected: "transport error" },
]

for (const { scenario, error, timeoutMs, expected } of TRANSPORT_FAILURES) {
    test(`transportFailure_${scenario}_returnsFixedPhrase`, () => {
        // Without `timeoutMs`, the flag requests' deadline applies.
        assert.equal(transportFailure(error, timeoutMs), expected)
    })
}

/** A Puppeteer response stand-in whose body `json()` resolves or rejects. */
function fakeResponse(json) {
    const url = `http://127.0.0.1/broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}`
    return {
        url: () => url,
        request: () => ({ method: () => "GET" }),
        status: () => 200,
        json,
    }
}

class ProtocolError extends Error {
    constructor(message) {
        super(message)
        this.name = "ProtocolError"
    }
}

const BODY_FAILURES = [
    {
        scenario: "parserQuotesBody",
        json: async () => JSON.parse(`{"token": ${SECRET}`),
        expected: "the body is not valid JSON",
    },
    {
        scenario: "namedReadFailure",
        json: async () => {
            throw new ProtocolError(`Could not load body: ${SECRET}`)
        },
        expected: "the body could not be read (ProtocolError)",
    },
    {
        scenario: "plainReadFailure",
        json: async () => {
            throw new Error(SECRET)
        },
        expected: "the body could not be read",
    },
    {
        scenario: "nonErrorRejection",
        json: () => Promise.reject(SECRET),
        expected: "the body could not be read",
    },
]

for (const { scenario, json, expected } of BODY_FAILURES) {
    test(`recordResponse_${scenario}_keepsFixedBodyError`, async () => {
        const session = { responses: [], pendingBodies: new Set() }
        recordResponse(session, fakeResponse(json))
        await Promise.all([...session.pendingBodies])
        const [entry] = session.responses
        assert.deepEqual(
            { parsed: entry.parsed, bodyError: entry.bodyError },
            { parsed: false, bodyError: expected }
        )
    })
}

const DESCRIBED_VALUES = [
    { scenario: "null", value: null, expected: "null" },
    { scenario: "boolean", value: true, expected: "true" },
    { scenario: "finiteNumber", value: -12.5, expected: "-12.5" },
    { scenario: "nonFiniteNumber", value: Number.NaN, expected: "NaN" },
    {
        scenario: "secretString",
        value: SECRET,
        expected: `a string of ${SECRET.length} characters`,
    },
    {
        scenario: "oneCharacter",
        value: "x",
        expected: "a string of 1 character",
    },
    {
        scenario: "knownString",
        value: "HIGH",
        known: ["LOW", "HIGH"],
        expected: '"HIGH"',
    },
    { scenario: "emptyArray", value: [], expected: "an empty array" },
    {
        scenario: "array",
        value: [SECRET, SECRET],
        expected: "an array of 2 items",
    },
    { scenario: "object", value: { token: SECRET }, expected: "an object" },
    { scenario: "missing", value: undefined, expected: "undefined" },
]

for (const { scenario, value, known, expected } of DESCRIBED_VALUES) {
    test(`describeValue_${scenario}_describesWithoutContent`, () => {
        assert.equal(describeValue(value, known), expected)
    })
}

const DESCRIBED_TIMESTAMPS = [
    { scenario: "utc", value: TRIGGERED_AT, expected: `"${TRIGGERED_AT}"` },
    {
        scenario: "offset",
        value: "2026-11-25T22:27:06+01:00",
        expected: '"2026-11-25T22:27:06+01:00"',
    },
    { scenario: "null", value: null, expected: "null" },
    {
        scenario: "notATimestamp",
        value: SECRET,
        expected: `a string of ${SECRET.length} characters`,
    },
]

for (const { scenario, value, expected } of DESCRIBED_TIMESTAMPS) {
    test(`describeTimestamp_${scenario}_printsOnlyTimestamps`, () => {
        assert.equal(describeTimestamp(value), expected)
    })
}

const DESCRIBED_ERRORS = [
    {
        scenario: "controlCharacters",
        error: new Error("line\nFAIL forged\r\u2028\u0085\u001b[31m"),
        expected:
            "Error: line\\u000aFAIL forged\\u000d\\u2028\\u0085\\u001b[31m",
    },
    {
        scenario: "longMessage",
        error: new Error("a".repeat(600)),
        expected: `Error: ${"a".repeat(499)}…`,
    },
    {
        scenario: "causeChain",
        error: new Error("GET x failed: ECONNREFUSED", {
            cause: new TypeError(`fetch failed ${SECRET}`, {
                cause: Object.assign(new Error(SECRET), {
                    code: "ECONNREFUSED",
                }),
            }),
        }),
        expected:
            "Error: GET x failed: ECONNREFUSED; caused by TypeError; caused by Error [ECONNREFUSED]",
    },
    {
        scenario: "nonErrorCause",
        error: new Error("read failed", { cause: SECRET }),
        expected: "Error: read failed; caused by a non-Error string",
    },
    {
        scenario: "nameOutsideItsForm",
        error: Object.assign(new Error("read failed"), {
            name: `Bad name ${SECRET}`,
        }),
        expected: "Error: read failed",
    },
    {
        scenario: "nonErrorThrown",
        error: SECRET,
        expected: `a non-Error value was thrown: a string of ${SECRET.length} characters`,
    },
]

for (const { scenario, error, expected } of DESCRIBED_ERRORS) {
    test(`describeError_${scenario}_printsOneSafeLine`, () => {
        assert.equal(describeError(error), expected)
    })
}

const CHECK_OUTCOMES = [
    {
        scenario: "checkThrows",
        check: () => {
            throw new Error("broken\nPASS forged", { cause: new Error(SECRET) })
        },
        stdout: ["FAIL flag-on:forged: broken\\u000aPASS forged"],
        stderr: ["Error: broken\\u000aPASS forged; caused by Error"],
        reason: "broken\\u000aPASS forged",
    },
    {
        scenario: "problemWithControlCharacters",
        check: (problems) => {
            problems.push("value\r\nPASS forged")
        },
        stdout: ["FAIL flag-on:forged: value\\u000d\\u000aPASS forged"],
        stderr: [],
        reason: "value\\u000d\\u000aPASS forged",
    },
]

for (const { scenario, check, stdout, stderr, reason } of CHECK_OUTCOMES) {
    test(`runCheck_${scenario}_printsEscapedFailLine`, async (t) => {
        const log = t.mock.method(console, "log", () => {})
        const errorLog = t.mock.method(console, "error", () => {})
        const report = { checks: [] }
        await runCheck(report, "flag-on:forged", check)
        const printed = (mocked) =>
            mocked.mock.calls.map((call) => call.arguments.join(" "))
        assert.deepEqual(
            {
                stdout: printed(log),
                stderr: printed(errorLog),
                reason: report.checks[0].reason,
            },
            { stdout, stderr, reason }
        )
    })
}

/** A Toast as `openSession` records it. */
function recordedToast(account, seq, text, className) {
    return {
        account,
        text,
        className,
        url: "/insights",
        at: new Date(Date.UTC(2026, 10, 25, 22, 0, seq)).toISOString(),
        seq,
        alertId: null,
        armingRevision: null,
        key: null,
    }
}

/** A read notification response of `ACCOUNT_ID` listing `results`. */
function notificationEntry(seq, results) {
    return {
        kind: "notifications",
        parsed: true,
        accountId: ACCOUNT_ID,
        seq,
        at: 0,
        status: 200,
        body: { results },
    }
}

/**
 * The holder's and the empty account's sessions: one notification response
 * listing `ALERT` under `armingRevision`, the holder's `alertToast` among
 * Toasts that name no fixture alert, and the empty account's login error.
 */
function toastSessions(armingRevision, alertToast) {
    const holder = {
        label: "holder",
        account: { accountId: ACCOUNT_ID },
        responses: [
            notificationEntry(1, [
                {
                    id: ALERT_ID,
                    armingRevision,
                    triggeredAt: TRIGGERED_AT,
                    token: SECRET,
                },
            ]),
        ],
        toasts: [
            recordedToast(
                "holder",
                4,
                `Saved ${SECRET}`,
                "toast toast-success"
            ),
            alertToast,
            recordedToast(
                "holder",
                5,
                SECRET,
                `toast toast-${SECRET.replaceAll("-", "_")}`
            ),
        ],
    }
    const empty = {
        label: "empty",
        account: { accountId: EMPTY_ACCOUNT_ID },
        responses: [],
        toasts: [
            recordedToast(
                "empty",
                3,
                `Invalid login ${SECRET}`,
                "toast toast-error"
            ),
        ],
    }
    return [holder, empty]
}

/** The Toasts of `toastSessions` that name no fixture alert, by variant. */
const OTHER_TOASTS = { "toast-success": 1, unknown: 1, "toast-error": 1 }

/** The Toast log entry of `ALERT`'s arming 1, as `summariseToasts` keeps it. */
const LOGGED_TOAST = {
    account: "holder",
    alertId: ALERT_ID,
    armingRevision: 1,
    key: `${ALERT_ID}:1`,
    at: "2026-11-25T22:00:02.000Z",
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: "123.45",
    now: "124",
    url: "/insights",
}

const SUMMARISED_TOASTS = [
    {
        scenario: "keyedToastNamingSecretInstrument",
        armingRevision: 1,
        alertToast: recordedToast(
            "holder",
            2,
            ALERT_TOAST_TEXT,
            "toast toast-info"
        ),
        expected: {
            toasts: [LOGGED_TOAST],
            unexplainedAlertToasts: [],
            otherToasts: OTHER_TOASTS,
        },
    },
    {
        scenario: "keyedToastWithMalformedNowAndPath",
        armingRevision: 1,
        alertToast: {
            ...recordedToast(
                "holder",
                2,
                `Alert triggered: ${SECRET} Price above 123.45 (now ${SECRET})`,
                "toast toast-info"
            ),
            url: `/insights/${SECRET}.html`,
        },
        expected: {
            toasts: [{ ...LOGGED_TOAST, now: null, url: null }],
            unexplainedAlertToasts: [],
            otherToasts: OTHER_TOASTS,
        },
    },
    {
        scenario: "fixtureToastNoArmingExplains",
        armingRevision: SECRET,
        alertToast: recordedToast(
            "holder",
            2,
            ALERT_TOAST_TEXT,
            "toast toast-info"
        ),
        expected: {
            toasts: [],
            unexplainedAlertToasts: [
                {
                    account: "holder",
                    alertId: ALERT_ID,
                    type: "TARGET_PRICE",
                    direction: "ABOVE",
                    at: "2026-11-25T22:00:02.000Z",
                },
            ],
            otherToasts: OTHER_TOASTS,
        },
    },
]

for (const {
    scenario,
    armingRevision,
    alertToast,
    expected,
} of SUMMARISED_TOASTS) {
    test(`summariseToasts_${scenario}_keepsValidatedFieldsOnly`, () => {
        const summary = summariseToasts(
            toastSessions(armingRevision, alertToast),
            [ALERT]
        )
        assert.deepEqual(
            { summary, leaks: JSON.stringify(summary).includes(SECRET) },
            { summary: expected, leaks: false }
        )
    })
}

// Each threshold reads as 123.45 to `Number` once its commas are dropped,
// but none is in the form `formatAlertNumber` writes.
for (const threshold of [
    "1,23.45",
    "12,3.45",
    "0123.45",
    "+123.45",
    "123.45e0",
    "123.450000001",
]) {
    test(`summariseToasts_malformedThreshold_namesNoFixtureAlert (${threshold})`, () => {
        const alertToast = recordedToast(
            "holder",
            2,
            `Alert triggered: ${SECRET} Price above ${threshold} (now 124)`,
            "toast toast-info"
        )
        const summary = summariseToasts(toastSessions(1, alertToast), [ALERT])
        assert.deepEqual(summary, {
            toasts: [],
            unexplainedAlertToasts: [],
            otherToasts: { ...OTHER_TOASTS, "toast-info": 1 },
        })
    })
}

test("summariseNotifications_secretFields_keepsDefinedFormsOnly", () => {
    const session = {
        label: "holder",
        responses: [
            notificationEntry(1, [
                {
                    id: ALERT_ID.toUpperCase(),
                    armingRevision: 2,
                    triggeredAt: TRIGGERED_AT,
                    triggerValue: 124.5,
                    acknowledged: false,
                    token: SECRET,
                },
                {
                    id: SECRET,
                    armingRevision: SECRET,
                    triggeredAt: SECRET,
                    triggerValue: SECRET,
                    acknowledged: SECRET,
                },
                SECRET,
            ]),
            {
                kind: "notifications",
                parsed: false,
                at: 0,
                status: 200,
                bodyError: "the body is not valid JSON",
            },
            { kind: "insights", parsed: true, at: 0, status: 200, body: {} },
        ],
    }
    assert.deepEqual(summariseNotifications([session]), [
        {
            account: "holder",
            at: "1970-01-01T00:00:00.000Z",
            status: 200,
            results: [
                {
                    id: ALERT_ID,
                    armingRevision: 2,
                    triggeredAt: TRIGGERED_AT,
                    triggerValue: 124.5,
                    acknowledged: false,
                },
                {
                    id: null,
                    armingRevision: null,
                    triggeredAt: `not a timestamp: a string of ${SECRET.length} characters`,
                    triggerValue: null,
                    acknowledged: null,
                },
                null,
            ],
            bodyError: null,
        },
        {
            account: "holder",
            at: "1970-01-01T00:00:00.000Z",
            status: 200,
            results: null,
            bodyError: "the body is not valid JSON",
        },
    ])
})

const ALLOCATION = {
    instrumentId: OTHER_ALERT_ID,
    name: "EasyTravel",
    quantity: 3,
    value: 300,
    percent: 100,
}

/** An insights response of an account holding `ALLOCATION` only. */
const INSIGHTS = {
    totalValue: 300,
    totalInvested: 250,
    unrealizedPnl: 50,
    unrealizedPnlPercent: 20,
    allocations: [ALLOCATION],
    largestPosition: ALLOCATION,
    riskLevel: "HIGH",
}

/** An instrument name with a control character, far past the bound. */
const LONG_NAME = `Easy\u0007Travel${"y".repeat(300)}`
/** `LONG_NAME` escaped and cut to 160 characters, as the check repeats it. */
const BOUNDED_NAME = `${`Easy\\u0007Travel${"y".repeat(300)}`.slice(0, 159)}…`

const INSIGHTS_BODIES = [
    {
        scenario: "longNameWithControlCharacter",
        body: {
            ...INSIGHTS,
            allocations: [{ ...ALLOCATION, name: LONG_NAME }],
            largestPosition: { ...ALLOCATION, name: LONG_NAME },
        },
        expected: {
            ...INSIGHTS,
            allocations: [{ ...ALLOCATION, name: BOUNDED_NAME }],
            largestPosition: { ...ALLOCATION, name: BOUNDED_NAME },
        },
    },
    {
        scenario: "validWithUnknownFields",
        body: {
            totalValue: 300,
            totalInvested: 250,
            unrealizedPnl: 50,
            unrealizedPnlPercent: 20,
            allocations: [{ ...ALLOCATION, token: SECRET }],
            largestPosition: { ...ALLOCATION, token: SECRET },
            riskLevel: "HIGH",
            token: SECRET,
        },
        expected: {
            totalValue: 300,
            totalInvested: 250,
            unrealizedPnl: 50,
            unrealizedPnlPercent: 20,
            allocations: [ALLOCATION],
            largestPosition: ALLOCATION,
            riskLevel: "HIGH",
        },
    },
    {
        scenario: "secretValues",
        body: {
            totalValue: SECRET,
            totalInvested: null,
            unrealizedPnl: [SECRET],
            allocations: [SECRET, { instrumentId: SECRET, quantity: SECRET }],
            largestPosition: SECRET,
            riskLevel: SECRET,
        },
        expected: {
            totalValue: null,
            totalInvested: null,
            unrealizedPnl: null,
            unrealizedPnlPercent: null,
            allocations: [
                null,
                {
                    instrumentId: null,
                    name: null,
                    quantity: null,
                    value: null,
                    percent: null,
                },
            ],
            largestPosition: null,
            riskLevel: null,
        },
    },
    { scenario: "notAnObject", body: SECRET, expected: null },
]

for (const { scenario, body, expected } of INSIGHTS_BODIES) {
    test(`projectInsights_${scenario}_keepsShownFieldsOnly`, () => {
        assert.deepEqual(projectInsights(body), expected)
    })
}

/** What the page shows for `INSIGHTS`, as `readInsightsDom` reads it. */
const INSIGHTS_DOM = {
    totalValue: "$300.00",
    totalInvested: "$250.00",
    unrealizedPnl: "$50.00",
    unrealizedPnlPercent: "+20.00%",
    largestPosition: "EasyTravel (+100.00%)",
    riskBadge: "High",
    emptyState: false,
    rows: [["EasyTravel", "3", "$300.00", "+100.00%"]],
}

/** An insights response of an account without holdings, and its page. */
const EMPTY_INSIGHTS = {
    totalValue: 0,
    totalInvested: 0,
    unrealizedPnl: 0,
    unrealizedPnlPercent: 0,
    allocations: [],
    largestPosition: null,
    riskLevel: null,
}
const EMPTY_INSIGHTS_DOM = {
    totalValue: "$0",
    totalInvested: "$0",
    unrealizedPnl: "$0",
    unrealizedPnlPercent: "0.00%",
    largestPosition: "\u2014",
    riskBadge: null,
    emptyState: true,
    rows: null,
}

/** A page whose `evaluate` runs the page function, `formatInPage`, in Node. */
const FORMATTING_PAGE = { evaluate: async (fn, arg) => fn(arg) }

/** The pair of every compared element whose page value equals `value`. */
function matchingPairs(values) {
    return values.map(([element, value]) => ({
        element,
        dom: value,
        expected: value,
        ok: true,
    }))
}

const MATCHING_PAGES = [
    {
        scenario: "holder",
        dom: INSIGHTS_DOM,
        body: INSIGHTS,
        pairs: matchingPairs([
            ["#insights-total-value", "$300.00"],
            ["#insights-total-invested", "$250.00"],
            ["#insights-unrealized-pnl", "$50.00"],
            ["#insights-unrealized-pnl-percent", "+20.00%"],
            ["#insights-largest-position", "EasyTravel (+100.00%)"],
            ["#insights-risk-badge", "High"],
            ["#insights-empty-state shown", false],
            ["#insights-allocations row count", 1],
            ["#insights-allocations row 1 instrument", "EasyTravel"],
            ["#insights-allocations row 1 quantity", "3"],
            ["#insights-allocations row 1 value", "$300.00"],
            ["#insights-allocations row 1 allocation", "+100.00%"],
        ]),
    },
    {
        scenario: "emptyAccount",
        dom: EMPTY_INSIGHTS_DOM,
        body: EMPTY_INSIGHTS,
        pairs: matchingPairs([
            ["#insights-total-value", "$0"],
            ["#insights-total-invested", "$0"],
            ["#insights-unrealized-pnl", "$0"],
            ["#insights-unrealized-pnl-percent", "0.00%"],
            ["#insights-largest-position", "\u2014"],
            ["#insights-risk-badge", null],
            ["#insights-empty-state shown", true],
            ["#insights-allocations", null],
        ]),
    },
]

for (const { scenario, dom, body, pairs } of MATCHING_PAGES) {
    test(`compareInsights_pageMatchesResponse_keepsValuesVerbatim (${scenario})`, async () => {
        const result = await compareInsights(FORMATTING_PAGE, dom, body)
        assert.deepEqual(
            { problems: result.problems, pairs: result.pairs },
            { problems: [], pairs }
        )
    })
}

/** `INSIGHTS_DOM` with its first allocation row's `column` showing `text`. */
function domWithCell(column, text) {
    const row = [...INSIGHTS_DOM.rows[0]]
    row[column] = text
    return { ...INSIGHTS_DOM, rows: [row] }
}

/** The pair of `element` among the pairs of `result`. */
function pairOf(result, element) {
    return result.pairs.find((pair) => pair.element === element)
}

// Page text outside its element's defined form: a problem and the pair
// describe it by kind and size, and never repeat any of it.
const FREE_TEXT_MISMATCHES = [
    {
        scenario: "secretAfterTotalValue",
        element: "#insights-total-value",
        text: `$300.00 ${SECRET}`,
        show: (text) => ({ ...INSIGHTS_DOM, totalValue: text }),
        expected: "$300.00",
        hidden: SECRET,
    },
    {
        scenario: "secretLargestPosition",
        element: "#insights-largest-position",
        text: `${SECRET} (+100.00%)`,
        show: (text) => ({ ...INSIGHTS_DOM, largestPosition: text }),
        expected: "EasyTravel (+100.00%)",
        hidden: SECRET,
    },
    {
        scenario: "forgedLineInRiskBadge",
        element: "#insights-risk-badge",
        text: "High\nPASS forged",
        show: (text) => ({ ...INSIGHTS_DOM, riskBadge: text }),
        expected: "High",
        hidden: "PASS forged",
    },
    {
        scenario: "tenThousandCharacterInstrument",
        element: "#insights-allocations row 1 instrument",
        text: "x".repeat(10_000),
        show: (text) => domWithCell(0, text),
        expected: "EasyTravel",
        hidden: "xxxxxxxx",
    },
    {
        scenario: "secretQuantity",
        element: "#insights-allocations row 1 quantity",
        text: `3 ${SECRET}`,
        show: (text) => domWithCell(1, text),
        expected: "3",
        hidden: SECRET,
    },
    {
        scenario: "secretPercent",
        element: "#insights-allocations row 1 allocation",
        text: `+100.00% ${SECRET}`,
        show: (text) => domWithCell(3, text),
        expected: "+100.00%",
        hidden: SECRET,
    },
]

for (const {
    scenario,
    element,
    text,
    show,
    expected,
    hidden,
} of FREE_TEXT_MISMATCHES) {
    test(`compareInsights_${scenario}_describesPageTextWithoutRepeatingIt`, async () => {
        const result = await compareInsights(
            FORMATTING_PAGE,
            show(text),
            INSIGHTS
        )
        const described = `a string of ${text.length} characters`
        const serialized = JSON.stringify({
            problems: result.problems,
            pairs: result.pairs,
        })
        assert.deepEqual(
            {
                problems: result.problems,
                pair: pairOf(result, element),
                leaks: serialized.includes(hidden),
            },
            {
                problems: [
                    `${element} shows ${described}, expected "${expected}"`,
                ],
                pair: { element, dom: described, expected, ok: false },
                leaks: false,
            }
        )
    })
}

test("compareInsights_rowsWhereNoneExpected_describesRowsWithoutRepeatingThem", async () => {
    const dom = { ...EMPTY_INSIGHTS_DOM, rows: [[SECRET, "3"]] }
    const result = await compareInsights(FORMATTING_PAGE, dom, EMPTY_INSIGHTS)
    assert.deepEqual(
        {
            problems: result.problems,
            pair: pairOf(result, "#insights-allocations"),
            leaks: JSON.stringify(result.pairs).includes(SECRET),
        },
        {
            problems: [
                "#insights-allocations shows an array of 1 item, expected null",
            ],
            pair: {
                element: "#insights-allocations",
                dom: "an array of 1 item",
                expected: null,
                ok: false,
            },
            leaks: false,
        }
    )
})

// Page text in its element's defined form holds no free text, so a
// mismatch repeats it as it is.
const FORMED_MISMATCHES = [
    ["#insights-total-value", { totalValue: "$299.99" }, "$299.99", "$300.00"],
    ["#insights-unrealized-pnl", { unrealizedPnl: "-$50" }, "-$50", "$50.00"],
    [
        "#insights-unrealized-pnl-percent",
        { unrealizedPnlPercent: "-20.00%" },
        "-20.00%",
        "+20.00%",
    ],
    [
        "#insights-largest-position",
        { largestPosition: "\u2014" },
        "\u2014",
        "EasyTravel (+100.00%)",
    ],
    ["#insights-risk-badge", { riskBadge: "Low" }, "Low", "High"],
    ["#insights-risk-badge", { riskBadge: null }, null, "High"],
    ["#insights-empty-state shown", { emptyState: true }, true, false],
    ["#insights-allocations row 1 quantity", domWithCell(1, "4"), "4", "3"],
    [
        "#insights-allocations row 1 value",
        domWithCell(2, "$1,300.00"),
        "$1,300.00",
        "$300.00",
    ],
    [
        "#insights-allocations row 1 allocation",
        domWithCell(3, "0.00%"),
        "0.00%",
        "+100.00%",
    ],
]

for (const [element, shown, dom, expected] of FORMED_MISMATCHES) {
    test(`compareInsights_pageTextInDefinedForm_repeatsItVerbatim (${element} ${JSON.stringify(dom)})`, async () => {
        const result = await compareInsights(
            FORMATTING_PAGE,
            { ...INSIGHTS_DOM, ...shown },
            INSIGHTS
        )
        assert.deepEqual(
            { problems: result.problems, pair: pairOf(result, element) },
            {
                problems: [
                    `${element} shows ${JSON.stringify(dom)}, expected ${JSON.stringify(expected)}`,
                ],
                pair: { element, dom, expected, ok: false },
            }
        )
    })
}

test("compareInsights_expectedNameLongWithControlCharacter_repeatsItEscapedAndBounded", async () => {
    const allocation = { ...ALLOCATION, name: LONG_NAME }
    const body = {
        ...INSIGHTS,
        allocations: [allocation],
        largestPosition: allocation,
    }
    const result = await compareInsights(FORMATTING_PAGE, INSIGHTS_DOM, body)
    assert.deepEqual(
        {
            problems: result.problems,
            pairs: [
                pairOf(result, "#insights-largest-position"),
                pairOf(result, "#insights-allocations row 1 instrument"),
            ],
        },
        {
            problems: [
                `#insights-largest-position shows a string of 21 characters, expected ${JSON.stringify(BOUNDED_NAME)}`,
                `#insights-allocations row 1 instrument shows a string of 10 characters, expected ${JSON.stringify(BOUNDED_NAME)}`,
            ],
            pairs: [
                {
                    element: "#insights-largest-position",
                    dom: "a string of 21 characters",
                    expected: BOUNDED_NAME,
                    ok: false,
                },
                {
                    element: "#insights-allocations row 1 instrument",
                    dom: "a string of 10 characters",
                    expected: BOUNDED_NAME,
                    ok: false,
                },
            ],
        }
    )
})

test("triggeredArmings_invalidFields_skipsOrDescribesThem", () => {
    const session = {
        account: { accountId: ACCOUNT_ID },
        responses: [
            notificationEntry(1, [
                { id: ALERT_ID, armingRevision: 1, triggeredAt: TRIGGERED_AT },
                { id: ALERT_ID, armingRevision: SECRET, triggeredAt: SECRET },
                { id: OTHER_ALERT_ID, armingRevision: 3, triggeredAt: SECRET },
                { id: SECRET, armingRevision: 1, triggeredAt: TRIGGERED_AT },
            ]),
        ],
    }
    const alerts = [ALERT, { ...ALERT, id: OTHER_ALERT_ID }]
    assert.deepEqual(
        [...triggeredArmings(session, alerts).values()],
        [
            {
                key: `${ALERT_ID}:1`,
                id: ALERT_ID,
                armingRevision: 1,
                triggeredAt: TRIGGERED_AT,
                firstSeenAt: "1970-01-01T00:00:00.000Z",
            },
            {
                key: `${OTHER_ALERT_ID}:3`,
                id: OTHER_ALERT_ID,
                armingRevision: 3,
                triggeredAt: `not a timestamp: a string of ${SECRET.length} characters`,
                firstSeenAt: "1970-01-01T00:00:00.000Z",
            },
        ]
    )
})

test("recordRequest_traceHeaders_keepsEscapedBoundedTraceHeadersOnly", () => {
    const report = { traceHeaders: [] }
    const dynatrace = `FW4;1\n${"x".repeat(300)}`
    recordRequest({ label: "holder" }, report, {
        url: () =>
            `http://127.0.0.1/broker-service/v1/portfolio/insights/${ACCOUNT_ID}`,
        headers: () => ({
            traceparent:
                "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
            "x-dynatrace": dynatrace,
            cookie: SECRET,
        }),
    })
    const [{ account, path, headers }] = report.traceHeaders
    assert.deepEqual(
        { account, path, headers },
        {
            account: "holder",
            path: `/broker-service/v1/portfolio/insights/${ACCOUNT_ID}`,
            headers: {
                traceparent:
                    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "x-dynatrace": `${dynatrace.replace("\n", "\\u000a").slice(0, 255)}…`,
            },
        }
    )
})

test("login_errorToastsShown_countsThemWithoutText", async () => {
    const page = {
        goto: async () => {},
        type: async () => {},
        click: async () => {},
        waitForSelector: async (selector) => {
            if (selector === "#nav-home") {
                throw new Error("Waiting for selector `#nav-home` failed")
            }
        },
    }
    const session = {
        page,
        account: { username: "pi-e2e-1-holder", password: SECRET },
        toasts: [
            recordedToast(
                "holder",
                1,
                `Invalid ${SECRET}`,
                "toast toast-error"
            ),
            recordedToast("holder", 2, SECRET, "toast toast-error"),
            recordedToast("holder", 3, SECRET, "toast toast-success"),
        ],
    }
    await assert.rejects(login(session, "http://127.0.0.1"), {
        message:
            "login as pi-e2e-1-holder never reached #nav-home: Waiting for selector `#nav-home` failed; the page showed 2 error Toasts",
    })
})

const LISTED_IDS = [
    {
        scenario: "nothingListed",
        listed: [],
        expected: { ids: [], withoutUuid: 0, text: "" },
    },
    {
        scenario: "uuidAndOthers",
        listed: [ALERT_ID, SECRET, ""],
        expected: {
            ids: [ALERT_ID],
            withoutUuid: 2,
            text: `${ALERT_ID}, 2 items without a UUID id`,
        },
    },
    {
        scenario: "oneOther",
        listed: [SECRET],
        expected: { ids: [], withoutUuid: 1, text: "1 item without a UUID id" },
    },
]

for (const { scenario, listed, expected } of LISTED_IDS) {
    test(`summariseListedIds_${scenario}_repeatsOnlyUuids`, () => {
        assert.deepEqual(summariseListedIds(listed), expected)
    })
}
