// The page check's login sends the fixture's credentials to the configured
// origin only: it refuses a navigation, page, document or login form off
// that origin, or a form that submits into another browsing context, before
// typing anything; blocks and fails any request or main-frame navigation off
// it, and fails and closes any target opened beside the page, until /home
// is reached; and never repeats the password in an error or a log line.
//
// The page is a stand-in that records what the login types and clicks, and
// raises Puppeteer's request and navigation events where a case needs them.
// Its `evaluate` runs the check's own in-page reader against a stand-in
// document, and every wait settles at once or on the guard's abort signal,
// so no outcome waits on a timer.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { test } from "node:test"

import {
    describeError,
    describeLocation,
    guardLoginOrigin,
    login,
} from "./portfolio-insights-page-check.mjs"

const ORIGIN = "http://app.test:20360"
const OTHER = "http://elsewhere.test:20379"
const USERNAME = "pi-login-holder"
/** Assembled at run time, so no scanner takes it for a credential. */
const PASSWORD = ["pi", "login", "canary", "5b1e"].join("-")
const NAV_HOME_TIMEOUT = "Waiting for selector `#nav-home` failed"
/** The browser context of the login's page, and that page's own target. */
const CONTEXT_ID = "context-login"
const OWN_TARGET_ID = "own-page"
/** Every step a login takes once nothing stops it. */
const ALL_STEPS = [
    ["type", "#login", USERNAME],
    ["type", "#password", PASSWORD],
    ["click", "#submitButton"],
]

/**
 * A login form whose page and form are on `origin`, submitting into
 * `target`, with `elements` swapped in.
 */
function loginDom(
    origin,
    { documentOrigin = origin, target = "", elements = {} } = {}
) {
    const form = { action: `${origin}/login`, target }
    return {
        origin: documentOrigin,
        elements: {
            "#login": {
                tagName: "INPUT",
                type: "text",
                form,
                formAction: `${origin}/login`,
            },
            "#password": {
                tagName: "INPUT",
                type: "password",
                form,
                formAction: `${origin}/login`,
            },
            "#submitButton": {
                tagName: "BUTTON",
                type: "submit",
                form,
                formAction: `${origin}/login`,
                formTarget: "",
            },
            ...elements,
        },
    }
}

/**
 * A Puppeteer page stand-in. `redirects` and `finalUrl` make the response
 * `goto` answers, `noResponse` makes it answer none; `pageUrl` and `dom`
 * are where the login form is found. `onType`, `onClick`, `whileWaiting`
 * and `whileReleasing` raise events while the login types, clicks, waits
 * for #nav-home, which appears only when `reachesHome` is true, and stops
 * intercepting requests. `failInterception` names the
 * interception state, `true` or `false`, whose setting throws. The page
 * sits in browser context `contextId`, where the targets of `openBefore`
 * are open before the login starts; a browser-level attach reports them
 * and those `openTarget` adds, and a browser-level interception pauses
 * what `pause` sends, `whileStopping` raising events as that interception
 * stops. `failHold` names the attach state, `true` or `false`, whose
 * setting throws, and `failFetch` the Fetch command that throws; without
 * `childSessions`, no attached target has a session to resume it through.
 */
