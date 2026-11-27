// Unit tests of the page check's one-Toast-per-arming rule: the armings an
// authoritative notifications read expects, their reconciliation with the
// page's responses and Toasts, and the read itself against loopback stubs.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { randomUUID } from "node:crypto"
import { createServer } from "node:http"
import process from "node:process"
import { test } from "node:test"
import { parseArgs } from "node:util"

import {
    checkOneToastPerArming,
    expectedArmings,
    NotificationReadError,
    readNotifications,
    reconcileArmings,
    WaitTimeoutError,
} from "./portfolio-insights-page-check.mjs"

/**
 * `--live-base-url URL` adds the read of a running stack. It is given only
 * when this file runs directly, as
 * `node verification/portfolio-insights-page-check.toasts.test.mjs --live-base-url URL`,
 * so `node --test` stays independent of any stack.
 */
const { values: OPTIONS } = parseArgs({
    args: process.argv.slice(2),
    options: { "live-base-url": { type: "string" } },
    strict: true,
})
const LIVE_BASE_URL =
    OPTIONS["live-base-url"] === undefined
        ? null
        : new URL(OPTIONS["live-base-url"]).origin

const ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f"
const NOTIFICATIONS_TARGET = `/broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}`
/** Text a response may carry that no message may repeat. */
const SECRET = `secret-${randomUUID()}`

/** The four fixture alerts, as the page check parses them. */
const ALERTS = [
    {
        id: "a1000000-0000-4000-8000-000000000001",
        pair: "target_price",
        type: "TARGET_PRICE",
        direction: "ABOVE",
        threshold: "99.99999999",
        armingRevision: 1,
    },
    {
        id: "a1000000-0000-4000-8000-000000000002",
        pair: "target_price",
        type: "TARGET_PRICE",
        direction: "BELOW",
        threshold: "100.00000001",
        armingRevision: 1,
    },
    {
        id: "a1000000-0000-4000-8000-000000000003",
        pair: "profit_loss",
        type: "PROFIT_LOSS",
        direction: "ABOVE",
        threshold: "-0.00000001",
        armingRevision: 1,
    },
    {
        id: "a1000000-0000-4000-8000-000000000004",
        pair: "profit_loss",
        type: "PROFIT_LOSS",
        direction: "BELOW",
        threshold: "0.00000001",
        armingRevision: 1,
    },
]
const [TARGET_ABOVE, TARGET_BELOW, PNL_ABOVE, PNL_BELOW] = ALERTS

/** A notification of `alert`'s current arming, as the broker lists it. */
function notification(alert, overrides = {}) {
    return {
        id: alert.id,
        accountId: ACCOUNT_ID,
        instrumentId: "1b2c3d4e-0000-4000-8000-000000000001",
        type: alert.type,
        direction: alert.direction,
        threshold: Number(alert.threshold),
        enabled: true,
        armingRevision: alert.armingRevision,
        triggeredAt: "2026-11-25T22:00:00.000Z",
        triggerValue: 100,
        acknowledged: false,
        createdAt: "2026-11-25T21:58:00.000Z",
        ...overrides,
    }
}

/** The arming `expectedArmings` derives for `alert` at `armingRevision`. */
function arming(alert, armingRevision = alert.armingRevision) {
    return {
        key: `${alert.id}:${armingRevision}`,
        id: alert.id,
        armingRevision,
        pair: alert.pair,
        direction: alert.direction,
    }
}

/** The armings the page's responses showed triggered, keyed as it keys them. */
function observedOf(keys) {
    return new Map(keys.map((key) => [key, { key }]))
}

/** A server on a free loopback port, closed with its connections after `t`. */
async function startServer(t, handler) {
    const server = createServer(handler)
    await new Promise((resolve, reject) => {
        server.once("error", reject)
        server.listen(0, "127.0.0.1", resolve)
    })
    t.after(
        () =>
            new Promise((resolve) => {
                server.closeAllConnections()
                server.close(() => resolve())
            })
    )
    return `http://127.0.0.1:${server.address().port}`
}

