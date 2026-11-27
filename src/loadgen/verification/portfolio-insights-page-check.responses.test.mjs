// Unit tests of which responses and requests the page check counts: the
// recorder's acceptance of each page response, the notification polls,
// insights comparison, acknowledgement and evidence built on it, the
// check's own flag and notification requests,
// which take a 200 only and never follow a redirect, the flag-off link
// check, which needs a valid `false` and a settled page, and the direct
// visit, which fails on any feature element or request before or after its
// redirect.
//
// Time is controlled, never slept: `performance.now()` reads a test clock and
// `setTimeout` runs on node:test's mock timers, which the clock moves on
// together. The direct-request cases use loopback stubs on ports the system
// picks.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { createServer } from "node:http"
import { test } from "node:test"

import {
    checkAcknowledge,
    checkDirectVisit,
    checkNavLinkAbsent,
    compareWithLastInsights,
    flagRequest,
    installFeatureRecorder,
    latestRevision,
    NotificationReadError,
    notificationEntries,
    pageFlagAnswers,
    readFeatureIds,
    readNotifications,
    recordFeatureElement,
    recordRequest,
    recordResponse,
    summariseNotifications,
} from "./portfolio-insights-page-check.mjs"

const ORIGIN = "http://localhost:20000"
const ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f"
const OTHER_ACCOUNT_ID = "5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9"
const ALERT_ID = "1b2c3d4e-0000-4000-8000-000000000001"
const FLAG_ID = "portfolio-insights-enabled"
const FLAG_PATH = `/feature-flag-service/v1/flags/${FLAG_ID}`
const BROKER = "/broker-service/v1"
const NOTIFICATIONS_PATH = `${BROKER}/alerts/notifications`
const POLL_URL = `${ORIGIN}${NOTIFICATIONS_PATH}?accountId=${ACCOUNT_ID}&unacknowledged=true`
/** Assembled at run time, so no scanner takes it for a credential. */
const SECRET = ["pi", "responses", "canary", "5c1d"].join("-")
const REDIRECTED = "a redirect, which the check does not follow"

/** Lets every promise continuation that is already due run. */
function settle() {
    return new Promise((resolve) => setImmediate(resolve))
}

/** Records how `promise` settles. */
function track(promise) {
    const outcome = { state: "pending", value: undefined, error: undefined }
    promise.then(
        (value) => Object.assign(outcome, { state: "fulfilled", value }),
        (error) => Object.assign(outcome, { state: "rejected", error })
    )
    return outcome
}

/**
 * Puts `performance.now()` and `setTimeout` under the test's control and
 * returns a driver that moves both on, `stepMs` at a time, until a promise
 * settles or `limitMs` have passed.
 */
function controlClock(t) {
    let now = 0
    t.mock.method(performance, "now", () => now)
    t.mock.timers.enable({ apis: ["setTimeout"] })
    return async (promise, limitMs, stepMs = 10) => {
        const outcome = track(promise)
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
        return { ...outcome, elapsedMs: now }
    }
}

/** A session as `openSession` opens it on `ORIGIN`, without its page. */
function recorderSession() {
    return {
        label: "holder",
        account: { username: "pi-holder", accountId: ACCOUNT_ID },
        origin: ORIGIN,
        toasts: [],
        responses: [],
        notificationRequests: [],
        featureElements: [],
        featureRequests: [],
        pendingBodies: new Set(),
    }
}

/** A Puppeteer HTTPResponse stand-in; `body` is the JSON it answers with. */
function fakeResponse({ method = "GET", url, status = 200, body = {} }) {
    return {
        url: () => url,
        request: () => ({ method: () => method }),
        status: () => status,
        json: async () => body,
    }
}

/** A Puppeteer HTTPRequest stand-in. */
function fakeRequest(method, url) {
    return { url: () => url, method: () => method, headers: () => ({}) }
}

/** Records each response in `session` and waits for every body read. */
async function record(session, responses) {
    for (const response of responses) {
        recordResponse(session, fakeResponse(response))
    }
    await Promise.all([...session.pendingBodies])
    return session
}

/** A server on a free loopback port that counts its requests. */
async function startServer(t, handler) {
    const server = createServer((request, response) => {
        server.requests += 1
        request.resume()
        handler(request, response)
    })
    server.requests = 0
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
    return { server, baseUrl: `http://127.0.0.1:${server.address().port}` }
}