function fakePage({
    redirects = [],
    finalUrl = `${ORIGIN}/`,
    noResponse = false,
    pageUrl = `${ORIGIN}/login`,
    dom = loginDom(ORIGIN),
    formRead,
    onType = {},
    onClick = () => {},
    whileWaiting = () => {},
    whileReleasing = () => {},
    reachesHome = true,
    failInterception = null,
    contextId = CONTEXT_ID,
    openBefore = [],
    failHold = null,
    failFetch = null,
    whileStopping = () => {},
    childSessions = true,
} = {}) {
    const listeners = new Map()
    /** Every target `openTarget` opened, by id, and whether closing throws. */
    const targets = new Map()
    const attached = (targetId, type, context, waitingForDebugger) =>
        page.emit("Target.attachedToTarget", {
            sessionId: `session:${targetId}`,
            targetInfo: { targetId, type, browserContextId: context },
            waitingForDebugger,
        })
    const actOn = (sessionId, action) =>
        targets
            .get(sessionId.slice("session:".length))
            ?.outcome.actions.push(action)
    const browserSession = {
        on: (event, handler) => page.on(event, handler),
        off: (event, handler) => page.off(event, handler),
        connection: () => ({
            session: (sessionId) =>
                childSessions
                    ? { send: async () => actOn(sessionId, "resumed") }
                    : null,
        }),
        send: async (method, params) => {
            if (method === "Target.setAutoAttach") {
                // As Chrome answers a browser-level attach, to start or stop.
                if (params.flatten !== true) {
                    throw new Error(
                        "Only flatten protocol is supported with browser level auto-attach"
                    )
                }
                page.hold.push(params.autoAttach)
                if (failHold === params.autoAttach) {
                    throw new Error(
                        `Protocol error: setAutoAttach ${params.autoAttach}`
                    )
                }
                page.holding = params.autoAttach
                if (params.autoAttach) {
                    attached(OWN_TARGET_ID, "page", contextId, false)
                    for (const [targetId, { outcome }] of targets) {
                        attached(targetId, outcome.type, outcome.context, false)
                    }
                }
            } else if (method === "Target.closeTarget") {
                const target = targets.get(params.targetId)
                if (target.closeFails) {
                    throw new Error("Target closed")
                }
                target.outcome.actions.push("closed")
            } else if (method === "Target.detachFromTarget") {
                actOn(params.sessionId, "left")
            } else if (method.startsWith("Fetch.")) {
                if (failFetch === method) {
                    throw new Error(`Protocol error: ${method}`)
                }
                if (method === "Fetch.disable") {
                    whileStopping(page)
                }
                const action = {
                    "Fetch.continueRequest": "continue",
                    "Fetch.failRequest": `fail:${params?.errorReason}`,
                }[method]
                page.paused[params?.requestId]?.push(action)
            }
            return {}
        },
        detach: async () => {
            page.holdDetached = true
        },
    }
    const page = {
        steps: [],
        interception: [],
        requests: [],
        /** What became of each target `openTarget` opened, in order. */
        opened: [],
        /** How each request `pause` paused was resolved, in order. */
        paused: [],
        /** Each browser-level attach the guard started or stopped. */
        hold: [],
        holding: false,
        holdDetached: false,
        intercepting: false,
        currentUrl: pageUrl,
        listenerCount: () =>
            [...listeners.values()].reduce((sum, set) => sum + set.size, 0),
        on(event, handler) {
            if (!listeners.has(event)) {
                listeners.set(event, new Set())
            }
            listeners.get(event).add(handler)
        },
        off(event, handler) {
            listeners.get(event)?.delete(handler)
        },
        emit(event, value) {
            for (const handler of listeners.get(event) ?? []) {
                handler(value)
            }
        },
        /** Raises a request as Puppeteer does, and returns it. */
        request(
            url,
            {
                method = "GET",
                resourceType = "fetch",
                action = page.intercepting ? "none" : "disabled",
                rejects = false,
            } = {}
        ) {
            const resolutions = []
            const resolve = (resolution) => {
                resolutions.push(resolution)
                return rejects
                    ? Promise.reject(new Error("Target closed"))
                    : Promise.resolve()
            }
            const request = {
                resolutions,
                url: () => url,
                method: () => method,
                resourceType: () => resourceType,
                interceptResolutionState: () => ({ action }),
                continue: () => resolve("continue"),
                abort: (code) => resolve(`abort:${code}`),
            }
            page.requests.push(request)
            page.emit("request", request)
            return request
        },
        /** Raises a navigation of the main frame, or of a child frame. */
        navigate(url, { main = true } = {}) {
            if (main) {
                page.currentUrl = url
            }
            page.emit("framenavigated", {
                parentFrame: () => (main ? null : {}),
                url: () => url,
            })
        },
        /**
         * Opens a target of `type` in browser context `context`, which a
         * browser-level attach then holding reports paused on its start.
         * Closing it throws when `closeFails` is true.
         */
        openTarget({
            type = "page",
            context = contextId,
            closeFails = false,
        } = {}) {
            const targetId = `target-${targets.size + 1}`
            const outcome = { type, context, actions: [] }
            page.opened.push(outcome)
            targets.set(targetId, { outcome, closeFails })
            if (page.holding) {
                attached(targetId, type, context, true)
            }
        },
        /** Pauses a request with `headers` at browser level, as Fetch does. */
        pause(headers = {}) {
            const requestId = page.paused.length
            page.paused.push([])
            page.emit("Fetch.requestPaused", {
                requestId,
                request: { url: `${ORIGIN}/worker.js`, headers },
            })
        },
        browserContext: () => ({ id: contextId }),
        createCDPSession: async () => ({
            send: async () => ({ targetInfo: { targetId: OWN_TARGET_ID } }),
            detach: async () => {},
        }),
        browser: () => ({
            target: () => ({ createCDPSession: async () => browserSession }),
        }),
        goto: async () =>
            noResponse
                ? null
                : {
                      url: () => finalUrl,
                      request: () => ({
                          redirectChain: () =>
                              redirects.map((url) => ({ url: () => url })),
                      }),
                  },
        url: () => page.currentUrl,
        evaluate: async (read, ...args) => {
            if (formRead !== undefined) {
                return formRead
            }
            const saved = Object.getOwnPropertyDescriptors(globalThis)
            globalThis.document = {
                querySelector: (selector) => dom.elements[selector] ?? null,
            }
            globalThis.location = { origin: dom.origin }
            try {
                return structuredClone(read(...args))
            } finally {
                for (const name of ["document", "location"]) {
                    if (name in saved) {
                        Object.defineProperty(globalThis, name, saved[name])
                    } else {
                        delete globalThis[name]
                    }
                }
            }
        },
        setRequestInterception: async (value) => {
            page.interception.push(value)
            if (failInterception === value) {
                throw new Error(`Protocol error: interception ${value}`)
            }
            page.intercepting = value
            if (!value) {
                whileReleasing(page)
            }
        },
        type: async (selector, text) => {
            page.steps.push(["type", selector, text])
            onType[selector]?.(page)
        },
        click: async (selector) => {
            page.steps.push(["click", selector])
            onClick(page)
        },
        waitForSelector: async (selector, options = {}) => {
            if (selector !== "#nav-home") {
                return {}
            }
            const { signal } = options
            signal?.throwIfAborted()
            if (reachesHome) {
                whileWaiting(page)
                return {}
            }
            // As Puppeteer's wait does, an abort while waiting ends it with
            // the signal's reason; without one, the wait runs out.
            return new Promise((resolve, reject) => {
                signal?.addEventListener("abort", () => reject(signal.reason), {
                    once: true,
                })
                whileWaiting(page)
                reject(new Error(NAV_HOME_TIMEOUT))
            })
        },
    }
    for (const target of openBefore) {
        page.openTarget(target)
    }
    return page
}