/** A broker answering every request with `status` and `body`. */
function brokerAnswering(t, status, body) {
    return startServer(t, (_, response) => {
        response.writeHead(status, { "Content-Type": "application/json" })
        response.end(body)
    })
}

/** A notification response of the holder's page, as the page check records it. */
function pageResponse(seq, alerts) {
    return {
        kind: "notifications",
        accountId: ACCOUNT_ID,
        alertId: null,
        url: `http://localhost${NOTIFICATIONS_TARGET}&unacknowledged=true`,
        path: "/broker-service/v1/alerts/notifications",
        method: "GET",
        status: 200,
        accepted: true,
        rejection: null,
        at: Date.parse("2026-11-25T22:01:00.000Z"),
        seq,
        body: { results: alerts.map((alert) => notification(alert)) },
        parsed: true,
    }
}

/**
 * The Toast `AlertNotificationWatcher` shows for `alert`, as recorded. Its
 * instrument part is page text, which no problem or detail may repeat.
 */
function pageToast(seq, alert) {
    const type = alert.type === "TARGET_PRICE" ? "Price" : "P/L"
    return {
        account: "holder",
        text: `Alert triggered: ${SECRET} ${type} ${alert.direction.toLowerCase()} ${alert.threshold} (now 100)`,
        className: "toast toast-info",
        url: "/insights",
        at: "2026-11-25T22:01:00.000Z",
        seq,
        alertId: null,
        armingRevision: null,
        key: null,
    }
}

/**
 * The holder's page on /insights. It has received four notification
 * responses listing `before` triggered and the Toasts of `toasted`; its
 * reload brings two responses listing `after` and the Toasts of
 * `toastedAfter`. Sequence numbers place the first events before, and the
 * reload's events after, any the page check takes.
 */
function holderSession(
    baseUrl,
    { before, toasted, after = before, toastedAfter = [] }
) {
    const calls = []
    const session = {
        label: "holder",
        account: {
            username: "pi-e2e-holder",
            password: SECRET,
            accountId: ACCOUNT_ID,
        },
        toasts: toasted.map((alert, index) => pageToast(-50 + index, alert)),
        responses: [-100, -99, -98, -97].map((seq) =>
            pageResponse(seq, before)
        ),
        notificationRequests: [],
        pendingBodies: new Set(),
        calls,
    }
    session.page = {
        bringToFront: async () => calls.push("bringToFront"),
        url: () => `${baseUrl}/insights`,
        evaluate: async (_, selector) => selector === "#portfolio-insights",
        reload: async () => {
            calls.push("reload")
            session.responses.push(
                pageResponse(1_000_000, after),
                pageResponse(1_000_001, after)
            )
            session.toasts.push(
                ...toastedAfter.map((alert, index) =>
                    pageToast(1_000_002 + index, alert)
                )
            )
        },
        waitForSelector: async (selector) => calls.push(selector),
    }
    return session
}

/** Asserts that `promise` rejects with exactly `message` and `status`. */
async function assertReadError(promise, message, status) {
    const error = await promise.then(
        () => assert.fail("the read resolved"),
        (reason) => reason
    )
    assert.ok(error instanceof NotificationReadError)
    assert.equal(error.message, message)
    assert.equal(error.status, status)
    assert.ok(!error.message.includes(SECRET))
}

test("expectedArmings_onePerPairTriggered_expectsThoseArmings", () => {
    const results = [
        notification(PNL_BELOW, { id: PNL_BELOW.id.toUpperCase() }),
        notification(TARGET_ABOVE),
        // An alert the fixture does not own is not the page check's concern.
        notification(TARGET_BELOW, { id: randomUUID() }),
    ]

    const { expected, problems } = expectedArmings(results, ALERTS)

    assert.deepEqual(expected, [arming(PNL_BELOW), arming(TARGET_ABOVE)])
    assert.deepEqual(problems, [])
})