test("recordResponse_pageResponse_acceptsOnlyFrontendCallAnswer", async (t) => {
    const alert = `${ORIGIN}${BROKER}/alerts/${ALERT_ID}`
    const poll = `${ORIGIN}${NOTIFICATIONS_PATH}`
    const rows = [
        { name: "notificationPoll", url: POLL_URL, rejection: null },
        {
            name: "notificationPollUpperCaseAccount",
            url: `${poll}?accountId=${ACCOUNT_ID.toUpperCase()}&unacknowledged=true`,
            rejection: null,
        },
        {
            name: "notificationServerError",
            url: POLL_URL,
            status: 500,
            rejection: "answered HTTP 500, not 200",
        },
        {
            name: "notificationOtherSuccess",
            url: POLL_URL,
            status: 201,
            rejection: "answered HTTP 201, not 200",
        },
        {
            name: "notificationRedirect",
            url: POLL_URL,
            status: 302,
            rejection: "answered HTTP 302, not 200",
        },
        {
            name: "notificationPost",
            method: "POST",
            url: POLL_URL,
            rejection: "answered a POST request, not GET",
        },
        {
            name: "notificationOtherOrigin",
            url: POLL_URL.replace(ORIGIN, "http://127.0.0.1:20000"),
            rejection: "came from another origin",
        },
        {
            name: "notificationOtherAccount",
            url: `${poll}?accountId=${OTHER_ACCOUNT_ID}&unacknowledged=true`,
            rejection: "is for another account",
        },
        {
            name: "notificationNoAccount",
            url: `${poll}?unacknowledged=true`,
            rejection: "names no account",
        },
        {
            name: "notificationAllFilter",
            url: `${poll}?accountId=${ACCOUNT_ID}&unacknowledged=false`,
            rejection: "lacks the exact query the frontend sends",
        },
        {
            name: "notificationNoFilter",
            url: `${poll}?accountId=${ACCOUNT_ID}`,
            rejection: "lacks the exact query the frontend sends",
        },
        {
            name: "notificationRepeatedFilter",
            url: `${POLL_URL}&unacknowledged=true`,
            rejection: "lacks the exact query the frontend sends",
        },
        {
            name: "notificationExtraParameter",
            url: `${POLL_URL}&page=2`,
            rejection: "lacks the exact query the frontend sends",
        },
        {
            name: "acknowledge204",
            method: "POST",
            url: `${alert}/acknowledge`,
            status: 204,
            rejection: null,
        },
        {
            name: "acknowledge200",
            method: "POST",
            url: `${alert}/acknowledge`,
            rejection: "answered HTTP 200, not 204",
        },
        {
            name: "acknowledgeWithQuery",
            method: "POST",
            url: `${alert}/acknowledge?accountId=${ACCOUNT_ID}`,
            status: 204,
            rejection: "lacks the exact query the frontend sends",
        },
        { name: "patch200", method: "PATCH", url: alert, rejection: null },
        {
            name: "patch204",
            method: "PATCH",
            url: alert,
            status: 204,
            rejection: "answered HTTP 204, not 200",
        },
        {
            name: "alertList",
            url: `${ORIGIN}${BROKER}/alerts?accountId=${ACCOUNT_ID}`,
            rejection: null,
        },
        {
            name: "alertListWithFilter",
            url: `${ORIGIN}${BROKER}/alerts?accountId=${ACCOUNT_ID}&unacknowledged=true`,
            rejection: "lacks the exact query the frontend sends",
        },
        {
            name: "insightsOwnAccount",
            url: `${ORIGIN}${BROKER}/portfolio/insights/${ACCOUNT_ID}`,
            rejection: null,
        },
        {
            name: "insightsOtherAccount",
            url: `${ORIGIN}${BROKER}/portfolio/insights/${OTHER_ACCOUNT_ID}`,
            rejection: "is for another account",
        },
        { name: "flagRead", url: `${ORIGIN}${FLAG_PATH}`, rejection: null },
        {
            name: "flagWrite",
            method: "PUT",
            url: `${ORIGIN}${FLAG_PATH}`,
            rejection: "answered a PUT request, not GET",
        },
    ]
    for (const { name, rejection, ...response } of rows) {
        await t.test(name, async () => {
            const session = await record(recorderSession(), [response])

            const [entry] = session.responses
            assert.deepEqual(
                { accepted: entry.accepted, rejection: entry.rejection },
                { accepted: rejection === null, rejection }
            )
        })
    }
})

test("notificationEntries_unacceptedReplies_notCounted", async () => {
    const poll = `${ORIGIN}${NOTIFICATIONS_PATH}`
    const body = { results: [] }
    const session = await record(recorderSession(), [
        { url: POLL_URL, status: 500, body },
        { url: POLL_URL, method: "POST", body },
        { url: POLL_URL.replace(ORIGIN, "http://127.0.0.1:20000"), body },
        {
            url: `${poll}?accountId=${OTHER_ACCOUNT_ID}&unacknowledged=true`,
            body,
        },
        { url: `${poll}?accountId=${ACCOUNT_ID}`, body },
        { url: POLL_URL, body },
    ])
    // A poll whose body is still being read is not counted yet.
    recordResponse(session, {
        ...fakeResponse({ url: POLL_URL }),
        json: () => new Promise(() => {}),
    })

    const counted = notificationEntries(session)

    assert.deepEqual(
        counted.map((entry) => ({ url: entry.url, status: entry.status })),
        [{ url: POLL_URL, status: 200 }]
    )
    assert.equal(session.responses.length, 7)
})

/**
 * Bodies of a poll the recorder accepts, and whether each is the results
 * list the frontend applies (`toAlertsDto`), the only one that is a poll.
 */
const POLL_BODIES = [
    { name: "resultsList", body: { results: [] }, listed: true },
    { name: "resultsNull", body: { results: null }, listed: false },
    { name: "resultsObject", body: { results: {} }, listed: false },
    { name: "resultsText", body: { results: SECRET }, listed: false },
    { name: "bodyList", body: [], listed: false },
    { name: "bodyWithoutResults", body: {}, listed: false },
    { name: "bodyNull", body: null, listed: false },
]

test("notificationEntries_acceptedReplyBodies_countsResultsListOnly", async (t) => {
    for (const { name, body, listed } of POLL_BODIES) {
        await t.test(name, async () => {
            const session = await record(recorderSession(), [
                { url: POLL_URL, body },
            ])

            const counted = notificationEntries(session)

            assert.deepEqual(
                {
                    accepted: session.responses[0].accepted,
                    counted: counted.length,
                },
                { accepted: true, counted: listed ? 1 : 0 }
            )
        })
    }
})

test("summariseNotifications_rejectedReply_keptWithFixedReason", async () => {
    const session = await record(recorderSession(), [
        { url: POLL_URL, status: 500, body: { error: SECRET } },
    ])

    const [summary] = summariseNotifications([session])

    assert.deepEqual(
        {
            status: summary.status,
            accepted: summary.accepted,
            rejection: summary.rejection,
            counted: summary.counted,
            leaks: JSON.stringify(summary).includes(SECRET),
        },
        {
            status: 500,
            accepted: false,
            rejection: "answered HTTP 500, not 200",
            counted: false,
            leaks: false,
        }
    )
})