function sessionOf(page) {
    return {
        page,
        account: { username: USERNAME, password: PASSWORD },
        toasts: [],
    }
}

/**
 * Runs the login on `page` with console.error recorded, and returns what a
 * case asserts: the error message, if any, the steps taken, the
 * interception states set, the listeners left and whether the password
 * appears in the error, the line `main` prints for it, or any log line.
 */
async function runLogin(t, page) {
    const logged = t.mock.method(console, "error", () => {})
    let error = null
    try {
        await login(sessionOf(page), ORIGIN)
    } catch (caught) {
        error = caught
    }
    const texts = [
        ...logged.mock.calls.map((call) => call.arguments.join(" ")),
        ...(error === null ? [] : [error.message, describeError(error)]),
    ]
    return {
        message: error?.message ?? null,
        steps: page.steps,
        interception: page.interception,
        listenersLeft: page.listenerCount(),
        repeatsPassword: texts.some((text) =>
            text.toLowerCase().includes(PASSWORD.toLowerCase())
        ),
    }
}

test("login_sameOrigin_typesAndSubmitsCredentials", async (t) => {
    const page = fakePage({
        onType: {
            "#login": (p) => p.request("data:image/png;base64,AAAA"),
        },
        onClick: (p) => {
            p.request(`${ORIGIN}/user-service/api/auth/login`, {
                method: "POST",
            })
            p.navigate(`${ORIGIN}/home`)
            p.navigate(`${OTHER}/widget`, { main: false })
        },
    })
    const outcome = await runLogin(t, page)
    assert.deepEqual(
        {
            ...outcome,
            resolutions: page.requests.map((request) => request.resolutions),
        },
        {
            message: null,
            steps: ALL_STEPS,
            interception: [true, false],
            listenersLeft: 0,
            repeatsPassword: false,
            resolutions: [["continue"], ["continue"]],
        }
    )
})

/** Forms that submit into the page's own browsing context by name. */
const SELF_TARGETS = [
    { scenario: "formTargetSelf", dom: loginDom(ORIGIN, { target: "_self" }) },
    {
        scenario: "buttonFormTargetSelfInUpperCase",
        dom: loginDom(ORIGIN, {
            elements: {
                "#submitButton": {
                    tagName: "BUTTON",
                    type: "submit",
                    form: { action: `${ORIGIN}/login`, target: "" },
                    formAction: `${ORIGIN}/login`,
                    formTarget: "_SELF",
                },
            },
        }),
    },
    {
        scenario: "baseTargetSelf",
        dom: loginDom(ORIGIN, {
            elements: { "base[target]": { target: "_self" } },
        }),
    },
]

