/* global document, window, MutationObserver, location */
/**
 * Browser check of the Portfolio Insights page against the broker responses
 * the page itself received: the figures and allocations it shows, its empty
 * state, one Toast per triggered alert arming, re-arming, acknowledging, and
 * the shutdown once the `portfolio-insights-enabled` flag turns off.
 *
 * Usage, from src/loadgen after `npm ci`:
 *
 *     node verification/portfolio-insights-page-check.mjs --base-url URL
 *         --mode flag-off|flag-on --fixture FILE --evidence-dir DIR
 *
 * Every option is required, and no environment variable is read. The flag
 * must already be in the state the mode names: `false` for flag-off and
 * `true` for flag-on. flag-on turns it off for its last check and on again.
 *
 * Fixture, written by scripts/portfolio-insights/e2e.sh:
 *
 *     { "evaluationIntervalSeconds": 60,
 *       "holder": { "username": "…", "password": "…", "accountId": "<uuid>" },
 *       "empty": { "username": "…", "password": "…", "accountId": "<uuid>" },
 *       "alerts": [ { "id": "<uuid>", "pair": "target_price",
 *                     "type": "TARGET_PRICE", "direction": "ABOVE",
 *                     "threshold": "123.45", "armingRevision": 1 } ] }
 *
 * - `evaluationIntervalSeconds`: optional positive integer, 60 by default.
 * - flag-off needs `holder`; `empty` is optional and `alerts` is ignored.
 * - flag-on needs `holder`, `empty` and exactly four `alerts`: for each pair,
 *   `target_price` (type `TARGET_PRICE`) and `profit_loss` (`PROFIT_LOSS`),
 *   one `ABOVE` and one `BELOW` member.
 *
 * Passwords are never printed or written.
 *
 * Output: one `PASS <check>` or `FAIL <check>: <reason>` line per check, and
 * `portfolio-insights-page-check-<mode>.json` plus screenshots in the
 * evidence directory.
 *
 * Exit codes: 0 when every check passed; 1 when a check or the setup failed;
 * 2 on a usage or fixture error.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { parseArgs } from "node:util"

const USAGE =
    "Usage: node verification/portfolio-insights-page-check.mjs --base-url URL --mode flag-off|flag-on --fixture FILE --evidence-dir DIR"

const OPTIONS = {
    "base-url": { type: "string" },
    mode: { type: "string" },
    fixture: { type: "string" },
    "evidence-dir": { type: "string" },
}

const MODES = ["flag-off", "flag-on"]

const FLAG_ID = "portfolio-insights-enabled"
const FLAG_PATH = `/feature-flag-service/v1/flags/${FLAG_ID}`
const INSIGHTS_PATH_PREFIX = "/broker-service/v1/portfolio/insights/"
const ALERTS_PATH = "/broker-service/v1/alerts"
const NOTIFICATIONS_PATH = `${ALERTS_PATH}/notifications`
/** `PATCH /alerts/{id}` and `POST /alerts/{id}/acknowledge`. */
const ALERT_ID_PATH =
    /^\/broker-service\/v1\/alerts\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(\/acknowledge)?$/i

const UUID_PATTERN =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const THRESHOLD_PATTERN = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/

/** Fixture pair name → the alert type both of its members carry. */
const PAIR_TYPES = { target_price: "TARGET_PRICE", profit_loss: "PROFIT_LOSS" }
const DIRECTIONS = ["ABOVE", "BELOW"]
const DEFAULT_EVALUATION_INTERVAL_S = 60

const RISK_LABELS = { LOW: "Low", MEDIUM: "Medium", HIGH: "High" }

/** The text `AlertNotificationWatcher` gives a triggered-alert Toast. */
const TOAST_PATTERN =
    /^Alert triggered: (.+) (Price|P\/L) (above|below) (\S+) \(now (\S+)\)$/
const TOAST_TYPES = { Price: "TARGET_PRICE", "P/L": "PROFIT_LOSS" }
const TOAST_DIRECTIONS = { above: "ABOVE", below: "BELOW" }
/** A Toast threshold is the 8-place display rounding of the alert's. */
const THRESHOLD_TOLERANCE = 1e-8

const TRACE_HEADERS = ["traceparent", "x-dynatrace"]
const TRACE_CORRELATION_NOTE =
    "Browser-to-broker trace correlation needs a deployment monitored by OneAgent with RUM injected into the frontend. traceHeaders records what the browser sent on each insights request and is not asserted."

const VIEWPORT = { width: 1366, height: 900 }

/** Deadline of every navigation, login step and page selector wait. */
const PAGE_TIMEOUT_MS = 30_000
/** Deadline of the check's own flag read and write. */
const FLAG_REQUEST_TIMEOUT_MS = 10_000
/** Deadline for the page's first flag response. */
const FLAG_RESPONSE_TIMEOUT_MS = 15_000
/** Deadline for the client-side redirect of a direct /insights visit. */
const REDIRECT_TIMEOUT_MS = 15_000
/** Deadline for the page to render the last insights response it received. */
const RENDER_TIMEOUT_MS = 10_000
/** Reads abandoned because a newer insights response arrived meanwhile. */
const MAX_UNSTABLE_READS = 3
/** Deadline for response bodies still being read. */
const BODY_TIMEOUT_MS = 10_000
/** Notification polls awaited before the reload, and their deadline. */
const POLLS_BEFORE_RELOAD = 4
const POLLS_BEFORE_RELOAD_TIMEOUT_MS = 90_000
/** Notification polls awaited after the reload, and their deadline. */
const POLLS_AFTER_RELOAD = 2
const POLLS_AFTER_RELOAD_TIMEOUT_MS = 60_000
/** Deadline for the Toast of a triggered arming. */
const TOAST_TIMEOUT_MS = 10_000
/** Deadline for an alert row, its toggle and the PATCH a click sends. */
const ROW_TIMEOUT_MS = 20_000
/** Deadline for a notification item, its acknowledge response and removal. */
const ACKNOWLEDGE_TIMEOUT_MS = 20_000
/** Deadline for the first notification poll after the acknowledge click. */
const NEXT_POLL_TIMEOUT_MS = 25_000
/** Added to two evaluation intervals while re-armed alerts are awaited. */
const REARM_MARGIN_S = 30
/** Covers the page's 15 s flag poll and 2 s read deadline, with margin. */
const SHUTDOWN_TIMEOUT_MS = 30_000
/** After the shutdown, no notification request or Toast may occur for this. */
const ABSENCE_WINDOW_MS = 20_000
const POLL_INTERVAL_MS = 250

/** A bad command line or fixture; the run stops with exit code 2. */
class UsageError extends Error {
    constructor(message) {
        super(message)
        this.name = "UsageError"
    }
}

/** A bounded wait that ran out of time. */
class WaitTimeoutError extends Error {
    constructor(message) {
        super(message)
        this.name = "WaitTimeoutError"
    }
}