test("summariseNotifications_acceptedReplyBodies_keepsNonListUncountedWithFixedReason", async (t) => {
    for (const { name, body, listed } of POLL_BODIES) {
        await t.test(name, async () => {
            const session = await record(recorderSession(), [
                { url: POLL_URL, body },
            ])

            const [summary] = summariseNotifications([session])

            assert.deepEqual(
                {
                    accepted: summary.accepted,
                    rejection: summary.rejection,
                    counted: summary.counted,
                    results: summary.results,
                    bodyError: summary.bodyError,
                    leaks: JSON.stringify(summary).includes(SECRET),
                },
                {
                    accepted: true,
                    rejection: null,
                    counted: listed,
                    results: listed ? [] : null,
                    bodyError: listed ? null : "the body is not a results list",
                    leaks: false,
                }
            )
        })
    }
})

test("latestRevision_unacceptedResponses_ignored", async () => {
    const alertUrl = `${ORIGIN}${BROKER}/alerts/${ALERT_ID}`
    const listed = (armingRevision) => ({
        results: [{ id: ALERT_ID.toUpperCase(), armingRevision }],
    })
    const session = await record(recorderSession(), [
        {
            url: `${ORIGIN}${BROKER}/alerts?accountId=${ACCOUNT_ID}`,
            body: listed(2),
        },
        {
            method: "PATCH",
            url: alertUrl,
            body: { id: ALERT_ID, armingRevision: 3 },
        },
        // Each of these would move the revision on if it counted.
        { url: POLL_URL, status: 500, body: listed(7) },
        {
            url: POLL_URL.replace(ORIGIN, "http://127.0.0.1:20000"),
            body: listed(8),
        },
        {
            url: `${ORIGIN}${BROKER}/alerts?accountId=${OTHER_ACCOUNT_ID}`,
            body: listed(9),
        },
        {
            method: "PATCH",
            url: alertUrl,
            status: 201,
            body: { id: ALERT_ID, armingRevision: 10 },
        },
    ])

    assert.equal(
        latestRevision(session, { id: ALERT_ID, armingRevision: 1 }),
        3
    )
})

/** An insights response of an account without holdings. */
const EMPTY_INSIGHTS = {
    totalValue: 0,
    totalInvested: 0,
    unrealizedPnl: 0,
    unrealizedPnlPercent: 0,
    allocations: [],
    largestPosition: null,
    riskLevel: null,
}
/** What the page shows for `EMPTY_INSIGHTS`, as `readInsightsDom` reads it. */
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

test("compareWithLastInsights_lastResponseNotComparable_reportsWhyWithoutReadingPage", async (t) => {
    const insights = `${ORIGIN}${BROKER}/portfolio/insights/${ACCOUNT_ID}`
    const last = "the last insights response"
    const rows = [
        {
            name: "otherOrigin",
            url: insights.replace(ORIGIN, "http://127.0.0.1:20000"),
            problem: `${last} came from another origin`,
        },
        {
            name: "post",
            method: "POST",
            url: insights,
            problem: `${last} answered a POST request, not GET`,
        },
        {
            name: "withQuery",
            url: `${insights}?accountId=${ACCOUNT_ID}`,
            problem: `${last} lacks the exact query the frontend sends`,
        },
        {
            name: "serverError",
            url: insights,
            status: 500,
            problem: `${last} answered HTTP 500, not 200`,
        },
        {
            name: "acceptedUnreadableBody",
            url: insights,
            unreadable: true,
            problem: `${last} answered HTTP 200 with an unreadable body: the body is not valid JSON`,
        },
    ]
    for (const { name, problem, unreadable = false, ...response } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const session = recorderSession()
            const answer = fakeResponse({ ...response, body: EMPTY_INSIGHTS })
            if (unreadable) {
                answer.json = async () => {
                    throw new SyntaxError(SECRET)
                }
            }
            recordResponse(session, answer)
            await Promise.all([...session.pendingBodies])
            // The page shows the body, so a comparison would find no problem.
            let reads = 0
            session.page = {
                evaluate: async (fn, arg) => {
                    reads += 1
                    return fn.name === "formatInPage"
                        ? fn(arg)
                        : EMPTY_INSIGHTS_DOM
                },
                close: async () => {},
            }

            const outcome = await run(
                compareWithLastInsights(session),
                20_000,
                250
            )

            assert.deepEqual(
                { state: outcome.state, value: outcome.value, reads },
                {
                    state: "fulfilled",
                    value: {
                        problems: [problem],
                        pairs: [],
                        response: null,
                        unstableReads: 0,
                    },
                    reads: 0,
                }
            )
        })
    }
})

/**
 * The holder's page on /insights, whose #alert-notifications lists
 * `ALERT_ID` until its Acknowledge button is clicked. The click records the
 * page's answer `acknowledge` and the next notification poll, and the item
 * leaves the list.
 */
function acknowledgingHolder(acknowledge) {
    const holder = recorderSession()
    let clicked = false
    holder.page = {
        bringToFront: async () => {},
        url: () => `${ORIGIN}/insights`,
        evaluate: async (fn, selector) => {
            if (fn.name === "readNotificationIds") {
                return clicked ? [] : [ALERT_ID]
            }
            if (fn.name === "isClickable") {
                return true
            }
            return (
                selector === "#portfolio-insights" ||
                (!clicked && selector.includes(ALERT_ID))
            )
        },
        click: async () => {
            clicked = true
            recordResponse(holder, fakeResponse(acknowledge))
            recordResponse(
                holder,
                fakeResponse({ url: POLL_URL, body: { results: [] } })
            )
        },
        close: async () => {},
    }
    return holder
}