for (const { scenario, dom } of SELF_TARGETS) {
    test(`login_${scenario}_typesAndSubmitsCredentials`, async (t) => {
        assert.deepEqual(await runLogin(t, fakePage({ dom })), {
            message: null,
            steps: ALL_STEPS,
            interception: [true, false],
            listenersLeft: 0,
            repeatsPassword: false,
        })
    })
}

const REFUSED = `login as ${USERNAME} refused before entering credentials`
/** The refusal of a form that submits into another window or frame. */
const OTHER_CONTEXT =
    "its form submits into a browsing context other than the page's own"

/** Pages whose navigation, page, document or form is off the origin. */
const REFUSALS = [
    {
        scenario: "redirectedOffOrigin",
        page: { redirects: [`${ORIGIN}/`], finalUrl: `${OTHER}/?next=1` },
        reason: `the navigation to ${ORIGIN} was redirected to ${OTHER}/`,
        interception: [],
    },
    {
        scenario: "redirectedThroughAnotherOrigin",
        page: { redirects: [`${ORIGIN}/`, `${OTHER}/bounce?token=1#x`] },
        reason: `the navigation to ${ORIGIN} was redirected to ${OTHER}/bounce`,
        interception: [],
    },
    {
        scenario: "pageLeftOrigin",
        page: {
            noResponse: true,
            pageUrl: `${OTHER}/login`,
            dom: loginDom(OTHER),
        },
        reason: `the page is on ${OTHER}/login, not ${ORIGIN}; its document is on ${OTHER}/, not ${ORIGIN}; its form submits to ${OTHER}/login, not ${ORIGIN}`,
        interception: [true, false],
    },
    {
        scenario: "documentOnAnotherOrigin",
        page: { dom: loginDom(ORIGIN, { documentOrigin: OTHER }) },
        reason: `its document is on ${OTHER}/, not ${ORIGIN}`,
        interception: [true, false],
    },
    {
        scenario: "documentOriginOpaque",
        page: { dom: loginDom(ORIGIN, { documentOrigin: "null" }) },
        reason: `its document is on an opaque origin, not ${ORIGIN}`,
        interception: [true, false],
    },
    {
        scenario: "formSubmitsOffOrigin",
        page: {
            dom: loginDom(ORIGIN, {
                elements: {
                    "#password": {
                        tagName: "INPUT",
                        type: "password",
                        form: { action: `${OTHER}/collect?user=1` },
                        formAction: `${OTHER}/collect?user=1`,
                    },
                },
            }),
        },
        reason: `its form submits to ${OTHER}/collect, not ${ORIGIN}`,
        interception: [true, false],
    },
    {
        scenario: "buttonFormActionOffOrigin",
        page: {
            dom: loginDom(ORIGIN, {
                elements: {
                    "#submitButton": {
                        tagName: "BUTTON",
                        type: "submit",
                        form: { action: `${ORIGIN}/login` },
                        formAction: "javascript:void 0",
                    },
                },
            }),
        },
        reason: `its form submits to a javascript: URL, not ${ORIGIN}`,
        interception: [true, false],
    },
    {
        scenario: "formTargetsNewWindow",
        page: { dom: loginDom(ORIGIN, { target: "_blank" }) },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "formTargetsTopWindow",
        page: { dom: loginDom(ORIGIN, { target: "_top" }) },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "formTargetsNamedWindow",
        page: { dom: loginDom(ORIGIN, { target: PASSWORD }) },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "buttonFormTargetsNewWindow",
        page: {
            dom: loginDom(ORIGIN, {
                elements: {
                    "#submitButton": {
                        tagName: "BUTTON",
                        type: "submit",
                        form: { action: `${ORIGIN}/login`, target: "" },
                        formAction: `${ORIGIN}/login`,
                        formTarget: "_blank",
                    },
                },
            }),
        },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "baseTargetsNewWindow",
        page: {
            dom: loginDom(ORIGIN, {
                elements: { "base[target]": { target: "_blank" } },
            }),
        },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "targetUnreadable",
        page: {
            formRead: {
                origin: ORIGIN,
                missing: [],
                masked: true,
                actions: [],
                targets: [null],
            },
        },
        reason: OTHER_CONTEXT,
        interception: [true, false],
    },
    {
        scenario: "passwordUnmasked",
        page: {
            dom: loginDom(ORIGIN, {
                elements: {
                    "#password": { tagName: "INPUT", type: "text" },
                },
            }),
        },
        reason: "#password is not a password input",
        interception: [true, false],
    },
    {
        scenario: "fieldsMissing",
        page: {
            dom: loginDom(ORIGIN, {
                elements: { "#password": null, "#submitButton": null },
            }),
        },
        reason: "it has no #password, #submitButton",
        interception: [true, false],
    },
    {
        scenario: "formUnreadable",
        page: { formRead: { origin: ORIGIN, missing: "#login" } },
        reason: "its login form could not be read",
        interception: [true, false],
    },
    {
        scenario: "targetsUnread",
        page: {
            formRead: {
                origin: ORIGIN,
                missing: [],
                masked: true,
                actions: [],
            },
        },
        reason: "its login form could not be read",
        interception: [true, false],
    },
]