for (const [scenario, triggered, missingPair] of [
    ["targetPriceOnly", [TARGET_ABOVE, TARGET_BELOW], "profit_loss"],
    ["profitLossOnly", [PNL_ABOVE], "target_price"],
]) {
    test(`expectedArmings_onlyOnePairTriggered_reportsMissingPair (${scenario})`, () => {
        const { expected, problems } = expectedArmings(
            triggered.map((alert) => notification(alert)),
            ALERTS
        )

        assert.deepEqual(
            expected,
            triggered.map((alert) => arming(alert))
        )
        assert.deepEqual(problems, [
            `the notifications read shows no ${missingPair} fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger`,
        ])
    })
}

test("expectedArmings_noFixtureAlertTriggered_reportsBothPairs", () => {
    const { expected, problems } = expectedArmings([], ALERTS)

    assert.deepEqual(expected, [])
    assert.deepEqual(problems, [
        "the notifications read shows no target_price fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger",
        "the notifications read shows no profit_loss fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger",
    ])
})

test("expectedArmings_revisionDiffersFromFixture_reportsMismatchAndKeysReadRevision", () => {
    const { expected, problems } = expectedArmings(
        [
            notification(TARGET_BELOW, { armingRevision: 2 }),
            notification(PNL_ABOVE),
        ],
        ALERTS
    )

    assert.deepEqual(expected, [arming(TARGET_BELOW, 2), arming(PNL_ABOVE)])
    assert.deepEqual(problems, [
        `the notifications read gives alert ${TARGET_BELOW.id} armingRevision 2, but the fixture holds 1`,
    ])
})

for (const [scenario, armingRevision] of [
    ["string", SECRET],
    ["fraction", 1.5],
    ["null", null],
    ["absent", undefined],
]) {
    test(`expectedArmings_revisionNotInteger_reportsProblemWithoutValue (${scenario})`, () => {
        const { expected, problems } = expectedArmings(
            [
                notification(TARGET_ABOVE, { armingRevision }),
                notification(PNL_ABOVE),
            ],
            ALERTS
        )

        assert.deepEqual(expected, [arming(PNL_ABOVE)])
        assert.deepEqual(problems, [
            `the notifications read gives alert ${TARGET_ABOVE.id} no integer armingRevision`,
            "the notifications read shows no target_price fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger",
        ])
    })
}

for (const [scenario, item] of [
    ["null", null],
    ["text", SECRET],
    ["nonUuidId", { id: SECRET }],
    ["numericId", { id: 42 }],
]) {
    test(`expectedArmings_itemWithoutUuidId_reportsIndexOnly (${scenario})`, () => {
        const { expected, problems } = expectedArmings(
            [notification(TARGET_ABOVE), item, notification(PNL_ABOVE)],
            ALERTS
        )

        assert.deepEqual(expected, [arming(TARGET_ABOVE), arming(PNL_ABOVE)])
        assert.deepEqual(problems, [
            "the notifications read gives results[1] no UUID id",
        ])
    })
}

test("expectedArmings_fixtureAlertListedTwice_reportsRepeatOnce", () => {
    const { expected, problems } = expectedArmings(
        [
            notification(TARGET_ABOVE),
            notification(TARGET_ABOVE),
            notification(TARGET_ABOVE),
            notification(PNL_BELOW),
        ],
        ALERTS
    )

    assert.deepEqual(expected, [arming(TARGET_ABOVE), arming(PNL_BELOW)])
    assert.deepEqual(problems, [
        `the notifications read lists alert ${TARGET_ABOVE.id} more than once`,
    ])
})

for (const triggeredAt of [null, undefined]) {
    test(`expectedArmings_fixtureAlertWithoutTriggeredAt_reportsProblem (${triggeredAt})`, () => {
        const { expected, problems } = expectedArmings(
            [
                notification(TARGET_ABOVE, { triggeredAt }),
                notification(TARGET_BELOW),
                notification(PNL_ABOVE),
            ],
            ALERTS
        )

        assert.deepEqual(expected, [arming(TARGET_BELOW), arming(PNL_ABOVE)])
        assert.deepEqual(problems, [
            `the notifications read lists alert ${TARGET_ABOVE.id} without a triggeredAt`,
        ])
    })
}