test("checkAcknowledge_acknowledgeResponse_acknowledgesOnlyAcceptedAnswer", async (t) => {
    const acknowledge = `${ORIGIN}${BROKER}/alerts/${ALERT_ID}/acknowledge`
    const rows = [
        { name: "accepted", url: acknowledge, status: 204, rejection: null },
        {
            name: "serverError",
            url: acknowledge,
            status: 500,
            rejection: "answered HTTP 500, not 204",
        },
        {
            name: "okWithBody",
            url: acknowledge,
            status: 200,
            rejection: "answered HTTP 200, not 204",
        },
        {
            name: "otherOrigin",
            url: acknowledge.replace(ORIGIN, "http://127.0.0.1:20000"),
            status: 204,
            rejection: "came from another origin",
        },
        {
            name: "withQuery",
            url: `${acknowledge}?accountId=${ACCOUNT_ID}`,
            status: 204,
            rejection: "lacks the exact query the frontend sends",
        },
    ]
    for (const { name, rejection, ...response } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const holder = acknowledgingHolder({
                ...response,
                method: "POST",
                body: { error: SECRET },
            })
            const report = {}
            const problems = []
            const details = {}

            const outcome = await run(
                checkAcknowledge(problems, details, report, holder, [
                    { id: ALERT_ID, armingRevision: 1 },
                ]),
                60_000,
                250
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    error: outcome.error?.message,
                    problems,
                    acknowledged: report.acknowledged,
                    status: details.acknowledgeStatus,
                },
                {
                    state: "fulfilled",
                    error: undefined,
                    problems:
                        rejection === null
                            ? []
                            : [`the acknowledge response ${rejection}`],
                    acknowledged:
                        rejection === null
                            ? { id: ALERT_ID, armingRevision: 1 }
                            : undefined,
                    status: response.status,
                }
            )
        })
    }
})

/** Sets the global `name` to `value` until `t` ends. */
function setGlobal(t, name, value) {
    const had = Object.hasOwn(globalThis, name)
    const previous = globalThis[name]
    globalThis[name] = value
    t.after(() => {
        if (had) {
            globalThis[name] = previous
        } else {
            delete globalThis[name]
        }
    })
}

/** A DOM element stand-in holding `descendants`. */
function element(id, descendants = []) {
    return { nodeType: 1, id, querySelectorAll: () => descendants }
}

/** The feature-id pattern the recorder tests hand the in-page functions. */
const FEATURE_IDS = "^(?:portfolio-insights|alerts-panel|insights-[a-z-]+)$"

test("installFeatureRecorder_mutations_reportsEachFeatureIdOncePerDocument", (t) => {
    const reported = []
    const observers = []
    setGlobal(t, "window", {
        __recordFeatureElement: async (entry) => {
            reported.push(entry)
        },
    })
    setGlobal(t, "document", { documentElement: {} })
    setGlobal(
        t,
        "MutationObserver",
        class {
            constructor(callback) {
                observers.push({ callback })
            }

            observe(target, options) {
                observers.at(-1).options = options
            }
        }
    )

    installFeatureRecorder(FEATURE_IDS)
    const [{ callback, options }] = observers
    callback([
        {
            type: "childList",
            addedNodes: [
                { nodeType: 3 },
                element("portfolio-insights", [
                    element("insights-total-value"),
                    element("nav-home"),
                ]),
            ],
        },
        { type: "attributes", target: element("alerts-panel"), addedNodes: [] },
        { type: "childList", addedNodes: [element("portfolio-insights")] },
        { type: "childList", addedNodes: [element(""), element(SECRET)] },
    ])

    assert.deepEqual(
        { reported, options },
        {
            reported: [
                { id: "portfolio-insights" },
                { id: "insights-total-value" },
                { id: "alerts-panel" },
            ],
            options: {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ["id"],
            },
        }
    )
})

test("readFeatureIds_documentIds_returnsFeatureIdsOnly", (t) => {
    setGlobal(t, "document", {
        querySelectorAll: (selector) =>
            selector === "[id]"
                ? [
                      element("nav-home"),
                      element("alerts-panel"),
                      element(SECRET),
                      element("insights-risk-badge"),
                  ]
                : [],
    })

    assert.deepEqual(readFeatureIds(FEATURE_IDS), [
        "alerts-panel",
        "insights-risk-badge",
    ])
})

test("pageFlagAnswers_flagResponses_projectsSettledOutcomes", async () => {
    const flagUrl = `${ORIGIN}${FLAG_PATH}`
    const session = await record(recorderSession(), [
        { url: flagUrl, body: { id: FLAG_ID, enabled: false, token: SECRET } },
        { url: flagUrl, status: 503, body: { error: SECRET } },
        { url: flagUrl, body: { id: "db_not_responding", enabled: true } },
    ])
    recordResponse(session, {
        ...fakeResponse({ url: flagUrl }),
        json: () => new Promise(() => {}),
    })

    assert.deepEqual(pageFlagAnswers(session, 0), [
        { status: 200, accepted: true, enabled: false, problem: null },
        {
            status: 503,
            accepted: false,
            enabled: null,
            problem: "answered HTTP 503, not 200",
        },
        {
            status: 200,
            accepted: true,
            enabled: null,
            problem: `has a body without "${FLAG_ID}" and a boolean "enabled"`,
        },
    ])
})

test("recordRequest_featureRequest_keepsMethodAndRouteOnly", async (t) => {
    const broker = `${ORIGIN}${BROKER}`
    const rows = [
        {
            name: "insights",
            url: `${broker}/portfolio/insights/${ACCOUNT_ID}`,
            expected: [
                {
                    method: "GET",
                    route: `${BROKER}/portfolio/insights/{accountId}`,
                },
            ],
        },
        {
            name: "notificationPoll",
            url: POLL_URL,
            expected: [{ method: "GET", route: NOTIFICATIONS_PATH }],
        },
        {
            name: "alertCreate",
            method: "POST",
            url: `${broker}/alerts`,
            expected: [{ method: "POST", route: `${BROKER}/alerts` }],
        },
        {
            name: "alertPatch",
            method: "PATCH",
            url: `${broker}/alerts/${ALERT_ID}`,
            expected: [{ method: "PATCH", route: `${BROKER}/alerts/{id}` }],
        },
        {
            name: "acknowledge",
            method: "POST",
            url: `${broker}/alerts/${ALERT_ID}/acknowledge`,
            expected: [
                { method: "POST", route: `${BROKER}/alerts/{id}/acknowledge` },
            ],
        },
        {
            name: "otherAlertRoute",
            url: `${broker}/alerts/${SECRET}`,
            expected: [{ method: "GET", route: `${BROKER}/alerts/…` }],
        },
        {
            name: "methodOutsideItsForm",
            method: `get ${SECRET}`,
            url: `${broker}/alerts`,
            expected: [{ method: null, route: `${BROKER}/alerts` }],
        },
        { name: "flagRead", url: `${ORIGIN}${FLAG_PATH}`, expected: [] },
        {
            name: "otherBrokerRoute",
            url: `${broker}/instruments`,
            expected: [],
        },
    ]
    for (const { name, method = "GET", url, expected } of rows) {
        await t.test(name, () => {
            const session = recorderSession()

            recordRequest(
                session,
                { traceHeaders: [] },
                fakeRequest(method, url)
            )

            assert.deepEqual(
                session.featureRequests.map(({ method, route }) => ({
                    method,
                    route,
                })),
                expected
            )
        })
    }
})

