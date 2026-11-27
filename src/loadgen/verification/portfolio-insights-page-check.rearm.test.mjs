// Unit tests of the page check's re-arm step. A row's toggle is clicked only
// on a label the state the page last received for the alert explains, and
// each click is judged by that label: the PATCH it caused must send what the
// label sends, and an accepted 200 for the clicked alert must answer, as a
// full AlertDTO, the state that value sets. Only a "Disable" answered
// disabled goes on to "Enable". A row whose label changed with the state it
// received is sampled again, a bounded number of times, and a wrong answer
// never is.
//
// The page is a stand-in whose `evaluate` runs the check's own in-page
// functions against a stand-in row, and whose click passes the row's click
// guard before the frontend's handler sends the PATCH. Every PATCH answer,
// alert list and notification poll goes through the real `recordResponse`
// on a session with its origin and account, so acceptance is decided as in
// a run. Time is controlled, never slept: `performance.now()` reads a test
// clock and `setTimeout` runs on node:test's mock timers, which the clock
// moves on together.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { test } from "node:test"

import {
    clickShownToggle,
    rearmMember,
    recordResponse,
} from "./portfolio-insights-page-check.mjs"

const ORIGIN = "http://localhost:20360"
const ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f"
const ALERT_ID = "0b5c9f2e-6a1d-4c3b-9e8f-7a6b5c4d3e2f"
const OTHER_ALERT_ID = "1b2c3d4e-0000-4000-8000-000000000001"
const ROW = `li.alert-item[data-alert-id="${ALERT_ID}" i]`
const TOGGLE = `${ROW} button.alert-toggle`
const PATCH_URL = `${ORIGIN}/broker-service/v1/alerts/${ALERT_ID}`
/** The URL of each frontend read `receive` records, for `ACCOUNT_ID`. */
const READ_URLS = {
    alertsList: `${ORIGIN}/broker-service/v1/alerts?accountId=${ACCOUNT_ID}`,
    notifications: `${ORIGIN}/broker-service/v1/alerts/notifications?accountId=${ACCOUNT_ID}&unacknowledged=true`,
}
const TRIGGERED_AT = "2026-11-26T13:21:28.504Z"
/** Assembled at run time, so no scanner takes it for a credential. */
const SECRET = ["pi", "rearm", "canary", "7d2f"].join("-")
/** The page check's deadline for an alert row, its toggle and its PATCH. */
const ROW_TIMEOUT_MS = 20_000
/** The fixture alert, at the revision e2e.sh wrote. */
const ALERT = {
    id: ALERT_ID,
    pair: "target_price",
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: "100",
    armingRevision: 1,
}

/** The state fields of an alert in each state `AlertList` shows. */
const STATES = {
    armed: {
        enabled: true,
        triggeredAt: null,
        triggerValue: null,
        acknowledged: false,
    },
    triggered: {
        enabled: true,
        triggeredAt: TRIGGERED_AT,
        triggerValue: 101.5,
        acknowledged: false,
    },
    disabled: {
        enabled: false,
        triggeredAt: null,
        triggerValue: null,
        acknowledged: false,
    },
}

/** The alert as the broker answers it, in `state`, at revision 1. */
function alertBody(state) {
    return {
        id: ALERT_ID,
        accountId: ACCOUNT_ID,
        instrumentId: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",
        type: "TARGET_PRICE",
        direction: "ABOVE",
        threshold: 100,
        armingRevision: 1,
        createdAt: "2026-11-26T13:00:00.000Z",
        ...STATES[state],
    }
}

/** The label `AlertList` gives the toggle of a row showing `alert`. */
function labelOf(alert) {
    if (!alert.enabled) {
        return "Enable"
    }
    return alert.triggeredAt === null ? "Disable" : "Re-arm"
}

/** The broker's PATCH: `true` re-arms, `false` sets only `enabled`. */
function brokerPatch(alert, enabled) {
    return enabled
        ? {
              ...alert,
              enabled: true,
              triggeredAt: null,
              triggerValue: null,
              acknowledged: false,
              armingRevision: alert.armingRevision + 1,
          }
        : { ...alert, enabled: false }
}

/** The broker answering every PATCH as its contract says. */
function asContracted({ state, enabled }) {
    return { body: brokerPatch(state, enabled) }
}

/** The broker's re-arm of `state`, without the fields named in `omitted`. */
function rearmedWithout(state, ...omitted) {
    const body = brokerPatch(state, true)
    for (const name of omitted) {
        delete body[name]
    }
    return body
}

/**
 * Records, through `recordResponse`, the frontend's `kind` read ("alertsList"
 * or "notifications") answering `alerts` with a 200 from `url`. A `held` body
 * is read only once the function returned is called.
 */