test("reconcileArmings_expectedArmingsSeenAndToastedOnce_reportsNoProblem", () => {
    const expected = [arming(TARGET_ABOVE), arming(PNL_BELOW)]
    const keys = expected.map((item) => item.key)

    const problems = reconcileArmings(
        expected,
        observedOf(keys),
        new Map(keys.map((key) => [key, 1]))
    )

    assert.deepEqual(problems, [])
})

test("reconcileArmings_expectedArmingNotSeenByPage_reportsMissingArming", () => {
    const expected = [arming(TARGET_ABOVE), arming(PNL_BELOW)]
    const seen = arming(TARGET_ABOVE).key
    const missing = arming(PNL_BELOW).key

    const problems = reconcileArmings(
        expected,
        observedOf([seen]),
        new Map([[seen, 1]])
    )

    assert.deepEqual(problems, [
        `no notification response of the page shows arming ${missing} (profit_loss BELOW) triggered, though the notifications read does`,
        `arming ${missing} has 0 Toasts, expected 1`,
    ])
})

for (const count of [0, 2, 3]) {
    test(`reconcileArmings_expectedArmingToastCountNotOne_reportsCount (${count})`, () => {
        const expected = [arming(TARGET_BELOW), arming(PNL_ABOVE)]
        const keys = expected.map((item) => item.key)

        const problems = reconcileArmings(
            expected,
            observedOf(keys),
            new Map([
                [keys[0], count],
                [keys[1], 1],
            ])
        )

        assert.deepEqual(problems, [
            `arming ${keys[0]} has ${count} Toasts, expected 1`,
        ])
    })
}

for (const [count, problems] of [
    [1, []],
    [2, [`arming ${arming(TARGET_BELOW).key} has 2 Toasts, expected 1`]],
]) {
    test(`reconcileArmings_armingTriggeredDuringCheck_judgesItsToasts (${count})`, () => {
        const expected = [arming(TARGET_ABOVE), arming(PNL_ABOVE)]
        // TARGET_BELOW triggered after the read, so only the page saw it.
        const keys = [...expected, arming(TARGET_BELOW)].map((item) => item.key)

        const actual = reconcileArmings(
            expected,
            observedOf(keys),
            new Map([
                [keys[0], 1],
                [keys[1], 1],
                [keys[2], count],
            ])
        )

        assert.deepEqual(actual, problems)
    })
}

test("reconcileArmings_noExpectedArmings_judgesObservedArmingsOnly", () => {
    const once = arming(TARGET_ABOVE, 2).key
    const never = arming(PNL_BELOW, 2).key

    const problems = reconcileArmings(
        [],
        observedOf([once, never]),
        new Map([
            [once, 1],
            // A Toast of an arming no response showed triggered is not counted.
            [arming(TARGET_BELOW).key, 1],
        ])
    )

    assert.deepEqual(problems, [`arming ${never} has 0 Toasts, expected 1`])
})

test("readNotifications_resultsList_resolvesStatusAndResults", async (t) => {
    const results = [notification(TARGET_ABOVE)]
    const requests = []
    const baseUrl = await startServer(t, (request, response) => {
        requests.push({
            method: request.method,
            url: request.url,
            accept: request.headers.accept,
        })
        response.writeHead(200, { "Content-Type": "application/json" })
        response.end(JSON.stringify({ results }))
    })

    const read = await readNotifications(baseUrl, ACCOUNT_ID.toUpperCase())

    assert.deepEqual(read, { status: 200, results })
    assert.deepEqual(requests, [
        {
            method: "GET",
            url: NOTIFICATIONS_TARGET,
            accept: "application/json",
        },
    ])
})