test("recordFeatureElement_reportedElement_keepsFeatureIdsOnly", async (t) => {
    const rows = [
        { name: "page", entry: { id: "portfolio-insights" }, kept: true },
        { name: "link", entry: { id: "nav-portfolio-insights" }, kept: true },
        { name: "figure", entry: { id: "insights-total-value" }, kept: true },
        { name: "panel", entry: { id: "alerts-panel" }, kept: true },
        { name: "form", entry: { id: "alert-form" }, kept: true },
        { name: "legacyLink", entry: { id: "nav-home" }, kept: false },
        { name: "pageText", entry: { id: `alert-${SECRET} x` }, kept: false },
        { name: "notString", entry: { id: 7 }, kept: false },
        { name: "notObject", entry: SECRET, kept: false },
    ]
    for (const { name, entry, kept } of rows) {
        await t.test(name, () => {
            const session = recorderSession()

            recordFeatureElement(session, entry)

            assert.deepEqual(
                session.featureElements.map((element) => element.id),
                kept ? [entry.id] : []
            )
        })
    }
})

test("flagRequest_otherSuccessOrRedirect_throwsFixedReasonWithoutFollowing", async (t) => {
    const rows = [
        { name: "created", status: 201, reason: "answered HTTP 201" },
        { name: "noContent", status: 204, reason: "answered HTTP 204" },
        {
            name: "found",
            status: 302,
            reason: `answered HTTP 302, ${REDIRECTED}`,
        },
        {
            name: "foundOnPut",
            method: "PUT",
            status: 302,
            reason: `answered HTTP 302, ${REDIRECTED}`,
        },
        {
            name: "temporaryRedirect",
            status: 307,
            reason: `answered HTTP 307, ${REDIRECTED}`,
        },
    ]
    for (const { name, method = "GET", status, reason } of rows) {
        await t.test(name, async (t) => {
            const elsewhere = await startServer(t, (_, response) => {
                response.writeHead(200, { "Content-Type": "application/json" })
                response.end(JSON.stringify({ id: FLAG_ID, enabled: false }))
            })
            const { baseUrl } = await startServer(t, (_, response) => {
                response.writeHead(status, {
                    "Content-Type": "application/json",
                    Location: `${elsewhere.baseUrl}${FLAG_PATH}?${SECRET}`,
                })
                response.end(
                    status === 204
                        ? undefined
                        : JSON.stringify({ id: FLAG_ID, enabled: false })
                )
            })

            const error = await flagRequest(baseUrl, {
                method,
                body: method === "PUT" ? '{"enabled":false}' : undefined,
            }).then(
                () => assert.fail("the request resolved"),
                (reason) => reason
            )

            assert.deepEqual(
                {
                    message: error.message,
                    followed: elsewhere.server.requests,
                },
                {
                    message: `${method} ${baseUrl}${FLAG_PATH} ${reason}`,
                    followed: 0,
                }
            )
        })
    }
})

test("readNotifications_otherSuccessOrRedirect_throwsFixedReasonWithoutFollowing", async (t) => {
    const results = JSON.stringify({ results: [] })
    const rows = [
        { name: "created", status: 201, reason: "answered HTTP 201" },
        {
            name: "partialContent",
            status: 206,
            reason: "answered HTTP 206",
        },
        {
            name: "movedPermanently",
            status: 301,
            reason: `answered HTTP 301, ${REDIRECTED}`,
        },
        {
            name: "found",
            status: 302,
            reason: `answered HTTP 302, ${REDIRECTED}`,
        },
    ]
    for (const { name, status, reason } of rows) {
        await t.test(name, async (t) => {
            const elsewhere = await startServer(t, (_, response) => {
                response.writeHead(200, { "Content-Type": "application/json" })
                response.end(results)
            })
            const { baseUrl } = await startServer(t, (_, response) => {
                response.writeHead(status, {
                    "Content-Type": "application/json",
                    Location: `${elsewhere.baseUrl}${NOTIFICATIONS_PATH}?${SECRET}`,
                })
                response.end(results)
            })

            const error = await readNotifications(baseUrl, ACCOUNT_ID).then(
                () => assert.fail("the read resolved"),
                (reason) => reason
            )

            assert.ok(error instanceof NotificationReadError)
            assert.deepEqual(
                {
                    message: error.message,
                    status: error.status,
                    followed: elsewhere.server.requests,
                },
                {
                    message: `GET ${NOTIFICATIONS_PATH}?accountId=${ACCOUNT_ID} ${reason}`,
                    status,
                    followed: 0,
                }
            )
        })
    }
})

/**
 * The flag-off holder's page on /home after the login. It received the flag
 * responses `flags`, and its sidebar link is present from read
 * `linkFromRead` on, which is never by default.
 */
