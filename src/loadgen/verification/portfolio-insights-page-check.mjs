/* global document, window, MutationObserver, location */
/**
 * Browser check of the Portfolio Insights page against the broker responses
 * the page itself received: the figures and allocations it shows, its empty
 * state, one Toast per triggered alert arming, re-arming, acknowledging, the
 * five existing sidebar links' layout with the feature on and off, and the
 * shutdown once the `portfolio-insights-enabled` flag turns off. One Toast
 * per arming is also held to the check's own notifications read through the
 * broker API, apart from the page.
 *
 * Usage, from src/loadgen after `npm ci`:
 *
 *     node verification/portfolio-insights-page-check.mjs --base-url URL
 *         --mode flag-off|flag-on --fixture FILE --evidence-dir DIR
 *     node verification/portfolio-insights-page-check.mjs --help
 *
 * Every option but `--help` is required, and no environment variable is
 * read. `--help` (`-h`) prints the options, modes, fixture, exit codes and an
 * example, then exits 0 without reading the fixture or contacting the app,
 * whatever the other options hold; an unknown option, a positional argument
 * or an option without its value is still a usage error. The flag must
 * already be in the state the mode names: `false` for flag-off and `true`
 * for flag-on. flag-on turns it off and on again for its sidebar continuity
 * check and for its last check.
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
 * - `evaluationIntervalSeconds`: optional integer from 1 to 4294967, the
 *   broker's interval range, 60 by default.
 * - `holder` and `empty`: a non-empty string `username` and `password`, and
 *   a UUID `accountId`.
 * - flag-off needs `holder`; `empty` is optional and `alerts` is ignored.
 * - flag-on needs `holder`, `empty` and exactly four `alerts` with distinct
 *   UUID ids: for each pair, `target_price` (type `TARGET_PRICE`) and
 *   `profit_loss` (`PROFIT_LOSS`), one `ABOVE` and one `BELOW` member.
 * - `threshold`: a plain decimal string, `-?(0|[1-9][0-9]*)(\.[0-9]+)?`, of
 *   at most 10 integer and 8 fractional digits once trailing fractional
 *   zeros are removed; above 0 for `TARGET_PRICE`, of any sign for
 *   `PROFIT_LOSS`.
 * - `armingRevision`: an integer from 1 to 2147483647.
 * - Any other fixture stops the run with exit code 2 before any browser or
 *   API action.
 *
 * Passwords are never printed or written. Neither are response bodies, JSON
 * parser messages, response fields the checks do not know, or the text of
 * any Toast: a failure names the method, path, HTTP status and a fixed
 * reason, a value from a response or the page is printed only in its defined
 * form, escaped and bounded, and otherwise described by kind and size, error
 * messages are escaped and bounded, and the evidence keeps validated fields
 * only: the parsed fields of each Toast matched to a fixture arming, the
 * alert, type, direction and time of each other fixture-alert Toast, and
 * every remaining Toast counted by variant.
 *
 * Output: one `PASS <check>` or `FAIL <check>: <reason>` line per check, and
 * `portfolio-insights-page-check-<mode>.json` plus screenshots in the
 * evidence directory.
 *
 * Every wait ends at its deadline. A page that leaves a read unanswered then
 * is closed, which ends the read at once; that check and every later check
 * on the same page fail.
 *
 * Exit codes: 0 when every check passed, or for `--help`; 1 when a check or
 * the setup failed; 2 on a usage or fixture error.
 *
 * The check runs only when node starts this file. Importing it runs nothing
 * and exposes the helpers the unit tests exercise, which run from
 * src/loadgen, with the other verification suites, as:
 *
 *     node --test "verification/*.test.mjs"
 */
import { execFile } from "node:child_process"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { parseArgs } from "node:util"

const USAGE =
    "Usage: node verification/portfolio-insights-page-check.mjs --base-url URL --mode flag-off|flag-on --fixture FILE --evidence-dir DIR"

/** What `--help` prints: the options, modes, fixture, exit codes, example. */
export const HELP = `${USAGE}
       node verification/portfolio-insights-page-check.mjs --help

Browser check of the Portfolio Insights page against the broker responses
the page received. Run it from src/loadgen after npm ci. Every input is an
option or the fixture; no environment variable is read.

Options, all required except --help:
  --base-url URL      The app's origin: http or https, without a path, query,
                      fragment or credentials, such as http://localhost.
  --mode MODE         flag-off or flag-on, as described under Modes.
  --fixture FILE      The JSON fixture scripts/portfolio-insights/e2e.sh
                      writes, as described under Fixture.
  --evidence-dir DIR  The directory, created when missing, that receives
                      portfolio-insights-page-check-<mode>.json and the
                      screenshots.
  -h, --help          Prints this help and exits 0 without reading the
                      fixture or contacting the app, whatever the other
                      options hold. An unknown option, a positional argument
                      or an option without its value is still a usage error.

Modes. The portfolio-insights-enabled flag must already have the state the
mode names:
  flag-off  The flag must be false. Checks that the page's navigation link
            is absent and that a direct visit to /insights lands on /home.
  flag-on   The flag must be true. Checks the page against the insights
            response it received, the empty state, one Toast per triggered
            alert arming, re-arming, acknowledging, the existing sidebar
            links' layout and the live shutdown. It turns the flag off and
            on again for the sidebar continuity check and for its last
            check, and re-arms and acknowledges the fixture's alerts.

Fixture, a JSON object:
  { "evaluationIntervalSeconds": 60,
    "holder": { "username": "...", "password": "...", "accountId": "<uuid>" },
    "empty": { "username": "...", "password": "...", "accountId": "<uuid>" },
    "alerts": [ { "id": "<uuid>", "pair": "target_price",
                  "type": "TARGET_PRICE", "direction": "ABOVE",
                  "threshold": "123.45", "armingRevision": 1 } ] }
  evaluationIntervalSeconds  Optional integer from 1 to 4294967, the broker's
                             interval range; 60 by default.
  holder, empty              Each a non-empty string username and password
                             and a UUID accountId. flag-off needs holder and
                             takes an optional empty; flag-on needs both.
  alerts                     flag-on only; flag-off ignores it. Exactly four
                             with distinct UUID ids: for each pair,
                             target_price (type TARGET_PRICE) and profit_loss
                             (type PROFIT_LOSS), one ABOVE and one BELOW
                             member.
  threshold                  A plain decimal string such as "-12.5" or "0.5",
                             without a plus sign, exponent or extra leading
                             zero, of at most 10 integer and 8 fractional
                             digits once trailing fractional zeros are
                             removed. Above 0 for TARGET_PRICE; of any sign
                             for PROFIT_LOSS.
  armingRevision             An integer from 1 to 2147483647.

Output: one "PASS <check>" or "FAIL <check>: <reason>" line per check.
Passwords are never printed or written.

Exit codes:
  0  Every check passed, or --help.
  1  A check or the setup failed.
  2  A usage or fixture error, found before any browser or API action.

Example, from src/loadgen:
  node verification/portfolio-insights-page-check.mjs --base-url http://localhost --mode flag-on --fixture run/fixture.json --evidence-dir run/evidence`

const OPTIONS = {
    "base-url": { type: "string" },
    mode: { type: "string" },
    fixture: { type: "string" },
    "evidence-dir": { type: "string" },
    help: { type: "boolean", short: "h" },
}
/** The options a run needs, in the order a missing one is reported. */
const REQUIRED_OPTIONS = ["base-url", "mode", "fixture", "evidence-dir"]

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
/**
 * A `THRESHOLD_PATTERN` match inside the broker's threshold domain, decided
 * on the text: at most 10 integer and 8 fractional digits once trailing
 * fractional zeros are removed, which is what `DECIMAL(18, 8)` stores.
 */
const THRESHOLD_DOMAIN_PATTERN = /^-?(0|[1-9][0-9]{0,9})(\.[0-9]{1,8}0*)?$/
/** The broker uses an evaluation interval only from 1 to this, in seconds. */
const MAX_EVALUATION_INTERVAL_S = 4294967
/** Largest arming revision: the int32 of the gRPC contract and `INT` column. */
const MAX_ARMING_REVISION = 2147483647

/** Fixture pair name → the alert type both of its members carry. */
const PAIR_TYPES = { target_price: "TARGET_PRICE", profit_loss: "PROFIT_LOSS" }
const DIRECTIONS = ["ABOVE", "BELOW"]
const DEFAULT_EVALUATION_INTERVAL_S = 60

const RISK_LABELS = { LOW: "Low", MEDIUM: "Medium", HIGH: "High" }
/** Money as `formatInPage` writes it, in each of its formats. */
const CURRENCY_TEXT_PATTERN = /^-?\$\d{1,3}(,\d{3})*(\.\d+)?$/
/** A percent as `formatInPage` writes it: two places, signed unless zero. */
const PERCENT_TEXT_PATTERN = /^[+-]?\d{1,3}(,\d{3})*\.\d{2}%$/
/** Longest compared value, in characters, a problem or the evidence repeats. */
const MAX_COMPARED_CHARS = 160

/** The text `AlertNotificationWatcher` gives a triggered-alert Toast. */
const TOAST_PATTERN =
    /^Alert triggered: (.+) (Price|P\/L) (above|below) (\S+) \(now (\S+)\)$/
const TOAST_TYPES = { Price: "TARGET_PRICE", "P/L": "PROFIT_LOSS" }
const TOAST_DIRECTIONS = { above: "ABOVE", below: "BELOW" }
/**
 * A threshold or "now" value as `formatAlertNumber` writes it: en-US digit
 * grouping, at most 8 fractional digits and no exponent.
 */
const ALERT_NUMBER_PATTERN = /^-?\d{1,3}(,\d{3})*(\.\d{1,8})?$/
/** A Toast threshold is the 8-place display rounding of the alert's. */
const THRESHOLD_TOLERANCE = 1e-8
/** The only form of page path the Toast evidence repeats. */
const TOAST_PATH_PATTERN = /^\/[A-Za-z0-9/_-]{0,64}$/

const TRACE_HEADERS = ["traceparent", "x-dynatrace"]
const TRACE_CORRELATION_NOTE =
    "Browser-to-broker trace correlation needs a deployment monitored by OneAgent with RUM injected into the frontend. traceHeaders records what the browser sent on each insights request and is not asserted."
/** Longest trace header value, in characters, the evidence keeps. */
const MAX_TRACE_HEADER_CHARS = 256

/** The variants `ToastContext` gives a Toast, as its `toast-<variant>` class. */
const TOAST_VARIANTS = ["success", "error", "info"]
const TOAST_VARIANT_CLASS = /\btoast-(\w+)\b/g

/** A timestamp as the broker serialises one. */
const TIMESTAMP_PATTERN =
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/

/** Longest error message, in characters, a diagnostic repeats. */
const MAX_DIAGNOSTIC_CHARS = 500
/** Causes of an error that a diagnostic names. */
const MAX_CAUSE_DEPTH = 5
/** The only forms in which an error's name or code is printed. */
const ERROR_NAME_PATTERN = /^\w{1,64}$/
const ERROR_CODE_PATTERN = /^[A-Z][A-Z0-9_]{0,63}$/

const VIEWPORT = { width: 1366, height: 900 }

/**
 * The five sidebar links that predate Portfolio Insights, in their order,
 * each with the route its `NavLink` in Navigation.tsx renders as its href.
 */
const LEGACY_NAV_ROUTES = new Map([
    ["nav-home", "/home"],
    ["nav-instruments", "/instruments"],
    ["nav-deposit", "/deposit"],
    ["nav-withdraw", "/withdraw"],
    ["nav-credit-card", "/credit-card"],
])
/** The ids of `LEGACY_NAV_ROUTES`, in their order. */
const LEGACY_NAV_IDS = [...LEGACY_NAV_ROUTES.keys()]
/**
 * Viewport widths of the sidebar continuity check: the mobile row whose
 * labels wrap, the mobile row where the five links fit on one line and a
 * sixth would not, and the desktop column.
 */
const CONTINUITY_WIDTHS = [375, 668, 1366]
/** The width whose sidebar the continuity check screenshots. */
const CONTINUITY_SCREENSHOT_WIDTH = 668
/**
 * The defined form of a computed style value the continuity check reads: a
 * CSS keyword, a number or a pixel length.
 */
const CSS_VALUE_PATTERN =
    /^(?:[a-z][a-z-]{0,31}|-?\d{1,6}(?:\.\d{1,6})?(?:px)?)$/

/** Deadline of every navigation, login step and page selector wait. */
const PAGE_TIMEOUT_MS = 30_000
/** Deadline of the check's own flag read and write. */
const FLAG_REQUEST_TIMEOUT_MS = 10_000
/** Deadline for the page's first flag response. */
const FLAG_RESPONSE_TIMEOUT_MS = 15_000
/** Deadline for the client-side redirect of a direct /insights visit. */
const REDIRECT_TIMEOUT_MS = 15_000
/**
 * How long a flag-off page must stay without the feature once its first flag
 * response arrived, and once a direct /insights visit landed on /home. The
 * frontend applies a flag answer in its next render, well within this, and
 * an element or request the page reports late still arrives within it.
 */
const SETTLE_WINDOW_MS = 3_000
/**
 * The method and the one status of each page response kind the frontend's
 * own call gets on success: the flag read (the flag service's `GetByID`), the
 * insights read, the alert list, the notification poll and the PATCH answer
 * 200, the acknowledge 204 (`AlertController`). Any other answer is recorded
 * as evidence and never consumed.
 */
const EXPECTED_RESPONSES = {
    flag: { method: "GET", status: 200 },
    insights: { method: "GET", status: 200 },
    alertsList: { method: "GET", status: 200 },
    notifications: { method: "GET", status: 200 },
    patch: { method: "PATCH", status: 200 },
    acknowledge: { method: "POST", status: 204 },
}
/** Why a 3xx fails the check's own requests: they never follow one. */
const REDIRECT_REASON = "a redirect, which the check does not follow"
/**
 * The ids of the feature's elements: the sidebar link, the page with its
 * figures and states, and the alerts panel with its form, list and
 * notifications. A direct visit the flag sends to /home shows none of them.
 */
const FEATURE_ELEMENT_ID_PATTERN =
    /^(?:nav-portfolio-insights|portfolio-insights|insights-[a-z0-9-]{1,64}|alerts?-[a-z0-9-]{1,64})$/
/** The only form in which a request method is repeated. */
const METHOD_PATTERN = /^[A-Z]{1,16}$/
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
/**
 * Deadline for an alert row, its toggle, the received state that explains
 * the toggle's label, and the PATCH a click sends.
 */
const ROW_TIMEOUT_MS = 20_000
/**
 * The `enabled` value the PATCH of each `button.alert-toggle` label sends
 * (`AlertList`): "Disable" on an armed row, "Re-arm" on a triggered one and
 * "Enable" on a disabled one.
 */
const TOGGLE_SENDS = { Disable: false, "Re-arm": true, Enable: true }
const TOGGLE_LABELS = Object.keys(TOGGLE_SENDS)
/**
 * Samples of a row's toggle, at most, while its label changes between the
 * sample and the click, as when the alert triggers just before it.
 */
const MAX_TOGGLE_SAMPLES = 3
/** The response kinds that carry an alert's state to the page. */
const ALERT_STATE_KINDS = ["alertsList", "notifications", "patch"]
/** Deadline for a notification item, its acknowledge response and removal. */
const ACKNOWLEDGE_TIMEOUT_MS = 20_000
/** Deadline for the first notification poll after the acknowledge click. */
const NEXT_POLL_TIMEOUT_MS = 25_000
/** Added to two evaluation intervals while re-armed alerts are awaited. */
const REARM_MARGIN_S = 30
/**
 * Counted from the start of the flag PUT; covers the page's 15 s flag poll
 * and 2 s read deadline, with margin.
 */
const SHUTDOWN_TIMEOUT_MS = 30_000
/** After the shutdown, no notification request or Toast may occur for this. */
const ABSENCE_WINDOW_MS = 20_000
const POLL_INTERVAL_MS = 250
/**
 * Bound of every single DevTools protocol call, such as a `page.evaluate`
 * probe. A selector wait holds one call open for up to its own timeout, at
 * most `PAGE_TIMEOUT_MS`, so the bound must exceed that. A probe call still
 * running when its wait times out ends sooner: `probePage` closes its page.
 */
const PROTOCOL_TIMEOUT_MS = 2 * PAGE_TIMEOUT_MS
/**
 * Deadline for the browser to close. Puppeteer bounds the close command by
 * PROTOCOL_TIMEOUT_MS, then waits for Chrome's process to exit without any
 * bound; past this deadline that process is killed instead.
 */
const BROWSER_CLOSE_TIMEOUT_MS = 15_000
/** Deadline for the browser process to be killed and seen to exit. */
const BROWSER_KILL_TIMEOUT_MS = 10_000

/** A bad command line or fixture; the run stops with exit code 2. */
class UsageError extends Error {
    constructor(message) {
        super(message)
        this.name = "UsageError"
    }
}

/**
 * A bounded wait that ran out of time, or whose probe did not answer by its
 * deadline. `options.cause` holds an error the probe threw too late to count.
 */
export class WaitTimeoutError extends Error {
    constructor(message, options) {
        super(message, options)
        this.name = "WaitTimeoutError"
    }
}

/**
 * Longest delay a single `setTimeout` keeps. Node runs a longer one after
 * 1 ms with a TimeoutOverflowWarning, so longer delays are taken in steps.
 */
const MAX_TIMER_MS = 2 ** 31 - 1

/** Resolves once `ms` have passed, in timer steps of at most MAX_TIMER_MS. */
function pause(ms) {
    return new Promise((resolve) => {
        const wait = (leftMs) => {
            if (leftMs > MAX_TIMER_MS) {
                setTimeout(wait, MAX_TIMER_MS, leftMs - MAX_TIMER_MS)
            } else {
                setTimeout(resolve, leftMs)
            }
        }
        wait(ms)
    })
}