function pause(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * Polls `predicate` every `intervalMs` until it returns a truthy value, which
 * it resolves with, and throws a `WaitTimeoutError` naming `what` once
 * `timeoutMs` has passed without one. An error the predicate throws ends the
 * wait at once.
 */
async function waitFor(
    predicate,
    { timeoutMs, intervalMs = POLL_INTERVAL_MS, what }
) {
    const deadline = Date.now() + timeoutMs
    for (;;) {
        const value = await predicate()
        if (value) {
            return value
        }
        const remainingMs = deadline - Date.now()
        if (remainingMs <= 0) {
            throw new WaitTimeoutError(
                `timed out after ${timeoutMs} ms waiting for ${what}`
            )
        }
        await pause(Math.min(intervalMs, remainingMs))
    }
}

/**
 * Polls `violation` for `windowMs` and throws as soon as it returns the
 * description of something that must not happen in that window.
 */
async function observeAbsence(
    violation,
    { windowMs, intervalMs = POLL_INTERVAL_MS }
) {
    const deadline = Date.now() + windowMs
    for (;;) {
        const found = await violation()
        if (found) {
            throw new Error(found)
        }
        const remainingMs = deadline - Date.now()
        if (remainingMs <= 0) {
            return
        }
        await pause(Math.min(intervalMs, remainingMs))
    }
}

/** Runs `wait`; a timeout becomes a problem, any other error is rethrown. */
async function waitOrReport(problems, wait) {
    try {
        return await wait()
    } catch (error) {
        if (!(error instanceof WaitTimeoutError)) {
            throw error
        }
        problems.push(error.message)
        return null
    }
}

function parseBaseUrl(text) {
    let url
    try {
        url = new URL(text)
    } catch (error) {
        throw new UsageError(`--base-url is not a URL: ${error.message}`)
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
        throw new UsageError(
            `--base-url must be an http or https URL, not ${url.protocol}`
        )
    }
    if (url.username !== "" || url.password !== "") {
        throw new UsageError("--base-url must not carry credentials")
    }
    if (url.search !== "" || url.hash !== "") {
        throw new UsageError("--base-url must not carry a query or fragment")
    }
    // The frontend calls every service at its own origin and routes from
    // the root, so the app cannot be served below a path.
    if (url.pathname.replace(/\/+$/, "") !== "") {
        throw new UsageError(
            `--base-url must be the app's origin, without the path ${url.pathname}`
        )
    }
    return url.origin
}

function parseOptions(args) {
    let parsed
    try {
        parsed = parseArgs({ args, options: OPTIONS, strict: true })
    } catch (error) {
        throw new UsageError(error.message)
    }
    const { values } = parsed
    for (const name of Object.keys(OPTIONS)) {
        if (values[name] === undefined || values[name] === "") {
            throw new UsageError(`--${name} is required`)
        }
    }
    if (!MODES.includes(values.mode)) {
        throw new UsageError(
            `--mode must be ${MODES.join(" or ")}, not "${values.mode}"`
        )
    }
    return {
        baseUrl: parseBaseUrl(values["base-url"]),
        mode: values.mode,
        fixturePath: path.resolve(values.fixture),
        evidenceDir: path.resolve(values["evidence-dir"]),
    }
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
}

function isNonEmptyString(value) {
    return typeof value === "string" && value !== ""
}

function parseAccount(fixturePath, value, name) {
    if (!isPlainObject(value)) {
        throw new UsageError(`--fixture ${fixturePath} needs an object ${name}`)
    }
    for (const field of ["username", "password"]) {
        if (!isNonEmptyString(value[field])) {
            throw new UsageError(
                `--fixture ${fixturePath} needs a non-empty string ${name}.${field}`
            )
        }
    }
    if (
        typeof value.accountId !== "string" ||
        !UUID_PATTERN.test(value.accountId)
    ) {
        throw new UsageError(
            `--fixture ${fixturePath} needs a UUID ${name}.accountId`
        )
    }
    return {
        username: value.username,
        password: value.password,
        accountId: value.accountId.toLowerCase(),
    }
}

function parseAlert(fixturePath, alert, index) {
    const name = `alerts[${index}]`
    const invalid = (reason) =>
        new UsageError(`--fixture ${fixturePath}: ${name} ${reason}`)
    if (!isPlainObject(alert)) {
        throw invalid("must be an object")
    }
    if (typeof alert.id !== "string" || !UUID_PATTERN.test(alert.id)) {
        throw invalid("needs a UUID id")
    }
    if (
        typeof alert.pair !== "string" ||
        !Object.hasOwn(PAIR_TYPES, alert.pair)
    ) {
        throw invalid(`needs a pair of ${Object.keys(PAIR_TYPES).join(" or ")}`)
    }
    if (alert.type !== PAIR_TYPES[alert.pair]) {
        throw invalid(
            `of pair ${alert.pair} needs type ${PAIR_TYPES[alert.pair]}`
        )
    }
    if (!DIRECTIONS.includes(alert.direction)) {
        throw invalid(`needs a direction of ${DIRECTIONS.join(" or ")}`)
    }
    if (
        typeof alert.threshold !== "string" ||
        !THRESHOLD_PATTERN.test(alert.threshold)
    ) {
        throw invalid("needs a plain decimal string threshold")
    }
    if (!Number.isInteger(alert.armingRevision) || alert.armingRevision < 1) {
        throw invalid("needs an integer armingRevision of at least 1")
    }
    return {
        id: alert.id.toLowerCase(),
        pair: alert.pair,
        type: alert.type,
        direction: alert.direction,
        threshold: alert.threshold,
        armingRevision: alert.armingRevision,
    }
}

/** The four pair alerts, ordered by pair, then direction. */
function parseAlerts(fixturePath, value) {
    if (!Array.isArray(value) || value.length !== 4) {
        throw new UsageError(
            `--fixture ${fixturePath} needs exactly four alerts for flag-on`
        )
    }
    const alerts = value.map((alert, index) =>
        parseAlert(fixturePath, alert, index)
    )
    if (new Set(alerts.map((alert) => alert.id)).size !== alerts.length) {
        throw new UsageError(
            `--fixture ${fixturePath} needs four distinct alert ids`
        )
    }
    const ordered = []
    for (const pair of Object.keys(PAIR_TYPES)) {
        for (const direction of DIRECTIONS) {
            const members = alerts.filter(
                (alert) => alert.pair === pair && alert.direction === direction
            )
            if (members.length !== 1) {
                throw new UsageError(
                    `--fixture ${fixturePath} needs exactly one ${pair} ${direction} alert, not ${members.length}`
                )
            }
            ordered.push(members[0])
        }
    }
    return ordered
}

async function readFixture(fixturePath, mode) {
    let text
    try {
        text = await readFile(fixturePath, "utf8")
    } catch (error) {
        throw new UsageError(`cannot read --fixture: ${error.message}`)
    }
    let fixture
    try {
        fixture = JSON.parse(text.replace(/^\uFEFF/, ""))
    } catch {
        // The parser's message quotes the text around the error, which can
        // hold a password, so it is not repeated.
        throw new UsageError(`--fixture ${fixturePath} is not valid JSON`)
    }
    if (!isPlainObject(fixture)) {
        throw new UsageError(`--fixture ${fixturePath} must hold a JSON object`)
    }
    const evaluationIntervalSeconds =
        fixture.evaluationIntervalSeconds ?? DEFAULT_EVALUATION_INTERVAL_S
    if (
        !Number.isInteger(evaluationIntervalSeconds) ||
        evaluationIntervalSeconds <= 0
    ) {
        throw new UsageError(
            `--fixture ${fixturePath} needs a positive integer evaluationIntervalSeconds`
        )
    }
    const holder = parseAccount(fixturePath, fixture.holder, "holder")
    if (mode === "flag-off") {
        return {
            evaluationIntervalSeconds,
            holder,
            empty:
                fixture.empty === undefined
                    ? null
                    : parseAccount(fixturePath, fixture.empty, "empty"),
            alerts: [],
        }
    }
    return {
        evaluationIntervalSeconds,
        holder,
        empty: parseAccount(fixturePath, fixture.empty, "empty"),
        alerts: parseAlerts(fixturePath, fixture.alerts),
    }
}

/** Prints a check's `PASS` or `FAIL` line and records it in the report. */
function recordCheck(report, name, ok, reason, details) {
    report.checks.push({
        name,
        status: ok ? "PASS" : "FAIL",
        reason: ok ? null : reason,
        details,
        at: new Date().toISOString(),
    })
    console.log(ok ? `PASS ${name}` : `FAIL ${name}: ${reason}`)
    return ok
}

/**
 * Runs one check, which adds what it finds wrong to `problems` and what it
 * measured to `details`. An error it throws is one more problem, and the
 * details gathered up to then are kept. Never throws.
 */
async function runCheck(report, name, check) {
    const problems = []
    const details = {}
    try {
        await check(problems, details)
    } catch (error) {
        console.error(error)
        problems.push(error.message)
    }
    return recordCheck(
        report,
        name,
        problems.length === 0,
        problems.join("; "),
        details
    )
}

/** Adds a problem to `problems` unless `actual` equals `expected`. */
function expectEqual(problems, label, actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        problems.push(
            `${label} is ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
        )
    }
}

/** The flag in a flag-service response body, or `null` when it holds none. */
function parseFlagBody(text) {
    let flag
    try {
        flag = JSON.parse(text)
    } catch {
        // Not JSON, so not a flag; the caller reports the body.
        return null
    }
    return isPlainObject(flag) &&
        flag.id === FLAG_ID &&
        typeof flag.enabled === "boolean"
        ? flag
        : null
}

async function flagRequest(baseUrl, init) {
    const url = `${baseUrl}${FLAG_PATH}`
    const method = init.method ?? "GET"
    let response
    let text
    try {
        response = await fetch(url, {
            ...init,
            signal: AbortSignal.timeout(FLAG_REQUEST_TIMEOUT_MS),
        })
        text = await response.text()
    } catch (error) {
        // fetch reports a refused connection only as "fetch failed"; the
        // reason is its cause.
        throw new Error(
            `${method} ${url} failed: ${error.cause?.message ?? error.message}`,
            { cause: error }
        )
    }
    if (!response.ok) {
        throw new Error(
            `${method} ${url} answered HTTP ${response.status}: ${text}`
        )
    }
    const flag = parseFlagBody(text)
    if (flag === null) {
        throw new Error(
            `${method} ${url} answered HTTP ${response.status} without "${FLAG_ID}" and a boolean "enabled": ${text}`
        )
    }
    return flag
}

/** Reads the flag from the flag service, as the frontend does. */
async function readFlag(baseUrl) {
    return (await flagRequest(baseUrl, {})).enabled
}

/** Sets the flag and verifies the state the flag service answers with. */
async function setFlag(baseUrl, enabled) {
    const flag = await flagRequest(baseUrl, {
        method: "PUT",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ enabled }),
    })
    if (flag.enabled !== enabled) {
        throw new Error(
            `PUT ${FLAG_PATH} answered enabled ${flag.enabled}, expected ${enabled}`
        )
    }
    return flag
}

async function checkFlagState(problems, details, baseUrl, expected) {
    const enabled = await readFlag(baseUrl)
    Object.assign(details, { flagId: FLAG_ID, enabled, expected })
    expectEqual(problems, `${FLAG_ID} enabled`, enabled, expected)
}

let sequence = 0

/**
 * Orders the requests, responses and Toasts of every page as this process
 * receives them. Puppeteer delivers one page's network and binding events in
 * the order Chrome emits them, and a response's event precedes the Toast its
 * body causes, so a Toast is explained by the responses sequenced before it.
 */
function nextSequence() {
    sequence += 1
    return sequence
}

/** The kind of a page response the checks consume, or `null` for others. */
function classifyResponse(method, url) {
    const { pathname } = url
    if (pathname === FLAG_PATH) {
        return { kind: "flag", accountId: null, alertId: null }
    }
    if (pathname.startsWith(INSIGHTS_PATH_PREFIX)) {
        return {
            kind: "insights",
            accountId: pathname
                .slice(INSIGHTS_PATH_PREFIX.length)
                .toLowerCase(),
            alertId: null,
        }
    }
    const accountId = (url.searchParams.get("accountId") ?? "").toLowerCase()
    if (pathname === NOTIFICATIONS_PATH) {
        return { kind: "notifications", accountId, alertId: null }
    }
    if (pathname === ALERTS_PATH) {
        return method === "GET"
            ? { kind: "alertsList", accountId, alertId: null }
            : null
    }
    const match = ALERT_ID_PATH.exec(pathname)
    if (match === null) {
        return null
    }
    const alertId = match[1].toLowerCase()
    if (match[2] === undefined) {
        return method === "PATCH"
            ? { kind: "patch", accountId: null, alertId }
            : null
    }
    return method === "POST"
        ? { kind: "acknowledge", accountId: null, alertId }
        : null
}

/**
 * Records a response in arrival order at once and reads its JSON body in the
 * background; consumers use an entry once `parsed` is set or it is a 204.
 */
function recordResponse(session, response) {
    const url = new URL(response.url())
    const method = response.request().method()
    const classified = classifyResponse(method, url)
    if (classified === null) {
        return
    }
    const entry = {
        ...classified,
        url: response.url(),
        path: url.pathname,
        method,
        status: response.status(),
        at: Date.now(),
        seq: nextSequence(),
        body: undefined,
        parsed: false,
    }
    session.responses.push(entry)
    if (entry.status === 204) {
        return
    }
    const reading = response
        .json()
        .then(
            (body) => {
                entry.body = body
                entry.parsed = true
            },
            (error) => {
                entry.bodyError = error.message
            }
        )
        .finally(() => session.pendingBodies.delete(reading))
    session.pendingBodies.add(reading)
}

/**
 * Records when the page asks for notifications, and the trace headers of each
 * insights request as observed data only.
 */
function recordRequest(session, report, request) {
    const url = new URL(request.url())
    if (url.pathname === NOTIFICATIONS_PATH) {
        session.notificationRequests.push({
            seq: nextSequence(),
            at: Date.now(),
        })
    } else if (url.pathname.startsWith(INSIGHTS_PATH_PREFIX)) {
        const headers = request.headers()
        report.traceHeaders.push({
            account: session.label,
            path: url.pathname,
            at: new Date().toISOString(),
            headers: Object.fromEntries(
                TRACE_HEADERS.filter((name) => headers[name] !== undefined).map(
                    (name) => [name, headers[name]]
                )
            ),
        })
    }
}

/**
 * In every document of a page, before its own scripts: reports each Toast
 * as it is added. A Toast leaves the DOM after 4 s, so counting the visible
 * ones would miss some.
 */
function installToastRecorder() {
    const seen = new WeakSet()
    const record = (toast) => {
        if (seen.has(toast)) {
            return
        }
        seen.add(toast)
        const message = toast.querySelector(".toast-message")
        window
            .__recordToast({
                text: (message ?? toast).textContent.trim(),
                className: toast.className,
                url: location.pathname,
                at: Date.now(),
            })
            .catch((error) => console.error(error))
    }
    const visit = (node) => {
        // Only elements can be or hold a Toast.
        if (node.nodeType !== 1) {
            return
        }
        if (node.matches(".toast-container .toast")) {
            record(node)
        }
        for (const toast of node.querySelectorAll(".toast-container .toast")) {
            record(toast)
        }
    }
    new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                visit(node)
            }
        }
    }).observe(document.documentElement ?? document, {
        childList: true,
        subtree: true,
    })
}

/**
 * Opens a browser context and page of their own for `account`, so session
 * storage, the login and the notification tracker never leak between
 * accounts, and instruments the page before its first navigation.
 */
async function openSession(browser, report, label, account) {
    const context = await browser.createBrowserContext()
    const page = await context.newPage()
    const session = {
        label,
        account,
        context,
        page,
        toasts: [],
        responses: [],
        notificationRequests: [],
        pendingBodies: new Set(),
    }
    page.setDefaultTimeout(PAGE_TIMEOUT_MS)
    page.setDefaultNavigationTimeout(PAGE_TIMEOUT_MS)
    await page.setViewport(VIEWPORT)
    await page.exposeFunction("__recordToast", (entry) => {
        const toast = {
            account: label,
            text: String(entry.text),
            className: String(entry.className),
            url: String(entry.url),
            at: new Date(entry.at).toISOString(),
            seq: nextSequence(),
            alertId: null,
            armingRevision: null,
            key: null,
        }
        session.toasts.push(toast)
        report.toasts.push(toast)
    })
    await page.evaluateOnNewDocument(installToastRecorder)
    page.on("response", (response) => {
        try {
            recordResponse(session, response)
        } catch (error) {
            console.error(error)
        }
    })
    page.on("request", (request) => {
        try {
            recordRequest(session, report, request)
        } catch (error) {
            console.error(error)
        }
    })
    return session
}

async function launchBrowser(state) {
    const { default: puppeteer } = await import("puppeteer")
    // The check can run as root on a disposable host, where Chrome refuses
    // to start with its sandbox.
    state.browser = await puppeteer.launch({
        headless: true,
        args: ["--no-sandbox"],
    })
    return state.browser
}

/** Signs `session`'s account in through the login form, landing on /home. */
async function login(session, baseUrl) {
    const { page, account } = session
    await page.goto(baseUrl, { waitUntil: "domcontentloaded" })
    await page.waitForSelector("#login", { timeout: PAGE_TIMEOUT_MS })
    await page.type("#login", account.username)
    await page.type("#password", account.password)
    await page.click("#submitButton")
    try {
        await page.waitForSelector("#nav-home", { timeout: PAGE_TIMEOUT_MS })
    } catch (error) {
        const errorToasts = session.toasts
            .filter((toast) => toast.className.includes("toast-error"))
            .map((toast) => toast.text)
        throw new Error(
            `login as ${account.username} never reached #nav-home: ${error.message}` +
                (errorToasts.length > 0
                    ? `; error Toasts: ${errorToasts.join(" | ")}`
                    : ""),
            { cause: error }
        )
    }
}