async function flagOffHolder(flags, linkFromRead = Infinity) {
    const holder = await record(recorderSession(), flags)
    holder.reads = 0
    holder.page = {
        evaluate: async (_, selector) => {
            holder.reads += 1
            return (
                selector === "#nav-portfolio-insights" &&
                holder.reads >= linkFromRead
            )
        },
        screenshot: async () => {},
        close: async () => {},
    }
    return holder
}

const LOGIN = { seq: 0, at: Date.now(), what: "the login started" }
const FLAG_URL = `${ORIGIN}${FLAG_PATH}`
const FLAG_FALSE = { url: FLAG_URL, body: { id: FLAG_ID, enabled: false } }
const FLAG_TRUE = { url: FLAG_URL, body: { id: FLAG_ID, enabled: true } }
const NO_FALSE = "no flag response of the page reads enabled false"

test("checkNavLinkAbsent_flagAnswers_needsValidFalseOnly", async (t) => {
    const rows = [
        { name: "validFalse_passes", flags: [FLAG_FALSE], problems: [] },
        {
            name: "acceptedTrue_fails",
            flags: [FLAG_TRUE],
            problems: [
                "the page's flag response 1 reads enabled true",
                NO_FALSE,
            ],
        },
        {
            name: "serverError_fails",
            flags: [{ url: FLAG_URL, status: 500, body: { error: SECRET } }],
            problems: [
                "the page's flag response 1 answered HTTP 500, not 200",
                NO_FALSE,
            ],
        },
        {
            name: "otherOrigin_fails",
            flags: [
                { ...FLAG_FALSE, url: `http://127.0.0.1:20000${FLAG_PATH}` },
            ],
            problems: [
                "the page's flag response 1 came from another origin",
                NO_FALSE,
            ],
        },
        {
            name: "notTheFlag_fails",
            flags: [{ url: FLAG_URL, body: { id: FLAG_ID, enabled: SECRET } }],
            problems: [
                `the page's flag response 1 has a body without "${FLAG_ID}" and a boolean "enabled"`,
                NO_FALSE,
            ],
        },
        {
            name: "falseThenTrue_fails",
            flags: [FLAG_FALSE, FLAG_TRUE],
            problems: ["the page's flag response 2 reads enabled true"],
        },
    ]
    for (const { name, flags, problems: expected } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const holder = await flagOffHolder(flags)
            const report = { screenshots: [] }
            const problems = []
            const details = {}

            const outcome = await run(
                checkNavLinkAbsent(problems, details, {
                    report,
                    holder,
                    evidenceDir: "",
                    since: LOGIN,
                }),
                10_000
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    problems,
                    answers: details.flagResponses.length,
                    screenshots: report.screenshots,
                    leaks: JSON.stringify({ problems, details }).includes(
                        SECRET
                    ),
                },
                {
                    state: "fulfilled",
                    problems: expected,
                    answers: flags.length,
                    screenshots: ["flag-off-home.png"],
                    leaks: false,
                }
            )
            // The link's absence was held for the whole settle window.
            assert.ok(outcome.elapsedMs >= 3000, `${outcome.elapsedMs} ms`)
        })
    }
})

test("checkNavLinkAbsent_linkRendersAfterAnswer_failsWithinWindow", async (t) => {
    const run = controlClock(t)
    // The first read races the frontend's render; the third sees the link.
    const holder = await flagOffHolder([FLAG_TRUE], 3)
    const problems = []

    const outcome = await run(
        checkNavLinkAbsent(
            problems,
            {},
            {
                report: { screenshots: [] },
                holder,
                evidenceDir: "",
                since: LOGIN,
            }
        ),
        10_000
    )

    assert.deepEqual(
        {
            state: outcome.state,
            error: outcome.error?.message,
            reads: holder.reads,
            problems,
        },
        {
            state: "rejected",
            error: "#nav-portfolio-insights is shown",
            reads: 3,
            problems: [
                "the page's flag response 1 reads enabled true",
                NO_FALSE,
            ],
        }
    )
})

test("checkNavLinkAbsent_linkShownMomentarily_failsThoughAbsentAtEveryRead", async (t) => {
    const run = controlClock(t)
    const holder = await flagOffHolder([FLAG_FALSE])
    recordFeatureElement(holder, { id: "nav-portfolio-insights" })
    const problems = []
    const details = {}

    const outcome = await run(
        checkNavLinkAbsent(problems, details, {
            report: { screenshots: [] },
            holder,
            evidenceDir: "",
            since: LOGIN,
        }),
        10_000
    )

    assert.equal(outcome.state, "fulfilled")
    assert.equal(problems.length, 1)
    assert.match(
        problems[0],
        /^#nav-portfolio-insights appeared -?\d+ ms after the login started$/
    )
    assert.equal(details.linkAppearedAfterMs.length, 1)
})

test("checkNavLinkAbsent_noFlagResponse_timesOut", async (t) => {
    const run = controlClock(t)
    // A body never read is no answer.
    const holder = await flagOffHolder([])
    recordResponse(holder, {
        ...fakeResponse({ url: FLAG_URL }),
        json: () => new Promise(() => {}),
    })
    const problems = []

    const outcome = await run(
        checkNavLinkAbsent(
            problems,
            {},
            {
                report: { screenshots: [] },
                holder,
                evidenceDir: "",
                since: LOGIN,
            }
        ),
        20_000
    )

    assert.deepEqual(
        {
            state: outcome.state,
            name: outcome.error?.name,
            error: outcome.error?.message,
            reads: holder.reads,
            problems,
        },
        {
            state: "rejected",
            name: "WaitTimeoutError",
            error: "timed out after 15000 ms waiting for the page's first flag response",
            reads: 0,
            problems: [],
        }
    )
})

/**
 * The holder's page for a direct visit. `goto` puts it on /insights, where
 * it sends each of `flagReads` that is `on` /insights to its request
 * listeners and records its `response`, if not `null`, as the loader's
 * entry decision does; runs `during(session)` and, unless the page
 * `staysOnInsights`, redirects it to /home, where it sends the reads `on`
 * /home. Each later read of the feature's ids answers
 * `shownAt(read, session)`.
 */