/** Rejects a duration that would leave a wait without a finite deadline. */
function requireDuration(name, ms) {
    if (!Number.isFinite(ms) || ms <= 0) {
        throw new RangeError(
            `${name} must be a positive number of milliseconds, not ${ms}`
        )
    }
}

/**
 * Runs `probe(signal)` and settles with `{ late, failed, value, error }` by
 * `deadline`, a `performance.now()` time. `late` is true when the probe has
 * not answered by the deadline or answered after it. A probe left without an
 * answer keeps running unobserved: its later value or rejection is consumed
 * here, so it never becomes an unhandled rejection. The expiry timer is
 * re-armed in steps of at most MAX_TIMER_MS until `performance.now()`
 * reaches the deadline, so any finite deadline holds.
 */
async function answerBy(probe, signal, deadline) {
    const answer = new Promise((resolve) => resolve(probe(signal))).then(
        (value) => ({
            late: performance.now() > deadline,
            failed: false,
            value,
        }),
        (error) => ({
            late: performance.now() > deadline,
            failed: true,
            error,
        })
    )
    let timer
    const expiry = new Promise((resolve) => {
        const arm = () => {
            timer = setTimeout(
                () => {
                    if (performance.now() >= deadline) {
                        resolve({ late: true, failed: false, value: undefined })
                    } else {
                        arm()
                    }
                },
                Math.min(
                    Math.max(deadline - performance.now(), 0),
                    MAX_TIMER_MS
                )
            )
        }
        arm()
    })
    try {
        return await Promise.race([answer, expiry])
    } finally {
        clearTimeout(timer)
    }
}

/**
 * Polls `predicate(signal)` every `intervalMs` until it answers a truthy
 * value, which it resolves with, and throws a `WaitTimeoutError` naming
 * `what` once `timeoutMs` has passed without one. A wait whose window opened
 * before the call passes the window's end as `deadline`, a
 * `performance.now()` time, which replaces `timeoutMs` from now; `timeoutMs`
 * then gives the window's length for the message.
 *
 * The deadline comes from the monotonic `performance.now()` clock and bounds
 * every probe as well as the wait: a truthy answer counts only if it arrives
 * by the deadline, no probe starts at or after it, so a deadline already
 * past ends the wait without one, and a probe that has not answered by then
 * ends the wait. On a timeout `signal` is aborted with the thrown error. An
 * error the predicate throws by the deadline ends the wait at once; one
 * thrown later becomes the timeout's `cause`.
 */
export async function waitFor(
    predicate,
    { timeoutMs, deadline: endsAt, intervalMs = POLL_INTERVAL_MS, what }
) {
    requireDuration("timeoutMs", timeoutMs)
    requireDuration("intervalMs", intervalMs)
    if (endsAt !== undefined && !Number.isFinite(endsAt)) {
        throw new RangeError(
            `deadline must be a finite performance.now() time, not ${endsAt}`
        )
    }
    const deadline = endsAt ?? performance.now() + timeoutMs
    const controller = new AbortController()
    const timedOut = (answer) => {
        const error = new WaitTimeoutError(
            `timed out after ${timeoutMs} ms waiting for ${what}` +
                (answer === null
                    ? ""
                    : "; its last probe did not answer in time"),
            answer?.failed ? { cause: answer.error } : undefined
        )
        controller.abort(error)
        return error
    }
    for (;;) {
        if (performance.now() >= deadline) {
            throw timedOut(null)
        }
        const answer = await answerBy(predicate, controller.signal, deadline)
        if (answer.late) {
            throw timedOut(answer)
        }
        if (answer.failed) {
            throw answer.error
        }
        if (answer.value) {
            return answer.value
        }
        const remainingMs = deadline - performance.now()
        if (remainingMs > 0) {
            await pause(Math.min(intervalMs, remainingMs))
        }
    }
}

/**
 * Polls `violation(signal)` every `intervalMs` for `windowMs` and throws as
 * soon as it answers the description of something that must not happen in
 * that window. A violation is reported whenever its answer arrives.
 *
 * It resolves only on a clean answer from a probe that started at or after
 * the end of the window, so the whole window was observed. By the monotonic
 * `performance.now()` clock, every probe must answer within one poll
 * interval after the window ends; one that does not ends the observation
 * with a `WaitTimeoutError` and aborts `signal` with it, because the window
 * was not fully observed. An error the probe throws by then ends the wait
 * at once; one thrown later becomes the timeout's `cause`.
 */
export async function observeAbsence(
    violation,
    { windowMs, intervalMs = POLL_INTERVAL_MS }
) {
    requireDuration("windowMs", windowMs)
    requireDuration("intervalMs", intervalMs)
    const windowEnd = performance.now() + windowMs
    // The probe that closes the window starts at its end and needs time to
    // answer; one poll interval is the most any probe may run beyond it.
    const answerDeadline = windowEnd + intervalMs
    const controller = new AbortController()
    for (;;) {
        const closing = performance.now() >= windowEnd
        const answer = await answerBy(
            violation,
            controller.signal,
            answerDeadline
        )
        if (!answer.failed && answer.value) {
            throw new Error(answer.value)
        }
        if (answer.late) {
            const error = new WaitTimeoutError(
                `timed out after ${windowMs + intervalMs} ms waiting for the absence probe to answer; the ${windowMs} ms window was not fully observed`,
                answer.failed ? { cause: answer.error } : undefined
            )
            controller.abort(error)
            throw error
        }
        if (answer.failed) {
            throw answer.error
        }
        if (closing) {
            return
        }
        const remainingMs = windowEnd - performance.now()
        if (remainingMs > 0) {
            await pause(Math.min(intervalMs, remainingMs))
        }
    }
}

/**
 * Runs `probe()`, a read that awaits `page`, as the probe of a wait whose
 * `signal` aborts when the wait times out. `page.evaluate` takes no signal,
 * so a call still pending then would keep the page busy until
 * PROTOCOL_TIMEOUT_MS. The page is closed at the abort instead, which ends
 * every pending call on it at once: a stalled page is closed, and the later
 * checks that use it fail. A probe that settles first leaves the page open,
 * and an already aborted `signal` throws its reason before any call.
 */