function currentPath(page) {
    return new URL(page.url()).pathname
}

function isPresent(page, selector) {
    return page.evaluate(
        (sel) => document.querySelector(sel) !== null,
        selector
    )
}

async function waitForPath(page, pathname, timeoutMs) {
    try {
        await waitFor(() => currentPath(page) === pathname, {
            timeoutMs,
            what: `the page to reach ${pathname}`,
        })
    } catch (error) {
        if (error instanceof WaitTimeoutError) {
            error.message += `; it is on ${currentPath(page)}`
        }
        throw error
    }
}

/** Brings the account's page to the front on /insights. */
async function openInsightsPage(session) {
    const { page } = session
    await page.bringToFront()
    if (
        currentPath(page) === "/insights" &&
        (await isPresent(page, "#portfolio-insights"))
    ) {
        return
    }
    await page.waitForSelector("#nav-portfolio-insights", {
        timeout: PAGE_TIMEOUT_MS,
    })
    await page.click("#nav-portfolio-insights")
    await page.waitForSelector("#portfolio-insights", {
        timeout: PAGE_TIMEOUT_MS,
    })
}

/**
 * In the page: scrolls the enabled element `selector` to the middle of the
 * viewport and tells whether its centre is free of anything drawn over it.
 */
function isClickable(selector) {
    const element = document.querySelector(selector)
    if (element === null || element.disabled) {
        return false
    }
    element.scrollIntoView({ block: "center", inline: "center" })
    const box = element.getBoundingClientRect()
    const top = document.elementFromPoint(
        box.left + box.width / 2,
        box.top + box.height / 2
    )
    return top !== null && element.contains(top)
}