for (const { scenario, page: options, reason, interception } of REFUSALS) {
    test(`login_${scenario}_refusesBeforeTyping`, async (t) => {
        assert.deepEqual(await runLogin(t, fakePage(options)), {
            message: `${REFUSED}: ${reason}`,
            steps: [],
            interception,
            listenersLeft: 0,
            repeatsPassword: false,
        })
    })
}

const BLOCKED = `login as ${USERNAME} refused: the page sent`
/** Holds the password in its host, path and query, as a page could. */
const LEAKING_URL = `http://${PASSWORD}.elsewhere.test/${PASSWORD}?p=${PASSWORD}`

/** Logins that leave the origin once the form is being filled in. */
const VIOLATIONS = [
    {
        scenario: "requestWhileTypingLogin",
        page: {
            onType: {
                "#login": (p) =>
                    p.request(LEAKING_URL, { resourceType: "image" }),
            },
        },
        message: `${BLOCKED} a GET image request to an origin other than ${ORIGIN} during the login; it was blocked`,
        steps: ALL_STEPS.slice(0, 1),
        resolutions: [["abort:blockedbyclient"]],
    },
    {
        scenario: "requestOnSubmit",
        page: {
            onClick: (p) => p.request(`${OTHER}/steal`, { method: "POST" }),
        },
        message: `${BLOCKED} a POST fetch request to an origin other than ${ORIGIN} during the login; it was blocked`,
        steps: ALL_STEPS,
        resolutions: [["abort:blockedbyclient"]],
    },
    {
        scenario: "requestNotInterceptable",
        page: {
            onClick: (p) =>
                p.request(LEAKING_URL, {
                    method: "post ",
                    resourceType: "Ping!",
                    action: "disabled",
                }),
        },
        message: `${BLOCKED} a non-standard other request to an origin other than ${ORIGIN} during the login; it could not be blocked`,
        steps: ALL_STEPS,
        resolutions: [[]],
    },
    {
        scenario: "twoRequestsOnSubmit",
        page: {
            onClick: (p) => {
                p.request(`${OTHER}/a`, { method: "POST" })
                p.request(`${OTHER}/b`, { method: "POST" })
            },
        },
        message: `${BLOCKED} a POST fetch request to an origin other than ${ORIGIN} during the login; it was blocked; 1 further violation`,
        steps: ALL_STEPS,
        resolutions: [["abort:blockedbyclient"], ["abort:blockedbyclient"]],
    },
    {
        scenario: "mainFrameLeftOnSubmit",
        page: { onClick: (p) => p.navigate(LEAKING_URL) },
        message: `login as ${USERNAME} refused: the page's main frame left ${ORIGIN} during the login`,
        steps: ALL_STEPS,
        resolutions: [],
    },
    {
        scenario: "requestWhileWaitingForHome",
        page: {
            reachesHome: false,
            whileWaiting: (p) => p.request(LEAKING_URL),
        },
        message: `${BLOCKED} a GET fetch request to an origin other than ${ORIGIN} during the login; it was blocked`,
        steps: ALL_STEPS,
        resolutions: [["abort:blockedbyclient"]],
    },
    {
        scenario: "requestAsHomeAppears",
        page: { whileWaiting: (p) => p.request(LEAKING_URL) },
        message: `${BLOCKED} a GET fetch request to an origin other than ${ORIGIN} during the login; it was blocked`,
        steps: ALL_STEPS,
        resolutions: [["abort:blockedbyclient"]],
    },
]