for (const [scenario, status, body, reason] of [
    ["serverErrorWithText", 500, SECRET, "answered HTTP 500"],
    [
        "notFoundWithJson",
        404,
        JSON.stringify({ error: SECRET }),
        "answered HTTP 404",
    ],
    [
        "okNotJson",
        200,
        `<html>${SECRET}</html>`,
        "answered HTTP 200 with a body that is not JSON",
    ],
    [
        "okWithoutResults",
        200,
        JSON.stringify({ secret: SECRET }),
        "answered HTTP 200 without a results list",
    ],
    [
        "okResultsNotList",
        200,
        JSON.stringify({ results: SECRET }),
        "answered HTTP 200 without a results list",
    ],
    [
        "okTopLevelList",
        200,
        JSON.stringify([SECRET]),
        "answered HTTP 200 without a results list",
    ],
]) {
    test(`readNotifications_unusableAnswer_throwsClassWithoutBody (${scenario})`, async (t) => {
        const baseUrl = await startServer(t, (_, response) => {
            response.writeHead(status, { "Content-Type": "application/json" })
            response.end(body)
        })

        await assertReadError(
            readNotifications(baseUrl, ACCOUNT_ID),
            `GET ${NOTIFICATIONS_TARGET} ${reason}`,
            status
        )
    })
}

for (const [scenario, respond, status] of [
    // The response is prepared but never sent until the server closes.
    [
        "noResponse",
        (response) => response.setHeader("Content-Type", "application/json"),
        null,
    ],
    [
        "stalledBody",
        (response) => {
            response.writeHead(200, { "Content-Type": "application/json" })
            response.write(`{"results": [{"id": "${SECRET}"`)
        },
        200,
    ],
]) {
    test(`readNotifications_noCompleteAnswerBeforeDeadline_throwsTimeout (${scenario})`, async (t) => {
        const baseUrl = await startServer(t, (_, response) => respond(response))

        await assertReadError(
            readNotifications(baseUrl, ACCOUNT_ID, { timeoutMs: 200 }),
            `GET ${NOTIFICATIONS_TARGET} failed: timed out after 200 ms`,
            status
        )
    })
}

test("readNotifications_nothingListening_throwsSystemErrorCode", async () => {
    const server = createServer()
    await new Promise((resolve, reject) => {
        server.once("error", reject)
        server.listen(0, "127.0.0.1", resolve)
    })
    const { port } = server.address()
    await new Promise((resolve) => server.close(() => resolve()))

    await assertReadError(
        readNotifications(`http://127.0.0.1:${port}`, ACCOUNT_ID),
        `GET ${NOTIFICATIONS_TARGET} failed: ECONNREFUSED`,
        null
    )
})

test("readNotifications_fetchFailsWithoutSystemCode_throwsTransportError", async (t) => {
    const requests = []
    const baseUrl = await startServer(t, (request, response) => {
        requests.push(request.url)
        response.end()
    })

    // fetch refuses a URL with credentials before any request, with a
    // TypeError that carries no code and quotes the URL.
    const withCredentials = baseUrl.replace("//", `//pi:${SECRET}@`)
    await assertReadError(
        readNotifications(withCredentials, ACCOUNT_ID),
        `GET ${NOTIFICATIONS_TARGET} failed: transport error`,
        null
    )
    assert.deepEqual(requests, [])
})

for (const timeoutMs of [-1, 1.5, Number.NaN]) {
    test(`readNotifications_invalidDeadline_throwsRangeErrorBeforeRequest (${timeoutMs})`, async (t) => {
        const requests = []
        const baseUrl = await startServer(t, (request, response) => {
            requests.push(request.url)
            response.end()
        })

        await assert.rejects(
            readNotifications(baseUrl, ACCOUNT_ID, { timeoutMs }),
            { name: "RangeError" }
        )
        assert.deepEqual(requests, [])
    })
}

for (const [scenario, accountId] of [
    ["text", SECRET],
    ["number", 42],
    ["absent", undefined],
]) {
    test(`readNotifications_accountIdNotUuid_throwsWithoutValue (${scenario})`, async (t) => {
        const requests = []
        const baseUrl = await startServer(t, (request, response) => {
            requests.push(request.url)
            response.end()
        })

        await assertReadError(
            readNotifications(baseUrl, accountId),
            "GET /broker-service/v1/alerts/notifications needs a UUID accountId",
            null
        )
        assert.deepEqual(requests, [])
    })
}