/**
 * Clicks `selector` once it is enabled and nothing covers it. The fixed
 * Toast stack in the bottom-right corner can cover an alert button, and a
 * click there would land on the Toast instead.
 */
async function clickWhenClear(page, selector, timeoutMs) {
    await waitFor(() => page.evaluate(isClickable, selector), {
        timeoutMs,
        what: `${selector} to be enabled and uncovered`,
    })
    await page.click(selector)
}

async function captureScreenshot(
    report,
    page,
    evidenceDir,
    fileName,
    problems
) {
    const file = path.join(evidenceDir, fileName)
    try {
        await page.screenshot({ path: file, fullPage: true })
        report.screenshots.push(file)
    } catch (error) {
        console.error(error)
        problems.push(`screenshot ${fileName} failed: ${error.message}`)
    }
}

/** Waits until every response body being read has been read. */
async function settleBodies(session) {
    await waitFor(() => session.pendingBodies.size === 0, {
        timeoutMs: BODY_TIMEOUT_MS,
        what: `the pending response bodies of the ${session.label} page`,
    })
}

/**
 * In the page: the strings `FormatterContext` gives each value, from the same
 * Intl options, so Chrome's own ICU produces them. `percent` values are in
 * percent, as the broker sends them, and are formatted as ratios.
 */
function formatInPage(values) {
    const currency = new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: "USD",
        minimumFractionDigits: 2,
    })
    const smallCurrency = new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: "USD",
        minimumSignificantDigits: 1,
    })
    const percent = new Intl.NumberFormat("en-US", {
        style: "percent",
        minimumFractionDigits: 2,
        signDisplay: "exceptZero",
    })
    return {
        currency: values.currency.map((n) =>
            (n < 0.01 ? smallCurrency : currency).format(n)
        ),
        percent: values.percent.map((p) => percent.format(p / 100)),
    }
}

function resultsOf(entry) {
    return isPlainObject(entry.body) && Array.isArray(entry.body.results)
        ? entry.body.results
        : []
}

function idOf(item) {
    return isPlainObject(item) && typeof item.id === "string"
        ? item.id.toLowerCase()
        : null
}

function isTriggered(item) {
    return item.triggeredAt !== null && item.triggeredAt !== undefined
}

function armingKey(id, armingRevision) {
    return `${id}:${armingRevision}`
}

/** The account's own notification responses whose body was read. */
function notificationEntries(session) {
    return session.responses.filter(
        (entry) =>
            entry.kind === "notifications" &&
            entry.parsed &&
            entry.accountId === session.account.accountId
    )
}

/** Every fixture arming a notification response showed as triggered. */
function triggeredArmings(session, alerts) {
    const ids = new Set(alerts.map((alert) => alert.id))
    const armings = new Map()
    for (const entry of notificationEntries(session)) {
        for (const item of resultsOf(entry)) {
            const id = idOf(item)
            const key = armingKey(id, item.armingRevision)
            if (!ids.has(id) || !isTriggered(item) || armings.has(key)) {
                continue
            }
            armings.set(key, {
                key,
                id,
                armingRevision: item.armingRevision,
                triggeredAt: item.triggeredAt,
                firstSeenAt: new Date(entry.at).toISOString(),
            })
        }
    }
    return armings
}

/** The fixture alert a Toast names, or `null` for any other Toast. */
function fixtureAlertOf(text, alerts) {
    const match = TOAST_PATTERN.exec(text)
    if (match === null) {
        return null
    }
    const type = TOAST_TYPES[match[2]]
    const direction = TOAST_DIRECTIONS[match[3]]
    const threshold = Number(match[4].replaceAll(",", ""))
    return (
        alerts.find((alert) => {
            const expected = Number(alert.threshold)
            // A double holds fewer than 8 places once a value nears 1e10,
            // so the tolerance grows with the magnitude there.
            const tolerance =
                THRESHOLD_TOLERANCE + Math.abs(expected) * Number.EPSILON * 8
            return (
                alert.type === type &&
                alert.direction === direction &&
                Math.abs(threshold - expected) <= tolerance
            )
        }) ?? null
    )
}

/**
 * Gives every Toast that names a fixture alert the arming it announced: the
 * revision of that alert in the last notification response, sequenced before
 * the Toast, that showed it triggered. A Toast no response explains keeps a
 * `null` key.
 */
function attributeToasts(session, alerts) {
    const entries = notificationEntries(session)
    for (const toast of session.toasts) {
        const alert = fixtureAlertOf(toast.text, alerts)
        if (alert === null) {
            continue
        }
        let armingRevision = null
        for (const entry of entries) {
            if (entry.seq > toast.seq) {
                break
            }
            const item = resultsOf(entry).find(
                (candidate) =>
                    idOf(candidate) === alert.id && isTriggered(candidate)
            )
            if (item !== undefined) {
                armingRevision = item.armingRevision
            }
        }
        toast.alertId = alert.id
        toast.armingRevision = armingRevision
        toast.key =
            armingRevision === null ? null : armingKey(alert.id, armingRevision)
    }
}

function toastCounts(session) {
    const counts = new Map()
    for (const toast of session.toasts) {
        if (toast.key !== null) {
            counts.set(toast.key, (counts.get(toast.key) ?? 0) + 1)
        }
    }
    return counts
}

/**
 * Waits for the Toast of every fixture arming shown as triggered, including
 * armings that trigger while it waits. A missing Toast is left to the count.
 */
async function waitForArmingToasts(session, alerts) {
    const awaited = new Set()
    for (;;) {
        const keys = [...triggeredArmings(session, alerts).keys()].filter(
            (key) => !awaited.has(key)
        )
        if (keys.length === 0) {
            return
        }
        for (const key of keys) {
            awaited.add(key)
            try {
                await waitFor(
                    () => {
                        if (session.pendingBodies.size > 0) {
                            return false
                        }
                        attributeToasts(session, alerts)
                        return session.toasts.some((toast) => toast.key === key)
                    },
                    { timeoutMs: TOAST_TIMEOUT_MS, what: `the Toast of ${key}` }
                )
            } catch (error) {
                // `expectOneToastPerArming` reports the arming's 0 Toasts.
                if (!(error instanceof WaitTimeoutError)) {
                    throw error
                }
            }
        }
    }
}