function directVisitSession({
    flagReads = [{ on: "/insights", response: FLAG_FALSE }],
    during = () => {},
    staysOnInsights = false,
    shownAt = () => [],
}) {
    const session = recorderSession()
    const listeners = new Set()
    let path = "/home"
    const readFlag = (on) => {
        for (const read of flagReads.filter((item) => item.on === on)) {
            const request = fakeRequest("GET", read.response?.url ?? FLAG_URL)
            listeners.forEach((listener) => listener(request))
            if (read.response !== null) {
                recordResponse(session, fakeResponse(read.response))
            }
        }
    }
    session.reads = 0
    session.requestListeners = listeners
    session.page = {
        on: (event, listener) => {
            if (event === "request") {
                listeners.add(listener)
            }
        },
        off: (event, listener) => {
            if (event === "request") {
                listeners.delete(listener)
            }
        },
        goto: async (url) => {
            session.visited = url
            path = "/insights"
            readFlag("/insights")
            during(session)
            if (!staysOnInsights) {
                path = "/home"
                readFlag("/home")
            }
        },
        url: () => `${ORIGIN}${path}`,
        evaluate: async () => {
            session.reads += 1
            return shownAt(session.reads, session)
        },
        close: async () => {},
    }
    return session
}

/** What `pageFlagAnswers` gives for an accepted 200 reading `false`. */
const FALSE_ANSWER = {
    status: 200,
    accepted: true,
    enabled: false,
    problem: null,
}
const NO_READ_ON_INSIGHTS =
    "the page sent no flag read while on /insights, so no flag answer decided its redirect"
const NO_ANSWER =
    "the page received no flag response with a known outcome during the direct visit"

test("checkDirectVisit_cleanRedirect_passesAfterSettleWindow", async (t) => {
    const run = controlClock(t)
    // Page ids outside the feature's form are neither violations nor repeated.
    const session = directVisitSession({ shownAt: () => ["nav-home", SECRET] })
    const details = {}

    const outcome = await run(
        checkDirectVisit(details, session, ORIGIN),
        10_000
    )

    assert.deepEqual(
        { state: outcome.state, visited: session.visited, details },
        {
            state: "fulfilled",
            visited: `${ORIGIN}/insights`,
            details: {
                landedOn: "/home",
                flagReadsOnInsights: 1,
                flagResponses: [FALSE_ANSWER],
                featureActivity: [],
            },
        }
    )
    assert.ok(outcome.elapsedMs >= 3000, `${outcome.elapsedMs} ms`)
})

test("checkDirectVisit_featureActivityAroundRedirect_fails", async (t) => {
    const report = { traceHeaders: [] }
    const rows = [
        {
            name: "pageMountedBeforeRedirect",
            during: (session) =>
                recordFeatureElement(session, { id: "portfolio-insights" }),
            error: /^#portfolio-insights appeared -?\d+ ms after the direct visit started$/,
            activity: [{ element: "portfolio-insights", request: null }],
        },
        {
            name: "loadingStateBeforeRedirect",
            during: (session) =>
                recordFeatureElement(session, { id: "insights-loading" }),
            error: /^#insights-loading appeared -?\d+ ms after the direct visit started$/,
            activity: [{ element: "insights-loading", request: null }],
        },
        {
            name: "notificationPollBeforeRedirect",
            during: (session) =>
                recordRequest(session, report, fakeRequest("GET", POLL_URL)),
            error: /^the page sent GET \/broker-service\/v1\/alerts\/notifications -?\d+ ms after the direct visit started$/,
            activity: [{ element: null, request: `GET ${NOTIFICATIONS_PATH}` }],
        },
        {
            name: "insightsReadBeforeRedirect",
            during: (session) =>
                recordRequest(
                    session,
                    report,
                    fakeRequest(
                        "GET",
                        `${ORIGIN}${BROKER}/portfolio/insights/${ACCOUNT_ID}`
                    )
                ),
            error: /^the page sent GET \/broker-service\/v1\/portfolio\/insights\/\{accountId\} -?\d+ ms after the direct visit started$/,
            activity: [
                {
                    element: null,
                    request: `GET ${BROKER}/portfolio/insights/{accountId}`,
                },
            ],
        },
        {
            name: "panelAfterRedirect",
            shownAt: (read) => (read >= 2 ? ["alerts-panel"] : []),
            error: /^the page shows #alerts-panel after the redirect$/,
            activity: [],
        },
    ]
    for (const { name, error, activity, ...visit } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const session = directVisitSession(visit)
            const details = {}

            const outcome = await run(
                checkDirectVisit(details, session, ORIGIN),
                10_000
            )

            assert.equal(outcome.state, "rejected")
            assert.match(outcome.error.message, error)
            assert.ok(!outcome.error.message.includes(ACCOUNT_ID))
            assert.deepEqual(
                details.featureActivity.map(({ element, request }) => ({
                    element,
                    request,
                })),
                activity
            )
        })
    }
})