for (const [scenario, read, page, problems] of [
    [
        "pageMatchesRead",
        [TARGET_ABOVE, PNL_BELOW],
        {
            before: [TARGET_ABOVE, PNL_BELOW],
            toasted: [TARGET_ABOVE, PNL_BELOW],
        },
        [],
    ],
    [
        "pageMissesTriggeredAlert",
        [TARGET_ABOVE, PNL_BELOW],
        { before: [TARGET_ABOVE], toasted: [TARGET_ABOVE] },
        [
            `no notification response of the page shows arming ${arming(PNL_BELOW).key} (profit_loss BELOW) triggered, though the notifications read does`,
            `arming ${arming(PNL_BELOW).key} has 0 Toasts, expected 1`,
        ],
    ],
    [
        "toastRepeatedAfterReload",
        [TARGET_ABOVE, PNL_BELOW],
        {
            before: [TARGET_ABOVE, PNL_BELOW],
            toasted: [TARGET_ABOVE, PNL_BELOW],
            toastedAfter: [PNL_BELOW],
        },
        [`arming ${arming(PNL_BELOW).key} has 2 Toasts, expected 1`],
    ],
    [
        "onePairTriggered",
        [TARGET_BELOW],
        { before: [TARGET_BELOW], toasted: [TARGET_BELOW] },
        [
            "the notifications read shows no profit_loss fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger",
        ],
    ],
]) {
    test(`checkOneToastPerArming_pageAgainstNotificationsRead_reportsDifferences (${scenario})`, async (t) => {
        const baseUrl = await brokerAnswering(
            t,
            200,
            JSON.stringify({
                results: read.map((alert) => notification(alert)),
            })
        )
        const holder = holderSession(baseUrl, page)
        const actual = []
        const details = {}

        await checkOneToastPerArming(actual, details, baseUrl, holder, ALERTS)

        assert.deepEqual(actual, problems)
        assert.deepEqual(details.authoritativeRead, {
            path: "/broker-service/v1/alerts/notifications",
            status: 200,
            results: read.length,
        })
        assert.deepEqual(
            details.expected,
            read.map((alert) => arming(alert))
        )
        assert.deepEqual(
            details.triggered.map((item) => item.key),
            page.before.map((alert) => arming(alert).key)
        )
        assert.equal(details.notificationResponses, 6)
        assert.ok(holder.calls.includes("reload"))
    })
}

test("checkOneToastPerArming_fixtureToastNoNotificationExplains_describesItWithoutText", async (t) => {
    const read = [TARGET_ABOVE, PNL_BELOW]
    const baseUrl = await brokerAnswering(
        t,
        200,
        JSON.stringify({ results: read.map((alert) => notification(alert)) })
    )
    // TARGET_BELOW's Toast follows no response showing it triggered.
    const holder = holderSession(baseUrl, {
        before: read,
        toasted: [TARGET_ABOVE, PNL_BELOW, TARGET_BELOW],
    })
    const problems = []
    const details = {}

    await checkOneToastPerArming(problems, details, baseUrl, holder, ALERTS)

    assert.deepEqual(problems, [
        `a TARGET_PRICE BELOW Toast of alert ${TARGET_BELOW.id}, shown at 2026-11-25T22:01:00.000Z, follows no notification showing it triggered`,
    ])
    assert.ok(!JSON.stringify({ problems, details }).includes(SECRET))
})

test("checkOneToastPerArming_readFails_reportsClassAndJudgesPage", async (t) => {
    const baseUrl = await brokerAnswering(t, 500, SECRET)
    const holder = holderSession(baseUrl, {
        before: [TARGET_ABOVE, PNL_BELOW],
        toasted: [TARGET_ABOVE, PNL_BELOW, TARGET_ABOVE],
    })
    const problems = []
    const details = {}

    await checkOneToastPerArming(problems, details, baseUrl, holder, ALERTS)

    const failure = `GET ${NOTIFICATIONS_TARGET} answered HTTP 500`
    assert.deepEqual(problems, [
        failure,
        `arming ${arming(TARGET_ABOVE).key} has 2 Toasts, expected 1`,
    ])
    assert.deepEqual(details.authoritativeRead, {
        path: "/broker-service/v1/alerts/notifications",
        status: 500,
        error: failure,
    })
    assert.deepEqual(details.expected, [])
    assert.ok(!JSON.stringify({ problems, details }).includes(SECRET))
})