/**
 * Adds a problem for every triggered fixture arming without exactly one
 * Toast, and for every fixture Toast no notification response explains.
 */
async function expectOneToastPerArming(problems, session, alerts) {
    await settleBodies(session)
    attributeToasts(session, alerts)
    const armings = triggeredArmings(session, alerts)
    const counts = toastCounts(session)
    for (const key of armings.keys()) {
        const count = counts.get(key) ?? 0
        if (count !== 1) {
            problems.push(`arming ${key} has ${count} Toasts, expected 1`)
        }
    }
    for (const toast of session.toasts) {
        if (toast.alertId !== null && toast.key === null) {
            problems.push(
                `the Toast "${toast.text}" of alert ${toast.alertId} follows no notification showing it triggered`
            )
        }
    }
    return armings
}

/** In the page: the text of every insights figure and allocation cell. */
function readInsightsDom() {
    const text = (id) => {
        const element = document.getElementById(id)
        return element === null ? null : element.textContent.trim()
    }
    const table = document.getElementById("insights-allocations")
    return {
        totalValue: text("insights-total-value"),
        totalInvested: text("insights-total-invested"),
        unrealizedPnl: text("insights-unrealized-pnl"),
        unrealizedPnlPercent: text("insights-unrealized-pnl-percent"),
        largestPosition: text("insights-largest-position"),
        // textContent, not innerText: the badge is uppercased by CSS only.
        riskBadge: text("insights-risk-badge"),
        emptyState: document.getElementById("insights-empty-state") !== null,
        rows:
            table === null
                ? null
                : Array.from(table.querySelectorAll("tbody tr"), (row) =>
                      Array.from(row.querySelectorAll("td"), (cell) =>
                          cell.textContent.trim()
                      )
                  ),
    }
}

function isFiniteNumber(value) {
    return typeof value === "number" && Number.isFinite(value)
}

function isAllocation(value) {
    return (
        isPlainObject(value) &&
        typeof value.name === "string" &&
        ["quantity", "value", "percent"].every((field) =>
            isFiniteNumber(value[field])
        )
    )
}

/** Why `body` is not an insights response, or `null` when it is one. */
function insightsShapeProblem(body) {
    if (!isPlainObject(body)) {
        return "the insights response is not a JSON object"
    }
    for (const field of [
        "totalValue",
        "totalInvested",
        "unrealizedPnl",
        "unrealizedPnlPercent",
    ]) {
        if (!isFiniteNumber(body[field])) {
            return `the insights response has no numeric ${field}`
        }
    }
    if (
        !Array.isArray(body.allocations) ||
        !body.allocations.every(isAllocation)
    ) {
        return "the insights response has no valid allocations list"
    }
    if (body.largestPosition !== null && !isAllocation(body.largestPosition)) {
        return "the insights response has an invalid largestPosition"
    }
    if (
        body.riskLevel !== null &&
        !Object.hasOwn(RISK_LABELS, body.riskLevel)
    ) {
        return `the insights response has an unknown riskLevel ${JSON.stringify(body.riskLevel)}`
    }
    return null
}

/**
 * Compares what the page shows with the insights response `body`. Each
 * figure span and table cell holds only its formatted value, so their text
 * must equal it, which also rules out a missing sign that containment would
 * let through. The largest position holds a name and a percent, which must
 * both appear in it.
 */
async function compareInsights(page, dom, body) {
    const shapeProblem = insightsShapeProblem(body)
    if (shapeProblem !== null) {
        return { problems: [shapeProblem], pairs: [], response: body }
    }
    const { allocations, largestPosition } = body
    const formats = await page.evaluate(formatInPage, {
        currency: [
            body.totalValue,
            body.totalInvested,
            body.unrealizedPnl,
            ...allocations.map((allocation) => allocation.value),
        ],
        percent: [
            body.unrealizedPnlPercent,
            ...allocations.map((allocation) => allocation.percent),
            ...(largestPosition === null ? [] : [largestPosition.percent]),
        ],
    })
    const problems = []
    const pairs = []
    const compare = (
        element,
        actual,
        expected,
        matches = (a, e) => a === e
    ) => {
        const ok = matches(actual, expected)
        pairs.push({ element, dom: actual, expected, ok })
        if (!ok) {
            problems.push(
                `${element} shows ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
            )
        }
    }
    compare("#insights-total-value", dom.totalValue, formats.currency[0])
    compare("#insights-total-invested", dom.totalInvested, formats.currency[1])
    compare("#insights-unrealized-pnl", dom.unrealizedPnl, formats.currency[2])
    compare(
        "#insights-unrealized-pnl-percent",
        dom.unrealizedPnlPercent,
        formats.percent[0]
    )
    if (largestPosition !== null) {
        compare(
            "#insights-largest-position",
            dom.largestPosition,
            {
                name: largestPosition.name,
                percent: formats.percent[formats.percent.length - 1],
            },
            (actual, expected) =>
                typeof actual === "string" &&
                actual.includes(expected.name) &&
                actual.includes(`(${expected.percent})`)
        )
    }
    compare(
        "#insights-risk-badge",
        dom.riskBadge,
        body.riskLevel === null ? null : RISK_LABELS[body.riskLevel]
    )
    compare(
        "#insights-empty-state shown",
        dom.emptyState,
        allocations.length === 0
    )
    if (allocations.length === 0) {
        compare("#insights-allocations", dom.rows, null)
    } else {
        compare(
            "#insights-allocations row count",
            dom.rows === null ? null : dom.rows.length,
            allocations.length
        )
        allocations.forEach((allocation, index) => {
            const cells = dom.rows?.[index] ?? []
            const row = `#insights-allocations row ${index + 1}`
            compare(`${row} instrument`, cells[0] ?? null, allocation.name)
            compare(
                `${row} quantity`,
                cells[1] ?? null,
                allocation.quantity,
                (actual, expected) =>
                    typeof actual === "string" &&
                    actual !== "" &&
                    Number(actual.replaceAll(",", "")) === expected
            )
            compare(
                `${row} value`,
                cells[2] ?? null,
                formats.currency[3 + index]
            )
            compare(
                `${row} allocation`,
                cells[3] ?? null,
                formats.percent[1 + index]
            )
        })
    }
    return { problems, pairs, response: body }
}

/** The account's own insights responses, in arrival order. */
function insightsEntries(session) {
    return session.responses.filter(
        (entry) =>
            entry.kind === "insights" &&
            entry.accountId === session.account.accountId
    )
}

/**
 * Compares the page with the last insights response it received, polling
 * until the page has rendered that response. A read during which a newer
 * response arrived is repeated, at most `MAX_UNSTABLE_READS` times.
 */
async function compareWithLastInsights(session) {
    let unstableReads = 0
    let last = {
        problems: ["the page received no insights response"],
        pairs: [],
        response: null,
    }
    try {
        await waitFor(
            async () => {
                const entries = insightsEntries(session)
                const latest = entries[entries.length - 1]
                if (
                    latest === undefined ||
                    (!latest.parsed && latest.bodyError === undefined)
                ) {
                    return false
                }
                if (latest.status !== 200 || !latest.parsed) {
                    last = {
                        problems: [
                            `the last insights response answered HTTP ${latest.status}` +
                                (latest.bodyError === undefined
                                    ? ""
                                    : ` with an unreadable body: ${latest.bodyError}`),
                        ],
                        pairs: [],
                        response: null,
                    }
                    return false
                }
                const dom = await session.page.evaluate(readInsightsDom)
                if (insightsEntries(session).length !== entries.length) {
                    unstableReads += 1
                    if (unstableReads >= MAX_UNSTABLE_READS) {
                        throw new Error(
                            `unstable: a newer insights response arrived during each of ${unstableReads} reads`
                        )
                    }
                    return false
                }
                last = await compareInsights(session.page, dom, latest.body)
                return last.problems.length === 0
            },
            {
                timeoutMs: RENDER_TIMEOUT_MS,
                what: "the page to show its last insights response",
            }
        )
    } catch (error) {
        // On a timeout, `last` holds the mismatches of the final read.
        if (!(error instanceof WaitTimeoutError)) {
            throw error
        }
    }
    return { ...last, unstableReads }
}