for (const {
    scenario,
    page: options,
    message,
    steps,
    resolutions,
} of VIOLATIONS) {
    test(`login_${scenario}_failsAndBlocksIt`, async (t) => {
        const page = fakePage(options)
        const outcome = await runLogin(t, page)
        assert.deepEqual(
            {
                ...outcome,
                resolutions: page.requests.map(
                    (request) => request.resolutions
                ),
            },
            {
                message,
                steps,
                interception: [true, false],
                listenersLeft: 0,
                repeatsPassword: false,
                resolutions,
            }
        )
    })
}

/** The error of a login during which `kind` opened beside its page. */
function otherTarget(kind) {
    return `login as ${USERNAME} refused: ${kind} opened during the login, outside the page whose requests the login holds to ${ORIGIN}`
}

/** Logins during which a target opens, or is open, beside the page. */
const OTHER_TARGETS = [
    {
        scenario: "windowOpenedOnSubmit",
        page: { onClick: (p) => p.openTarget() },
        kind: "another page target",
        steps: ALL_STEPS,
        opened: [{ type: "page", context: CONTEXT_ID, actions: ["closed"] }],
    },
    {
        scenario: "windowOpenBeforeTheLogin",
        page: { openBefore: [{}] },
        kind: "another page target",
        steps: [],
        opened: [{ type: "page", context: CONTEXT_ID, actions: ["closed"] }],
    },
    {
        scenario: "sharedWorkerStartedWhileTypingLogin",
        page: {
            onType: {
                "#login": (p) => p.openTarget({ type: "shared_worker" }),
            },
        },
        kind: "another shared_worker target",
        steps: ALL_STEPS.slice(0, 1),
        opened: [
            { type: "shared_worker", context: CONTEXT_ID, actions: ["closed"] },
        ],
    },
    {
        scenario: "serviceWorkerRunningBeforeTheLogin",
        page: { openBefore: [{ type: "service_worker" }] },
        kind: "another service_worker target",
        steps: [],
        opened: [
            {
                type: "service_worker",
                context: CONTEXT_ID,
                actions: ["closed"],
            },
        ],
    },
    {
        scenario: "targetOfUnknownType",
        page: { onClick: (p) => p.openTarget({ type: "Odd Type" }) },
        kind: "another target",
        steps: ALL_STEPS,
        opened: [
            { type: "Odd Type", context: CONTEXT_ID, actions: ["closed"] },
        ],
    },
    {
        scenario: "windowCannotBeClosed",
        page: { onClick: (p) => p.openTarget({ closeFails: true }) },
        kind: "another page target",
        steps: ALL_STEPS,
        opened: [{ type: "page", context: CONTEXT_ID, actions: [] }],
    },
    {
        scenario: "windowOpenedAsHomeAppears",
        page: { whileWaiting: (p) => p.openTarget() },
        kind: "another page target",
        steps: ALL_STEPS,
        opened: [{ type: "page", context: CONTEXT_ID, actions: ["closed"] }],
    },
    {
        scenario: "windowOpenedAsTheGuardEnds",
        page: { whileReleasing: (p) => p.openTarget() },
        kind: "another page target",
        steps: ALL_STEPS,
        opened: [{ type: "page", context: CONTEXT_ID, actions: ["closed"] }],
    },
]

for (const { scenario, page: options, kind, steps, opened } of OTHER_TARGETS) {
    test(`login_${scenario}_failsAndClosesItWhenPossible`, async (t) => {
        const page = fakePage(options)
        const outcome = await runLogin(t, page)
        assert.deepEqual(
            { ...outcome, opened: page.opened },
            {
                message: otherTarget(kind),
                steps,
                interception: [true, false],
                listenersLeft: 0,
                repeatsPassword: false,
                opened,
            }
        )
    })
}

/**
 * Targets the hold leaves without failing the login: one in another
 * context, resumed when it can be, and a new service worker, which only
 * its script, blocked below, can stop.
 */
const LEFT_TARGETS = [
    {
        scenario: "windowInAnotherContext",
        page: {},
        target: { context: "context-other" },
        result: "resumesAndLeavesIt",
        actions: ["resumed", "left"],
    },
    {
        scenario: "windowInAnotherContextWithoutASession",
        page: { childSessions: false },
        target: { context: "context-other" },
        result: "leavesIt",
        actions: ["left"],
    },
    {
        scenario: "serviceWorkerStarting",
        page: {},
        target: { type: "service_worker" },
        result: "resumesAndLeavesIt",
        actions: ["resumed", "left"],
    },
]