/** Lets every promise continuation that is already due run. */
function settle() {
    return new Promise((resolve) => setImmediate(resolve))
}

/**
 * Puts `performance.now()` and `setTimeout` under the test's control and
 * returns a driver that moves both on, `stepMs` at a time, until `promise`
 * settles or `limitMs` have passed, and resolves with how it settled.
 */
function controlClock(t) {
    let now = 0
    t.mock.method(performance, "now", () => now)
    t.mock.timers.enable({ apis: ["setTimeout"] })
    return async (promise, limitMs, stepMs) => {
        const outcome = { state: "pending", error: undefined }
        promise.then(
            () => Object.assign(outcome, { state: "fulfilled" }),
            (error) => Object.assign(outcome, { state: "rejected", error })
        )
        await settle()
        for (
            let elapsed = 0;
            outcome.state === "pending" && elapsed < limitMs;
            elapsed += stepMs
        ) {
            now += stepMs
            t.mock.timers.tick(stepMs)
            await settle()
        }
        return outcome
    }
}

/**
 * Bodies of an accepted 200 notification reply that are no results list,
 * which the frontend rejects (`toAlertsDto`), so no poll wait may count one.
 */
const MALFORMED_BODIES = [
    ["resultsNull", { results: null }],
    ["resultsObject", { results: {} }],
    ["bodyList", []],
    ["bodyWithoutResults", {}],
]

for (const [stage, timeoutMs, what] of [
    ["beforeReload", 90_000, "4 notification responses"],
    ["afterReload", 60_000, "2 notification responses after the reload"],
]) {
    for (const [scenario, body] of MALFORMED_BODIES) {
        test(`checkOneToastPerArming_awaitedPollNotResultsList_waitTimesOut (${stage}, ${scenario})`, async (t) => {
            const read = [TARGET_ABOVE]
            const baseUrl = await brokerAnswering(
                t,
                200,
                JSON.stringify({
                    results: read.map((alert) => notification(alert)),
                })
            )
            const holder = holderSession(baseUrl, {
                before: read,
                toasted: read,
            })
            // The wait of `stage` gets every poll it needs, but the last one
            // answers with `body`.
            if (stage === "beforeReload") {
                holder.responses.at(-1).body = body
            } else {
                const { reload } = holder.page
                holder.page.reload = async () => {
                    await reload()
                    holder.responses.at(-1).body = body
                }
            }
            let opened
            const pageOpened = new Promise((resolve) => {
                opened = resolve
            })
            const { bringToFront } = holder.page
            holder.page.bringToFront = async () => {
                await bringToFront()
                opened()
            }
            const run = controlClock(t)

            const checking = checkOneToastPerArming(
                [],
                {},
                baseUrl,
                holder,
                ALERTS
            )
            // The read is loopback I/O; the clock moves once the page opens.
            await Promise.race([pageOpened, checking])
            const outcome = await run(checking, timeoutMs + 30_000, 1_000)

            assert.deepEqual(
                {
                    state: outcome.state,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                    reloaded: holder.calls.includes("reload"),
                },
                {
                    state: "rejected",
                    timeout: true,
                    message: `timed out after ${timeoutMs} ms waiting for ${what}`,
                    reloaded: stage === "afterReload",
                }
            )
        })
    }
}

test(
    "readNotifications_unknownAccountOnLiveStack_reportsStatusOnly",
    {
        skip:
            LIVE_BASE_URL === null &&
            "run this file directly with --live-base-url URL to read a stack",
    },
    async () => {
        // A random account is unknown: 404, or 403 while the flag is off.
        const accountId = randomUUID()
        const error = await readNotifications(LIVE_BASE_URL, accountId).then(
            () => assert.fail("the read of an unknown account resolved"),
            (reason) => reason
        )

        assert.ok(error instanceof NotificationReadError)
        assert.ok([403, 404].includes(error.status), `status ${error.status}`)
        assert.equal(
            error.message,
            `GET /broker-service/v1/alerts/notifications?accountId=${accountId} answered HTTP ${error.status}`
        )
    }
)