test("checkDirectVisit_flagEvidence_needsFalseReadOnInsightsOnly", async (t) => {
    const onInsights = (response) => ({ on: "/insights", response })
    const rows = [
        { name: "validFalse_passes", flagReads: [onInsights(FLAG_FALSE)] },
        {
            name: "validFalseThenNavigationFalse_passes",
            flagReads: [
                onInsights(FLAG_FALSE),
                { on: "/home", response: FLAG_FALSE },
            ],
        },
        {
            name: "noFlagRead_fails",
            flagReads: [],
            error: `${NO_READ_ON_INSIGHTS}; ${NO_ANSWER}`,
        },
        {
            name: "readUnanswered_fails",
            flagReads: [onInsights(null)],
            error: NO_ANSWER,
        },
        {
            name: "readOnlyAfterRedirect_fails",
            flagReads: [{ on: "/home", response: FLAG_FALSE }],
            error: NO_READ_ON_INSIGHTS,
        },
        {
            name: "acceptedTrue_fails",
            flagReads: [onInsights(FLAG_TRUE)],
            error: `the page's flag response 1 reads enabled true; ${NO_FALSE}`,
        },
        {
            name: "serverError_fails",
            flagReads: [
                onInsights({
                    url: FLAG_URL,
                    status: 500,
                    body: { error: SECRET },
                }),
            ],
            error: `the page's flag response 1 answered HTTP 500, not 200; ${NO_FALSE}`,
        },
        {
            name: "otherOrigin_fails",
            flagReads: [
                onInsights({
                    ...FLAG_FALSE,
                    url: `http://127.0.0.1:20000${FLAG_PATH}`,
                }),
            ],
            error: `the page's flag response 1 came from another origin; ${NO_FALSE}`,
        },
        {
            name: "notTheFlag_fails",
            flagReads: [
                onInsights({
                    url: FLAG_URL,
                    body: { id: FLAG_ID, enabled: SECRET },
                }),
            ],
            error: `the page's flag response 1 has a body without "${FLAG_ID}" and a boolean "enabled"; ${NO_FALSE}`,
        },
        {
            name: "falseThenNavigationTrue_fails",
            flagReads: [
                onInsights(FLAG_FALSE),
                { on: "/home", response: FLAG_TRUE },
            ],
            error: "the page's flag response 2 reads enabled true",
        },
    ]
    for (const { name, flagReads, error = null } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const session = directVisitSession({ flagReads })
            const details = {}

            const outcome = await run(
                checkDirectVisit(details, session, ORIGIN),
                10_000
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    error: outcome.error?.message ?? null,
                    readsOnInsights: details.flagReadsOnInsights,
                    answers: details.flagResponses.length,
                    listening: session.requestListeners.size,
                    leaks: JSON.stringify({
                        error: outcome.error?.message,
                        details,
                    }).includes(SECRET),
                },
                {
                    state: error === null ? "fulfilled" : "rejected",
                    error,
                    readsOnInsights: flagReads.filter(
                        (read) => read.on === "/insights"
                    ).length,
                    answers: flagReads.filter((read) => read.response !== null)
                        .length,
                    listening: 0,
                    leaks: false,
                }
            )
            // The flag answers were judged once the settle window had passed.
            assert.ok(outcome.elapsedMs >= 3000, `${outcome.elapsedMs} ms`)
        })
    }
})

test("checkDirectVisit_unreadableRequest_loggedAndNotCounted", async (t) => {
    const run = controlClock(t)
    const logged = t.mock.method(console, "error", () => {})
    // A request whose address cannot be parsed reaches the listener as well.
    const session = directVisitSession({
        during: (visit) =>
            visit.requestListeners.forEach((listener) =>
                listener(fakeRequest("GET", "not an address"))
            ),
    })
    const details = {}

    const outcome = await run(
        checkDirectVisit(details, session, ORIGIN),
        10_000
    )

    assert.deepEqual(
        {
            state: outcome.state,
            readsOnInsights: details.flagReadsOnInsights,
            logged: logged.mock.callCount(),
        },
        { state: "fulfilled", readsOnInsights: 1, logged: 1 }
    )
})

/**
 * A read of the feature's ids that finds none and runs `record(session)`
 * once, during the read that starts `SETTLE_WINDOW_MS` (3 s) after the
 * first: the probe that closes the settle window.
 */
function recordDuringClosingRead(record) {
    let firstAt
    let recorded = false
    return (_, session) => {
        firstAt ??= performance.now()
        if (!recorded && performance.now() - firstAt >= 3000) {
            recorded = true
            record(session)
        }
        return []
    }
}

test("checkDirectVisit_activityDuringClosingProbe_fails", async (t) => {
    const report = { traceHeaders: [] }
    const rows = [
        {
            name: "featureMounted",
            record: (session) =>
                recordFeatureElement(session, { id: "insights-loading" }),
            error: /^#insights-loading appeared -?\d+ ms after the direct visit started$/,
            activity: [{ element: "insights-loading", request: null }],
        },
        {
            name: "featureRequestSent",
            record: (session) =>
                recordRequest(session, report, fakeRequest("GET", POLL_URL)),
            error: /^the page sent GET \/broker-service\/v1\/alerts\/notifications -?\d+ ms after the direct visit started$/,
            activity: [{ element: null, request: `GET ${NOTIFICATIONS_PATH}` }],
        },
    ]
    for (const { name, record, error, activity } of rows) {
        await t.test(name, async (t) => {
            const run = controlClock(t)
            const session = directVisitSession({
                shownAt: recordDuringClosingRead(record),
            })
            const details = {}

            const outcome = await run(
                checkDirectVisit(details, session, ORIGIN),
                10_000
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    matches: error.test(outcome.error?.message ?? ""),
                    activity: details.featureActivity.map(
                        ({ element, request }) => ({ element, request })
                    ),
                    closedWindow: outcome.elapsedMs >= 3000,
                },
                {
                    state: "rejected",
                    matches: true,
                    activity,
                    closedWindow: true,
                }
            )
        })
    }
})

test("checkDirectVisit_noRedirect_timesOutNamingPath", async (t) => {
    const run = controlClock(t)
    const session = directVisitSession({ staysOnInsights: true })
    const details = {}

    const outcome = await run(
        checkDirectVisit(details, session, ORIGIN),
        20_000
    )

    assert.deepEqual(
        {
            state: outcome.state,
            name: outcome.error?.name,
            error: outcome.error?.message,
            details,
        },
        {
            state: "rejected",
            name: "WaitTimeoutError",
            error: "timed out after 15000 ms waiting for the page to reach /home; it is on /insights",
            details: {
                flagReadsOnInsights: 1,
                flagResponses: [FALSE_ANSWER],
                featureActivity: [],
            },
        }
    )
})