for (const {
    scenario,
    page: options,
    target,
    result,
    actions,
} of LEFT_TARGETS) {
    test(`login_${scenario}_${result}`, async (t) => {
        const page = fakePage({
            ...options,
            onClick: (p) => p.openTarget(target),
        })
        const outcome = await runLogin(t, page)
        assert.deepEqual(
            { ...outcome, opened: page.opened },
            {
                message: null,
                steps: ALL_STEPS,
                interception: [true, false],
                listenersLeft: 0,
                repeatsPassword: false,
                opened: [
                    {
                        type: target.type ?? "page",
                        context: target.context ?? CONTEXT_ID,
                        actions,
                    },
                ],
            }
        )
    })
}

const SCRIPT_BLOCKED = `login as ${USERNAME} refused: a service worker's script was requested during the login, outside the page whose requests the login holds to ${ORIGIN}; it was blocked`

/** Requests the hold's browser-level interception pauses, and their end. */
const BROWSER_REQUESTS = [
    {
        scenario: "serviceWorkerRegisteredOnSubmit",
        page: {
            onClick: (p) => {
                p.openTarget({ type: "service_worker" })
                p.pause({ "Service-Worker": "script" })
            },
        },
        result: "failsAndBlocksTheScript",
        message: SCRIPT_BLOCKED,
        paused: [["fail:BlockedByClient"]],
    },
    {
        scenario: "serviceWorkerHeaderInLowerCase",
        page: { onClick: (p) => p.pause({ "service-worker": "script" }) },
        result: "failsAndBlocksTheScript",
        message: SCRIPT_BLOCKED,
        paused: [["fail:BlockedByClient"]],
    },
    {
        scenario: "otherRequest",
        page: { onClick: (p) => p.pause({ Accept: "*/*" }) },
        result: "continuesIt",
        message: null,
        paused: [["continue"]],
    },
    {
        scenario: "requestPausedAsTheHoldStops",
        page: { whileStopping: (p) => p.pause() },
        result: "leavesItToTheEndOfInterception",
        message: null,
        paused: [[]],
    },
]

for (const {
    scenario,
    page: options,
    result,
    message,
    paused,
} of BROWSER_REQUESTS) {
    test(`login_${scenario}_${result}`, async (t) => {
        const page = fakePage(options)
        const outcome = await runLogin(t, page)
        assert.deepEqual(
            { ...outcome, paused: page.paused },
            {
                message,
                steps: ALL_STEPS,
                interception: [true, false],
                listenersLeft: 0,
                repeatsPassword: false,
                paused,
            }
        )
    })
}

test("login_homeNeverReached_keepsTheNavHomeDiagnostic", async (t) => {
    const outcome = await runLogin(t, fakePage({ reachesHome: false }))
    assert.deepEqual(outcome, {
        message: `login as ${USERNAME} never reached #nav-home: ${NAV_HOME_TIMEOUT}`,
        steps: ALL_STEPS,
        interception: [true, false],
        listenersLeft: 0,
        repeatsPassword: false,
    })
})

/** A guard that cannot stop, after a login that passed or was refused. */
const RELEASE_FAILURES = [
    {
        scenario: "AfterSignIn",
        page: {},
        message: "Protocol error: interception false",
        steps: ALL_STEPS,
    },
    {
        scenario: "AfterRefusal",
        page: { dom: loginDom(ORIGIN, { documentOrigin: OTHER }) },
        message: `${REFUSED}: its document is on ${OTHER}/, not ${ORIGIN}`,
        steps: [],
    },
]

for (const { scenario, page: options, message, steps } of RELEASE_FAILURES) {
    test(`login_interceptionCannotStop${scenario}_reportsTheFirstError`, async (t) => {
        const page = fakePage({ ...options, failInterception: false })
        assert.deepEqual(await runLogin(t, page), {
            message,
            steps,
            interception: [true, false],
            listenersLeft: 0,
            repeatsPassword: false,
        })
    })
}

/** A browser-level hold that cannot stop after a login that passed. */
const HOLD_STOP_FAILURES = [
    {
        scenario: "targetHoldCannotStop",
        page: { failHold: false },
        message: "Protocol error: setAutoAttach false",
        hold: [true, false],
    },
    {
        scenario: "requestPauseCannotStop",
        page: { failFetch: "Fetch.disable" },
        message: "Protocol error: Fetch.disable",
        hold: [true],
    },
]