function receive(
    session,
    kind,
    alerts,
    { url = READ_URLS[kind], held = false } = {}
) {
    let release = () => {}
    const body = held
        ? new Promise((resolve) => {
              release = () => resolve({ results: alerts })
          })
        : Promise.resolve({ results: alerts })
    recordResponse(session, {
        url: () => url,
        status: () => 200,
        json: () => body,
        request: () => ({ method: () => "GET" }),
    })
    return release
}

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
    return async (promise, limitMs = 3 * ROW_TIMEOUT_MS, stepMs = 50) => {
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

/** An element of the stand-in page, matching only the selectors it is given. */
class StandInElement {
    constructor(selectors, parent = null) {
        this.selectors = selectors
        this.parent = parent
    }

    closest(selector) {
        if (this.selectors.includes(selector)) {
            return this
        }
        return this.parent === null ? null : this.parent.closest(selector)
    }

    contains(other) {
        for (let element = other; element !== null; element = element.parent) {
            if (element === this) {
                return true
            }
        }
        return false
    }
}

/** Runs `run` with `window` and `document` set to the page's stand-ins. */
function inPage(globals, run) {
    const saved = Object.getOwnPropertyDescriptors(globalThis)
    Object.assign(globalThis, globals)
    try {
        return run()
    } finally {
        for (const name of Object.keys(globals)) {
            if (name in saved) {
                Object.defineProperty(globalThis, name, saved[name])
            } else {
                delete globalThis[name]
            }
        }
    }
}

/**
 * A Puppeteer page stand-in on /insights, showing the row of `ALERT` in the
 * state `initial`; its toggle reads the label `AlertList` gives the row's
 * current state. A click that passes every capture listener and lands on
 * the toggle runs the frontend's handler: it sends the `enabled` that
 * `sends` gives for the label, in the request body `postData` makes of it
 * (`postDataPending` never reads one), and `respond` answers it with
 * `{ status, url, body, unreadable }`, recorded through `recordResponse`. A
 * 200 for the alert becomes the row's state, and the list the frontend then
 * reads again answers it (`page.refetchList`). `beforeArm`, `beforeClick`
 * and `beforeRead` run before each guard check, each click and each read of
 * the toggle, numbered from 1. `target` picks the element click `n` lands
 * on, `null` for none; `clickError` and `failAfterClick` the error it throws
 * before or after the click event, `null` for none; `failTake` makes
 * reading the guard back fail. `covered`, `disabled` and `hidden` keep the
 * toggle from being clickable; `page.hidden` and `page.failTake` can be set
 * later. `shows` gives the toggle's text, which the handler acts on, for
 * the row's state and the page.
 */
function fakePage(
    session,
    {
        initial,
        sends = (label) => label !== "Disable",
        postData = (enabled) => JSON.stringify({ enabled }),
        postDataPending = false,
        respond = asContracted,
        beforeArm = () => {},
        beforeClick = () => {},
        beforeRead = () => {},
        target = (dom) => dom.toggle,
        clickError = () => null,
        failAfterClick = () => null,
        failTake = false,
        covered = false,
        disabled = false,
        hidden = false,
        shows = labelOf,
    }
) {
    const row = new StandInElement([ROW])
    const dom = {
        row,
        toggle: new StandInElement(["button.alert-toggle"], row),
        deleteButton: new StandInElement(["button.alert-delete"], row),
        toast: new StandInElement(["div.toast"]),
    }
    const page = {
        state: alertBody(initial),
        handled: [],
        sent: [],
        stopped: 0,
        deleted: 0,
        arms: 0,
        clicks: 0,
        reads: 0,
        closes: 0,
        listeners: [],
        hidden,
        failTake,
    }
    Object.defineProperty(dom.toggle, "textContent", {
        get: () => ` ${shows(page.state, page)} `,
    })
    Object.assign(dom.toggle, {
        disabled,
        scrollIntoView: () => {},
        getBoundingClientRect: () => ({
            left: 10,
            top: 20,
            width: 60,
            height: 24,
        }),
    })
    const globals = {
        window: {
            Element: StandInElement,
            addEventListener: (type, listener, capture) => {
                assert.deepEqual([type, capture], ["click", true])
                page.listeners.push(listener)
            },
            removeEventListener: (type, listener, capture) => {
                assert.deepEqual([type, capture], ["click", true])
                page.listeners = page.listeners.filter(
                    (registered) => registered !== listener
                )
            },
        },
        document: {
            querySelector: (selector) =>
                selector === TOGGLE && !page.hidden ? dom.toggle : null,
            elementFromPoint: () => (covered ? dom.toast : dom.toggle),
        },
    }
    page.window = globals.window
    const sendPatch = (label) => {
        const enabled = sends(label)
        page.handled.push(label)
        page.sent.push(enabled)
        const answer = respond({ state: page.state, enabled, label })
        const status = answer.status ?? 200
        recordResponse(session, {
            url: () => answer.url ?? PATCH_URL,
            status: () => status,
            json: async () => {
                if (answer.unreadable) {
                    throw new SyntaxError(`Unexpected token in ${SECRET}`)
                }
                return answer.body
            },
            request: () => ({
                method: () => "PATCH",
                fetchPostData: () =>
                    postDataPending
                        ? new Promise(() => {})
                        : Promise.resolve(postData(enabled)),
            }),
        })
        if (status === 200 && answer.body?.id === ALERT_ID) {
            page.state = answer.body
            page.refetchList()
        }
    }
    Object.assign(page, {
        refetchList: () => receive(session, "alertsList", [page.state]),
        waitForSelector: async (selector) => {
            assert.equal(selector, ROW)
            return {}
        },
        close: async () => {
            page.closes += 1
        },
        evaluate: async (fn, ...args) => {
            if (fn.name === "armToggleGuard") {
                page.arms += 1
                beforeArm(page, page.arms)
            }
            if (fn.name === "readRowToggle") {
                page.reads += 1
                beforeRead(page, page.reads)
            }
            if (fn.name === "takeToggleGuard" && page.failTake) {
                throw new Error("Execution context was destroyed")
            }
            return structuredClone(inPage(globals, () => fn(...args)))
        },
        click: async (selector) => {
            assert.equal(selector, TOGGLE)
            page.clicks += 1
            beforeClick(page, page.clicks)
            const error = clickError(page.clicks)
            if (error !== null) {
                throw error
            }
            const landed = target(dom, page.clicks)
            if (landed === null) {
                return
            }
            let stopped = false
            const event = {
                target: landed,
                stopImmediatePropagation: () => {
                    stopped = true
                },
                preventDefault: () => {},
            }
            inPage(globals, () => {
                for (const listener of [...page.listeners]) {
                    if (stopped) {
                        break
                    }
                    listener(event)
                }
            })
            if (stopped) {
                page.stopped += 1
            } else if (landed === dom.deleteButton) {
                page.deleted += 1
            } else if (landed === dom.toggle) {
                sendPatch(shows(page.state, page))
            }
            const late = failAfterClick(page.clicks)
            if (late !== null) {
                throw late
            }
        },
    })
    return page
}

/** A session as `openSession` opens it for the holder on `ORIGIN`. */
function holderSession() {
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

/**
 * Runs `rearmMember` for `ALERT` on a stand-in page set up by `scenario`,
 * with the lines it logs kept in `logged`. `received(session, page)`
 * records what the page received before the step; by default, the list
 * the row is rendered from.
 */
async function runRearm(
    t,
    { received = (session, page) => page.refetchList(), ...scenario }
) {
    const drive = controlClock(t)
    const logs = t.mock.method(console, "error", () => {})
    const session = holderSession()
    const page = fakePage(session, scenario)
    session.page = page
    received(session, page)
    const report = { patches: [] }
    const outcome = await drive(rearmMember(session, report, ALERT))
    const logged = logs.mock.calls.map((call) => call.arguments.join(" "))
    return { outcome, page, report, logged }
}

/** A PATCH snapshot of the evidence, without its click time. */
function withoutTime({ clickedAt, ...snapshot }) {
    assert.equal(typeof clickedAt, "string")
    return snapshot
}

/** The evidence of an accepted 200 answering the alert with `fields`. */
function answered(clicked, sent, fields) {
    return {
        alertId: ALERT_ID,
        clicked,
        sent,
        status: 200,
        rejection: null,
        bodyError: null,
        answeredId: ALERT_ID,
        enabled: fields.enabled,
        armingRevision: fields.armingRevision,
        triggeredAt: fields.triggeredAt,
        acknowledged: fields.acknowledged,
    }
}

const REARMED = {
    enabled: true,
    armingRevision: 2,
    triggeredAt: null,
    acknowledged: false,
}
const DISABLED = {
    enabled: false,
    armingRevision: 1,
    triggeredAt: null,
    acknowledged: false,
}

test("rearmMember_answeredAsLabelActs_rearmsMember", async (t) => {
    const rows = [
        {
            name: "triggeredRow_reArmed",
            initial: "triggered",
            expected: {
                initialState: "Re-arm",
                handled: ["Re-arm"],
                sent: [true],
                patches: [answered("Re-arm", true, REARMED)],
            },
        },
        {
            name: "disabledRow_enabled",
            initial: "disabled",
            expected: {
                initialState: "Enable",
                handled: ["Enable"],
                sent: [true],
                patches: [answered("Enable", true, REARMED)],
            },
        },
        {
            name: "armedRow_disabledThenEnabled",
            initial: "armed",
            expected: {
                initialState: "Disable",
                handled: ["Disable", "Enable"],
                sent: [false, true],
                patches: [
                    answered("Disable", false, DISABLED),
                    answered("Enable", true, REARMED),
                ],
            },
        },
        {
            // `false` keeps trigger data, so a trigger the page had not
            // shown yet stays in the Disable answer.
            name: "armedRowTriggeredMeanwhile_disableKeepsTrigger",
            initial: "armed",
            respond: ({ state, enabled }) => ({
                body: enabled
                    ? brokerPatch(state, true)
                    : {
                          ...brokerPatch(state, false),
                          triggeredAt: TRIGGERED_AT,
                          triggerValue: 101.5,
                      },
            }),
            expected: {
                initialState: "Disable",
                handled: ["Disable", "Enable"],
                sent: [false, true],
                patches: [
                    answered("Disable", false, {
                        ...DISABLED,
                        triggeredAt: TRIGGERED_AT,
                    }),
                    answered("Enable", true, REARMED),
                ],
            },
        },
        {
            name: "upperCaseAnswerId_reArmed",
            initial: "triggered",
            respond: ({ state }) => ({
                body: {
                    ...brokerPatch(state, true),
                    id: ALERT_ID.toUpperCase(),
                },
            }),
            expected: {
                initialState: "Re-arm",
                handled: ["Re-arm"],
                sent: [true],
                patches: [answered("Re-arm", true, REARMED)],
            },
        },
    ]
    for (const { name, expected, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const { outcome, page, report } = await runRearm(t, scenario)

            assert.deepEqual(
                {
                    state: outcome.state,
                    initialState: outcome.value?.initialState,
                    previousRevision: outcome.value?.previousRevision,
                    newRevision: outcome.value?.newRevision,
                    memberPatches: outcome.value?.patches.map(withoutTime),
                    handled: page.handled,
                    sent: page.sent,
                    stopped: page.stopped,
                    guardsLeft: page.listeners.length,
                    patches: report.patches.map(withoutTime),
                },
                {
                    state: "fulfilled",
                    initialState: expected.initialState,
                    previousRevision: 1,
                    newRevision: 2,
                    memberPatches: expected.patches,
                    handled: expected.handled,
                    sent: expected.sent,
                    stopped: 0,
                    guardsLeft: 0,
                    patches: expected.patches,
                }
            )
        })
    }
})

/** How the broker answered the alert, as the check's message gives it. */
function answerText(fields) {
    const body = { ...alertBody("armed"), ...fields }
    const triggeredAt =
        body.triggeredAt === null ? "null" : `"${body.triggeredAt}"`
    return `was answered for alert ${body.id} with enabled ${body.enabled}, triggeredAt ${triggeredAt}, triggerValue ${body.triggerValue}, acknowledged ${body.acknowledged} and armingRevision ${body.armingRevision}`
}

test("rearmMember_answerContradictsLabel_throwsWithoutFurtherClick", async (t) => {
    const reArm = `"Re-arm" on alert ${ALERT_ID} sent enabled true and`
    const rows = [
        {
            name: "reArmAnsweredDisabled",
            initial: "triggered",
            respond: ({ state }) => ({ body: brokerPatch(state, false) }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ ...STATES.triggered, enabled: false })}; expected enabled true, triggeredAt null, triggerValue null, armingRevision 2`,
        },
        {
            name: "enableAnsweredDisabled",
            initial: "disabled",
            respond: ({ state }) => ({ body: brokerPatch(state, false) }),
            handled: ["Enable"],
            message: `"Enable" on alert ${ALERT_ID} sent enabled true and ${answerText(STATES.disabled)}; expected enabled true, armingRevision 2`,
        },
        {
            name: "disableAnsweredEnabled",
            initial: "armed",
            respond: ({ state }) => ({ body: brokerPatch(state, true) }),
            handled: ["Disable"],
            message: `"Disable" on alert ${ALERT_ID} sent enabled false and ${answerText({ armingRevision: 2 })}; expected enabled false, armingRevision 1`,
        },
        {
            name: "disableAnsweredNewRevision",
            initial: "armed",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, false), armingRevision: 2 },
            }),
            handled: ["Disable"],
            message: `"Disable" on alert ${ALERT_ID} sent enabled false and ${answerText({ enabled: false, armingRevision: 2 })}; expected armingRevision 1`,
        },
        {
            name: "enableAfterDisableAnsweredTriggered",
            initial: "armed",
            respond: ({ state, enabled }) => ({
                body: enabled
                    ? { ...brokerPatch(state, true), triggeredAt: TRIGGERED_AT }
                    : brokerPatch(state, false),
            }),
            handled: ["Disable", "Enable"],
            message: `"Enable" on alert ${ALERT_ID} sent enabled true and ${answerText({ triggeredAt: TRIGGERED_AT, armingRevision: 2 })}; expected triggeredAt null`,
        },
        {
            name: "enableAnsweredSameRevision",
            initial: "disabled",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, true), armingRevision: 1 },
            }),
            handled: ["Enable"],
            message: `"Enable" on alert ${ALERT_ID} sent enabled true and ${answerText({})}; expected armingRevision 2`,
        },
        {
            name: "reArmAnsweredRevisionPlusTwo",
            initial: "triggered",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, true), armingRevision: 3 },
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ armingRevision: 3 })}; expected armingRevision 2`,
        },
        {
            name: "reArmAnsweredWithoutTriggerValue",
            initial: "triggered",
            respond: ({ state }) => ({
                body: rearmedWithout(state, "triggerValue"),
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ armingRevision: 2, triggerValue: undefined })}; expected triggerValue null`,
        },
        {
            name: "reArmAnsweredWithoutAcknowledged",
            initial: "triggered",
            respond: ({ state }) => ({
                body: rearmedWithout(state, "acknowledged"),
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ armingRevision: 2, acknowledged: undefined })}; expected acknowledged false`,
        },
        {
            name: "reArmAnsweredWithoutTriggerValueAndAcknowledged",
            initial: "triggered",
            respond: ({ state }) => ({
                body: rearmedWithout(state, "triggerValue", "acknowledged"),
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ armingRevision: 2, triggerValue: undefined, acknowledged: undefined })}; expected triggerValue null, acknowledged false`,
        },
        {
            name: "reArmAnsweredAcknowledged",
            initial: "triggered",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, true), acknowledged: true },
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ acknowledged: true, armingRevision: 2 })}; expected acknowledged false`,
        },
        {
            name: "answerForAnotherAlert",
            initial: "triggered",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, true), id: OTHER_ALERT_ID },
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ id: OTHER_ALERT_ID, armingRevision: 2 })}; expected the answer for alert ${ALERT_ID}`,
        },
        {
            name: "answerIdNotUuid",
            initial: "triggered",
            respond: ({ state }) => ({
                body: { ...brokerPatch(state, true), id: SECRET },
            }),
            handled: ["Re-arm"],
            message: `${reArm} ${answerText({ armingRevision: 2 }).replace(ALERT_ID, `a string of ${SECRET.length} characters`)}; expected the answer for alert ${ALERT_ID}`,
        },
        {
            name: "payloadContradictsLabel",
            initial: "triggered",
            sends: () => false,
            respond: ({ state }) => ({ body: brokerPatch(state, true) }),
            handled: ["Re-arm"],
            message: `"Re-arm" on alert ${ALERT_ID} sent enabled false and ${answerText({ armingRevision: 2 })}; expected to send enabled true`,
        },
        {
            name: "payloadUnreadable",
            initial: "triggered",
            postData: () => `enabled=true&note=${SECRET}`,
            handled: ["Re-arm"],
            message: `"Re-arm" on alert ${ALERT_ID} sent no {"enabled": bool} body and ${answerText({ armingRevision: 2 })}; expected to send enabled true`,
        },
        {
            name: "serverError",
            initial: "triggered",
            respond: () => ({ status: 500, body: { error: SECRET } }),
            handled: ["Re-arm"],
            message: `${reArm} its response answered HTTP 500, not 200; expected an accepted 200 answer`,
        },
        {
            name: "redirect",
            initial: "triggered",
            respond: () => ({ status: 302, body: { location: SECRET } }),
            handled: ["Re-arm"],
            message: `${reArm} its response answered HTTP 302, not 200; expected an accepted 200 answer`,
        },
        {
            name: "otherOrigin",
            initial: "triggered",
            respond: ({ state }) => ({
                url: PATCH_URL.replace(ORIGIN, "http://127.0.0.1:20360"),
                body: brokerPatch(state, true),
            }),
            handled: ["Re-arm"],
            message: `${reArm} its response came from another origin; expected an accepted 200 answer`,
        },
        {
            name: "unreadableAnswer",
            initial: "triggered",
            respond: () => ({ unreadable: true }),
            handled: ["Re-arm"],
            message: `${reArm} its response body is unreadable: the body is not valid JSON; expected a JSON object body`,
        },
        {
            name: "requestBodyNeverRead",
            initial: "triggered",
            postDataPending: true,
            handled: ["Re-arm"],
            message: `timed out after ${ROW_TIMEOUT_MS} ms waiting for the PATCH response of alert ${ALERT_ID}`,
        },
    ]
    for (const { name, handled, message, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const { outcome, page } = await runRearm(t, scenario)

            assert.deepEqual(
                {
                    state: outcome.state,
                    message: outcome.error?.message,
                    leaks: String(outcome.error?.message).includes(SECRET),
                    handled: page.handled,
                    stopped: page.stopped,
                    guardsLeft: page.listeners.length,
                },
                {
                    state: "rejected",
                    message,
                    leaks: false,
                    handled,
                    stopped: 0,
                    guardsLeft: 0,
                }
            )
        })
    }
})

test("rearmMember_answerWithoutReadableFields_keptAsEvidenceWithReason", async (t) => {
    const unread = {
        alertId: ALERT_ID,
        clicked: "Re-arm",
        sent: true,
        answeredId: null,
        enabled: null,
        armingRevision: null,
        triggeredAt: null,
        acknowledged: null,
    }
    const rows = [
        {
            name: "serverError_statusAndRejectionKept",
            respond: ({ state }) => ({
                status: 500,
                body: { ...brokerPatch(state, true), error: SECRET },
            }),
            expected: {
                ...unread,
                status: 500,
                rejection: "answered HTTP 500, not 200",
                bodyError: null,
            },
        },
        {
            name: "unreadableBody_bodyErrorKept",
            respond: () => ({ unreadable: true }),
            expected: {
                ...unread,
                status: 200,
                rejection: null,
                bodyError: "the body is not valid JSON",
            },
        },
    ]
    for (const { name, respond, expected } of rows) {
        await t.test(name, async (t) => {
            const { report } = await runRearm(t, {
                initial: "triggered",
                respond,
            })

            assert.deepEqual(
                {
                    patches: report.patches.map(withoutTime),
                    leaks: JSON.stringify(report).includes(SECRET),
                },
                { patches: [expected], leaks: false }
            )
        })
    }
})

/** Moves the stand-in row to `state` by a list refetch the page records. */
function moveTo(page, state) {
    page.state = { ...page.state, ...STATES[state] }
    page.refetchList()
}

test("rearmMember_labelChangesBeforeClick_resamplesAndRearms", async (t) => {
    const rows = [
        {
            // The guard meets the click on "Re-arm" and stops it.
            name: "triggersAtClick_clickStoppedThenReArmed",
            beforeClick: (page, click) => {
                if (click === 1) {
                    moveTo(page, "triggered")
                }
            },
            expected: { clicks: 2, stopped: 1, logged: [] },
        },
        {
            // The guard check finds "Re-arm" and arms nothing.
            name: "triggersBeforeGuard_noClickThenReArmed",
            beforeArm: (page, arm) => {
                if (arm === 1) {
                    moveTo(page, "triggered")
                }
            },
            expected: { clicks: 1, stopped: 0, logged: [] },
        },
        {
            // Puppeteer's click fails on the replaced button, and the toggle
            // then reads "Re-arm".
            name: "toggleReplacedBeforeClick_clickFailsThenReArmed",
            beforeClick: (page, click) => {
                if (click === 1) {
                    moveTo(page, "triggered")
                }
            },
            clickError: (click) =>
                click === 1
                    ? new Error("Node is detached from document")
                    : null,
            expected: {
                clicks: 2,
                stopped: 0,
                logged: ["Error: Node is detached from document"],
            },
        },
        {
            // The replaced button leaves the click to the row itself, which
            // the guard stops, and the toggle then reads "Re-arm".
            name: "toggleReplacedDuringClick_clickOnRowStoppedThenReArmed",
            beforeClick: (page, click) => {
                if (click === 1) {
                    moveTo(page, "triggered")
                }
            },
            target: (dom, click) => (click === 1 ? dom.row : dom.toggle),
            expected: { clicks: 2, stopped: 1, logged: [] },
        },
    ]
    for (const { name, expected, ...hooks } of rows) {
        await t.test(name, async (t) => {
            const { outcome, page, report, logged } = await runRearm(t, {
                initial: "armed",
                ...hooks,
            })

            assert.deepEqual(
                {
                    state: outcome.state,
                    initialState: outcome.value?.initialState,
                    newRevision: outcome.value?.newRevision,
                    handled: page.handled,
                    sent: page.sent,
                    clicks: page.clicks,
                    stopped: page.stopped,
                    guardsLeft: page.listeners.length,
                    patches: report.patches.map(withoutTime),
                    logged,
                },
                {
                    state: "fulfilled",
                    initialState: "Re-arm",
                    newRevision: 2,
                    handled: ["Re-arm"],
                    sent: [true],
                    clicks: expected.clicks,
                    stopped: expected.stopped,
                    guardsLeft: 0,
                    patches: [answered("Re-arm", true, REARMED)],
                    logged: expected.logged,
                }
            )
        })
    }
})

test("rearmMember_labelKeepsChanging_throwsAfterBoundedSamples", async (t) => {
    const { outcome, page, report } = await runRearm(t, {
        initial: "armed",
        // Every click finds the row in the other state.
        beforeClick: (page) =>
            moveTo(
                page,
                labelOf(page.state) === "Disable" ? "triggered" : "armed"
            ),
    })

    assert.deepEqual(
        {
            state: outcome.state,
            message: outcome.error?.message,
            handled: page.handled,
            clicks: page.clicks,
            stopped: page.stopped,
            guardsLeft: page.listeners.length,
            patches: report.patches,
        },
        {
            state: "rejected",
            message: `the toggle of alert ${ALERT_ID} changed state before each of 3 clicks, last from "Disable" to "Re-arm"`,
            handled: [],
            clicks: 3,
            stopped: 3,
            guardsLeft: 0,
            patches: [],
        }
    )
})

/** The problem for a sampled `label` the received state does not explain. */
function unexplained(label, reason) {
    return `the "${label}" toggle of alert ${ALERT_ID} was not explained within ${ROW_TIMEOUT_MS} ms by the state the page received: ${reason}`
}

/** The reason given for a last received state of `fields` showing `label`. */
function lastStateShows(fields, label) {
    const triggeredAt =
        fields.triggeredAt === null ? "null" : `"${fields.triggeredAt}"`
    return `its last state, enabled ${fields.enabled} and triggeredAt ${triggeredAt}, shows "${label}"`
}

/** Records the list the row renders, then a newer poll showing it triggered. */
function notifiedBeforeListed(session, page) {
    page.refetchList()
    receive(session, "notifications", [{ ...page.state, ...STATES.triggered }])
}

test("rearmMember_labelNotExplainedByReceivedState_throwsWithoutClick", async (t) => {
    const rows = [
        {
            name: "triggeredShownDisable",
            initial: "triggered",
            shows: () => "Disable",
            message: unexplained(
                "Disable",
                lastStateShows(STATES.triggered, "Re-arm")
            ),
        },
        {
            name: "disabledShownReArm",
            initial: "disabled",
            shows: () => "Re-arm",
            message: unexplained(
                "Re-arm",
                lastStateShows(STATES.disabled, "Enable")
            ),
        },
        {
            name: "armedShownReArm",
            initial: "armed",
            shows: () => "Re-arm",
            message: unexplained(
                "Re-arm",
                lastStateShows(STATES.armed, "Disable")
            ),
        },
        {
            // The label turns right with no state received meanwhile, which
            // is no transition: the wrong label stands.
            name: "triggeredShownDisableThenReArmWithoutNewState",
            initial: "triggered",
            shows: (alert, page) =>
                page.reads <= 2 ? "Disable" : labelOf(alert),
            message: unexplained(
                "Disable",
                lastStateShows(STATES.triggered, "Re-arm")
            ),
        },
        {
            // The list the row renders is overtaken and never read again.
            name: "notificationAheadOfListNeverRefetched",
            initial: "armed",
            received: notifiedBeforeListed,
            message: unexplained(
                "Disable",
                lastStateShows(STATES.triggered, "Re-arm")
            ),
        },
        {
            name: "nothingReceived",
            initial: "armed",
            received: () => {},
            message: unexplained(
                "Disable",
                "no accepted response named the alert"
            ),
        },
        {
            name: "listFromAnotherOrigin",
            initial: "armed",
            received: (session, page) =>
                receive(session, "alertsList", [page.state], {
                    url: READ_URLS.alertsList.replace(
                        ORIGIN,
                        "http://127.0.0.1:20360"
                    ),
                }),
            message: unexplained(
                "Disable",
                "no accepted response named the alert"
            ),
        },
        {
            name: "listOfAnotherAlertOnly",
            initial: "armed",
            received: (session, page) =>
                receive(session, "alertsList", [
                    { ...page.state, id: OTHER_ALERT_ID },
                ]),
            message: unexplained(
                "Disable",
                "no accepted response named the alert"
            ),
        },
        {
            // An older list explains the label, but a newer one is still
            // being read; once read, it contradicts the label.
            name: "newerListReadLate_contradictsLabel",
            initial: "triggered",
            shows: () => "Disable",
            received: (session, page) => {
                receive(session, "alertsList", [
                    { ...page.state, ...STATES.armed },
                ])
                page.release = receive(session, "alertsList", [page.state], {
                    held: true,
                })
            },
            beforeRead: (page, read) => {
                if (read === 2) {
                    page.release()
                }
            },
            message: unexplained(
                "Disable",
                lastStateShows(STATES.triggered, "Re-arm")
            ),
        },
        {
            name: "listStillBeingRead",
            initial: "armed",
            received: (session, page) =>
                receive(session, "alertsList", [page.state], { held: true }),
            message: unexplained(
                "Disable",
                "a response that may carry its state is still being read"
            ),
        },
        {
            name: "triggeredAtNotTimestamp",
            initial: "triggered",
            received: (session, page) =>
                receive(session, "alertsList", [
                    { ...page.state, triggeredAt: SECRET },
                ]),
            message: unexplained(
                "Re-arm",
                `its last state, enabled true and triggeredAt a string of ${SECRET.length} characters, shows no toggle label`
            ),
        },
    ]
    for (const { name, message, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const { outcome, page, report } = await runRearm(t, scenario)

            assert.deepEqual(
                {
                    state: outcome.state,
                    message: outcome.error?.message,
                    leaks: String(outcome.error?.message).includes(SECRET),
                    at: outcome.elapsedMs,
                    arms: page.arms,
                    clicks: page.clicks,
                    handled: page.handled,
                    patches: report.patches,
                },
                {
                    state: "rejected",
                    message,
                    leaks: false,
                    at: ROW_TIMEOUT_MS,
                    arms: 0,
                    clicks: 0,
                    handled: [],
                    patches: [],
                }
            )
        })
    }
})

test("rearmMember_receivedStateCatchesUp_clicksExplainedLabel", async (t) => {
    const rows = [
        {
            // The page rendered the list before its body was read here.
            name: "listReadAfterRender_reArmed",
            initial: "triggered",
            received: (session, page) => {
                page.release = receive(session, "alertsList", [page.state], {
                    held: true,
                })
            },
            beforeRead: (page, read) => {
                if (read === 3) {
                    page.release()
                }
            },
        },
        {
            // A genuine transition: the list read again after the poll turns
            // the row from "Disable" to "Re-arm", and no Disable is sent.
            name: "notificationAheadOfList_reArmedAfterListRefetch",
            initial: "armed",
            received: notifiedBeforeListed,
            beforeRead: (page, read) => {
                if (read === 3) {
                    moveTo(page, "triggered")
                }
            },
        },
    ]
    for (const { name, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const { outcome, page, report } = await runRearm(t, scenario)

            assert.deepEqual(
                {
                    state: outcome.state,
                    initialState: outcome.value?.initialState,
                    newRevision: outcome.value?.newRevision,
                    handled: page.handled,
                    sent: page.sent,
                    arms: page.arms,
                    clicks: page.clicks,
                    stopped: page.stopped,
                    patches: report.patches.map(withoutTime),
                },
                {
                    state: "fulfilled",
                    initialState: "Re-arm",
                    newRevision: 2,
                    handled: ["Re-arm"],
                    sent: [true],
                    arms: 1,
                    clicks: 1,
                    stopped: 0,
                    patches: [answered("Re-arm", true, REARMED)],
                }
            )
        })
    }
})

test("clickShownToggle_clickMissesUnchangedToggle_throwsWithoutSending", async (t) => {
    const detached = new Error("Node is detached from document")
    const stoppedMessage = `the click on the Disable toggle of alert ${ALERT_ID} met another element and was stopped`
    const rows = [
        {
            name: "landsOnToast_stopped",
            target: (dom) => dom.toast,
            message: stoppedMessage,
            stopped: 1,
        },
        {
            name: "landsOnDelete_stopped",
            target: (dom) => dom.deleteButton,
            message: stoppedMessage,
            stopped: 1,
        },
        {
            name: "targetNotAnElement_stopped",
            target: () => ({ closest: () => null }),
            message: stoppedMessage,
            stopped: 1,
        },
        {
            // A new document holds neither the guard nor its listener.
            name: "documentReplaced_noClickEvent",
            beforeClick: (page) => {
                delete page.window.__piToggleGuard
                page.listeners = []
            },
            target: () => null,
            message: `no click event followed the click on the Disable toggle of alert ${ALERT_ID}`,
        },
        {
            name: "noClickEvent_thrown",
            target: () => null,
            message: `no click event followed the click on the Disable toggle of alert ${ALERT_ID}`,
        },
        {
            name: "clickThrows_rethrown",
            clickError: () => detached,
            message: detached.message,
        },
        {
            // A row that is gone shows no other label, so nothing changed
            // state: the miss stands.
            name: "rowGoneAfterMiss_stopped",
            beforeClick: (page) => {
                page.hidden = true
            },
            target: (dom) => dom.toast,
            message: stoppedMessage,
            stopped: 1,
        },
    ]
    for (const { name, message, stopped = 0, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const drive = controlClock(t)
            const session = holderSession()
            const page = fakePage(session, { initial: "armed", ...scenario })

            const outcome = await drive(
                clickShownToggle(page, ALERT_ID, "Disable")
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    message: outcome.error?.message,
                    handled: page.handled,
                    deleted: page.deleted,
                    stopped: page.stopped,
                    guardsLeft: page.listeners.length,
                    responses: session.responses.length,
                },
                {
                    state: "rejected",
                    message,
                    handled: [],
                    deleted: 0,
                    stopped,
                    guardsLeft: 0,
                    responses: 0,
                }
            )
        })
    }
})

test("clickShownToggle_clickFailsAfterEvent_keepsEventOutcomeAndLogs", async (t) => {
    const late = new Error("Protocol error (Input.dispatchMouseEvent)")
    const rows = [
        {
            // Sampled again, it would send a second PATCH.
            name: "eventWentThrough_null",
            expected: { value: null, handled: ["Disable"], stopped: 0 },
        },
        {
            name: "eventStoppedOnNewLabel_newLabel",
            beforeClick: (page) => moveTo(page, "triggered"),
            expected: { value: "Re-arm", handled: [], stopped: 1 },
        },
    ]
    for (const { name, expected, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const drive = controlClock(t)
            const logs = t.mock.method(console, "error", () => {})
            const page = fakePage(holderSession(), {
                initial: "armed",
                failAfterClick: () => late,
                ...scenario,
            })

            const outcome = await drive(
                clickShownToggle(page, ALERT_ID, "Disable")
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    value: outcome.value,
                    handled: page.handled,
                    stopped: page.stopped,
                    guardsLeft: page.listeners.length,
                    logged: logs.mock.calls.map((call) =>
                        call.arguments.join(" ")
                    ),
                },
                {
                    state: "fulfilled",
                    ...expected,
                    guardsLeft: 0,
                    logged: [`Error: ${late.message}`],
                }
            )
        })
    }
})

test("clickShownToggle_guardLeftFromBefore_removedOnArming", async (t) => {
    const drive = controlClock(t)
    // The first click meets no event and its guard is never read back, so
    // a guard for "Re-arm" stays armed in the page.
    const page = fakePage(holderSession(), {
        initial: "triggered",
        target: (dom, click) => (click === 1 ? null : dom.toggle),
        failTake: true,
    })
    const first = await drive(clickShownToggle(page, ALERT_ID, "Re-arm"))
    const leftAfterFirst = page.listeners.length
    moveTo(page, "armed")
    page.failTake = false

    const second = await drive(clickShownToggle(page, ALERT_ID, "Disable"))

    assert.deepEqual(
        {
            first: first.error?.message,
            leftAfterFirst,
            second: second.value,
            handled: page.handled,
            stopped: page.stopped,
            guardsLeft: page.listeners.length,
        },
        {
            first: "Execution context was destroyed",
            leftAfterFirst: 1,
            second: null,
            handled: ["Disable"],
            stopped: 0,
            guardsLeft: 0,
        }
    )
})

test("rearmMember_toggleShowsUnknownText_throwsWithoutClick", async (t) => {
    const { outcome, page } = await runRearm(t, {
        initial: "armed",
        shows: () => SECRET,
    })

    assert.deepEqual(
        {
            state: outcome.state,
            message: outcome.error?.message,
            clicks: page.clicks,
            arms: page.arms,
        },
        {
            state: "rejected",
            message: `the row toggle reads a string of ${SECRET.length} characters`,
            clicks: 0,
            arms: 0,
        }
    )
})

test("clickShownToggle_guardReadFails_reportsClickFailureFirst", async (t) => {
    const detached = new Error("Node is detached from document")
    const rows = [
        {
            name: "clickSucceeded_readFailureThrown",
            message: "Execution context was destroyed",
            logged: [],
        },
        {
            name: "clickFailed_clickFailureThrown",
            clickError: () => detached,
            message: detached.message,
            logged: ["Error: Execution context was destroyed"],
        },
    ]
    for (const { name, message, logged, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const drive = controlClock(t)
            const logs = t.mock.method(console, "error", () => {})
            const page = fakePage(holderSession(), {
                initial: "armed",
                failTake: true,
                ...scenario,
            })

            const outcome = await drive(
                clickShownToggle(page, ALERT_ID, "Disable")
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    message: outcome.error?.message,
                    logged: logs.mock.calls.map((call) =>
                        call.arguments.join(" ")
                    ),
                },
                { state: "rejected", message, logged }
            )
        })
    }
})

test("clickShownToggle_toggleNotClickable_timesOutWithoutClick", async (t) => {
    const rows = [
        { name: "covered", covered: true },
        { name: "disabled", disabled: true },
        { name: "absent", hidden: true },
    ]
    for (const { name, ...scenario } of rows) {
        await t.test(name, async (t) => {
            const drive = controlClock(t)
            const page = fakePage(holderSession(), {
                initial: "armed",
                ...scenario,
            })

            const outcome = await drive(
                clickShownToggle(page, ALERT_ID, "Disable")
            )

            assert.deepEqual(
                {
                    state: outcome.state,
                    message: outcome.error?.message,
                    at: outcome.elapsedMs,
                    clicks: page.clicks,
                    guardsLeft: page.listeners.length,
                },
                {
                    state: "rejected",
                    message: `timed out after ${ROW_TIMEOUT_MS} ms waiting for the Disable toggle of alert ${ALERT_ID} to be enabled and uncovered`,
                    at: ROW_TIMEOUT_MS,
                    clicks: 0,
                    guardsLeft: 0,
                }
            )
        })
    }
})

/**
 * A PATCH answer whose request body `fetchPostData` reads; `reader` replaces
 * that reader, or removes it when `null`. Counts the reads of each body.
 */
function patchResponse({ status = 200, postData, reader }) {
    const reads = { request: 0, response: 0 }
    const request = { method: () => "PATCH" }
    if (reader !== null) {
        request.fetchPostData =
            reader ??
            (async () => {
                reads.request += 1
                return postData
            })
    }
    return {
        reads,
        url: () => PATCH_URL,
        status: () => status,
        json: async () => {
            reads.response += 1
            return brokerPatch(alertBody("triggered"), true)
        },
        request: () => request,
    }
}

test("recordResponse_patchRequestBody_recordsSentEnabledOnly", async (t) => {
    const rows = [
        { name: "enabledTrue_true", postData: '{"enabled":true}', sent: true },
        {
            name: "enabledFalse_false",
            postData: '{ "enabled": false }',
            sent: false,
        },
        {
            name: "enabledString_unknown",
            postData: `{"enabled":"${SECRET}"}`,
            sent: null,
        },
        {
            name: "enabledNull_unknown",
            postData: '{"enabled":null}',
            sent: null,
        },
        { name: "enabledMissing_unknown", postData: "{}", sent: null },
        {
            name: "extraField_unknown",
            postData: `{"enabled":true,"note":"${SECRET}"}`,
            sent: null,
        },
        { name: "arrayBody_unknown", postData: "[true]", sent: null },
        {
            name: "notJson_unknown",
            postData: `enabled=true&note=${SECRET}`,
            sent: null,
        },
        { name: "noBody_unknown", postData: undefined, sent: null },
        {
            name: "readRejects_unknown",
            reader: async () => {
                throw new Error(SECRET)
            },
            sent: null,
        },
        {
            name: "readThrows_unknown",
            reader: () => {
                throw new TypeError(SECRET)
            },
            sent: null,
        },
        { name: "noReader_unknown", reader: null, sent: null },
    ]
    for (const { name, sent, ...response } of rows) {
        await t.test(name, async () => {
            const session = holderSession()

            recordResponse(session, patchResponse(response))
            const [entry] = session.responses
            const beforeRead = {
                hasSent: Object.hasOwn(entry, "sentEnabled"),
                sentEnabled: entry.sentEnabled,
            }
            await Promise.all([...session.pendingBodies])

            assert.deepEqual(
                {
                    beforeRead,
                    sentEnabled: entry.sentEnabled,
                    accepted: entry.accepted,
                    pendingBodies: session.pendingBodies.size,
                    leaks: JSON.stringify(entry).includes(SECRET),
                },
                {
                    beforeRead: { hasSent: true, sentEnabled: undefined },
                    sentEnabled: sent,
                    accepted: true,
                    pendingBodies: 0,
                    leaks: false,
                }
            )
        })
    }
})

test("recordResponse_responseKind_readsRequestBodyOfPatchOnly", async (t) => {
    const rows = [
        {
            name: "patch200_bothRead",
            response: () => patchResponse({ postData: '{"enabled":true}' }),
            expected: {
                hasSent: true,
                sentEnabled: true,
                parsed: true,
                reads: { request: 1, response: 1 },
            },
        },
        {
            name: "patch204_requestBodyOnly",
            response: () =>
                patchResponse({ status: 204, postData: '{"enabled":true}' }),
            expected: {
                hasSent: true,
                sentEnabled: true,
                parsed: false,
                reads: { request: 1, response: 0 },
            },
        },
        {
            name: "alertList_responseBodyOnly",
            response: () => {
                const reads = { request: 0, response: 0 }
                return {
                    reads,
                    url: () =>
                        `${ORIGIN}/broker-service/v1/alerts?accountId=${ACCOUNT_ID}`,
                    status: () => 200,
                    json: async () => {
                        reads.response += 1
                        return { results: [] }
                    },
                    request: () => ({
                        method: () => "GET",
                        fetchPostData: async () => {
                            reads.request += 1
                            return undefined
                        },
                    }),
                }
            },
            expected: {
                hasSent: false,
                sentEnabled: undefined,
                parsed: true,
                reads: { request: 0, response: 1 },
            },
        },
    ]
    for (const { name, response, expected } of rows) {
        await t.test(name, async () => {
            const session = holderSession()
            const answer = response()

            recordResponse(session, answer)
            await Promise.all([...session.pendingBodies])

            const [entry] = session.responses
            assert.deepEqual(
                {
                    hasSent: Object.hasOwn(entry, "sentEnabled"),
                    sentEnabled: entry.sentEnabled,
                    parsed: entry.parsed,
                    reads: answer.reads,
                    pendingBodies: session.pendingBodies.size,
                },
                { ...expected, pendingBodies: 0 }
            )
        })
    }
})