export async function probePage(page, signal, probe) {
    signal.throwIfAborted()
    const closePage = () => {
        new Promise((resolve) => resolve(page.close())).catch((error) => {
            // The page may already be closing or gone.
            console.error(describeError(error))
        })
    }
    signal.addEventListener("abort", closePage, { once: true })
    try {
        return await probe()
    } finally {
        signal.removeEventListener("abort", closePage)
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

/**
 * The run's options, or `{ help: true }` for `--help` or `-h` before any
 * other option is checked. A command line `parseArgs` rejects stays a usage
 * error with `--help`.
 */
function parseOptions(args) {
    let parsed
    try {
        parsed = parseArgs({ args, options: OPTIONS, strict: true })
    } catch (error) {
        throw new UsageError(error.message)
    }
    const { values } = parsed
    if (values.help === true) {
        return { help: true }
    }
    for (const name of REQUIRED_OPTIONS) {
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
    if (!THRESHOLD_DOMAIN_PATTERN.test(alert.threshold)) {
        throw invalid(
            "needs a threshold of at most 10 integer and 8 fractional digits, not counting trailing fractional zeros"
        )
    }
    // Above 0, decided on the text: no minus sign and a nonzero digit.
    if (
        alert.type === "TARGET_PRICE" &&
        (alert.threshold.startsWith("-") || !/[1-9]/.test(alert.threshold))
    ) {
        throw invalid("of type TARGET_PRICE needs a threshold above 0")
    }
    if (
        !Number.isInteger(alert.armingRevision) ||
        alert.armingRevision < 1 ||
        alert.armingRevision > MAX_ARMING_REVISION
    ) {
        throw invalid(
            `needs an integer armingRevision from 1 to ${MAX_ARMING_REVISION}`
        )
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
    // The re-arm wait grows with the interval, so the broker's own range
    // also keeps that wait bounded.
    if (
        !Number.isInteger(evaluationIntervalSeconds) ||
        evaluationIntervalSeconds < 1 ||
        evaluationIntervalSeconds > MAX_EVALUATION_INTERVAL_S
    ) {
        throw new UsageError(
            `--fixture ${fixturePath} needs an integer evaluationIntervalSeconds from 1 to ${MAX_EVALUATION_INTERVAL_S}`
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

/** Whether `code` is a C0 or C1 control, or a line or paragraph separator. */
function isControlCode(code) {
    return (
        code < 0x20 ||
        (code >= 0x7f && code <= 0x9f) ||
        code === 0x2028 ||
        code === 0x2029
    )
}

/**
 * `text` with every control character and line or paragraph separator
 * written as a `\uXXXX` escape, so text this script did not write cannot
 * start a forged line in a log (CWE-117).
 */
function escapeControl(text) {
    let escaped = ""
    for (const character of String(text)) {
        const code = character.codePointAt(0)
        escaped += isControlCode(code)
            ? `\\u${code.toString(16).padStart(4, "0")}`
            : character
    }
    return escaped
}

/** `text` cut to at most `maxChars` characters, ending in "…" when cut. */
function boundText(text, maxChars) {
    if (text.length <= maxChars) {
        return text
    }
    let end = maxChars - 1
    const last = text.charCodeAt(end - 1)
    // Never keep half of a surrogate pair.
    if (last >= 0xd800 && last <= 0xdbff) {
        end -= 1
    }
    return `${text.slice(0, end)}…`
}

function plural(count, noun) {
    return `${count} ${noun}${count === 1 ? "" : "s"}`
}

/**
 * A description of a value from a response or the page that is safe to
 * print: `null`, booleans, numbers and the strings in `known` as JSON, any
 * other value by its kind and size only, never its content.
 */
export function describeValue(value, known = []) {
    if (value === null || typeof value === "boolean" || isFiniteNumber(value)) {
        return JSON.stringify(value)
    }
    if (typeof value === "number") {
        // JSON would write NaN or an infinity as null.
        return String(value)
    }
    if (typeof value === "string") {
        return known.includes(value)
            ? JSON.stringify(value)
            : `a string of ${plural(value.length, "character")}`
    }
    if (Array.isArray(value)) {
        return value.length === 0
            ? "an empty array"
            : `an array of ${plural(value.length, "item")}`
    }
    if (typeof value === "object") {
        return "an object"
    }
    return typeof value
}

function errorName(error) {
    return typeof error.name === "string" && ERROR_NAME_PATTERN.test(error.name)
        ? error.name
        : "Error"
}

function errorCode(error) {
    return typeof error.code === "string" && ERROR_CODE_PATTERN.test(error.code)
        ? error.code
        : null
}

/**
 * The message of `error`, escaped and bounded, for a `FAIL` reason or the
 * evidence. A thrown value that is not an `Error` is described by its kind.
 */
function errorMessage(error) {
    if (!(error instanceof Error)) {
        return `a non-Error value was thrown: ${describeValue(error)}`
    }
    return boundText(escapeControl(error.message), MAX_DIAGNOSTIC_CHARS)
}

/**
 * One line describing `error` for stderr: its name, code and bounded,
 * escaped message, then the name and code of each cause. A cause's message
 * and every stack are left out: a cause can come from a library that quotes
 * the input it failed on.
 */
export function describeError(error) {
    if (!(error instanceof Error)) {
        return errorMessage(error)
    }
    const label = (cause) => {
        const code = errorCode(cause)
        return code === null
            ? errorName(cause)
            : `${errorName(cause)} [${code}]`
    }
    let text = `${label(error)}: ${errorMessage(error)}`
    let cause = error.cause
    for (
        let depth = 0;
        cause !== undefined && cause !== null && depth < MAX_CAUSE_DEPTH;
        depth += 1
    ) {
        if (!(cause instanceof Error)) {
            text += `; caused by a non-Error ${typeof cause}`
            break
        }
        text += `; caused by ${label(cause)}`
        cause = cause.cause
    }
    return text
}

/**
 * The first system error code, such as `ECONNREFUSED`, that `error` or its
 * causes carry, or `null`. An `AggregateError`'s errors count as causes.
 */
function firstErrorCode(error) {
    const pending = [error]
    for (
        let visited = 0;
        pending.length > 0 && visited <= MAX_CAUSE_DEPTH;
        visited += 1
    ) {
        const current = pending.shift()
        if (!(current instanceof Error)) {
            continue
        }
        const code = errorCode(current)
        if (code !== null) {
            return code
        }
        if (current instanceof AggregateError) {
            pending.push(...current.errors)
        }
        pending.push(current.cause)
    }
    return null
}

/** Prints a check's `PASS` or `FAIL` line and records it in the report. */
function recordCheck(report, name, ok, reason, details) {
    // A reason quotes no response, yet an error message it repeats may come
    // from a library, so it is escaped before it is printed.
    const safeReason = ok ? null : escapeControl(reason)
    report.checks.push({
        name,
        status: ok ? "PASS" : "FAIL",
        reason: safeReason,
        details,
        at: new Date().toISOString(),
    })
    console.log(ok ? `PASS ${name}` : `FAIL ${name}: ${safeReason}`)
    return ok
}

/**
 * Runs one check, which adds what it finds wrong to `problems` and what it
 * measured to `details`. An error it throws is one more problem, and the
 * details gathered up to then are kept. Never throws.
 */
export async function runCheck(report, name, check) {
    const problems = []
    const details = {}
    try {
        await check(problems, details)
    } catch (error) {
        console.error(describeError(error))
        problems.push(errorMessage(error))
    }
    return recordCheck(
        report,
        name,
        problems.length === 0,
        problems.join("; "),
        details
    )
}

/**
 * Adds a problem to `problems` unless `actual` equals `expected`. Both are
 * described by `describeValue`, so a string is printed only when it is one
 * of `known`.
 */
function expectEqual(problems, label, actual, expected, known = []) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        problems.push(
            `${label} is ${describeValue(actual, known)}, expected ${describeValue(expected, known)}`
        )
    }
}

/**
 * The flag a flag-service response body holds, projected to its `id` and
 * `enabled`, or why the body holds none as a fixed phrase. A field the check
 * does not know never leaves this function.
 */
function parseFlagBody(text) {
    let body
    try {
        body = JSON.parse(text)
    } catch {
        // The parser's message quotes the body, so it is not kept.
        return { flag: null, problem: "with a body that is not JSON" }
    }
    if (
        !isPlainObject(body) ||
        body.id !== FLAG_ID ||
        typeof body.enabled !== "boolean"
    ) {
        return {
            flag: null,
            problem: `without "${FLAG_ID}" and a boolean "enabled"`,
        }
    }
    return { flag: { id: FLAG_ID, enabled: body.enabled }, problem: null }
}

/**
 * Why a request failed in transport, as a fixed phrase: its `timeoutMs`
 * deadline, else the system error code it or a cause carries. The messages
 * are left out: fetch's say only "fetch failed", and a cause's may quote its
 * input.
 */
export function transportFailure(error, timeoutMs = FLAG_REQUEST_TIMEOUT_MS) {
    let current = error
    for (
        let depth = 0;
        current instanceof Error && depth <= MAX_CAUSE_DEPTH;
        depth += 1
    ) {
        if (current.name === "TimeoutError" || current.name === "AbortError") {
            return `timed out after ${timeoutMs} ms`
        }
        current = current.cause
    }
    return firstErrorCode(error) ?? "transport error"
}

/**
 * Why the status of one of the check's own requests fails it, as a fixed
 * phrase. Only 200 passes. A 3xx comes back unfollowed, since every such
 * request is sent with `redirect: "manual"`, and is named as a redirect; its
 * `Location` is never repeated.
 */
function statusFailure(status) {
    return status >= 300 && status < 400
        ? `answered HTTP ${status}, ${REDIRECT_REASON}`
        : `answered HTTP ${status}`
}

/**
 * Sends one request to the flag service and returns the flag it answers
 * with, as `{ id, enabled }` only. Only a 200 answers, and a redirect is
 * never followed, so neither the request nor its body reaches another
 * address. A failure names the method, URL, HTTP status and a fixed reason,
 * never the body: the flag service, or a proxy in front of it, may answer
 * with any text.
 */
export async function flagRequest(baseUrl, init) {
    const url = `${baseUrl}${FLAG_PATH}`
    const method = init.method ?? "GET"
    const signal = AbortSignal.timeout(FLAG_REQUEST_TIMEOUT_MS)
    let response
    try {
        response = await fetch(url, { ...init, signal, redirect: "manual" })
    } catch (error) {
        throw new Error(`${method} ${url} failed: ${transportFailure(error)}`, {
            cause: error,
        })
    }
    let text
    try {
        text = await response.text()
    } catch (error) {
        throw new Error(
            `${method} ${url} answered HTTP ${response.status} with a body that could not be read: ${transportFailure(error)}`,
            { cause: error }
        )
    }
    if (response.status !== 200) {
        throw new Error(`${method} ${url} ${statusFailure(response.status)}`)
    }
    const { flag, problem } = parseFlagBody(text)
    if (flag === null) {
        throw new Error(
            `${method} ${url} answered HTTP ${response.status} ${problem}`
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
 * Why a response body could not be read as JSON, as a fixed phrase. The
 * error's message is not kept: the JSON parser's quotes the body around the
 * position it failed at.
 */
function bodyReadFailure(error) {
    if (error instanceof SyntaxError) {
        return "the body is not valid JSON"
    }
    const name = error instanceof Error ? errorName(error) : "Error"
    return name === "Error"
        ? "the body could not be read"
        : `the body could not be read (${name})`
}

/**
 * The query the frontend sends with a call of response kind `kind`
 * (`api/alerts/index.ts`): `accountId` alone on the alert list, `accountId`
 * and `unacknowledged=true` on the notification poll, nothing on the others.
 */
function expectedQuery(kind, session) {
    if (kind === "alertsList") {
        return { accountId: session.account.accountId }
    }
    if (kind === "notifications") {
        return { accountId: session.account.accountId, unacknowledged: "true" }
    }
    return {}
}

/**
 * Whether a page response answers the frontend's own call, decided once as
 * it is recorded: `null` when it does, else why not, as a fixed phrase. It
 * must come from the session's `origin`, the page's own, which the reverse
 * proxy serves the flag service and the broker from; answer the method of
 * `EXPECTED_RESPONSES` with its one status; be for the session's account;
 * and carry exactly `expectedQuery`, each parameter once, an account id in
 * any case. A redirect is a 3xx, so it is never accepted, and neither is a
 * response the redirect led to on another origin.
 */
function responseRejection(session, classified, url, method, status) {
    const expected = EXPECTED_RESPONSES[classified.kind]
    if (url.origin !== session.origin) {
        return "came from another origin"
    }
    if (method !== expected.method) {
        const sent = METHOD_PATTERN.test(method) ? method : "another"
        return `answered a ${sent} request, not ${expected.method}`
    }
    if (
        classified.accountId !== null &&
        classified.accountId !== session.account.accountId
    ) {
        return classified.accountId === ""
            ? "names no account"
            : "is for another account"
    }
    const query = Object.entries(expectedQuery(classified.kind, session))
    const exactQuery =
        [...url.searchParams.keys()].length === query.length &&
        query.every(([name, value]) => {
            const values = url.searchParams.getAll(name)
            const sent =
                name === "accountId" ? values[0]?.toLowerCase() : values[0]
            return values.length === 1 && sent === value
        })
    if (!exactQuery) {
        return "lacks the exact query the frontend sends"
    }
    if (status !== expected.status) {
        return `answered HTTP ${status}, not ${expected.status}`
    }
    return null
}

/**
 * Records a response in arrival order at once and reads its JSON body in the
 * background. An entry holds the `classifyResponse` fields (`kind`,
 * `accountId`, `alertId`), the `url`, `path`, `method` and `status`, its
 * arrival time `at` and sequence number `seq`, and `accepted` with
 * `rejection`: whether `responseRejection` found it the answer to the
 * frontend's own call, and else why not. A check counts a call of the page
 * only on an accepted entry; every other one is kept as evidence of what the
 * page received. Every body but a 204's is read: `parsed` is set and `body`
 * holds it once read, and a body that cannot be read leaves `bodyError`, a
 * fixed phrase. A PATCH entry also gets `sentEnabled`, what its request
 * sent (`sentEnabledOf`), `undefined` until that is read. Both reads are
 * pending in `session.pendingBodies` until done.
 */
export function recordResponse(session, response) {
    const url = new URL(response.url())
    const request = response.request()
    const method = request.method()
    const classified = classifyResponse(method, url)
    if (classified === null) {
        return
    }
    const status = response.status()
    const rejection = responseRejection(
        session,
        classified,
        url,
        method,
        status
    )
    const entry = {
        ...classified,
        url: response.url(),
        path: url.pathname,
        method,
        status,
        accepted: rejection === null,
        rejection,
        at: Date.now(),
        seq: nextSequence(),
        body: undefined,
        parsed: false,
    }
    session.responses.push(entry)
    const reads = []
    if (entry.kind === "patch") {
        entry.sentEnabled = undefined
        // `fetchPostData` is the replacement Puppeteer names for the
        // deprecated `postData`; a request it cannot read sent no known body.
        reads.push(
            new Promise((resolve) => resolve(request.fetchPostData())).then(
                (text) => {
                    entry.sentEnabled = sentEnabledOf(text)
                },
                () => {
                    entry.sentEnabled = null
                }
            )
        )
    }
    if (entry.status !== 204) {
        reads.push(
            response.json().then(
                (body) => {
                    entry.body = body
                    entry.parsed = true
                },
                (error) => {
                    entry.bodyError = bodyReadFailure(error)
                }
            )
        )
    }
    if (reads.length === 0) {
        return
    }
    const reading = Promise.all(reads).finally(() =>
        session.pendingBodies.delete(reading)
    )
    session.pendingBodies.add(reading)
}

/**
 * The `enabled` value of a PATCH request body that is the frontend's
 * `{"enabled": bool}` and nothing else (`updateAlertEnabled`), else `null`:
 * what was sent is unknown. The body itself is never kept.
 */
function sentEnabledOf(text) {
    if (typeof text !== "string") {
        return null
    }
    let body
    try {
        body = JSON.parse(text)
    } catch {
        // The parser's message quotes the body, so it is not kept.
        return null
    }
    return isPlainObject(body) &&
        Object.keys(body).length === 1 &&
        typeof body.enabled === "boolean"
        ? body.enabled
        : null
}

/**
 * The route of a feature request, as a template that repeats no id, or
 * `null` for any other path: the insights read, the alert routes and the
 * notification poll.
 */
function featureRoute(pathname) {
    if (pathname.startsWith(INSIGHTS_PATH_PREFIX)) {
        return `${INSIGHTS_PATH_PREFIX}{accountId}`
    }
    if (pathname === ALERTS_PATH || pathname === NOTIFICATIONS_PATH) {
        return pathname
    }
    const match = ALERT_ID_PATH.exec(pathname)
    if (match !== null) {
        return `${ALERTS_PATH}/{id}${match[2] ?? ""}`
    }
    return pathname.startsWith(`${ALERTS_PATH}/`) ? `${ALERTS_PATH}/…` : null
}

/**
 * Records every feature request the page sends, by method and route only,
 * when the page asks for notifications, and the trace headers of each
 * insights request as observed data only. A header value is escaped and cut
 * to `MAX_TRACE_HEADER_CHARS`, which a W3C or Dynatrace value never needs.
 */
export function recordRequest(session, report, request) {
    const url = new URL(request.url())
    const route = featureRoute(url.pathname)
    if (route !== null) {
        const method = request.method()
        session.featureRequests.push({
            seq: nextSequence(),
            at: Date.now(),
            method: METHOD_PATTERN.test(method) ? method : null,
            route,
        })
    }
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
                    (name) => [
                        name,
                        boundText(
                            escapeControl(headers[name]),
                            MAX_TRACE_HEADER_CHARS
                        ),
                    ]
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
 * In every document of a page, before its own scripts: reports, by its id
 * only, the first appearance in that document of each element whose id
 * `idPattern` matches, the feature's. A direct visit the flag redirects may
 * mount the feature for a moment, which no read after the redirect sees.
 */
export function installFeatureRecorder(idPattern) {
    const pattern = new RegExp(idPattern)
    const reported = new Set()
    const report = (element) => {
        const { id } = element
        if (typeof id !== "string" || reported.has(id) || !pattern.test(id)) {
            return
        }
        reported.add(id)
        window
            .__recordFeatureElement({ id })
            .catch((error) => console.error(error))
    }
    const visit = (node) => {
        // Only elements carry an id.
        if (node.nodeType !== 1) {
            return
        }
        report(node)
        for (const element of node.querySelectorAll("[id]")) {
            report(element)
        }
    }
    new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            if (mutation.type === "attributes") {
                report(mutation.target)
            }
            for (const node of mutation.addedNodes) {
                visit(node)
            }
        }
    }).observe(document.documentElement ?? document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["id"],
    })
}

/**
 * Records a feature element `installFeatureRecorder` reported, by its id
 * only, and only an id of the feature's form: anything else is page input
 * the check does not keep.
 */
export function recordFeatureElement(session, entry) {
    const id = isPlainObject(entry) ? entry.id : undefined
    if (typeof id !== "string" || !FEATURE_ELEMENT_ID_PATTERN.test(id)) {
        return
    }
    session.featureElements.push({ id, seq: nextSequence(), at: Date.now() })
}

/**
 * Opens a browser context and page of their own for `account`, so session
 * storage, the login and the notification tracker never leak between
 * accounts, and instruments the page before its first navigation. Every
 * Toast is kept in `session.toasts` for the checks; the evidence receives
 * only what `summariseToasts` keeps of them. `origin`, the app's, is the only
 * one whose responses `recordResponse` accepts. `featureElements` and
 * `featureRequests` keep every feature element the page's documents show
 * and every feature request the page sends.
 */
async function openSession(browser, report, label, account, origin) {
    const context = await browser.createBrowserContext()
    const page = await context.newPage()
    const session = {
        label,
        account,
        origin,
        context,
        page,
        toasts: [],
        responses: [],
        notificationRequests: [],
        featureElements: [],
        featureRequests: [],
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
    })
    await page.evaluateOnNewDocument(installToastRecorder)
    await page.exposeFunction("__recordFeatureElement", (entry) =>
        recordFeatureElement(session, entry)
    )
    await page.evaluateOnNewDocument(
        installFeatureRecorder,
        FEATURE_ELEMENT_ID_PATTERN.source
    )
    page.on("response", (response) => {
        try {
            recordResponse(session, response)
        } catch (error) {
            console.error(describeError(error))
        }
    })
    page.on("request", (request) => {
        try {
            recordRequest(session, report, request)
        } catch (error) {
            console.error(describeError(error))
        }
    })
    return session
}

/**
 * A Toast's variant from its class list: one of `TOAST_VARIANTS`, else
 * "unknown". The class list itself is page text and is never printed.
 */
function toastVariant(className) {
    for (const match of className.matchAll(TOAST_VARIANT_CLASS)) {
        if (TOAST_VARIANTS.includes(match[1])) {
            return match[1]
        }
    }
    return "unknown"
}

async function launchBrowser(state) {
    const { default: puppeteer } = await import("puppeteer")
    // The check can run as root on a disposable host, where Chrome refuses
    // to start with its sandbox.
    state.browser = await puppeteer.launch({
        headless: true,
        args: ["--no-sandbox"],
        // Puppeteer's default leaves a stalled call open for 180 s; this
        // bound stays above every single-call deadline the check sets.
        protocolTimeout: PROTOCOL_TIMEOUT_MS,
        // Waiting for Chrome's first tab would, on a timeout, close the
        // browser inside the launch with no bound on its exit. Every session
        // opens its own page, so only `teardownBrowser` ever closes it.
        waitForInitialPage: false,
    })
    return state.browser
}

/** The fields the login fills in, then the button that sends them. */
const LOGIN_FIELDS = ["#login", "#password", "#submitButton"]
const PASSWORD_FIELD = "#password"
/** Longest address, in characters, a login refusal repeats. */
const MAX_LOCATION_CHARS = 200
/**
 * The only form of resource type a login failure repeats; its method is
 * repeated only in the form of `METHOD_PATTERN`.
 */
const RESOURCE_TYPE_PATTERN = /^[a-z]{1,32}$/

/** Whether `text` is a URL whose origin is `origin`. */
function isOnOrigin(text, origin) {
    try {
        return new URL(text).origin === origin
    } catch {
        return false
    }
}

/**
 * Where `text` points, for a login refusal: a URL's origin and path,
 * escaped and bounded, never its query or fragment, which can carry tokens.
 * An opaque origin, or a URL that has one such as a data: URL, is named by
 * its kind only.
 */
export function describeLocation(text) {
    if (text === "null") {
        return "an opaque origin"
    }
    let url
    try {
        url = new URL(text)
    } catch {
        return "an address that is not a URL"
    }
    if (url.origin === "null") {
        return `a ${boundText(url.protocol, 32)} URL`
    }
    return boundText(
        escapeControl(`${url.origin}${url.pathname}`),
        MAX_LOCATION_CHARS
    )
}

/**
 * The first address off `origin` that the navigation `response` passed
 * through, one of its redirects or its final URL, as `describeLocation`
 * names it, or `null`. A navigation that answers no response has none.
 */
export function offOriginHop(response, origin) {
    if (response === null || response === undefined) {
        return null
    }
    const hops = response
        .request()
        .redirectChain()
        .map((request) => request.url())
    const hop = [...hops, response.url()].find(
        (url) => !isOnOrigin(url, origin)
    )
    return hop === undefined ? null : describeLocation(hop)
}

/**
 * In the page: the origin of the main frame's document, the one that both
 * `page.evaluate` and `page.type` address; which of `fields` it lacks;
 * whether `passwordField` is a password input, which masks what is typed;
 * every address a form holding one of the fields would submit to; and
 * every browsing context it would submit into, by target name.
 */
export function readLoginForm(fields, passwordField) {
    const missing = []
    const actions = []
    const targets = []
    // A form without a target of its own submits into the first
    // base[target]'s; an empty target attribute counts as none.
    const base = document.querySelector("base[target]")
    for (const selector of fields) {
        const element = document.querySelector(selector)
        if (element === null) {
            missing.push(selector)
        } else if (element.form) {
            actions.push(element.form.action)
            targets.push(element.form.target || (base?.target ?? ""))
            // A button's own formaction overrides its form's action, and its
            // own formtarget its form's target.
            if (typeof element.formAction === "string") {
                actions.push(element.formAction)
            }
            if (typeof element.formTarget === "string") {
                targets.push(element.formTarget)
            }
        }
    }
    const password = document.querySelector(passwordField)
    return {
        origin: location.origin,
        missing,
        masked:
            password !== null &&
            password.tagName === "INPUT" &&
            password.type === "password",
        actions,
        targets,
    }
}

/**
 * The target names that submit into the page's own browsing context: none,
 * or "_self" in any ASCII case, as the browser matches it. Any other name
 * can open or reach another context, whose requests the login's
 * interception of the page does not see; "_top" and "_parent" are refused
 * too, although in the page's main frame they name the page itself.
 */
const SELF_TARGET_PATTERN = /^(_self)?$/i

/**
 * Why the login page at `url` must not receive credentials, as fixed
 * reasons naming only origins, paths and login selectors, or none. The
 * page, its document and every address its login form submits to must be
 * on `origin`, and the form must submit into the page itself; every login
 * field must exist, and the password field must mask its text. `form` is
 * what `readLoginForm` read.
 */
export function loginPageProblems(url, form, origin) {
    const problems = []
    if (!isOnOrigin(url, origin)) {
        problems.push(`the page is on ${describeLocation(url)}, not ${origin}`)
    }
    if (
        !isPlainObject(form) ||
        !Array.isArray(form.missing) ||
        !Array.isArray(form.actions) ||
        !Array.isArray(form.targets)
    ) {
        problems.push("its login form could not be read")
        return problems
    }
    if (form.origin !== origin) {
        problems.push(
            `its document is on ${describeLocation(form.origin)}, not ${origin}`
        )
    }
    // Only the check's own selectors are repeated, never the page's text.
    const missing = LOGIN_FIELDS.filter((field) => form.missing.includes(field))
    if (missing.length > 0) {
        problems.push(`it has no ${missing.join(", ")}`)
    }
    if (!missing.includes(PASSWORD_FIELD) && form.masked !== true) {
        problems.push(`${PASSWORD_FIELD} is not a password input`)
    }
    const action = form.actions.find((address) => !isOnOrigin(address, origin))
    if (action !== undefined) {
        problems.push(
            `its form submits to ${describeLocation(action)}, not ${origin}`
        )
    }
    // A target name is page text, so the reason never repeats it.
    if (
        form.targets.some(
            (target) =>
                typeof target !== "string" || !SELF_TARGET_PATTERN.test(target)
        )
    ) {
        problems.push(
            "its form submits into a browsing context other than the page's own"
        )
    }
    return problems
}

/** A request the login stopped, by its method and resource type only. */
function describeRequest(request) {
    const method = request.method()
    const type = request.resourceType()
    const methodText =
        typeof method === "string" && METHOD_PATTERN.test(method)
            ? method
            : "non-standard"
    const typeText =
        typeof type === "string" && RESOURCE_TYPE_PATTERN.test(type)
            ? type
            : "other"
    return `a ${methodText} ${typeText} request`
}

/** The only form of target type a login failure repeats. */
const TARGET_TYPE_PATTERN = /^[a-z_]{1,32}$/
/**
 * The targets the login's hold attaches to: all but the browser, its tabs,
 * which only wrap pages, and its own interface, which no page can open.
 */
const HELD_TARGETS = [
    { type: "browser", exclude: true },
    { type: "tab", exclude: true },
    { type: "browser_ui", exclude: true },
    {},
]

/** A target beside the login's page, by its type only. */
function describeTarget(type) {
    return typeof type === "string" && TARGET_TYPE_PATTERN.test(type)
        ? `another ${type} target`
        : "another target"
}

/**
 * Whether the paused `request` fetches a service worker's script, which
 * the browser marks with a Service-Worker header.
 */
function isServiceWorkerScript(request) {
    return Object.keys(request.headers ?? {}).some(
        (name) => name.toLowerCase() === "service-worker"
    )
}

/**
 * Resumes the paused target that `session` attached as `sessionId`, and
 * leaves it whether or not it could be resumed.
 */
async function leaveTarget(session, sessionId, paused) {
    try {
        if (paused) {
            const attached = session.connection()?.session(sessionId)
            if (!attached) {
                throw new Error("a paused target the login left has no session")
            }
            await attached.send("Runtime.runIfWaitingForDebugger")
        }
    } finally {
        await session.send("Target.detachFromTarget", { sessionId })
    }
}

/**
 * Until the function it returns resolves, closes every target in `page`'s
 * browser context other than `page`, such as a window the page opens, and
 * blocks every service worker's script, passing `violate` a reason that
 * names `origin` for each. Puppeteer resumes every target it attaches to
 * before any of its events, so the check attaches at browser level too,
 * pausing each new target on start: one in the context is closed before it
 * runs, any other resumed and left. A target already open in the context
 * when the hold starts is closed as well. A new service worker runs once
 * any attach resumes it, so it is left too: a browser-level interception,
 * which continues every other request it pauses, blocks its script, in any
 * context, so that it is never registered.
 */
async function holdOtherTargets(page, origin, violate) {
    const contextId = page.browserContext().id
    if (typeof contextId !== "string") {
        throw new Error("the login's page has no browser context of its own")
    }
    const own = await page.createCDPSession()
    const ownId = await own
        .send("Target.getTargetInfo")
        .then(({ targetInfo }) => targetInfo.targetId)
        .finally(() => own.detach())
    const session = await page.browser().target().createCDPSession()
    const pending = []
    const settle = (promise) =>
        pending.push(
            promise.catch((error) => console.error(describeError(error)))
        )
    const onAttached = ({ sessionId, targetInfo, waitingForDebugger }) => {
        try {
            const other =
                targetInfo.browserContextId === contextId &&
                targetInfo.targetId !== ownId
            // A new service worker runs once Puppeteer resumes it, so it is
            // its blocked script that stops it and ends the login; ending
            // it here would stop the interception before the script comes.
            if (
                other &&
                !(targetInfo.type === "service_worker" && waitingForDebugger)
            ) {
                violate(
                    `${describeTarget(targetInfo.type)} opened during the login, outside the page whose requests the login holds to ${origin}`
                )
                // Sent at once, so it reaches the browser before the hold ends.
                settle(
                    session.send("Target.closeTarget", {
                        targetId: targetInfo.targetId,
                    })
                )
            } else {
                settle(leaveTarget(session, sessionId, waitingForDebugger))
            }
        } catch (error) {
            console.error(describeError(error))
        }
    }
    let stopping = false
    const onPaused = ({ requestId, request }) => {
        try {
            if (isServiceWorkerScript(request)) {
                violate(
                    `a service worker's script was requested during the login, outside the page whose requests the login holds to ${origin}; it was blocked`
                )
                settle(
                    session.send("Fetch.failRequest", {
                        requestId,
                        errorReason: "BlockedByClient",
                    })
                )
            } else if (!stopping) {
                // Once the hold stops, ending interception continues it.
                settle(session.send("Fetch.continueRequest", { requestId }))
            }
        } catch (error) {
            console.error(describeError(error))
        }
    }
    const stop = () => {
        session.off("Target.attachedToTarget", onAttached)
        session.off("Fetch.requestPaused", onPaused)
    }
    session.on("Target.attachedToTarget", onAttached)
    session.on("Fetch.requestPaused", onPaused)
    try {
        await session.send("Target.setAutoAttach", {
            autoAttach: true,
            waitForDebuggerOnStart: true,
            flatten: true,
            filter: HELD_TARGETS,
        })
        await session.send("Fetch.enable", { patterns: [{ urlPattern: "*" }] })
    } catch (error) {
        stop()
        // Leaving the browser ends whatever part of the hold had started.
        await new Promise((resolve) => resolve(session.detach())).catch(
            (cleanupError) => console.error(describeError(cleanupError))
        )
        throw error
    }
    return async () => {
        try {
            stopping = true
            await session.send("Fetch.disable")
            // A browser-level attach takes only the flat protocol, even to stop.
            await session.send("Target.setAutoAttach", {
                autoAttach: false,
                waitForDebuggerOnStart: false,
                flatten: true,
            })
        } finally {
            stop()
            await Promise.all(pending)
            await session.detach()
        }
    }
}

/**
 * Holds `page` to `origin` while a login runs, until `release` resolves.
 * Request interception pauses every request of the page: one for `origin`,
 * or for a data: URL, which never leaves the browser, continues, and any
 * other is aborted. Each paused request is continued or aborted exactly
 * once, unless another handler already resolved it.
 *
 * A request off `origin` is a violation, as is a navigation of the main
 * frame off it, which an aborted request causes too. So is any other
 * target in the page's browser context, such as a window the page opens,
 * and any service worker's script, since the page's interception does not
 * see their requests: `holdOtherTargets` closes the target, a new one
 * before it runs, and blocks the script. The first violation aborts
 * `signal`, and `violations` keeps each one. A violation names the
 * configured origin and the request's method and type or the target's
 * type, never an address: once the credentials are typed, the page can put
 * them into any part of an address, its host included.
 */
export async function guardLoginOrigin(page, origin) {
    const violations = []
    const controller = new AbortController()
    const violate = (reason) => {
        violations.push(reason)
        if (!controller.signal.aborted) {
            controller.abort(new Error(reason))
        }
    }
    const onRequest = (request) => {
        try {
            const url = request.url()
            const allowed = url.startsWith("data:") || isOnOrigin(url, origin)
            const { action } = request.interceptResolutionState()
            const paused = action !== "disabled" && action !== "already-handled"
            if (paused) {
                const resolution = allowed
                    ? request.continue()
                    : request.abort("blockedbyclient")
                resolution.catch((error) => console.error(describeError(error)))
            }
            if (!allowed) {
                violate(
                    `the page sent ${describeRequest(request)} to an origin other than ${origin} during the login; ${paused ? "it was blocked" : "it could not be blocked"}`
                )
            }
        } catch (error) {
            // An error thrown here would break Puppeteer's event dispatch.
            console.error(describeError(error))
        }
    }
    const onFrameNavigated = (frame) => {
        try {
            if (
                frame.parentFrame() === null &&
                !isOnOrigin(frame.url(), origin)
            ) {
                violate(`the page's main frame left ${origin} during the login`)
            }
        } catch (error) {
            console.error(describeError(error))
        }
    }
    const stop = () => {
        page.off("request", onRequest)
        page.off("framenavigated", onFrameNavigated)
    }
    page.on("request", onRequest)
    page.on("framenavigated", onFrameNavigated)
    let releaseTargets
    try {
        await page.setRequestInterception(true)
        releaseTargets = await holdOtherTargets(page, origin, violate)
    } catch (error) {
        // Interception may have started on part of the page: turning it off
        // releases what it paused before the listeners that resolve it go.
        await new Promise((resolve) =>
            resolve(page.setRequestInterception(false))
        ).catch((cleanupError) => console.error(describeError(cleanupError)))
        stop()
        throw error
    }
    return {
        violations,
        signal: controller.signal,
        release: async () => {
            try {
                await page.setRequestInterception(false)
            } finally {
                stop()
                await releaseTargets()
            }
        },
    }
}

/**
 * Throws the error that ends a login once `guard` has seen a violation,
 * naming the first and counting the others. `cause` is the error, if any,
 * of the step the violation interrupted.
 */
function throwIfViolated(account, guard, cause) {
    const [first, ...others] = guard.violations
    if (first === undefined) {
        return
    }
    throw new Error(
        `login as ${account.username} refused: ${first}` +
            (others.length > 0
                ? `; ${plural(others.length, "further violation")}`
                : ""),
        cause === undefined ? undefined : { cause }
    )
}

/** The error of a login refused before any credential was typed. */
function loginRefusal(account, reasons) {
    return new Error(
        `login as ${account.username} refused before entering credentials: ${reasons.join("; ")}`
    )
}

/**
 * Fills in and sends the login form of `session`'s page under `guard`,
 * once the page and its form are found on `baseUrl`. A violation seen
 * before a step, or while it ran, ends the login instead.
 */
async function submitLoginForm(session, baseUrl, guard) {
    const { page, account } = session
    const problems = loginPageProblems(
        page.url(),
        await page.evaluate(readLoginForm, LOGIN_FIELDS, PASSWORD_FIELD),
        baseUrl
    )
    if (problems.length > 0) {
        throw loginRefusal(account, problems)
    }
    for (const step of [
        () => page.type("#login", account.username),
        () => page.type(PASSWORD_FIELD, account.password),
        () => page.click("#submitButton"),
    ]) {
        throwIfViolated(account, guard)
        try {
            await step()
        } catch (error) {
            throwIfViolated(account, guard, error)
            throw error
        }
    }
}

/**
 * Ends `guard`. After a failed login an error ending it is only logged:
 * the login's own error is the one reported.
 */
async function releaseGuard(guard, loginFailed) {
    try {
        await guard.release()
    } catch (error) {
        if (!loginFailed) {
            throw error
        }
        console.error(describeError(error))
    }
}

/**
 * Signs `session`'s account in through the login form, landing on /home.
 * The credentials go to `baseUrl` only: the navigation, the page, its
 * document and its login form must be on that origin, and the form must
 * submit into the page itself, before anything is typed; `guardLoginOrigin`
 * blocks and fails any request or main-frame navigation off it, and fails
 * and closes any other target in the page's browser context, until /home
 * is reached. A refusal names origins, paths, selectors and target types
 * only, never what was typed.
 */
export async function login(session, baseUrl) {
    const { page, account } = session
    const hop = offOriginHop(
        await page.goto(baseUrl, { waitUntil: "domcontentloaded" }),
        baseUrl
    )
    if (hop !== null) {
        throw loginRefusal(account, [
            `the navigation to ${baseUrl} was redirected to ${hop}`,
        ])
    }
    await page.waitForSelector("#login", { timeout: PAGE_TIMEOUT_MS })
    const guard = await guardLoginOrigin(page, baseUrl)
    let failed = true
    try {
        await submitLoginForm(session, baseUrl, guard)
        try {
            await page.waitForSelector("#nav-home", {
                timeout: PAGE_TIMEOUT_MS,
                signal: guard.signal,
            })
        } catch (error) {
            throwIfViolated(account, guard, error)
            // Only their number: an error Toast's text is the service's answer.
            const errorToasts = session.toasts.filter(
                (toast) => toastVariant(toast.className) === "error"
            ).length
            throw new Error(
                `login as ${account.username} never reached #nav-home: ${errorMessage(error)}` +
                    (errorToasts > 0
                        ? `; the page showed ${plural(errorToasts, "error Toast")}`
                        : ""),
                { cause: error }
            )
        }
        throwIfViolated(account, guard)
        failed = false
    } finally {
        await releaseGuard(guard, failed)
    }
    // A target the guard closed only as it ended fails the login too.
    throwIfViolated(account, guard)
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
export async function clickWhenClear(page, selector, timeoutMs) {
    await waitFor(
        (signal) =>
            probePage(page, signal, () => page.evaluate(isClickable, selector)),
        {
            timeoutMs,
            what: `${selector} to be enabled and uncovered`,
        }
    )
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
        console.error(describeError(error))
        problems.push(`screenshot ${fileName} failed: ${errorMessage(error)}`)
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
 * `signedCurrency` values are written as `InsightsSummary` writes the signed
 * P/L: the magnitude in the `currency` format, after a minus for a loss, with
 * a magnitude below one cent first rounded to whole cents, and unsigned once
 * rounded to 0.
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
    const formatCurrency = (n) =>
        (n < 0.01 ? smallCurrency : currency).format(n)
    return {
        currency: values.currency.map(formatCurrency),
        signedCurrency: values.signedCurrency.map((n) => {
            const absolute = Math.abs(n)
            const magnitude =
                absolute < 0.01 ? Math.round(absolute * 100) / 100 : absolute
            const text = formatCurrency(magnitude)
            return n < 0 && magnitude > 0 ? `-${text}` : text
        }),
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

// The evidence keeps a response field only in the form the broker defines
// for it; anything else becomes `null`, or, where `null` has a meaning of its
// own, a description that does not repeat the value.

function booleanOrNull(value) {
    return typeof value === "boolean" ? value : null
}

function integerOrNull(value) {
    return Number.isInteger(value) ? value : null
}

function finiteOrNull(value) {
    return isFiniteNumber(value) ? value : null
}

function uuidOrNull(value) {
    return typeof value === "string" && UUID_PATTERN.test(value)
        ? value.toLowerCase()
        : null
}

function isTimestamp(value) {
    return typeof value === "string" && TIMESTAMP_PATTERN.test(value)
}

/** A timestamp or `null` as received; anything else only described. */
function projectTimestamp(value) {
    return value === null || isTimestamp(value)
        ? value
        : `not a timestamp: ${describeValue(value)}`
}

/** `describeValue`, which also prints a well-formed timestamp. */
export function describeTimestamp(value) {
    return isTimestamp(value) ? JSON.stringify(value) : describeValue(value)
}

/** Why a read notification body is no poll answer; it is never described. */
const NOT_A_RESULTS_LIST = "the body is not a results list"

/**
 * Whether a response's body was read as the `{"results": [...]}` list the
 * notifications endpoint answers with, the only body the frontend applies
 * (`toAlertsDto`): a JSON object whose `results` is an array.
 */
function hasResultsList(entry) {
    return (
        entry.parsed &&
        isPlainObject(entry.body) &&
        Array.isArray(entry.body.results)
    )
}

/**
 * Whether a response counts as a notification poll the page made as the
 * frontend does: an accepted answer (`responseRejection`), so no reply of
 * another origin, method, account or filter, or of any status but 200, and
 * one whose body was read as a results list (`hasResultsList`), so no reply
 * the frontend would reject either.
 */
function isPollAnswer(entry) {
    return (
        entry.kind === "notifications" &&
        entry.accepted &&
        hasResultsList(entry)
    )
}

/** The notification polls of the page, in arrival order (`isPollAnswer`). */
export function notificationEntries(session) {
    return session.responses.filter(isPollAnswer)
}

/**
 * Every fixture arming a notification response showed as triggered. An item
 * without an integer `armingRevision` names no arming and is skipped.
 */
export function triggeredArmings(session, alerts) {
    const ids = new Set(alerts.map((alert) => alert.id))
    const armings = new Map()
    for (const entry of notificationEntries(session)) {
        for (const item of resultsOf(entry)) {
            const id = idOf(item)
            if (
                !ids.has(id) ||
                !Number.isInteger(item.armingRevision) ||
                !isTriggered(item)
            ) {
                continue
            }
            const key = armingKey(id, item.armingRevision)
            if (armings.has(key)) {
                continue
            }
            armings.set(key, {
                key,
                id,
                armingRevision: item.armingRevision,
                triggeredAt: projectTimestamp(item.triggeredAt),
                firstSeenAt: new Date(entry.at).toISOString(),
            })
        }
    }
    return armings
}

/**
 * What the checks read from a triggered-alert Toast's text, or `null` for
 * any other text: the alert type and direction, and the threshold and "now"
 * value where each is in the form `formatAlertNumber` gives it, else `null`.
 * The instrument part is page text and is never kept.
 */
function parseAlertToast(text) {
    const match = TOAST_PATTERN.exec(text)
    if (match === null) {
        return null
    }
    const alertNumberOrNull = (value) =>
        ALERT_NUMBER_PATTERN.test(value) ? value : null
    return {
        type: TOAST_TYPES[match[2]],
        direction: TOAST_DIRECTIONS[match[3]],
        threshold: alertNumberOrNull(match[4]),
        now: alertNumberOrNull(match[5]),
    }
}

/**
 * The fixture alert a Toast names, or `null` for any other Toast. A
 * threshold outside the form `formatAlertNumber` gives it names no alert.
 */
function fixtureAlertOf(text, alerts) {
    const parsed = parseAlertToast(text)
    if (parsed === null || parsed.threshold === null) {
        return null
    }
    const { type, direction } = parsed
    const threshold = Number(parsed.threshold.replaceAll(",", ""))
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
 * the Toast, that showed it triggered under an integer revision. A Toast no
 * response explains keeps a `null` key.
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
                    idOf(candidate) === alert.id &&
                    Number.isInteger(candidate.armingRevision) &&
                    isTriggered(candidate)
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
 * What the evidence and the problems keep of a Toast that names a fixture
 * alert: this check's own account label, alert id, arming and time, the
 * type, direction, threshold and "now" value `parseAlertToast` validates,
 * and the page path only when it is a plain path. Its text, the instrument
 * name included, is never kept.
 */
function projectAlertToast(toast) {
    const parsed = parseAlertToast(toast.text)
    return {
        account: toast.account,
        alertId: toast.alertId,
        armingRevision: toast.armingRevision,
        key: toast.key,
        at: isTimestamp(toast.at) ? toast.at : null,
        type: parsed?.type ?? null,
        direction: parsed?.direction ?? null,
        threshold: parsed?.threshold ?? null,
        now: parsed?.now ?? null,
        url:
            typeof toast.url === "string" && TOAST_PATH_PATTERN.test(toast.url)
                ? toast.url
                : null,
    }
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
 * Each of the `expected` armings, which an authoritative notification read
 * showed triggered, must also be in the page's notification responses and
 * have exactly one Toast (`reconcileArmings`).
 */
async function expectOneToastPerArming(
    problems,
    session,
    alerts,
    expected = []
) {
    await settleBodies(session)
    attributeToasts(session, alerts)
    const armings = triggeredArmings(session, alerts)
    problems.push(...reconcileArmings(expected, armings, toastCounts(session)))
    for (const toast of session.toasts) {
        if (toast.alertId !== null && toast.key === null) {
            // Described by validated fields: a Toast's text is page text.
            const { alertId, type, direction, at } = projectAlertToast(toast)
            problems.push(
                `a ${type} ${direction} Toast of alert ${alertId}, shown at ${at}, follows no notification showing it triggered`
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
        return `the insights response has an unknown riskLevel, ${describeValue(body.riskLevel)}`
    }
    return null
}

/** An allocation as the evidence keeps it, or `null` for a non-object. */
function projectAllocation(value) {
    if (!isPlainObject(value)) {
        return null
    }
    return {
        instrumentId: uuidOrNull(value.instrumentId),
        name:
            typeof value.name === "string"
                ? boundText(escapeControl(value.name), MAX_COMPARED_CHARS)
                : null,
        quantity: finiteOrNull(value.quantity),
        value: finiteOrNull(value.value),
        percent: finiteOrNull(value.percent),
    }
}

/**
 * What the evidence keeps of an insights response: each field the page
 * shows, in the form the broker defines for it, and no other field.
 */
export function projectInsights(body) {
    if (!isPlainObject(body)) {
        return null
    }
    return {
        totalValue: finiteOrNull(body.totalValue),
        totalInvested: finiteOrNull(body.totalInvested),
        unrealizedPnl: finiteOrNull(body.unrealizedPnl),
        unrealizedPnlPercent: finiteOrNull(body.unrealizedPnlPercent),
        allocations: Array.isArray(body.allocations)
            ? body.allocations.map(projectAllocation)
            : null,
        largestPosition: projectAllocation(body.largestPosition),
        riskLevel:
            typeof body.riskLevel === "string" &&
            Object.hasOwn(RISK_LABELS, body.riskLevel)
                ? body.riskLevel
                : null,
    }
}

/**
 * The defined form of each kind of page text `compareInsights` reads, as
 * `formatInPage`, `String(quantity)` and `InsightsSummary` write it. Text in
 * its element's form carries no free text, so a problem and the evidence may
 * repeat it even where it differs from the expected value.
 */
const DOM_TEXT_FORMS = {
    currency: (text) => CURRENCY_TEXT_PATTERN.test(text),
    percent: (text) => PERCENT_TEXT_PATTERN.test(text),
    quantity: (text) => {
        const quantity = Number(text)
        return Number.isFinite(quantity) && String(quantity) === text
    },
    riskLabel: (text) => Object.values(RISK_LABELS).includes(text),
    noValue: (text) => text === "\u2014",
    none: () => false,
}

/**
 * A value `compareInsights` compared, as the evidence keeps it (`shown`) and
 * a problem prints it (`text`): `null`, a boolean or a finite number as it
 * is; a string, escaped and bounded, when `verbatim`; any other value only
 * by its kind and size (`describeValue`).
 */
function comparedValue(value, verbatim) {
    if (typeof value === "string" && verbatim) {
        const shown = boundText(escapeControl(value), MAX_COMPARED_CHARS)
        return { shown, text: JSON.stringify(shown) }
    }
    if (value === null || typeof value === "boolean" || isFiniteNumber(value)) {
        return { shown: value, text: JSON.stringify(value) }
    }
    const description = describeValue(value)
    return { shown: description, text: description }
}

/**
 * Compares what the page shows with the insights response `body`. Each
 * figure span and table cell holds only its value as `InsightsSummary` and
 * `AllocationTable` render it, so its trimmed text must equal that string
 * exactly: money and percents formatted as `FormatterContext` does, the
 * signed P/L as its magnitude so formatted, below one cent rounded to whole
 * cents, after a minus for a loss that does not round to 0 (`signedCurrency`
 * of `formatInPage`), the quantity as `String(quantity)`, and the largest
 * position as `name (percent)`, or the no-value dash when the response has
 * none.
 *
 * A pair and a problem repeat the page's text only where it equals the
 * expected value or is in its element's defined form (`DOM_TEXT_FORMS`),
 * escaped and bounded; other page text is described by its kind and size.
 * Expected values, which come from the response, are escaped and bounded.
 */
export async function compareInsights(page, dom, body) {
    const shapeProblem = insightsShapeProblem(body)
    if (shapeProblem !== null) {
        return { problems: [shapeProblem], pairs: [], response: body }
    }
    /** What `InsightsSummary` shows where the broker reports no value. */
    const noValue = "\u2014"
    const { allocations, largestPosition } = body
    const formats = await page.evaluate(formatInPage, {
        currency: [
            body.totalValue,
            body.totalInvested,
            ...allocations.map((allocation) => allocation.value),
        ],
        signedCurrency: [body.unrealizedPnl],
        percent: [
            body.unrealizedPnlPercent,
            ...allocations.map((allocation) => allocation.percent),
            ...(largestPosition === null ? [] : [largestPosition.percent]),
        ],
    })
    const problems = []
    const pairs = []
    const compare = (element, actual, expected, form = DOM_TEXT_FORMS.none) => {
        const ok = actual === expected
        const shown = comparedValue(
            actual,
            ok || (typeof actual === "string" && form(actual))
        )
        const wanted = comparedValue(expected, true)
        pairs.push({ element, dom: shown.shown, expected: wanted.shown, ok })
        if (!ok) {
            problems.push(
                `${element} shows ${shown.text}, expected ${wanted.text}`
            )
        }
    }
    compare(
        "#insights-total-value",
        dom.totalValue,
        formats.currency[0],
        DOM_TEXT_FORMS.currency
    )
    compare(
        "#insights-total-invested",
        dom.totalInvested,
        formats.currency[1],
        DOM_TEXT_FORMS.currency
    )
    compare(
        "#insights-unrealized-pnl",
        dom.unrealizedPnl,
        formats.signedCurrency[0],
        DOM_TEXT_FORMS.currency
    )
    compare(
        "#insights-unrealized-pnl-percent",
        dom.unrealizedPnlPercent,
        formats.percent[0],
        DOM_TEXT_FORMS.percent
    )
    compare(
        "#insights-largest-position",
        dom.largestPosition,
        largestPosition === null
            ? noValue
            : `${largestPosition.name} (${formats.percent[formats.percent.length - 1]})`.trim(),
        DOM_TEXT_FORMS.noValue
    )
    compare(
        "#insights-risk-badge",
        dom.riskBadge,
        body.riskLevel === null ? null : RISK_LABELS[body.riskLevel],
        DOM_TEXT_FORMS.riskLabel
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
            compare(
                `${row} instrument`,
                cells[0] ?? null,
                allocation.name.trim()
            )
            compare(
                `${row} quantity`,
                cells[1] ?? null,
                String(allocation.quantity),
                DOM_TEXT_FORMS.quantity
            )
            compare(
                `${row} value`,
                cells[2] ?? null,
                formats.currency[2 + index],
                DOM_TEXT_FORMS.currency
            )
            compare(
                `${row} allocation`,
                cells[3] ?? null,
                formats.percent[1 + index],
                DOM_TEXT_FORMS.percent
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
 * until the page has rendered that response. A read, from the DOM read to
 * the end of the formatting, during which a newer response arrived compared
 * an outdated response; it is discarded and repeated, at most
 * `MAX_UNSTABLE_READS` times. A last response the recorder did not accept,
 * or whose body cannot be read, is reported by its fixed reason and never
 * compared.
 *
 * Only a read the wait accepted is returned: a matching read once the wait
 * resolves with it, and on a timeout the last mismatch that answered by the
 * deadline. A read answering later never counts; without an accepted read,
 * a timeout reports the missing response, or else the timeout itself.
 */
export async function compareWithLastInsights(session) {
    let unstableReads = 0
    let last = null
    const deadline = performance.now() + RENDER_TIMEOUT_MS
    try {
        const matched = await waitFor(
            (signal) =>
                probePage(session.page, signal, async () => {
                    const publish = (read) => {
                        if (!signal.aborted && performance.now() <= deadline) {
                            last = read
                        }
                    }
                    const entries = insightsEntries(session)
                    const latest = entries[entries.length - 1]
                    if (latest === undefined) {
                        return false
                    }
                    // A response that does not answer the frontend's own
                    // read, a non-200 included, is never compared.
                    if (!latest.accepted) {
                        publish({
                            problems: [
                                `the last insights response ${latest.rejection}`,
                            ],
                            pairs: [],
                            response: null,
                        })
                        return false
                    }
                    if (!latest.parsed) {
                        if (latest.bodyError === undefined) {
                            return false
                        }
                        publish({
                            problems: [
                                `the last insights response answered HTTP ${latest.status} with an unreadable body: ${latest.bodyError}`,
                            ],
                            pairs: [],
                            response: null,
                        })
                        return false
                    }
                    const dom = await session.page.evaluate(readInsightsDom)
                    const comparison = await compareInsights(
                        session.page,
                        dom,
                        latest.body
                    )
                    // Both the DOM read and the formatting await the page, so
                    // a newer response can arrive during either.
                    const current = insightsEntries(session)
                    if (
                        current.length !== entries.length ||
                        current[current.length - 1] !== latest
                    ) {
                        unstableReads += 1
                        if (unstableReads >= MAX_UNSTABLE_READS) {
                            throw new Error(
                                `unstable: a newer insights response arrived during each of ${unstableReads} reads`
                            )
                        }
                        return false
                    }
                    if (comparison.problems.length > 0) {
                        publish(comparison)
                        return false
                    }
                    return comparison
                }),
            {
                timeoutMs: RENDER_TIMEOUT_MS,
                deadline,
                what: "the page to show its last insights response",
            }
        )
        return { ...matched, unstableReads }
    } catch (error) {
        if (!(error instanceof WaitTimeoutError)) {
            throw error
        }
        if (last !== null) {
            return { ...last, unstableReads }
        }
        return {
            problems: [
                insightsEntries(session).length === 0
                    ? "the page received no insights response"
                    : error.message,
            ],
            pairs: [],
            response: null,
            unstableReads,
        }
    }
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
    report.compared.pageEqualsResponse = {
        ...comparison,
        response: projectInsights(comparison.response),
    }
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
    const session = await openSession(
        browser,
        report,
        "empty",
        account,
        baseUrl
    )
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
        // The assertions below read the response as received; the evidence
        // keeps its projection.
        const body = comparison.response
        report.compared.emptyState = {
            ...comparison,
            response: projectInsights(body),
        }
        details.unstableReads = comparison.unstableReads
        problems.push(...comparison.problems)
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
            expectEqual(
                problems,
                "response riskLevel",
                body.riskLevel,
                null,
                Object.keys(RISK_LABELS)
            )
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
            console.error(describeError(error))
            problems.push(
                `closing the empty account's page failed: ${errorMessage(error)}`
            )
        }
    }
}

/** Deadline of the check's own notification read, its body included. */
const NOTIFICATION_READ_TIMEOUT_MS = 10_000

/**
 * A failed notification read. Its message names only the method, the path,
 * the HTTP status and a fixed classification, never response text, a parser
 * message or a field value, since it reaches the FAIL line, stderr and the
 * evidence. `status` is the HTTP status, or `null` when none arrived.
 */
export class NotificationReadError extends Error {
    constructor(message, status) {
        super(message)
        this.name = "NotificationReadError"
        this.status = status
    }
}

/**
 * Reads the notifications of `accountId` through the broker API, apart from
 * any page: every alert whose current arming has triggered, acknowledged or
 * not. Resolves with the HTTP status and the `results` list of a 200; any
 * other outcome, another 2xx or a redirect included, throws a
 * `NotificationReadError`, and a redirect is never followed. An invalid
 * `timeoutMs` is not one: `AbortSignal.timeout` throws for it before any
 * request is sent.
 */
export async function readNotifications(
    baseUrl,
    accountId,
    { timeoutMs = NOTIFICATION_READ_TIMEOUT_MS } = {}
) {
    if (typeof accountId !== "string" || !UUID_PATTERN.test(accountId)) {
        throw new NotificationReadError(
            `GET ${NOTIFICATIONS_PATH} needs a UUID accountId`,
            null
        )
    }
    const target = `${NOTIFICATIONS_PATH}?accountId=${accountId.toLowerCase()}`
    // Created outside the try: a bad deadline is no transport failure.
    const signal = AbortSignal.timeout(timeoutMs)
    let response
    let text
    try {
        response = await fetch(`${baseUrl}${target}`, {
            headers: { Accept: "application/json" },
            redirect: "manual",
            signal,
        })
        text = await response.text()
    } catch (error) {
        throw new NotificationReadError(
            `GET ${target} failed: ${transportFailure(error, timeoutMs)}`,
            response?.status ?? null
        )
    }
    if (response.status !== 200) {
        throw new NotificationReadError(
            `GET ${target} ${statusFailure(response.status)}`,
            response.status
        )
    }
    let body
    try {
        body = JSON.parse(text)
    } catch {
        // The parser's message quotes the body, so it is not repeated.
        throw new NotificationReadError(
            `GET ${target} answered HTTP ${response.status} with a body that is not JSON`,
            response.status
        )
    }
    if (!isPlainObject(body) || !Array.isArray(body.results)) {
        throw new NotificationReadError(
            `GET ${target} answered HTTP ${response.status} without a results list`,
            response.status
        )
    }
    return { status: response.status, results: body.results }
}

/**
 * The fixture armings an authoritative notification read shows triggered,
 * which the page must each toast once, and what is wrong with that read.
 * An arming is keyed by the read's revision, which must be an integer equal
 * to the fixture's, since nothing re-arms a fixture alert between e2e.sh
 * writing the fixture and this check. Each pair needs an expected arming,
 * because step 9 of e2e.sh saw one per pair trigger. Only validated values
 * reach the armings and the problems.
 */
export function expectedArmings(results, alerts) {
    const fixtureAlerts = new Map(alerts.map((alert) => [alert.id, alert]))
    const expected = []
    const problems = []
    const listed = new Set()
    const repeated = new Set()
    results.forEach((item, index) => {
        const id = idOf(item)
        if (id === null || !UUID_PATTERN.test(id)) {
            problems.push(
                `the notifications read gives results[${index}] no UUID id`
            )
            return
        }
        const alert = fixtureAlerts.get(id)
        if (alert === undefined) {
            return
        }
        if (listed.has(id)) {
            repeated.add(id)
            return
        }
        listed.add(id)
        if (!isTriggered(item)) {
            problems.push(
                `the notifications read lists alert ${id} without a triggeredAt`
            )
            return
        }
        if (!Number.isInteger(item.armingRevision)) {
            problems.push(
                `the notifications read gives alert ${id} no integer armingRevision`
            )
            return
        }
        if (item.armingRevision !== alert.armingRevision) {
            problems.push(
                `the notifications read gives alert ${id} armingRevision ${item.armingRevision}, but the fixture holds ${alert.armingRevision}`
            )
        }
        expected.push({
            key: armingKey(id, item.armingRevision),
            id,
            armingRevision: item.armingRevision,
            pair: alert.pair,
            direction: alert.direction,
        })
    })
    for (const id of repeated) {
        problems.push(`the notifications read lists alert ${id} more than once`)
    }
    for (const pair of Object.keys(PAIR_TYPES)) {
        if (!expected.some((arming) => arming.pair === pair)) {
            problems.push(
                `the notifications read shows no ${pair} fixture alert triggered, though step 9 of e2e.sh saw one per pair trigger`
            )
        }
    }
    return { expected, problems }
}

/**
 * The problems of the one-Toast-per-arming rule. `observed` maps the key of
 * every fixture arming the page's notification responses showed triggered,
 * and `counts` maps a key to the Toasts attributed to it. Each `expected`
 * arming must be among the observed ones, and every expected or observed
 * arming must have exactly one Toast. Without expected armings, only the
 * observed ones are judged.
 */
export function reconcileArmings(expected, observed, counts) {
    const problems = []
    for (const arming of expected) {
        if (!observed.has(arming.key)) {
            problems.push(
                `no notification response of the page shows arming ${arming.key} (${arming.pair} ${arming.direction}) triggered, though the notifications read does`
            )
        }
    }
    const keys = new Set([
        ...expected.map((arming) => arming.key),
        ...observed.keys(),
    ])
    for (const key of keys) {
        const count = counts.get(key) ?? 0
        if (count !== 1) {
            problems.push(`arming ${key} has ${count} Toasts, expected 1`)
        }
    }
    return problems
}

/**
 * One Toast per arming. Before the page's polls are awaited, the holder's
 * notifications are read through the API, apart from the page; the fixture
 * armings that read shows triggered are the expected ones, one per pair at
 * least (`expectedArmings`). After four notification responses, a reload
 * and two more, each expected arming must be in the page's responses, and
 * it and every other triggered fixture arming the page saw must have
 * exactly one Toast over the whole session, the reload included. A failed
 * read is a problem, and the page is still judged on the armings it saw.
 */
export async function checkOneToastPerArming(
    problems,
    details,
    baseUrl,
    holder,
    alerts
) {
    const { page } = holder
    let expected = []
    try {
        const read = await readNotifications(baseUrl, holder.account.accountId)
        const authoritative = expectedArmings(read.results, alerts)
        expected = authoritative.expected
        problems.push(...authoritative.problems)
        details.authoritativeRead = {
            path: NOTIFICATIONS_PATH,
            status: read.status,
            results: read.results.length,
        }
    } catch (error) {
        if (!(error instanceof NotificationReadError)) {
            throw error
        }
        problems.push(error.message)
        details.authoritativeRead = {
            path: NOTIFICATIONS_PATH,
            status: error.status,
            error: error.message,
        }
    }
    details.expected = expected
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
    const armings = await expectOneToastPerArming(
        problems,
        holder,
        alerts,
        expected
    )
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
export async function waitForToggle(page, alertId, label) {
    return await waitFor(
        async (signal) => {
            const toggle = await probePage(page, signal, () =>
                page.evaluate(readRowToggle, rowSelector(alertId))
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

/**
 * The revision the page last received for `alert` in an accepted response,
 * else the fixture's.
 */
export function latestRevision(session, alert) {
    let revision = alert.armingRevision
    for (const entry of session.responses) {
        if (!entry.accepted || !entry.parsed) {
            continue
        }
        let item
        if (entry.kind === "alertsList" || entry.kind === "notifications") {
            item = resultsOf(entry).find(
                (candidate) => idOf(candidate) === alert.id
            )
        } else if (entry.kind === "patch") {
            item = idOf(entry.body) === alert.id ? entry.body : undefined
        }
        if (item !== undefined && Number.isInteger(item.armingRevision)) {
            revision = item.armingRevision
        }
    }
    return revision
}

/**
 * The label `AlertList` gives the `button.alert-toggle` of a row showing
 * `alert`: "Enable" while it is disabled, "Disable" while it is armed
 * (`triggeredAt` null) and "Re-arm" once it triggered (`triggeredAt` a
 * timestamp). `null` for any other state, which explains no label.
 */
function toggleLabelOf(alert) {
    if (alert.enabled === false) {
        return "Enable"
    }
    if (alert.enabled !== true) {
        return null
    }
    if (alert.triggeredAt === null) {
        return "Disable"
    }
    return isTimestamp(alert.triggeredAt) ? "Re-arm" : null
}

/**
 * The state the page last received for `alert` in an accepted response,
 * from the entries `latestRevision` reads. Answers `alert`, the newest item
 * naming it, else the fixture's alert, which carries no state; `received`,
 * whether any accepted response named it; `pending`, whether an accepted
 * response that may name it is still being read, so a newer state may yet
 * arrive; and `previous`, the toggle label (`toggleLabelOf`) of the state
 * received before the last change of that label, `null` for none, which a
 * row rendered from an earlier list may still show.
 */
function latestAlertState(session, alert) {
    let latest = alert
    let pending = false
    let previous = null
    for (const entry of session.responses) {
        if (!entry.accepted || !ALERT_STATE_KINDS.includes(entry.kind)) {
            continue
        }
        if (!entry.parsed) {
            // A PATCH of another alert cannot carry this one's state.
            pending ||=
                entry.bodyError === undefined &&
                (entry.kind !== "patch" || entry.alertId === alert.id)
            continue
        }
        const item =
            entry.kind === "patch"
                ? idOf(entry.body) === alert.id
                    ? entry.body
                    : undefined
                : resultsOf(entry).find(
                      (candidate) => idOf(candidate) === alert.id
                  )
        if (item === undefined) {
            continue
        }
        if (latest !== alert && toggleLabelOf(latest) !== toggleLabelOf(item)) {
            previous = toggleLabelOf(latest)
        }
        latest = item
    }
    return { alert: latest, received: latest !== alert, pending, previous }
}

/**
 * Waits for the first PATCH response of `alertId` after `afterSeq`, the one
 * the click then caused, until what its request sent and, for an accepted
 * one, its body have been read. It is returned whatever it answered, for
 * `patchAnswerProblems` to judge.
 */
async function waitForPatchResponse(session, alertId, afterSeq) {
    return await waitFor(
        () => {
            const entry = session.responses.find(
                (candidate) =>
                    candidate.kind === "patch" &&
                    candidate.alertId === alertId &&
                    candidate.seq > afterSeq
            )
            return entry !== undefined &&
                entry.sentEnabled !== undefined &&
                (!entry.accepted ||
                    entry.parsed ||
                    entry.bodyError !== undefined)
                ? entry
                : false
        },
        {
            timeoutMs: ROW_TIMEOUT_MS,
            what: `the PATCH response of alert ${alertId}`,
        }
    )
}

/**
 * What the answer `entry` to a toggle's PATCH lacks of the action that sends
 * `enabled`, as the list of what was expected, empty when it lacks nothing.
 * The request must have sent `enabled`, and an accepted 200 for `alertId`
 * must answer the state the broker's PATCH sets, as an `AlertDTO`, which
 * carries every field: `true` re-arms, so `enabled` is true, `triggeredAt`
 * and `triggerValue` null, `acknowledged` false, and `armingRevision`
 * exactly `before` + 1, `before` being the revision the page held before the
 * click; `false` sets only `enabled` false and keeps any trigger data, so
 * `armingRevision` stays `before`.
 */
function patchAnswerProblems(entry, alertId, enabled, before) {
    const expected = []
    if (entry.sentEnabled !== enabled) {
        expected.push(`to send enabled ${enabled}`)
    }
    if (!entry.accepted) {
        expected.push("an accepted 200 answer")
        return expected
    }
    if (!entry.parsed || !isPlainObject(entry.body)) {
        expected.push("a JSON object body")
        return expected
    }
    const { body } = entry
    if (idOf(body) !== alertId) {
        expected.push(`the answer for alert ${alertId}`)
    }
    if (body.enabled !== enabled) {
        expected.push(`enabled ${enabled}`)
    }
    if (!enabled) {
        if (body.armingRevision !== before) {
            expected.push(`armingRevision ${before}`)
        }
        return expected
    }
    if (body.triggeredAt !== null) {
        expected.push("triggeredAt null")
    }
    if (body.triggerValue !== null) {
        expected.push("triggerValue null")
    }
    if (body.acknowledged !== false) {
        expected.push("acknowledged false")
    }
    if (body.armingRevision !== before + 1) {
        expected.push(`armingRevision ${before + 1}`)
    }
    return expected
}

/** What a PATCH request sent, from its recorded `sentEnabled`. */
function describeSent(sentEnabled) {
    return typeof sentEnabled === "boolean"
        ? `enabled ${sentEnabled}`
        : 'no {"enabled": bool} body'
}

/** How a toggle's PATCH was answered, in defined forms only. */
function describePatchAnswer(entry) {
    if (!entry.accepted) {
        return `its response ${entry.rejection}`
    }
    if (!entry.parsed || !isPlainObject(entry.body)) {
        return `its response body is unreadable: ${entry.bodyError ?? "not a JSON object"}`
    }
    const { body } = entry
    const id = uuidOrNull(body.id) ?? describeValue(body.id)
    return `was answered for alert ${id} with enabled ${describeValue(body.enabled)}, triggeredAt ${describeTimestamp(body.triggeredAt)}, triggerValue ${describeValue(body.triggerValue)}, acknowledged ${describeValue(body.acknowledged)} and armingRevision ${describeValue(body.armingRevision)}`
}

/**
 * In the page: once the `button.alert-toggle` of the row `row` is enabled,
 * shows `label` and is clear to click, as `isClickable` tells, arms a guard
 * on the next click; answers `armed` and the label shown, `null` without a
 * toggle. The guard meets the click before the page's own handlers and
 * stops it unless it meets that toggle still showing `label`: the row may
 * have changed state since this check, and a stopped click sends nothing.
 * It records the label of the row's toggle the click met, `null` for
 * anything else. Arming removes a guard left from before.
 */
function armToggleGuard(row, label) {
    const earlier = window.__piToggleGuard
    if (earlier !== undefined) {
        window.removeEventListener("click", earlier.listener, true)
        delete window.__piToggleGuard
    }
    const button = document.querySelector(`${row} button.alert-toggle`)
    if (button === null) {
        return { armed: false, label: null }
    }
    const shown = button.textContent.trim()
    if (shown !== label || button.disabled) {
        return { armed: false, label: shown }
    }
    button.scrollIntoView({ block: "center", inline: "center" })
    const box = button.getBoundingClientRect()
    const top = document.elementFromPoint(
        box.left + box.width / 2,
        box.top + box.height / 2
    )
    if (top === null || !button.contains(top)) {
        return { armed: false, label: shown }
    }
    const guard = { met: undefined, listener: null }
    guard.listener = (event) => {
        window.removeEventListener("click", guard.listener, true)
        const { target } = event
        const toggle =
            target instanceof window.Element && target.closest(row) !== null
                ? target.closest("button.alert-toggle")
                : null
        guard.met = toggle === null ? null : toggle.textContent.trim()
        if (guard.met !== label) {
            event.stopImmediatePropagation()
            event.preventDefault()
        }
    }
    window.addEventListener("click", guard.listener, true)
    window.__piToggleGuard = guard
    return { armed: true, label: shown }
}

/**
 * In the page: removes the guard `armToggleGuard` armed, and answers whether
 * a click event met it and the label of the row's toggle that click met,
 * `null` for anything else.
 */
function takeToggleGuard() {
    const guard = window.__piToggleGuard
    if (guard === undefined) {
        return { clicked: false, label: null }
    }
    window.removeEventListener("click", guard.listener, true)
    delete window.__piToggleGuard
    return { clicked: guard.met !== undefined, label: guard.met ?? null }
}

/** The row's toggle as `readRowToggle` reads it now, by a bounded probe. */
async function readToggleNow(page, alertId) {
    const { toggle } = await waitFor(
        async (signal) => ({
            toggle: await probePage(page, signal, () =>
                page.evaluate(readRowToggle, rowSelector(alertId))
            ),
        }),
        {
            timeoutMs: ROW_TIMEOUT_MS,
            what: `the toggle of alert ${alertId}`,
        }
    )
    return toggle
}

/**
 * Clicks the toggle of alert `alertId`'s row while it shows `label`, behind
 * the guard of `armToggleGuard`. Resolves with `null` once the click went
 * through, or with the page text the toggle showed instead: the row changed
 * state since `label` was sampled, and nothing was sent. A click that
 * failed, or met no toggle of the row, sent nothing either; it is such a
 * change only when the toggle now shows another label, and else throws.
 */
export async function clickShownToggle(page, alertId, label) {
    const row = rowSelector(alertId)
    const found = await waitFor(
        async (signal) => {
            const state = await probePage(page, signal, () =>
                page.evaluate(armToggleGuard, row, label)
            )
            return state.armed ||
                (state.label !== null && state.label !== label)
                ? state
                : false
        },
        {
            timeoutMs: ROW_TIMEOUT_MS,
            what: `the ${label} toggle of alert ${alertId} to be enabled and uncovered`,
        }
    )
    if (!found.armed) {
        return found.label
    }
    let failure = null
    try {
        await page.click(`${row} button.alert-toggle`)
    } catch (error) {
        failure = error
    }
    let click
    try {
        // Taken even after a failed click, so no guard is left to stop a
        // later one.
        click = await waitFor(
            (signal) =>
                probePage(page, signal, () => page.evaluate(takeToggleGuard)),
            {
                timeoutMs: ROW_TIMEOUT_MS,
                what: `the outcome of the click on the ${label} toggle of alert ${alertId}`,
            }
        )
    } catch (error) {
        if (failure === null) {
            throw error
        }
        // The click's own failure is the one reported.
        console.error(describeError(error))
        throw failure
    }
    if (click.label !== null) {
        if (failure !== null) {
            // The click event was dispatched, so its outcome stands.
            console.error(describeError(failure))
        }
        return click.label === label ? null : click.label
    }
    const toggle = await readToggleNow(page, alertId)
    if (toggle !== null && toggle.label !== label) {
        if (failure !== null) {
            console.error(describeError(failure))
        }
        return toggle.label
    }
    if (failure !== null) {
        throw failure
    }
    throw new Error(
        click.clicked
            ? `the click on the ${label} toggle of alert ${alertId} met another element and was stopped`
            : `no click event followed the click on the ${label} toggle of alert ${alertId}`
    )
}

/**
 * Why the state `latestAlertState` answered, `state`, explains no sampled
 * toggle label, in defined forms only.
 */
function unexplainedReason(state) {
    if (state.pending) {
        return "a response that may carry its state is still being read"
    }
    if (!state.received) {
        return "no accepted response named the alert"
    }
    const { alert } = state
    const shows = toggleLabelOf(alert)
    return `its last state, enabled ${describeValue(alert.enabled)} and triggeredAt ${describeTimestamp(alert.triggeredAt)}, shows ${shows === null ? "no toggle label" : `"${shows}"`}`
}

/**
 * Holds `label`, the label the toggle of `alert`'s row was sampled with, to
 * the state the page received for the alert (`latestAlertState`) before it
 * is clicked. Answers `label` once no response that may carry that state is
 * still being read and the last state shows it (`toggleLabelOf`). Answers
 * the label the toggle shows instead after a genuine transition: the
 * received state changed from one that shows `label` to one that shows the
 * toggle's new label, as when a notification shows a trigger before the
 * list the row renders is read again. Anything else is awaited, since the
 * page can render a response before its body is read here; once
 * ROW_TIMEOUT_MS have passed it throws why the label is not explained, and
 * nothing is clicked.
 */
async function waitForExplainedToggle(session, alert, label) {
    const { page } = session
    const explains = (state, shown) =>
        !state.pending && toggleLabelOf(state.alert) === shown
    try {
        return await waitFor(
            async (signal) => {
                if (explains(latestAlertState(session, alert), label)) {
                    return label
                }
                const toggle = await probePage(page, signal, () =>
                    page.evaluate(readRowToggle, rowSelector(alert.id))
                )
                const state = latestAlertState(session, alert)
                if (explains(state, label)) {
                    return label
                }
                return toggle !== null &&
                    !toggle.disabled &&
                    toggle.label !== label &&
                    state.previous === label &&
                    explains(state, toggle.label)
                    ? toggle.label
                    : false
            },
            {
                timeoutMs: ROW_TIMEOUT_MS,
                what: `the received state of alert ${alert.id} to explain its "${label}" toggle`,
            }
        )
    } catch (error) {
        if (!(error instanceof WaitTimeoutError)) {
            throw error
        }
        throw new Error(
            `the "${label}" toggle of alert ${alert.id} was not explained within ${ROW_TIMEOUT_MS} ms by the state the page received: ${unexplainedReason(latestAlertState(session, alert))}`,
            { cause: error }
        )
    }
}

/**
 * Samples the row's toggle, showing `wanted`, or any label for `null`, holds
 * the sampled label to the state the page received for the alert
 * (`waitForExplainedToggle`), and clicks it while it still shows that label
 * (`clickShownToggle`). A label that changed in between, a genuine change of
 * the row's state, is sampled again, MAX_TOGGLE_SAMPLES times in all at
 * most; a label the received state does not explain throws unclicked. The
 * PATCH the click caused is kept in the evidence and judged by
 * `patchAnswerProblems` against what the label sends (`TOGGLE_SENDS`); a
 * mismatch throws and is never retried. Returns the label clicked, the
 * response and the click's sequence number.
 */
async function clickToggle(session, report, member, wanted) {
    const { page } = session
    const { id } = member.alert
    for (let sample = 1; ; sample += 1) {
        const label = await waitForToggle(page, id, wanted)
        if (!TOGGLE_LABELS.includes(label)) {
            // Page text other than a known label is described, not repeated.
            throw new Error(`the row toggle reads ${describeValue(label)}`)
        }
        const shown = await waitForExplainedToggle(session, member.alert, label)
        const before = latestRevision(session, member.alert)
        const clickSeq = nextSequence()
        const clickedAt = new Date().toISOString()
        // A transition met before the click is sampled again, as one the
        // click meets is.
        const changed =
            shown === label ? await clickShownToggle(page, id, label) : shown
        if (changed !== null) {
            if (sample >= MAX_TOGGLE_SAMPLES) {
                throw new Error(
                    `the toggle of alert ${id} changed state before each of ${MAX_TOGGLE_SAMPLES} clicks, last from "${label}" to ${describeValue(changed, TOGGLE_LABELS)}`
                )
            }
            continue
        }
        const entry = await waitForPatchResponse(session, id, clickSeq)
        // Only an accepted, readable answer has fields to keep; `rejection`
        // or `bodyError` tells why another has none.
        const body =
            entry.accepted && entry.parsed && isPlainObject(entry.body)
                ? entry.body
                : null
        const snapshot = {
            alertId: id,
            clicked: label,
            clickedAt,
            sent: entry.sentEnabled,
            status: entry.status,
            rejection: entry.rejection,
            bodyError: entry.bodyError ?? null,
            answeredId: uuidOrNull(body?.id),
            enabled: booleanOrNull(body?.enabled),
            armingRevision: integerOrNull(body?.armingRevision),
            triggeredAt:
                body === null ? null : projectTimestamp(body.triggeredAt),
            acknowledged: booleanOrNull(body?.acknowledged),
        }
        member.patches.push(snapshot)
        report.patches.push(snapshot)
        const expected = patchAnswerProblems(
            entry,
            id,
            TOGGLE_SENDS[label],
            before
        )
        if (expected.length > 0) {
            throw new Error(
                `"${label}" on alert ${id} sent ${describeSent(entry.sentEnabled)} and ${describePatchAnswer(entry)}; expected ${expected.join(", ")}`
            )
        }
        return { label, entry, clickSeq }
    }
}

/**
 * Re-arms one fixture alert through its row, by the label its toggle shows:
 * "Re-arm" on a triggered row and "Enable" on a disabled one re-arm it at
 * once; "Disable" on an armed row is followed by "Enable" only once its
 * PATCH answered the alert disabled. `clickToggle` clicks only a label the
 * state the page received explains, judges each click by the label it was
 * made on, and samples again a row that changed state first.
 */
export async function rearmMember(session, report, alert) {
    const { page } = session
    await page.waitForSelector(rowSelector(alert.id), {
        timeout: ROW_TIMEOUT_MS,
    })
    const member = {
        alert,
        previousRevision: latestRevision(session, alert),
        initialState: null,
        patches: [],
        newRevision: null,
        enablingSeq: null,
    }
    let click = await clickToggle(session, report, member, null)
    member.initialState = click.label
    if (!TOGGLE_SENDS[click.label]) {
        click = await clickToggle(session, report, member, "Enable")
    }
    member.newRevision = click.entry.body.armingRevision
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
            console.error(describeError(error))
            problems.push(
                `re-arming ${alert.pair} ${alert.direction} alert ${alert.id}: ${errorMessage(error)}`
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

/**
 * What a problem and the evidence repeat of the ids `#alert-notifications`
 * lists: each canonical UUID, and only the number of any other id, since an
 * id there is a page attribute.
 */
export function summariseListedIds(listed) {
    const ids = listed.filter((id) => UUID_PATTERN.test(id))
    const withoutUuid = listed.length - ids.length
    const named =
        withoutUuid > 0
            ? [...ids, `${plural(withoutUuid, "item")} without a UUID id`]
            : ids
    return { ids, withoutUuid, text: named.join(", ") }
}

export async function checkAcknowledge(
    problems,
    details,
    report,
    holder,
    alerts
) {
    const { page } = holder
    await openInsightsPage(holder)
    const ids = new Set(alerts.map((alert) => alert.id))
    // Only a listing the wait accepts is reported: one read after the
    // deadline, or after the wait gave up, never counts.
    let listed = []
    const deadline = performance.now() + ACKNOWLEDGE_TIMEOUT_MS
    const alertId = await waitOrReport(problems, () =>
        waitFor(
            async (signal) => {
                const read = await probePage(page, signal, () =>
                    page.evaluate(readNotificationIds)
                )
                if (!signal.aborted && performance.now() <= deadline) {
                    listed = read
                }
                return read.find((id) => ids.has(id)) ?? false
            },
            {
                timeoutMs: ACKNOWLEDGE_TIMEOUT_MS,
                deadline,
                what: "a fixture alert in #alert-notifications",
            }
        )
    )
    const listing = summariseListedIds(listed)
    details.listed = listing.ids
    details.listedWithoutUuid = listing.withoutUuid
    if (alertId === null) {
        problems.push(
            listed.length === 0
                ? "#alert-notifications lists no notification"
                : `#alert-notifications lists only non-fixture alerts: ${listing.text}`
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
    // Only the answer to the frontend's own POST, a 204 from the page's
    // origin, acknowledged the alert.
    if (response.accepted) {
        report.acknowledged = { id: alertId, armingRevision }
    } else {
        problems.push(`the acknowledge response ${response.rejection}`)
    }
    await waitOrReport(problems, () =>
        waitFor(
            async (signal) =>
                !(await probePage(page, signal, () =>
                    isPresent(page, notificationSelector(alertId))
                )),
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

/**
 * In the page: the layout of each sidebar link in `ids`, and the sidebar's
 * height, or `null` without a sidebar. A link's position is its offset in
 * the sidebar's scrolled content, so a scrolled row reads the same, and its
 * line count is the number of line boxes its label text occupies.
 *
 * What tells whether a link is rendered is read beside its layout: whether
 * the sidebar contains it, how many layout boxes `getClientRects` gives it,
 * its computed `display` and `visibility`, and `checkVisibility` with the
 * opacity and visibility checks, which is `false` when the link has no box,
 * is hidden or collapsed, or it or an ancestor is fully transparent.
 *
 * Where the link leads is read the same way: whether it is an HTML anchor
 * and, for an anchor with an href, whether the URL the browser resolves
 * that href to has the page's own origin, and that URL's path, query and
 * fragment as `route`. Both are `null` for an element that is not an anchor
 * or has no href, and for an href that resolves to no URL. An opaque page
 * origin is same-origin with nothing.
 */
export function readLegacySidebar(ids) {
    const sidebar = document.querySelector(".sidebar")
    if (sidebar === null) {
        return null
    }
    const sidebarBox = sidebar.getBoundingClientRect()
    const lineCount = (link) => {
        const lineTops = new Set()
        for (const node of link.childNodes) {
            if (
                node.nodeType !== node.TEXT_NODE ||
                node.textContent.trim() === ""
            ) {
                continue
            }
            const range = document.createRange()
            range.selectNodeContents(node)
            for (const box of range.getClientRects()) {
                lineTops.add(Math.round(box.top))
            }
        }
        return lineTops.size
    }
    const destination = (link) => {
        if (
            !(link instanceof window.HTMLAnchorElement) ||
            !link.hasAttribute("href")
        ) {
            return null
        }
        try {
            return new URL(link.href)
        } catch {
            return null
        }
    }
    return {
        sidebarHeight: sidebarBox.height,
        links: ids.map((id) => {
            const link = document.getElementById(id)
            if (link === null) {
                return { id, present: false }
            }
            const box = link.getBoundingClientRect()
            const style = window.getComputedStyle(link)
            const target = destination(link)
            return {
                id,
                present: true,
                inSidebar: sidebar.contains(link),
                anchor: link instanceof window.HTMLAnchorElement,
                sameOrigin:
                    target === null
                        ? null
                        : location.origin !== "null" &&
                          target.origin === location.origin,
                route:
                    target === null
                        ? null
                        : `${target.pathname}${target.search}${target.hash}`,
                boxes: link.getClientRects().length,
                display: style.display,
                visibility: style.visibility,
                visible: link.checkVisibility({
                    opacityProperty: true,
                    visibilityProperty: true,
                }),
                left: box.left - sidebarBox.left + sidebar.scrollLeft,
                top: box.top - sidebarBox.top + sidebar.scrollTop,
                width: box.width,
                height: box.height,
                lines: lineCount(link),
                whiteSpace: style.whiteSpace,
                itemFlexShrink:
                    link.parentElement === null
                        ? null
                        : window.getComputedStyle(link.parentElement)
                              .flexShrink,
                scrollMarginInlineStart: style.scrollMarginInlineStart,
                scrollMarginInlineEnd: style.scrollMarginInlineEnd,
            }
        }),
    }
}

/**
 * A `readLegacySidebar` result with every value in its defined form: finite
 * numbers, booleans and `null` as read, a computed style value only when it
 * matches `CSS_VALUE_PATTERN`, a link's `route` only when it is that link's
 * own route in `LEGACY_NAV_ROUTES`, and any other value by its kind and size.
 */
export function projectLegacySidebar(layout) {
    if (!isPlainObject(layout) || !Array.isArray(layout.links)) {
        return null
    }
    const defined = (value) =>
        value === null ||
        typeof value === "boolean" ||
        isFiniteNumber(value) ||
        (typeof value === "string" && CSS_VALUE_PATTERN.test(value))
            ? value
            : describeValue(value)
    const definedRoute = (id, value) =>
        value === null || value === LEGACY_NAV_ROUTES.get(id)
            ? value
            : describeValue(value)
    return {
        sidebarHeight: defined(layout.sidebarHeight),
        links: LEGACY_NAV_IDS.map((id, index) => {
            const link = layout.links[index]
            if (!isPlainObject(link) || link.present !== true) {
                return { id, present: false }
            }
            const projected = { id }
            for (const [field, value] of Object.entries(link)) {
                if (field !== "id") {
                    projected[field] =
                        field === "route"
                            ? definedRoute(id, value)
                            : defined(value)
                }
            }
            return projected
        }),
    }
}

/** In the page: how many status regions the sidebar holds. */
function countSidebarStatusRegions() {
    return document.querySelectorAll('.sidebar-nav [role="status"]').length
}

/**
 * Reads `readLegacySidebar` at each width of `CONTINUITY_WIDTHS`, at the
 * check's viewport height, projected by `projectLegacySidebar`, and
 * screenshots the page at `CONTINUITY_SCREENSHOT_WIDTH` as
 * `legacy-sidebar-<width>-<label>.png`. Leaves the viewport at the last
 * width.
 */
async function readLegacySidebarLayouts(
    problems,
    { report, page, evidenceDir, label }
) {
    const layouts = {}
    for (const width of CONTINUITY_WIDTHS) {
        await page.setViewport({ ...VIEWPORT, width })
        layouts[width] = projectLegacySidebar(
            await page.evaluate(readLegacySidebar, LEGACY_NAV_IDS)
        )
        if (width === CONTINUITY_SCREENSHOT_WIDTH) {
            await captureScreenshot(
                report,
                page,
                evidenceDir,
                `legacy-sidebar-${width}-${label}.png`,
                problems
            )
        }
    }
    return layouts
}

/**
 * What each value of a present link, as `projectLegacySidebar` returns it,
 * must be for the link with id `id` to count as rendered: inside the
 * .sidebar, an HTML anchor whose href resolves on the page's own origin to
 * exactly the link's route in `LEGACY_NAV_ROUTES`, with at least one layout
 * box, a positive width and height, a computed `display` in its defined form
 * other than `none`, `visibility` `visible`, and `checkVisibility` true.
 */
const LEGACY_LINK_RENDERED = {
    inSidebar: (value) => value === true,
    anchor: (value) => value === true,
    sameOrigin: (value) => value === true,
    route: (value, id) => value === LEGACY_NAV_ROUTES.get(id),
    boxes: (value) => isFiniteNumber(value) && value > 0,
    width: (value) => isFiniteNumber(value) && value > 0,
    height: (value) => isFiniteNumber(value) && value > 0,
    display: (value) =>
        typeof value === "string" &&
        CSS_VALUE_PATTERN.test(value) &&
        value !== "none",
    visibility: (value) => value === "visible",
    visible: (value) => value === true,
}

/**
 * Why a present link, as `projectLegacySidebar` returns it, is not rendered:
 * each `LEGACY_LINK_RENDERED` value it fails, with the value read in its
 * defined form. A string outside `CSS_VALUE_PATTERN` is already the
 * projection's description of what was read, so it is named as it stands.
 * Empty for a rendered link.
 */
function legacyLinkRenderGaps(link) {
    return Object.entries(LEGACY_LINK_RENDERED)
        .filter(([field, rendered]) => !rendered(link[field], link.id))
        .map(([field]) => {
            const value = link[field]
            if (typeof value === "string" && !CSS_VALUE_PATTERN.test(value)) {
                return `${field} is ${value}`
            }
            const known = typeof value === "string" ? [value] : []
            return `${field} is ${describeValue(value, known)}`
        })
}

/**
 * Adds a problem for each mode whose page shows no .sidebar at a width, for
 * each of the five links missing or not rendered by `LEGACY_LINK_RENDERED`
 * at a width and mode, and for every sidebar value read with the feature on
 * that differs from the one read at the same width with the feature off. A
 * link's values are compared only where it is rendered in both modes, so a
 * link lost in both is reported, not matched. A computed style value is
 * named in a problem only in its defined form.
 */
export function compareLegacySidebarLayouts(
    problems,
    withFeature,
    withoutFeature
) {
    for (const width of CONTINUITY_WIDTHS) {
        const shown = withFeature[width]
        const reference = withoutFeature[width]
        const rendered = { on: new Set(), off: new Set() }
        for (const [mode, layout] of [
            ["on", shown],
            ["off", reference],
        ]) {
            if (layout === null) {
                problems.push(
                    `at ${width} px the page shows no .sidebar with the feature ${mode}`
                )
                continue
            }
            for (const link of layout.links) {
                if (link.present !== true) {
                    problems.push(
                        `with the feature ${mode} at ${width} px, #${link.id} is missing`
                    )
                    continue
                }
                const gaps = legacyLinkRenderGaps(link)
                if (gaps.length === 0) {
                    rendered[mode].add(link.id)
                } else {
                    problems.push(
                        `with the feature ${mode} at ${width} px, #${link.id} is not rendered in the .sidebar: ${gaps.join(", ")}`
                    )
                }
            }
        }
        if (shown === null || reference === null) {
            continue
        }
        expectEqual(
            problems,
            `with the feature on at ${width} px, the .sidebar height`,
            shown.sidebarHeight,
            reference.sidebarHeight
        )
        reference.links.forEach((link, index) => {
            if (!rendered.on.has(link.id) || !rendered.off.has(link.id)) {
                return
            }
            for (const [field, value] of Object.entries(link)) {
                if (field !== "id") {
                    const actual = shown.links[index][field]
                    expectEqual(
                        problems,
                        `with the feature on at ${width} px, #${link.id} ${field}`,
                        actual,
                        value,
                        [actual, value].filter(
                            (candidate) =>
                                typeof candidate === "string" &&
                                CSS_VALUE_PATTERN.test(candidate)
                        )
                    )
                }
            }
        })
    }
}

/**
 * Holds the five sidebar links that predate Portfolio Insights to the layout
 * they have without it. With the feature on, it reads their layout on /home
 * at each width of `CONTINUITY_WIDTHS`, turns the flag off, waits without a
 * reload until the page has removed the Portfolio Insights link, requires
 * that no sidebar status region remains, reads the layout again at the same
 * widths and reports every difference.
 *
 * Once the flag was turned off it is turned on again and the link awaited,
 * also when a step failed, so the checks after this one start with the
 * feature shown. The check's viewport is restored last.
 */
async function checkLegacySidebarContinuity(
    problems,
    details,
    { report, holder, baseUrl, evidenceDir }
) {
    const { page } = holder
    await page.bringToFront()
    if (currentPath(page) !== "/home") {
        await page.click("#nav-home")
        await waitForPath(page, "/home", PAGE_TIMEOUT_MS)
    }
    await page.waitForSelector("#nav-portfolio-insights", {
        timeout: PAGE_TIMEOUT_MS,
    })
    details.widths = CONTINUITY_WIDTHS
    let disableSent = false
    try {
        details.withFeature = await readLegacySidebarLayouts(problems, {
            report,
            page,
            evidenceDir,
            label: "on",
        })
        disableSent = true
        // The window opens as the PUT starts, so the time the PUT takes counts.
        const offStartedAt = performance.now()
        details.flagOff = await setFlag(baseUrl, false)
        await waitFor(
            async (signal) =>
                !(await probePage(page, signal, () =>
                    isPresent(page, "#nav-portfolio-insights")
                )),
            {
                timeoutMs: SHUTDOWN_TIMEOUT_MS,
                deadline: offStartedAt + SHUTDOWN_TIMEOUT_MS,
                what: `the page to remove #nav-portfolio-insights without a reload within ${SHUTDOWN_TIMEOUT_MS} ms of the flag PUT`,
            }
        )
        details.linkRemovedAfterMs = Math.round(
            performance.now() - offStartedAt
        )
        details.statusRegionsAfterRemoval = await page.evaluate(
            countSidebarStatusRegions
        )
        expectEqual(
            problems,
            '.sidebar-nav [role="status"] regions once the link is gone',
            details.statusRegionsAfterRemoval,
            0
        )
        details.withoutFeature = await readLegacySidebarLayouts(problems, {
            report,
            page,
            evidenceDir,
            label: "off",
        })
        compareLegacySidebarLayouts(
            problems,
            details.withFeature,
            details.withoutFeature
        )
    } finally {
        try {
            if (disableSent) {
                const onStartedAt = performance.now()
                details.flagRestored = await setFlag(baseUrl, true)
                await waitFor(
                    (signal) =>
                        probePage(page, signal, () =>
                            isPresent(page, "#nav-portfolio-insights")
                        ),
                    {
                        timeoutMs: SHUTDOWN_TIMEOUT_MS,
                        deadline: onStartedAt + SHUTDOWN_TIMEOUT_MS,
                        what: `#nav-portfolio-insights to return within ${SHUTDOWN_TIMEOUT_MS} ms of the flag PUT that turned it on again`,
                    }
                )
                details.linkReturnedAfterMs = Math.round(
                    performance.now() - onStartedAt
                )
            }
        } catch (error) {
            // Recorded rather than thrown, so an error that ended the steps
            // above still reaches the report as well.
            console.error(describeError(error))
            problems.push(errorMessage(error))
        } finally {
            await page.setViewport(VIEWPORT)
        }
    }
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

/** In the page: the ids of the feature's elements it shows, by `idPattern`. */
export function readFeatureIds(idPattern) {
    const pattern = new RegExp(idPattern)
    return Array.from(
        document.querySelectorAll("[id]"),
        (element) => element.id
    ).filter((id) => pattern.test(id))
}

/**
 * The page's flag responses sequenced after `afterSeq` whose outcome is
 * known, in arrival order, as `{ status, accepted, enabled, problem }`. An
 * accepted response whose body is the flag gives its boolean `enabled` and
 * no problem; any other gives `enabled: null` and why it is no answer, a
 * fixed phrase. One whose body is still being read is left out until then.
 */
export function pageFlagAnswers(session, afterSeq) {
    const answers = []
    for (const entry of session.responses) {
        if (entry.kind !== "flag" || entry.seq <= afterSeq) {
            continue
        }
        if (
            !entry.parsed &&
            entry.bodyError === undefined &&
            entry.status !== 204
        ) {
            continue
        }
        let enabled = null
        let problem = null
        if (!entry.accepted) {
            problem = entry.rejection
        } else if (!entry.parsed) {
            problem = `has an unreadable body: ${entry.bodyError}`
        } else if (
            !isPlainObject(entry.body) ||
            entry.body.id !== FLAG_ID ||
            typeof entry.body.enabled !== "boolean"
        ) {
            problem = `has a body without "${FLAG_ID}" and a boolean "enabled"`
        } else {
            enabled = entry.body.enabled
        }
        answers.push({
            status: entry.status,
            accepted: entry.accepted,
            enabled,
            problem,
        })
    }
    return answers
}

/**
 * What is wrong with the flag answers a flag-off page received: each that
 * is no valid answer or reads `true`, and, once there is one, the lack of
 * any valid `false`.
 */
function flagOffProblems(answers) {
    const problems = []
    answers.forEach((answer, index) => {
        const name = `the page's flag response ${index + 1}`
        if (answer.problem !== null) {
            problems.push(`${name} ${answer.problem}`)
        } else if (answer.enabled) {
            problems.push(`${name} reads enabled true`)
        }
    })
    if (
        answers.length > 0 &&
        !answers.some((answer) => answer.enabled === false)
    ) {
        problems.push("no flag response of the page reads enabled false")
    }
    return problems
}

/**
 * The feature elements the page showed and the feature requests it sent
 * after `since.seq`, in the order they reached this process. Each is named
 * by its id, or by its method and route, only, with the milliseconds after
 * `since.at`, a `Date.now()` time, and a description naming `since.what`.
 */
function featureActivity(session, since) {
    const elements = session.featureElements
        .filter((element) => element.seq > since.seq)
        .map((element) => ({
            seq: element.seq,
            element: element.id,
            request: null,
            afterMs: element.at - since.at,
        }))
    const requests = session.featureRequests
        .filter((request) => request.seq > since.seq)
        .map((request) => ({
            seq: request.seq,
            element: null,
            request: `${request.method ?? "a request to"} ${request.route}`,
            afterMs: request.at - since.at,
        }))
    return [...elements, ...requests]
        .sort((a, b) => a.seq - b.seq)
        .map((item) => ({
            ...item,
            text:
                item.element === null
                    ? `the page sent ${item.request} ${item.afterMs} ms after ${since.what}`
                    : `#${item.element} appeared ${item.afterMs} ms after ${since.what}`,
        }))
}

/**
 * flag-off: the sidebar shows no Portfolio Insights link once the page has
 * its flag answer, and keeps showing none. It waits for the page's first
 * flag response with a known outcome, then holds the link's absence for
 * `SETTLE_WINDOW_MS`, so a link the frontend renders a moment after its
 * answer is seen. Every flag response the page received since `since.seq`
 * must be an accepted 200 reading `false`, and the page's feature-element
 * recorder must not have seen the link since then, even for a moment.
 */
export async function checkNavLinkAbsent(
    problems,
    details,
    { report, holder, evidenceDir, since }
) {
    const { page } = holder
    try {
        await waitFor(() => pageFlagAnswers(holder, since.seq).length > 0, {
            timeoutMs: FLAG_RESPONSE_TIMEOUT_MS,
            what: "the page's first flag response",
        })
        await observeAbsence(
            async (signal) =>
                (await probePage(page, signal, () =>
                    isPresent(page, "#nav-portfolio-insights")
                ))
                    ? "#nav-portfolio-insights is shown"
                    : null,
            { windowMs: SETTLE_WINDOW_MS }
        )
    } finally {
        const answers = pageFlagAnswers(holder, since.seq)
        details.flagResponses = answers
        problems.push(...flagOffProblems(answers))
        const shown = featureActivity(holder, since).filter(
            (item) => item.element === "nav-portfolio-insights"
        )
        details.linkAppearedAfterMs = shown.map((item) => item.afterMs)
        problems.push(...shown.map((item) => item.text))
    }
    await captureScreenshot(
        report,
        page,
        evidenceDir,
        "flag-off-home.png",
        problems
    )
}

/**
 * What is wrong with the flag evidence of a direct visit, as fixed phrases:
 * no flag read the page sent while still on /insights, where the loader's
 * entry decision reads the flag; no flag answer with a known outcome; and
 * what `flagOffProblems` finds in the answers, each that is no valid answer
 * or reads `true` and the lack of any valid `false`.
 */
function directVisitFlagProblems(answers, readsOnInsights) {
    const problems = []
    if (readsOnInsights === 0) {
        problems.push(
            "the page sent no flag read while on /insights, so no flag answer decided its redirect"
        )
    }
    if (answers.length === 0) {
        problems.push(
            "the page received no flag response with a known outcome during the direct visit"
        )
    }
    problems.push(...flagOffProblems(answers))
    return problems
}

/**
 * Visits /insights directly and expects the flag to send the page to /home
 * without the feature. From the moment the visit starts, through the
 * redirect and for `SETTLE_WINDOW_MS` after the page lands, no feature
 * element may appear, even for a moment, no feature request may be sent,
 * and no feature element may be on the page; the first of these ends the
 * check, named by its id or route only. The elements and requests recorded
 * are read once more after the window, so one recorded while its last probe
 * read the page fails the check too. The redirect must come from the flag:
 * the page must read it while still on /insights, and the flag responses it
 * received since the visit started, judged once the window has passed, must
 * hold an accepted 200 reading `false` and nothing else (`flagOffProblems`).
 * `details` receives where the page landed, the flag reads it sent from
 * /insights, its flag answers, and every such element and request.
 */
export async function checkDirectVisit(details, session, baseUrl) {
    const { page } = session
    const since = {
        seq: nextSequence(),
        at: Date.now(),
        what: "the direct visit started",
    }
    let flagReadsOnInsights = 0
    const onRequest = (request) => {
        try {
            // Puppeteer reports a request after every navigation the page
            // reported before it, so the path is the page's when it was sent.
            if (
                request.method() === "GET" &&
                new URL(request.url()).pathname === FLAG_PATH &&
                currentPath(page) === "/insights"
            ) {
                flagReadsOnInsights += 1
            }
        } catch (error) {
            // An error thrown here would break Puppeteer's event dispatch.
            console.error(describeError(error))
        }
    }
    page.on("request", onRequest)
    try {
        await page.goto(`${baseUrl}/insights`, {
            waitUntil: "domcontentloaded",
        })
        await waitForPath(page, "/home", REDIRECT_TIMEOUT_MS)
        details.landedOn = currentPath(page)
        await observeAbsence(
            async (signal) => {
                const [first] = featureActivity(session, since)
                if (first !== undefined) {
                    return first.text
                }
                const ids = await probePage(page, signal, () =>
                    page.evaluate(
                        readFeatureIds,
                        FEATURE_ELEMENT_ID_PATTERN.source
                    )
                )
                // Repeated only in the feature's own id form.
                const shown = ids.filter(
                    (id) =>
                        typeof id === "string" &&
                        FEATURE_ELEMENT_ID_PATTERN.test(id)
                )
                return shown.length === 0
                    ? null
                    : `the page shows #${shown[0]} after the redirect`
            },
            { windowMs: SETTLE_WINDOW_MS }
        )
        // The window's last probe read the ledger before the page answered.
        const [late] = featureActivity(session, since)
        if (late !== undefined) {
            throw new Error(late.text)
        }
        const flagProblems = directVisitFlagProblems(
            pageFlagAnswers(session, since.seq),
            flagReadsOnInsights
        )
        if (flagProblems.length > 0) {
            throw new Error(flagProblems.join("; "))
        }
    } finally {
        page.off("request", onRequest)
        details.flagReadsOnInsights = flagReadsOnInsights
        details.flagResponses = pageFlagAnswers(session, since.seq)
        details.featureActivity = featureActivity(session, since).map(
            ({ element, request, afterMs }) => ({ element, request, afterMs })
        )
    }
}

/**
 * Turns the flag off with the page visible and expects the shutdown within
 * `SHUTDOWN_TIMEOUT_MS` of the PUT's start, then a quiet window and a direct
 * visit redirected without any feature element or request on the way
 * (`checkDirectVisit`).
 */
export async function checkLiveShutdown(
    problems,
    details,
    { report, holder, baseUrl, evidenceDir }
) {
    const { page } = holder
    await openInsightsPage(holder)
    // The window opens as the PUT starts, so the time the PUT takes counts:
    // the wait ends at this one deadline, however long the PUT took.
    const offStartedAt = performance.now()
    details.flagOff = await setFlag(baseUrl, false)
    const putMs = Math.ceil(performance.now() - offStartedAt)
    let shutdownState = null
    try {
        await waitFor(
            async (signal) => {
                shutdownState = await probePage(page, signal, () =>
                    page.evaluate(readShutdownState)
                )
                return (
                    shutdownState.path === "/home" &&
                    !shutdownState.insightsLink &&
                    !shutdownState.alertsPanel
                )
            },
            {
                timeoutMs: SHUTDOWN_TIMEOUT_MS,
                deadline: offStartedAt + SHUTDOWN_TIMEOUT_MS,
                what: `/home without #nav-portfolio-insights and #alerts-panel within ${SHUTDOWN_TIMEOUT_MS} ms of the flag PUT`,
            }
        )
    } catch (error) {
        if (error instanceof WaitTimeoutError) {
            error.message +=
                `; the flag PUT took ${putMs} ms` +
                (shutdownState === null
                    ? " and no read of the page answered"
                    : `, and the page shows ${JSON.stringify(shutdownState)}`)
        }
        throw error
    }
    const shutdownSeq = nextSequence()
    details.shutdownAfterMs = Math.round(performance.now() - offStartedAt)
    // Wall-clock, as the recorded request and Toast times are.
    const shutdownAt = Date.now()
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
                // Described by its variant: a Toast's text is page text.
                return `a Toast of variant ${toastVariant(toast.className)} appeared ${Date.parse(toast.at) - shutdownAt} ms after the shutdown`
            }
            return null
        },
        { windowMs: ABSENCE_WINDOW_MS }
    )
    details.quietForMs = ABSENCE_WINDOW_MS
    details.directVisit = {}
    await checkDirectVisit(details.directVisit, holder, baseUrl)
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
    const holder = await openSession(
        browser,
        report,
        "holder",
        fixture.holder,
        baseUrl
    )
    state.sessions.push(holder)
    const since = {
        seq: nextSequence(),
        at: Date.now(),
        what: "the login started",
    }
    await login(holder, baseUrl)

    await runCheck(report, "flag-off:nav-link-absent", (problems, details) =>
        checkNavLinkAbsent(problems, details, {
            report,
            holder,
            evidenceDir,
            since,
        })
    )

    await runCheck(report, "flag-off:direct-visit-redirects", (_, details) =>
        checkDirectVisit(details, holder, baseUrl)
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
    const holder = await openSession(
        browser,
        report,
        "holder",
        fixture.holder,
        baseUrl
    )
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
            checkOneToastPerArming(
                problems,
                details,
                baseUrl,
                holder,
                fixture.alerts
            )
    )
    await runCheck(report, "flag-on:rearm-both-members", (problems, details) =>
        checkRearmBothMembers(problems, details, report, holder, fixture)
    )
    await runCheck(report, "flag-on:acknowledge", (problems, details) =>
        checkAcknowledge(problems, details, report, holder, fixture.alerts)
    )
    await runCheck(
        report,
        "flag-on:legacy-sidebar-continuity",
        (problems, details) =>
            checkLegacySidebarContinuity(problems, details, {
                report,
                holder,
                baseUrl,
                evidenceDir,
            })
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

/**
 * What the evidence keeps of every notification response the pages read,
 * counted as a poll or not. `accepted` and the fixed `rejection` judge its
 * HTTP answer (`responseRejection`), `counted` tells whether it counts as a
 * poll (`isPollAnswer`), and `bodyError` is a fixed phrase for a body that
 * could not be read or is not a results list, whose content is never kept.
 * Of a results list, per item, the fields the checks judge, each in its
 * defined form, and `null` for an item that is not an object; without a
 * results list, `results` is `null`.
 */
export function summariseNotifications(sessions) {
    return sessions.flatMap((session) =>
        session.responses
            .filter((entry) => entry.kind === "notifications")
            .map((entry) => ({
                account: session.label,
                at: new Date(entry.at).toISOString(),
                status: entry.status,
                accepted: entry.accepted,
                rejection: entry.rejection,
                counted: isPollAnswer(entry),
                results: hasResultsList(entry)
                    ? resultsOf(entry).map((item) =>
                          isPlainObject(item)
                              ? {
                                    id: uuidOrNull(item.id),
                                    armingRevision: integerOrNull(
                                        item.armingRevision
                                    ),
                                    triggeredAt: projectTimestamp(
                                        item.triggeredAt
                                    ),
                                    triggerValue: finiteOrNull(
                                        item.triggerValue
                                    ),
                                    acknowledged: booleanOrNull(
                                        item.acknowledged
                                    ),
                                }
                              : null
                      )
                    : null,
                bodyError:
                    entry.parsed && !hasResultsList(entry)
                        ? NOT_A_RESULTS_LIST
                        : (entry.bodyError ?? null),
            }))
    )
}

/**
 * What the evidence keeps of the Toasts, each list in the order the Toasts
 * appeared: the Toast log, which holds every Toast matched to a fixture
 * arming in its validated fields (`projectAlertToast`); the account, alert,
 * type, direction and time of each Toast that names a fixture alert but no
 * arming explains; and of every other Toast only how many of each variant
 * there were. No Toast's text, a login error's included, is ever written.
 */
export function summariseToasts(sessions, alerts) {
    const toasts = []
    const unexplained = []
    const otherToasts = {}
    for (const session of sessions) {
        attributeToasts(session, alerts)
        for (const toast of session.toasts) {
            if (toast.key !== null) {
                toasts.push(toast)
                continue
            }
            if (toast.alertId !== null) {
                unexplained.push(toast)
                continue
            }
            const variant = toastVariant(toast.className)
            const key = variant === "unknown" ? variant : `toast-${variant}`
            otherToasts[key] = (otherToasts[key] ?? 0) + 1
        }
    }
    const bySeq = (a, b) => a.seq - b.seq
    return {
        toasts: toasts.sort(bySeq).map(projectAlertToast),
        unexplainedAlertToasts: unexplained.sort(bySeq).map((toast) => {
            const { account, alertId, type, direction, at } =
                projectAlertToast(toast)
            return { account, alertId, type, direction, at }
        }),
        otherToasts,
    }
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

/**
 * Kills `child`, the browser process this run launched, as Puppeteer's own
 * launcher does: `taskkill /T /F` on its pid on Windows, which takes its
 * process tree along, and SIGKILL to its process group elsewhere, where
 * Puppeteer starts it as the group's leader. When that is refused,
 * `child.kill("SIGKILL")` stops the process itself. Only that pid is ever
 * addressed, never a process name. `signal` ends a pending taskkill and
 * then skips the fallback. Rejects when every way fails. `platform`, `run`
 * (an `execFile`) and `killGroup` (a `process.kill`) are the test seams.
 */
export async function killBrowserProcess(
    child,
    signal,
    {
        platform = process.platform,
        run = execFile,
        killGroup = (pid, name) => process.kill(pid, name),
    } = {}
) {
    try {
        if (platform === "win32") {
            await new Promise((resolve, reject) => {
                run(
                    "taskkill",
                    ["/pid", String(child.pid), "/T", "/F"],
                    { signal, windowsHide: true },
                    (error) => {
                        if (error) {
                            reject(error)
                        } else {
                            resolve()
                        }
                    }
                )
            })
        } else {
            killGroup(-child.pid, "SIGKILL")
        }
        return
    } catch (error) {
        // Either can be refused, for want of permission for instance, while
        // the process itself can still be stopped.
        console.error(describeError(error))
        signal.throwIfAborted()
    }
    if (!child.kill("SIGKILL")) {
        throw new Error(
            `the browser process [${child.pid}] could not be signalled`
        )
    }
}

/**
 * Stops `child`, the process of a browser that did not close in time, by
 * `kill`, and waits at most `killTimeoutMs` for its exit. Answers what
 * became of it, with the part of the teardown reason that says so: `none`
 * without a process, `exited` when it was already gone, `killed` once its
 * exit is seen, `kill-failed` when every kill was refused, and `lingering`
 * when it was not seen to exit in time.
 */
async function stopBrowserProcess(child, kill, killTimeoutMs) {
    if (child === null) {
        return { process: "none", note: "it has no process this run can kill" }
    }
    if (child.exitCode !== null || child.signalCode !== null) {
        return { process: "exited", note: "its process had already exited" }
    }
    // Listening before the kill, so that an exit it causes at once is seen.
    const exit = new Promise((resolve) => child.once("exit", resolve))
    const controller = new AbortController()
    const killed = await answerBy(
        async (signal) => {
            await kill(child, signal)
            await exit
        },
        controller.signal,
        performance.now() + killTimeoutMs
    )
    if (killed.failed) {
        console.error(describeError(killed.error))
    }
    if (killed.late) {
        // A taskkill still running would keep node alive.
        controller.abort()
        return {
            process: "lingering",
            note: `its process was not seen to exit within ${killTimeoutMs} ms of the kill`,
        }
    }
    if (killed.failed) {
        return { process: "kill-failed", note: "killing its process failed" }
    }
    return {
        process: "killed",
        note: `its process was killed and exited within ${killTimeoutMs} ms`,
    }
}

/**
 * Lets node end while `child`, a browser process not seen to exit, may
 * still run: the DevTools connection is dropped, and neither the process
 * handle nor its pipes hold the event loop any longer. The connection's
 * socket then closes within the close timeout of the WebSocket client
 * Puppeteer uses.
 */
function releaseBrowser(browser, child) {
    new Promise((resolve) => resolve(browser.disconnect())).catch((error) => {
        console.error(describeError(error))
    })
    if (child !== null) {
        child.unref()
        for (const stream of child.stdio) {
            stream?.destroy()
        }
    }
}

/**
 * Closes `browser`, the one this run launched, and does nothing when it is
 * `null`. Puppeteer's close waits for Chrome's process to exit without any
 * bound, so a wedged process would hold back the report, the exit code and
 * the caller's cleanup. A close that fails, or has not finished within
 * `closeTimeoutMs`, is escalated for this browser's own process only: the
 * one `browser.process()` names, through `kill`. That process gets
 * `killTimeoutMs` to exit and is released when it is not seen to, and a
 * `teardown` FAIL names the deadline and the outcome. Answers whether the
 * browser closed in time; such a close records and prints nothing. Never
 * throws.
 */
export async function teardownBrowser(
    report,
    browser,
    {
        kill = killBrowserProcess,
        closeTimeoutMs = BROWSER_CLOSE_TIMEOUT_MS,
        killTimeoutMs = BROWSER_KILL_TIMEOUT_MS,
    } = {}
) {
    if (browser === null) {
        return true
    }
    const closed = await answerBy(
        () => browser.close(),
        undefined,
        performance.now() + closeTimeoutMs
    )
    if (!closed.late && !closed.failed) {
        return true
    }
    if (closed.failed) {
        console.error(describeError(closed.error))
    }
    const child = browser.process()
    const stopped = await stopBrowserProcess(child, kill, killTimeoutMs)
    if (stopped.process !== "exited" && stopped.process !== "killed") {
        releaseBrowser(browser, child)
    }
    const reason = closed.late
        ? `the browser did not close within ${closeTimeoutMs} ms`
        : `the browser close failed before its ${closeTimeoutMs} ms deadline`
    recordCheck(report, "teardown", false, `${reason}; ${stopped.note}`, {
        closeTimeoutMs,
        killTimeoutMs,
        process: stopped.process,
    })
    return false
}

async function main() {
    let options
    let fixture
    try {
        options = parseOptions(process.argv.slice(2))
        if (options.help === true) {
            console.log(HELP)
            process.exitCode = 0
            return
        }
        fixture = await readFixture(options.fixturePath, options.mode)
    } catch (error) {
        if (!(error instanceof UsageError)) {
            throw error
        }
        console.error(USAGE)
        console.error(errorMessage(error))
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
        unexplainedAlertToasts: [],
        otherToasts: {},
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
        console.error(describeError(error))
        recordCheck(report, "setup", false, errorMessage(error), {})
    } finally {
        // Bounded, and recorded in the report as a `teardown` FAIL when the
        // browser does not close in time.
        await teardownBrowser(report, state.browser)
        Object.assign(report, summariseToasts(state.sessions, fixture.alerts))
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
            console.log(`FAIL evidence: ${errorMessage(error)}`)
            console.error(describeError(error))
        }
    }
    process.exitCode =
        failed || report.checks.some((check) => check.status === "FAIL") ? 1 : 0
}

export {
    UsageError,
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
    resultsOf,
    toastCounts,
    waitOrReport,
}

// The check runs when this file is the entry point, and not when a unit test
// imports its helpers. A Node without `import.meta.main` runs it as well.
if (import.meta.main !== false) {
    await main()
}