async function checkPageEqualsResponse(
    problems,
    details,
    report,
    holder,
    evidenceDir
) {
    const { page } = holder
    await page.waitForSelector("#nav-portfolio-insights", {
        timeout: PAGE_TIMEOUT_MS,
    })
    await page.click("#nav-portfolio-insights")
    await page.waitForSelector("#insights-total-value", {
        timeout: PAGE_TIMEOUT_MS,
    })
    const comparison = await compareWithLastInsights(holder)
    report.compared.pageEqualsResponse = comparison
    details.unstableReads = comparison.unstableReads
    details.compared = comparison.pairs.length
    problems.push(...comparison.problems)
    await captureScreenshot(
        report,
        page,
        evidenceDir,
        "insights-page.png",
        problems
    )
}

async function checkEmptyState(
    problems,
    details,
    { report, state, browser, baseUrl, account, evidenceDir }
) {
    const session = await openSession(browser, report, "empty", account)
    state.sessions.push(session)
    try {
        const { page } = session
        await login(session, baseUrl)
        await page.waitForSelector("#nav-portfolio-insights", {
            timeout: PAGE_TIMEOUT_MS,
        })
        await page.click("#nav-portfolio-insights")
        await page.waitForSelector("#insights-empty-state", {
            timeout: PAGE_TIMEOUT_MS,
        })
        const comparison = await compareWithLastInsights(session)
        report.compared.emptyState = comparison
        details.unstableReads = comparison.unstableReads
        problems.push(...comparison.problems)
        const body = comparison.response
        if (isPlainObject(body)) {
            for (const field of [
                "totalValue",
                "totalInvested",
                "unrealizedPnl",
                "unrealizedPnlPercent",
            ]) {
                expectEqual(problems, `response ${field}`, body[field], 0)
            }
            expectEqual(problems, "response allocations", body.allocations, [])
            expectEqual(
                problems,
                "response largestPosition",
                body.largestPosition,
                null
            )
            expectEqual(problems, "response riskLevel", body.riskLevel, null)
        }
        expectEqual(
            problems,
            "#insights-risk-badge shown",
            await isPresent(page, "#insights-risk-badge"),
            false
        )
        await captureScreenshot(
            report,
            page,
            evidenceDir,
            "insights-empty.png",
            problems
        )
    } finally {
        try {
            await session.context.close()
        } catch (error) {
            console.error(error)
            problems.push(
                `closing the empty account's page failed: ${error.message}`
            )
        }
    }
}

async function checkOneToastPerArming(problems, details, holder, alerts) {
    const { page } = holder
    await openInsightsPage(holder)
    await waitFor(
        () => notificationEntries(holder).length >= POLLS_BEFORE_RELOAD,
        {
            timeoutMs: POLLS_BEFORE_RELOAD_TIMEOUT_MS,
            what: `${POLLS_BEFORE_RELOAD} notification responses`,
        }
    )
    const reloadSeq = nextSequence()
    await page.reload({ waitUntil: "domcontentloaded" })
    await page.waitForSelector("#portfolio-insights", {
        timeout: PAGE_TIMEOUT_MS,
    })
    await waitFor(
        () =>
            notificationEntries(holder).filter((entry) => entry.seq > reloadSeq)
                .length >= POLLS_AFTER_RELOAD,
        {
            timeoutMs: POLLS_AFTER_RELOAD_TIMEOUT_MS,
            what: `${POLLS_AFTER_RELOAD} notification responses after the reload`,
        }
    )
    await settleBodies(holder)
    // Every response since the page opened counts, not only the last: a
    // member that triggers during the check shows up in a later response
    // than the one read before its Toast.
    await waitForArmingToasts(holder, alerts)
    const armings = await expectOneToastPerArming(problems, holder, alerts)
    details.triggered = [...armings.values()]
    if (armings.size === 0) {
        problems.push(
            "no notification response shows a fixture alert triggered, though e2e.sh saw one per pair trigger"
        )
    }
    details.notificationResponses = notificationEntries(holder).length
}

function rowSelector(alertId) {
    return `li.alert-item[data-alert-id="${alertId}" i]`
}

function notificationSelector(alertId) {
    return `li.alert-notification[data-notification-id="${alertId}" i]`
}

/** In the page: the label and state of a row's toggle, or `null`. */
function readRowToggle(selector) {
    const button = document.querySelector(`${selector} button.alert-toggle`)
    return button === null
        ? null
        : { label: button.textContent.trim(), disabled: button.disabled }
}

/** Waits until the row's toggle is enabled, and for `label` when given. */
async function waitForToggle(page, alertId, label) {
    return await waitFor(
        async () => {
            const toggle = await page.evaluate(
                readRowToggle,
                rowSelector(alertId)
            )
            return toggle !== null &&
                !toggle.disabled &&
                (label === null || toggle.label === label)
                ? toggle.label
                : false
        },
        {
            timeoutMs: ROW_TIMEOUT_MS,
            what: `the ${label ?? "enabled"} toggle of alert ${alertId}`,
        }
    )
}

/** The revision the page last received for `alert`, else the fixture's. */
function latestRevision(session, alert) {
    let revision = alert.armingRevision
    for (const entry of session.responses) {
        if (!entry.parsed) {
            continue
        }
        let item
        if (entry.kind === "alertsList" || entry.kind === "notifications") {
            item = resultsOf(entry).find(
                (candidate) => idOf(candidate) === alert.id
            )
        } else if (entry.kind === "patch" && entry.status === 200) {
            item = idOf(entry.body) === alert.id ? entry.body : undefined
        }
        if (item !== undefined && Number.isInteger(item.armingRevision)) {
            revision = item.armingRevision
        }
    }
    return revision
}

/** Waits for the PATCH response of `alertId` sent after `afterSeq`. */
async function waitForPatchResponse(session, alertId, afterSeq) {
    const entry = await waitFor(
        () =>
            session.responses.find(
                (candidate) =>
                    candidate.kind === "patch" &&
                    candidate.alertId === alertId &&
                    candidate.seq > afterSeq &&
                    (candidate.parsed || candidate.bodyError !== undefined)
            ),
        {
            timeoutMs: ROW_TIMEOUT_MS,
            what: `the PATCH response of alert ${alertId}`,
        }
    )
    if (entry.status !== 200) {
        throw new Error(`PATCH ${entry.path} answered HTTP ${entry.status}`)
    }
    if (!entry.parsed || !isPlainObject(entry.body)) {
        throw new Error(
            `PATCH ${entry.path} answered an unreadable body: ${entry.bodyError ?? "not a JSON object"}`
        )
    }
    return entry
}

/** Clicks the row's toggle and returns the PATCH response it caused. */
async function clickToggle(session, report, member, label) {
    const clickSeq = nextSequence()
    const clickedAt = new Date().toISOString()
    await clickWhenClear(
        session.page,
        `${rowSelector(member.alert.id)} button.alert-toggle`,
        ROW_TIMEOUT_MS
    )
    const entry = await waitForPatchResponse(session, member.alert.id, clickSeq)
    const snapshot = {
        alertId: member.alert.id,
        clicked: label,
        clickedAt,
        status: entry.status,
        enabled: entry.body.enabled,
        armingRevision: entry.body.armingRevision,
        triggeredAt: entry.body.triggeredAt,
        acknowledged: entry.body.acknowledged,
    }
    member.patches.push(snapshot)
    report.patches.push(snapshot)
    return { entry, clickSeq }
}

/**
 * Re-arms one fixture alert through its row: "Re-arm" or "Enable" directly,
 * an armed row through "Disable" and then "Enable". The toggle is clicked by
 * the state it shows, and the PATCH it answers with decides the next step,
 * so a row that changed state just before the click is still handled.
 */