for (const { scenario, page: options, message, hold } of HOLD_STOP_FAILURES) {
    test(`login_${scenario}_reportsItsErrorAndDetaches`, async (t) => {
        const page = fakePage(options)
        assert.deepEqual(
            {
                ...(await runLogin(t, page)),
                hold: page.hold,
                holdDetached: page.holdDetached,
            },
            {
                message,
                steps: ALL_STEPS,
                interception: [true, false],
                listenersLeft: 0,
                repeatsPassword: false,
                hold,
                holdDetached: true,
            }
        )
    })
}

/** Guards whose start fails, and what each had begun. */
const START_FAILURES = [
    {
        scenario: "interceptionCannotStart",
        page: { failInterception: true },
        message: "Protocol error: interception true",
        hold: [],
        holdDetached: false,
    },
    {
        scenario: "targetsCannotBeHeld",
        page: { failHold: true },
        message: "Protocol error: setAutoAttach true",
        hold: [true],
        holdDetached: true,
    },
    {
        scenario: "requestsCannotBePaused",
        page: { failFetch: "Fetch.enable" },
        message: "Protocol error: Fetch.enable",
        hold: [true],
        holdDetached: true,
    },
    {
        scenario: "pageInNoContextOfItsOwn",
        page: { contextId: null },
        message: "the login's page has no browser context of its own",
        hold: [],
        holdDetached: false,
    },
]

for (const {
    scenario,
    page: options,
    message,
    hold,
    holdDetached,
} of START_FAILURES) {
    test(`guardLoginOrigin_${scenario}_removesListenersAndRethrows`, async (t) => {
        t.mock.method(console, "error", () => {})
        const page = fakePage(options)
        let caught = null
        try {
            await guardLoginOrigin(page, ORIGIN)
        } catch (error) {
            caught = error.message
        }
        assert.deepEqual(
            {
                message: caught,
                interception: page.interception,
                listenersLeft: page.listenerCount(),
                hold: page.hold,
                holdDetached: page.holdDetached,
            },
            {
                message,
                interception: [true, false],
                listenersLeft: 0,
                hold,
                holdDetached,
            }
        )
    })
}

/** Requests the guard leaves without a violation, and how it resolves them. */
const ALLOWED_REQUESTS = [
    {
        scenario: "alreadyHandled",
        url: `${ORIGIN}/user-service/api/auth/login`,
        options: { action: "already-handled" },
        resolutions: [],
        logged: 0,
    },
    {
        scenario: "resolutionRejects",
        url: `${ORIGIN}/user-service/api/auth/login`,
        options: { rejects: true },
        resolutions: ["continue"],
        logged: 1,
    },
]

for (const {
    scenario,
    url,
    options,
    resolutions,
    logged,
} of ALLOWED_REQUESTS) {
    test(`guardLoginOrigin_${scenario}_resolvesAtMostOnceWithoutViolation`, async (t) => {
        const errors = t.mock.method(console, "error", () => {})
        const page = fakePage()
        const guard = await guardLoginOrigin(page, ORIGIN)
        const request = page.request(url, options)
        await guard.release()
        assert.deepEqual(
            {
                resolutions: request.resolutions,
                violations: guard.violations,
                aborted: guard.signal.aborted,
                logged: errors.mock.callCount(),
            },
            { resolutions, violations: [], aborted: false, logged }
        )
    })
}

const LOCATIONS = [
    {
        scenario: "queryAndFragment",
        text: `${OTHER}/a/b?password=1#c`,
        expected: `${OTHER}/a/b`,
    },
    {
        scenario: "dataUrl",
        text: "data:text/html,<p>",
        expected: "a data: URL",
    },
    {
        scenario: "notAUrl",
        text: "not a url",
        expected: "an address that is not a URL",
    },
    {
        scenario: "notAString",
        text: undefined,
        expected: "an address that is not a URL",
    },
    { scenario: "opaqueOrigin", text: "null", expected: "an opaque origin" },
    {
        scenario: "longPath",
        text: `${OTHER}/${"p".repeat(300)}`,
        expected: `${`${OTHER}/${"p".repeat(300)}`.slice(0, 199)}…`,
    },
]

for (const { scenario, text, expected } of LOCATIONS) {
    test(`describeLocation_${scenario}_namesOriginAndPathOnly`, () => {
        assert.equal(describeLocation(text), expected)
    })
}