async function rearmMember(session, report, alert) {
    const { page } = session
    await page.waitForSelector(rowSelector(alert.id), {
        timeout: ROW_TIMEOUT_MS,
    })
    const label = await waitForToggle(page, alert.id, null)
    const member = {
        alert,
        previousRevision: latestRevision(session, alert),
        initialState: label,
        patches: [],
        newRevision: null,
        enablingSeq: null,
    }
    if (!["Re-arm", "Enable", "Disable"].includes(label)) {
        throw new Error(`the row toggle reads "${label}"`)
    }
    let click = await clickToggle(session, report, member, label)
    if (click.entry.body.enabled === false) {
        await waitForToggle(page, alert.id, "Enable")
        click = await clickToggle(session, report, member, "Enable")
    }
    const { body } = click.entry
    if (
        body.enabled !== true ||
        body.triggeredAt !== null ||
        !Number.isInteger(body.armingRevision) ||
        body.armingRevision <= member.previousRevision
    ) {
        throw new Error(
            `the enabling PATCH answered enabled ${body.enabled}, triggeredAt ${JSON.stringify(body.triggeredAt)} and armingRevision ${body.armingRevision}, expected true, null and above ${member.previousRevision}`
        )
    }
    member.newRevision = body.armingRevision
    member.enablingSeq = click.clickSeq
    return member
}

/** Whether a notification response shows `member` triggered when re-armed. */
function triggeredUnderNewRevision(session, member) {
    return notificationEntries(session).some(
        (entry) =>
            entry.seq > member.enablingSeq &&
            resultsOf(entry).some(
                (item) =>
                    idOf(item) === member.alert.id &&
                    item.armingRevision === member.newRevision &&
                    isTriggered(item)
            )
    )
}

async function checkRearmBothMembers(
    problems,
    details,
    report,
    holder,
    fixture
) {
    const { alerts } = fixture
    await openInsightsPage(holder)
    const members = []
    for (const alert of alerts) {
        try {
            members.push(await rearmMember(holder, report, alert))
        } catch (error) {
            console.error(error)
            problems.push(
                `re-arming ${alert.pair} ${alert.direction} alert ${alert.id}: ${error.message}`
            )
        }
    }
    const pairs = Object.keys(PAIR_TYPES)
    for (const pair of pairs) {
        if (!members.some((member) => member.alert.pair === pair)) {
            problems.push(`no member of pair ${pair} was re-armed`)
        }
    }
    if (members.length > 0) {
        // Both members of a pair are armed only once every re-arm is done,
        // and only then is one of them sure to trigger in the next cycle.
        const timeoutMs =
            (2 * fixture.evaluationIntervalSeconds + REARM_MARGIN_S) * 1000
        await waitOrReport(problems, () =>
            waitFor(
                () =>
                    pairs.every((pair) =>
                        members.some(
                            (member) =>
                                member.alert.pair === pair &&
                                triggeredUnderNewRevision(holder, member)
                        )
                    ),
                {
                    timeoutMs,
                    what: "one re-armed member per pair to trigger under its new revision",
                }
            )
        )
        await waitForArmingToasts(holder, alerts)
        await expectOneToastPerArming(problems, holder, alerts)
    }
    details.members = members.map((member) => {
        const newKey = armingKey(member.alert.id, member.newRevision)
        const after = holder.toasts.filter(
            (toast) =>
                toast.alertId === member.alert.id &&
                toast.seq > member.enablingSeq
        )
        const triggered = triggeredUnderNewRevision(holder, member)
        const newArmingToasts = after.filter((toast) => toast.key === newKey)
        // A later Toast of an earlier arming is that arming's first Toast,
        // which the one-per-arming count above already judges.
        if (newArmingToasts.length !== (triggered ? 1 : 0)) {
            problems.push(
                `alert ${member.alert.id} ${triggered ? "triggered" : "did not trigger"} under revision ${member.newRevision} and has ${newArmingToasts.length} Toasts for it, expected ${triggered ? 1 : 0}`
            )
        }
        return {
            alertId: member.alert.id,
            pair: member.alert.pair,
            direction: member.alert.direction,
            initialState: member.initialState,
            previousRevision: member.previousRevision,
            newRevision: member.newRevision,
            triggered,
            toastsForNewRevision: newArmingToasts.length,
            patches: member.patches,
        }
    })
}

/** In the page: the alert ids the notification list shows. */
function readNotificationIds() {
    return Array.from(
        document.querySelectorAll("#alert-notifications li.alert-notification"),
        (item) =>
            (item.getAttribute("data-notification-id") ?? "").toLowerCase()
    )
}

async function checkAcknowledge(problems, details, report, holder, alerts) {
    const { page } = holder
    await openInsightsPage(holder)
    const ids = new Set(alerts.map((alert) => alert.id))
    let listed = []
    const alertId = await waitOrReport(problems, () =>
        waitFor(
            async () => {
                listed = await page.evaluate(readNotificationIds)
                return listed.find((id) => ids.has(id)) ?? false
            },
            {
                timeoutMs: ACKNOWLEDGE_TIMEOUT_MS,
                what: "a fixture alert in #alert-notifications",
            }
        )
    )
    details.listed = listed
    if (alertId === null) {
        problems.push(
            listed.length === 0
                ? "#alert-notifications lists no notification"
                : `#alert-notifications lists only non-fixture alerts: ${listed.join(", ")}`
        )
        return
    }
    const alert = alerts.find((candidate) => candidate.id === alertId)
    const armingRevision = latestRevision(holder, alert)
    await settleBodies(holder)
    attributeToasts(holder, alerts)
    const before = toastCounts(holder)
    const clickSeq = nextSequence()
    await clickWhenClear(
        page,
        `${notificationSelector(alertId)} button.alert-acknowledge`,
        ACKNOWLEDGE_TIMEOUT_MS
    )
    const response = await waitFor(
        () =>
            holder.responses.find(
                (entry) =>
                    entry.kind === "acknowledge" &&
                    entry.alertId === alertId &&
                    entry.seq > clickSeq &&
                    (entry.status === 204 ||
                        entry.parsed ||
                        entry.bodyError !== undefined)
            ),
        {
            timeoutMs: ACKNOWLEDGE_TIMEOUT_MS,
            what: `the acknowledge response of alert ${alertId}`,
        }
    )
    details.acknowledgeStatus = response.status
    expectEqual(problems, "the acknowledge status", response.status, 204)
    if (response.status === 204) {
        report.acknowledged = { id: alertId, armingRevision }
    }
    await waitOrReport(problems, () =>
        waitFor(
            async () => !(await isPresent(page, notificationSelector(alertId))),
            {
                timeoutMs: ACKNOWLEDGE_TIMEOUT_MS,
                what: `alert ${alertId} to leave #alert-notifications`,
            }
        )
    )
    await waitOrReport(problems, () =>
        waitFor(
            () =>
                notificationEntries(holder).some(
                    (entry) => entry.seq > clickSeq
                ),
            {
                timeoutMs: NEXT_POLL_TIMEOUT_MS,
                what: "the next notification response after the acknowledge",
            }
        )
    )
    await expectOneToastPerArming(problems, holder, alerts)
    const after = toastCounts(holder)
    // A first Toast of another arming may legitimately appear meanwhile; an
    // arming already toasted must not be toasted again.
    details.newlyToasted = []
    for (const [key, count] of after) {
        const prior = before.get(key) ?? 0
        if (prior === 0) {
            details.newlyToasted.push(key)
        } else if (count > prior) {
            problems.push(
                `arming ${key} was toasted again after the acknowledge: ${prior} → ${count}`
            )
        }
    }
    details.acknowledged = { id: alertId, armingRevision }
}

/** In the page: where it is and whether the feature's elements remain. */
function readShutdownState() {
    return {
        path: location.pathname,
        insightsLink:
            document.getElementById("nav-portfolio-insights") !== null,
        alertsPanel: document.getElementById("alerts-panel") !== null,
    }
}

async function checkLiveShutdown(
    problems,
    details,
    { report, holder, baseUrl, evidenceDir }
) {
    const { page } = holder
    await openInsightsPage(holder)
    const offAt = Date.now()
    details.flagOff = await setFlag(baseUrl, false)
    let shutdownState = null
    try {
        await waitFor(
            async () => {
                shutdownState = await page.evaluate(readShutdownState)
                return (
                    shutdownState.path === "/home" &&
                    !shutdownState.insightsLink &&
                    !shutdownState.alertsPanel
                )
            },
            {
                timeoutMs: SHUTDOWN_TIMEOUT_MS,
                what: "/home without #nav-portfolio-insights and #alerts-panel",
            }
        )
    } catch (error) {
        if (error instanceof WaitTimeoutError) {
            error.message += `; the page shows ${JSON.stringify(shutdownState)}`
        }
        throw error
    }
    const shutdownSeq = nextSequence()
    const shutdownAt = Date.now()
    details.shutdownAfterMs = shutdownAt - offAt
    await observeAbsence(
        () => {
            const request = holder.notificationRequests.find(
                (candidate) => candidate.seq > shutdownSeq
            )
            if (request !== undefined) {
                return `a notification request was sent ${request.at - shutdownAt} ms after the shutdown`
            }
            const toast = holder.toasts.find(
                (candidate) => candidate.seq > shutdownSeq
            )
            if (toast !== undefined) {
                return `the Toast "${toast.text}" appeared after the shutdown`
            }
            return null
        },
        { windowMs: ABSENCE_WINDOW_MS }
    )
    details.quietForMs = ABSENCE_WINDOW_MS
    await page.goto(`${baseUrl}/insights`, { waitUntil: "domcontentloaded" })
    await waitForPath(page, "/home", REDIRECT_TIMEOUT_MS)
    expectEqual(
        problems,
        "#portfolio-insights shown after the direct visit",
        await isPresent(page, "#portfolio-insights"),
        false
    )
    await captureScreenshot(
        report,
        page,
        evidenceDir,
        "post-shutdown-home.png",
        problems
    )
}

async function runFlagOff(report, state, { baseUrl, evidenceDir }, fixture) {
    const flagReady = await runCheck(
        report,
        "flag-off:flag-disabled",
        (problems, details) => checkFlagState(problems, details, baseUrl, false)
    )
    if (!flagReady) {
        return
    }
    const browser = await launchBrowser(state)
    const holder = await openSession(browser, report, "holder", fixture.holder)
    state.sessions.push(holder)
    await login(holder, baseUrl)
    const { page } = holder

    await runCheck(
        report,
        "flag-off:nav-link-absent",
        async (problems, details) => {
            await waitFor(
                () =>
                    holder.responses.some(
                        (entry) => entry.kind === "flag" && entry.parsed
                    ),
                {
                    timeoutMs: FLAG_RESPONSE_TIMEOUT_MS,
                    what: "the page's first flag response",
                }
            )
            details.flagResponses = holder.responses
                .filter((entry) => entry.kind === "flag" && entry.parsed)
                .map((entry) => ({
                    status: entry.status,
                    enabled: isPlainObject(entry.body)
                        ? entry.body.enabled
                        : null,
                }))
            expectEqual(
                problems,
                "#nav-portfolio-insights shown",
                await isPresent(page, "#nav-portfolio-insights"),
                false
            )
            await captureScreenshot(
                report,
                page,
                evidenceDir,
                "flag-off-home.png",
                problems
            )
        }
    )

    await runCheck(
        report,
        "flag-off:direct-visit-redirects",
        async (problems, details) => {
            await page.goto(`${baseUrl}/insights`, {
                waitUntil: "domcontentloaded",
            })
            await waitForPath(page, "/home", REDIRECT_TIMEOUT_MS)
            details.landedOn = currentPath(page)
            expectEqual(
                problems,
                "#portfolio-insights shown",
                await isPresent(page, "#portfolio-insights"),
                false
            )
        }
    )
}

async function runFlagOn(report, state, { baseUrl, evidenceDir }, fixture) {
    const flagReady = await runCheck(
        report,
        "flag-on:flag-enabled",
        (problems, details) => checkFlagState(problems, details, baseUrl, true)
    )
    if (!flagReady) {
        return
    }
    const browser = await launchBrowser(state)
    const holder = await openSession(browser, report, "holder", fixture.holder)
    state.sessions.push(holder)
    await login(holder, baseUrl)

    await runCheck(
        report,
        "flag-on:page-equals-response",
        (problems, details) =>
            checkPageEqualsResponse(
                problems,
                details,
                report,
                holder,
                evidenceDir
            )
    )
    await runCheck(report, "flag-on:empty-state", (problems, details) =>
        checkEmptyState(problems, details, {
            report,
            state,
            browser,
            baseUrl,
            account: fixture.empty,
            evidenceDir,
        })
    )
    await runCheck(
        report,
        "flag-on:one-toast-per-arming",
        (problems, details) =>
            checkOneToastPerArming(problems, details, holder, fixture.alerts)
    )
    await runCheck(report, "flag-on:rearm-both-members", (problems, details) =>
        checkRearmBothMembers(problems, details, report, holder, fixture)
    )
    await runCheck(report, "flag-on:acknowledge", (problems, details) =>
        checkAcknowledge(problems, details, report, holder, fixture.alerts)
    )
    try {
        await runCheck(report, "flag-on:live-shutdown", (problems, details) =>
            checkLiveShutdown(problems, details, {
                report,
                holder,
                baseUrl,
                evidenceDir,
            })
        )
    } finally {
        // e2e.sh restores the flag as well if this process dies first.
        await runCheck(report, "flag-on:flag-restored", async (_, details) => {
            details.flag = await setFlag(baseUrl, true)
        })
    }
}

/** What the evidence keeps of every notification response the pages read. */
function summariseNotifications(sessions) {
    return sessions.flatMap((session) =>
        session.responses
            .filter((entry) => entry.kind === "notifications")
            .map((entry) => ({
                account: session.label,
                at: new Date(entry.at).toISOString(),
                status: entry.status,
                results: entry.parsed
                    ? resultsOf(entry).map((item) => ({
                          id: idOf(item),
                          armingRevision: item.armingRevision,
                          triggeredAt: item.triggeredAt,
                          triggerValue: item.triggerValue,
                          acknowledged: item.acknowledged,
                      }))
                    : null,
                bodyError: entry.bodyError ?? null,
            }))
    )
}

function summariseBodyErrors(sessions) {
    return sessions.flatMap((session) =>
        session.responses
            .filter((entry) => entry.bodyError !== undefined)
            .map((entry) => ({
                account: session.label,
                kind: entry.kind,
                method: entry.method,
                path: entry.path,
                status: entry.status,
                error: entry.bodyError,
            }))
    )
}

function accountSummary(account) {
    return account === null
        ? null
        : { username: account.username, accountId: account.accountId }
}

async function main() {
    let options
    let fixture
    try {
        options = parseOptions(process.argv.slice(2))
        fixture = await readFixture(options.fixturePath, options.mode)
    } catch (error) {
        if (!(error instanceof UsageError)) {
            throw error
        }
        console.error(USAGE)
        console.error(error.message)
        process.exitCode = 2
        return
    }

    const { baseUrl, mode, evidenceDir } = options
    const report = {
        mode,
        baseUrl,
        startedAt: new Date().toISOString(),
        finishedAt: null,
        holder: accountSummary(fixture.holder),
        empty: accountSummary(fixture.empty),
        evaluationIntervalSeconds: fixture.evaluationIntervalSeconds,
        checks: [],
        compared: {},
        toasts: [],
        patches: [],
        acknowledged: null,
        notifications: [],
        bodyErrors: [],
        screenshots: [],
        traceHeaders: [],
        traceCorrelation: "unverified",
        traceCorrelationNote: TRACE_CORRELATION_NOTE,
    }
    const state = { browser: null, sessions: [] }
    let failed = false
    try {
        await mkdir(evidenceDir, { recursive: true })
        if (mode === "flag-on") {
            await runFlagOn(report, state, options, fixture)
        } else {
            await runFlagOff(report, state, options, fixture)
        }
    } catch (error) {
        console.error(error)
        recordCheck(report, "setup", false, error.message, {})
    } finally {
        if (state.browser !== null) {
            try {
                await state.browser.close()
            } catch (error) {
                failed = true
                console.log(`FAIL teardown: ${error.message}`)
                console.error(error)
            }
        }
        report.notifications = summariseNotifications(state.sessions)
        report.bodyErrors = summariseBodyErrors(state.sessions)
        report.finishedAt = new Date().toISOString()
        try {
            await mkdir(evidenceDir, { recursive: true })
            await writeFile(
                path.join(
                    evidenceDir,
                    `portfolio-insights-page-check-${mode}.json`
                ),
                `${JSON.stringify(report, null, 4)}\n`
            )
        } catch (error) {
            failed = true
            console.log(`FAIL evidence: ${error.message}`)
            console.error(error)
        }
    }
    process.exitCode =
        failed || report.checks.some((check) => check.status === "FAIL") ? 1 : 0
}

await main()
