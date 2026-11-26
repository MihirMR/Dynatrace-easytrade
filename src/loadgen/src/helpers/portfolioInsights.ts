import { AsyncLocalStorage } from "node:async_hooks"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { createLoggerOptions } from "@demoability/loadgen-core/lib/logger"
import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import { Page } from "puppeteer"
import { Logger, createLogger } from "winston"
import { selectors } from "../selectors"
import { User } from "../user"
import { gotoPageWithNavBar } from "./common"

export const PORTFOLIO_INSIGHTS_FLAG_ID = "portfolio-insights-enabled"
export const FLAG_PATH =
    "/feature-flag-service/v1/flags/portfolio-insights-enabled"
export const ALERTS_API_PATH = "/broker-service/v1/alerts/"
export const MAX_PRESENCE_CHECKS = 20

/** `status` is the HTTP status as text, or `timeout` / `error`. */
export type OwnedAlertOutcome =
    | { kind: "not_submitted" }
    | { kind: "unconfirmed"; marker: string }
    | { kind: "deleted"; id: string; via: "ui" | "api" }
    | { kind: "absent"; id: string }
    | { kind: "left_in_place"; id: string; status: string }

const MARKER_PREFIX = "1000000."
const MARKER_RANDOM_DIGITS = 7
const UUID_PATTERN =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const VALUE_ATTRIBUTE_PATTERN = /\svalue="([^"]*)"/

const fallbackLogger: Logger = createLogger(createLoggerOptions("visit"))

/**
 * The logger of the visit whose withVisitLogger scope is running. Each scope
 * holds its own logger across its awaits, so visits of several workers in one
 * process never log through each other's logger.
 */
const visitLogger = new AsyncLocalStorage<Logger>()

/**
 * Runs action with logger as the visit logger of the flag reads it starts, so
 * their lines carry the tags of the visit's worker logger.
 *
 * @param logger the visit's logger
 * @param action work whose flag reads log to logger
 */
export function withVisitLogger<T>(
    logger: Logger,
    action: () => Promise<T>
): Promise<T> {
    return visitLogger.run(logger, action)
}

// The flag read logs classified values only: the status, a fixed reason, and
// the error's name and its cause's code, each only when it is one of the fixed
// values below, all in the message text, the one part the visit log format
// prints. The body, the parsed value, parser messages, error objects and any
// other name or code never reach the logger, because they can carry upstream
// bytes or the configured url (CWE-532). That is why this read logs the
// error's classified identity instead of the full error object that
// .claude/rules/typescript.md asks for.

/** Why a 200 body is not this flag's answer, named without its content. */
type FlagDefect =
    | "invalid_json"
    | "not_object"
    | "id_mismatch"
    | "enabled_not_boolean"
    | "body_too_large"

/**
 * The most bytes a flag answer's body may carry, counted once any content
 * coding is undone. The answer is a few hundred bytes; a longer body is not
 * this flag's answer, and is cancelled instead of buffered (CWE-400).
 */
const MAX_FLAG_BODY_BYTES = 16 * 1024

/**
 * The error names a line may carry: the built-in errors, the DOMException
 * names of an abort or a timeout, and the errors of undici, Node's fetch.
 */
const KNOWN_ERROR_NAMES: ReadonlySet<string> = new Set([
    "AbortError",
    "TimeoutError",
    "TypeError",
    "SyntaxError",
    "RangeError",
    "Error",
    "DOMException",
    "SocketError",
    "ConnectTimeoutError",
    "HeadersTimeoutError",
    "BodyTimeoutError",
    "RequestAbortedError",
    "ClientDestroyedError",
    "ClientClosedError",
    "UndiciError",
    "InformationalError",
])

/** The cause codes a line may carry: network system codes and undici's. */
const KNOWN_CAUSE_CODES: ReadonlySet<string> = new Set([
    "ECONNREFUSED",
    "ECONNRESET",
    "ECONNABORTED",
    "ENOTFOUND",
    "EAI_AGAIN",
    "ETIMEDOUT",
    "EHOSTUNREACH",
    "ENETUNREACH",
    "EPIPE",
    "EPROTO",
    "UND_ERR_SOCKET",
    "UND_ERR_CONNECT_TIMEOUT",
    "UND_ERR_HEADERS_TIMEOUT",
    "UND_ERR_BODY_TIMEOUT",
    "UND_ERR_CLOSED",
    "UND_ERR_DESTROYED",
    "UND_ERR_ABORTED",
])

/**
 * The `enabled` state a 200 body carries, or the class of its first defect.
 * The parser's message is dropped, because it quotes the body.
 */
function readFlagState(text: string): boolean | FlagDefect {
    let value: unknown
    try {
        value = JSON.parse(text)
    } catch {
        return "invalid_json"
    }
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        return "not_object"
    }
    if (!("id" in value) || value.id !== PORTFOLIO_INSIGHTS_FLAG_ID) {
        return "id_mismatch"
    }
    if (!("enabled" in value) || typeof value.enabled !== "boolean") {
        return "enabled_not_boolean"
    }
    return value.enabled
}

/**
 * The value of property key of value, or undefined when value is not an
 * object or reading the property throws, as a getter or a proxy trap can:
 * classifying an error must never throw out of the catch block that logs it.
 */
function readProperty(value: unknown, key: string): unknown {
    if (typeof value !== "object" || value === null) {
        return undefined
    }
    try {
        return Reflect.get(value, key)
    } catch {
        return undefined
    }
}

/** value when it is one of known, otherwise undefined. */
function knownValue(
    value: unknown,
    known: ReadonlySet<string>
): string | undefined {
    return typeof value === "string" && known.has(value) ? value : undefined
}

/** The error's name when it is a known error name, otherwise `unknown`. */
function errorName(error: unknown): string {
    return (
        knownValue(readProperty(error, "name"), KNOWN_ERROR_NAMES) ?? "unknown"
    )
}

/**
 * The code of the error's cause when it is a known code, such as
 * `ECONNREFUSED`, otherwise undefined.
 */
function causeCode(error: unknown): string | undefined {
    return knownValue(
        readProperty(readProperty(error, "cause"), "code"),
        KNOWN_CAUSE_CODES
    )
}

/** Why the read failed: its deadline, or the transport error's identity. */
function unreadableReason(error: unknown, timedOut: boolean): string {
    if (timedOut) {
        return "reason [timeout]"
    }
    const code = causeCode(error)
    const cause = code === undefined ? "" : ` cause [${code}]`
    return `reason [transport] error [${errorName(error)}]${cause}`
}

/**
 * Cancels a response body that a status-only outcome leaves unread, so its
 * connection is released instead of staying busy until the server finishes
 * sending. Callers run it while their request deadline is still armed: the
 * cancel starts at once, and is waited for only until signal, that deadline,
 * aborts, so a cancel that never settles cannot hold the caller past it. A
 * failed cancel does not change the outcome the status decided; it is logged
 * at debug by the error's name, also when it fails after the wait has ended.
 *
 * @param response the response whose body is not read
 * @param signal the abort signal of the request's deadline
 * @param logger
 * @param subject the request, as the debug line names it
 */
async function releaseBody(
    response: Response,
    signal: AbortSignal,
    logger: Logger,
    subject: string
): Promise<void> {
    if (response.body === null) {
        return
    }
    await awaitCancel(response.body.cancel(), signal, logger, subject)
}

/**
 * Waits for a body cancel that has already started, but only until signal
 * aborts, as releaseBody describes; a failed cancel is logged at debug by the
 * error's name, also when it fails after the wait has ended.
 *
 * @param cancel the started cancel
 * @param signal the abort signal of the request's deadline
 * @param logger
 * @param subject the request, as the debug line names it
 */
async function awaitCancel(
    cancel: Promise<void>,
    signal: AbortSignal,
    logger: Logger,
    subject: string
): Promise<void> {
    // Handled from the start, so a cancel that fails once the wait has ended
    // is still logged instead of left an unhandled rejection.
    const cancelled = cancel.catch((error: unknown) => {
        logger.debug(
            `${subject} response body not cancelled: error [${errorName(error)}]`
        )
    })
    await untilSettledOrAborted(cancelled, signal)
}

/**
 * The body of response as text, decoded as response.text() decodes it, or
 * undefined once more than maxBytes have arrived: the stream is then
 * cancelled, so an oversized body is never buffered whole. The cancel is
 * waited for as awaitCancel waits, only until signal, the request's deadline,
 * aborts. A missing body reads as empty text, and a failed read propagates.
 *
 * @param response the response whose body is read
 * @param maxBytes the most body bytes accepted, counted as they arrive, once
 *     any content coding is undone
 * @param signal the abort signal of the request's deadline
 * @param logger
 * @param subject the request, as the debug line of a failed cancel names it
 */
async function readBoundedText(
    response: Response,
    maxBytes: number,
    signal: AbortSignal,
    logger: Logger,
    subject: string
): Promise<string | undefined> {
    if (response.body === null) {
        return ""
    }
    const reader = response.body.getReader()
    const chunks: Uint8Array[] = []
    let size = 0
    let chunk = await reader.read()
    while (!chunk.done) {
        size += chunk.value.byteLength
        if (size > maxBytes) {
            // The reader holds the stream's lock, so it is the one to cancel.
            await awaitCancel(reader.cancel(), signal, logger, subject)
            return undefined
        }
        chunks.push(chunk.value)
        chunk = await reader.read()
    }
    // Decoded once, so a character split across chunks is read whole. As in
    // response.text(), the decoder is UTF-8, drops a leading byte order mark
    // and replaces invalid sequences.
    return new TextDecoder().decode(Buffer.concat(chunks))
}

/**
 * Waits for work, but only until signal aborts if that comes first; a signal
 * already aborted ends the wait at once. The abort listener is removed as the
 * wait ends.
 */
async function untilSettledOrAborted(
    work: Promise<void>,
    signal: AbortSignal
): Promise<void> {
    if (signal.aborted) {
        return
    }
    let onAbort: () => void = () => undefined
    const aborted = new Promise<void>((resolve) => {
        onAbort = () => resolve()
    })
    signal.addEventListener("abort", onAbort, { once: true })
    try {
        await Promise.race([work, aborted])
    } finally {
        signal.removeEventListener("abort", onAbort)
    }
}

/**
 * Reads the portfolio-insights-enabled flag once, fail-closed: only a 200
 * whose body carries this flag's id and a boolean `enabled` counts as an
 * answer.
 *
 * A redirect is never followed: its 3xx is this read's own status, read as
 * disabled like any other non-200, so no other endpoint's answer can count as
 * this flag's. A 200 body is read only up to MAX_FLAG_BODY_BYTES: a longer one
 * is cancelled once it passes the limit, and logged as invalid with reason
 * `body_too_large`.
 *
 * The feature defines an unreachable flag service as disabled, so every other
 * outcome, the deadline abort included, is logged with its reason and read as
 * false instead of propagated: the documented exception for flag reads to
 * .claude/rules/typescript.md. The created-id read retries and the cleanup
 * outcomes of createAndDeleteOwnedAlert are separately specified outcomes of
 * the alert lifecycle, not part of this exception.
 *
 * The lines go to the logger of the withVisitLogger scope the read is started
 * in, so they carry that visit's tags; outside any scope they go to a
 * standalone logger in the visit format.
 *
 * @param url EasyTrade base url
 * @param fetchFn fetch implementation
 * @param timeoutMs abort deadline of the whole read
 */
export async function isPortfolioInsightsEnabled(
    url: URL,
    fetchFn: typeof fetch = fetch,
    timeoutMs = 2000
): Promise<boolean> {
    // Taken before the first await, from the scope this read was started in.
    const logger = visitLogger.getStore() ?? fallbackLogger
    const controller = new AbortController()
    // Armed before the first await, through the global setTimeout looked up at
    // call time, so a mocked clock drives the deadline.
    const deadline = setTimeout(() => controller.abort(), timeoutMs)
    try {
        const response = await fetchFn(new URL(FLAG_PATH, url), {
            method: "GET",
            signal: controller.signal,
            headers: { accept: "application/json" },
            redirect: "manual",
        })
        if (response.status !== 200) {
            await releaseBody(
                response,
                controller.signal,
                logger,
                "Flag [portfolio-insights-enabled]"
            )
            logger.warn(
                `Flag [portfolio-insights-enabled] read returned status [${response.status}], treating as disabled`
            )
            return false
        }
        const text = await readBoundedText(
            response,
            MAX_FLAG_BODY_BYTES,
            controller.signal,
            logger,
            "Flag [portfolio-insights-enabled]"
        )
        const state =
            text === undefined ? "body_too_large" : readFlagState(text)
        if (typeof state !== "boolean") {
            logger.warn(
                `Flag [portfolio-insights-enabled] response invalid, treating as disabled: reason [${state}] status [${response.status}]`
            )
            return false
        }
        if (!state) {
            logger.debug("Flag [portfolio-insights-enabled] is disabled")
        }
        return state
    } catch (error) {
        logger.warn(
            `Flag [portfolio-insights-enabled] unreadable, treating as disabled: ${unreadableReason(error, controller.signal.aborted)}`
        )
        return false
    } finally {
        clearTimeout(deadline)
    }
}

/**
 * Assumes starting point on login screen.
 * End point on user Dashboard
 *
 * The steps and selectors of helpers/login.ts, except that the password never
 * passes through a loadgen-core page action: PageActions.inputHandle logs the
 * value it types, and clearInput the value it clears, at debug level. The
 * password field is therefore cleared and typed through its Puppeteer element.
 *
 * @param pageActions
 * @param user
 */
export async function loginWithoutLoggingPassword(
    pageActions: IPageActions,
    user: User
): Promise<void> {
    await pageActions.input(selectors.loginPage_username, user.username)
    await pageActions.shortDelay()
    await inputWithoutLogging(
        pageActions,
        selectors.loginPage_password,
        user.password
    )
    await pageActions.shortDelay()
    await pageActions.navigate(selectors.loginPage_loginButton)
}

/**
 * Replaces the text of the field with value as PageActions.input does, by
 * focusing it, deleting its current characters and typing value, but without
 * logging the field's old or new text.
 */
async function inputWithoutLogging(
    pageActions: IPageActions,
    selector: ISelector,
    value: string
): Promise<void> {
    const handle = await pageActions.getHandle(selector)
    await pageActions.scrollIntoView(handle)
    const element = handle.getHandle()
    const property = await element.getProperty("value")
    const current: unknown = await property.jsonValue()
    await property.dispose()
    await element.focus()
    const length = typeof current === "string" ? current.length : 0
    for (let deleted = 0; deleted < length; deleted++) {
        await element.press("Backspace")
    }
    await element.type(value)
}

/**
 * Assumes user is logged in on any protected page.
 * Endpoint Portfolio Insights page (/insights).
 *
 * @param pageActions
 */
export async function gotoPortfolioInsightsPage(
    pageActions: IPageActions
): Promise<void> {
    await gotoPageWithNavBar(
        pageActions,
        selectors.navigation_portfolioInsightsPage
    )
}

/**
 * Whether the Portfolio Insights feature is verifiably gone from the page.
 * The frontend renders the navigation link only while the flag reads true,
 * and its shutdown sends an open /insights page to /home, so a link missing
 * from the DOM means the flag turned off during the visit.
 *
 * The link is looked up through navigationLinkPresence, whose DOM query lets
 * browser failures through; the stock check would read any of them, a closed
 * target included, as a missing link. A failed lookup verifies no loss: it is
 * logged at debug, the message naming only the error's name and the entry
 * carrying the error object, and answers false, so the caller rethrows the
 * error of its own page step.
 *
 * @param pageActions
 * @param logger
 */
async function isFeatureLost(
    pageActions: IPageActions,
    logger: Logger
): Promise<boolean> {
    try {
        return !(await pageActions.isSelectorPresent(navigationLinkPresence))
    } catch (error) {
        logger.debug(
            `Portfolio insights feature check failed, loss not verified: error [${errorName(error)}]`,
            { error }
        )
        return false
    }
}

/**
 * Assumes user is logged in on any protected page.
 * Endpoint Portfolio Insights page, or the page the frontend left for once
 * the feature was lost.
 *
 * Opens the page through gotoPortfolioInsightsPage, then runs
 * createAndDeleteOwnedAlert. A navigation that fails while the feature is
 * verifiably lost (see isFeatureLost) ends with nothing submitted; any other
 * navigation error propagates, unchanged also when the loss check fails.
 *
 * @param pageActions
 * @param url EasyTrade base url
 * @param logger
 * @param options the test seams of createAndDeleteOwnedAlert
 */
export async function openPageAndRunOwnedAlert(
    pageActions: IPageActions,
    url: URL,
    logger: Logger,
    options?: Parameters<typeof createAndDeleteOwnedAlert>[3]
): Promise<OwnedAlertOutcome> {
    try {
        await gotoPortfolioInsightsPage(pageActions)
    } catch (error) {
        if (!(await isFeatureLost(pageActions, logger))) {
            throw error
        }
        logger.warn("Portfolio insights page unavailable, no alert created", {
            error,
        })
        return { kind: "not_submitted" }
    }
    return await createAndDeleteOwnedAlert(pageActions, url, logger, options)
}

/**
 * The error a visit fails with when its owned alert did not end clean, or
 * undefined when it did. Clean means the create was confirmed and the alert
 * deleted, through the UI or the API, or found already absent.
 *
 * @param outcome the outcome of createAndDeleteOwnedAlert
 */
export function ownedAlertFailure(
    outcome: OwnedAlertOutcome
): Error | undefined {
    switch (outcome.kind) {
        case "deleted":
        case "absent":
            return undefined
        case "not_submitted":
            return new Error(
                "Owned alert outcome [not_submitted]: no alert was submitted"
            )
        case "unconfirmed":
            return new Error(
                `Owned alert outcome [unconfirmed]: create of threshold [${outcome.marker}] not confirmed`
            )
        case "left_in_place":
            return new Error(
                `Owned alert outcome [left_in_place]: alert [${outcome.id}] not deleted, status [${outcome.status}]`
            )
    }
}

/**
 * Assumes starting point Portfolio Insights page.
 * Endpoint Portfolio Insights page.
 *
 * Creates one alert, confirms its id from the created-id output and deletes
 * only that id: through its own row, or through the broker REST API when the
 * UI deletion is not confirmed. It never touches an alert it did not create,
 * so visits sharing one preset user cannot disturb each other.
 *
 * A page step that fails while the feature is verifiably lost mid-visit (see
 * isFeatureLost) ends with the owned-id outcome reached so far: not_submitted
 * before the submit click, unconfirmed from it until the id is read. Any other
 * page error before the id is read propagates, unchanged also when the loss
 * check fails. Once the id is known, a failing UI deletion is logged and the
 * API fallback decides the outcome, so nothing is thrown after the outcome is
 * decided.
 *
 * @param pageActions
 * @param url EasyTrade base url
 * @param logger
 * @param options test seams: fetch implementation, random source, API deadline
 */
export async function createAndDeleteOwnedAlert(
    pageActions: IPageActions,
    url: URL,
    logger: Logger,
    {
        fetchFn = fetch,
        random = Math.random,
        apiTimeoutMs = 5000,
    }: {
        fetchFn?: typeof fetch
        random?: () => number
        apiTimeoutMs?: number
    } = {}
): Promise<OwnedAlertOutcome> {
    let marker: string
    try {
        const instrumentId = await waitForInstrumentId(pageActions)
        if (instrumentId === undefined) {
            logger.warn(
                "Alert instrument options did not load, no alert created"
            )
            return { kind: "not_submitted" }
        }

        marker = createMarker(random)
        await fillAlertForm(pageActions, instrumentId, marker)
    } catch (error) {
        // Nothing is submitted yet: a verified loss of the feature ends the
        // visit without an alert, and any other error propagates without an
        // outcome line.
        if (!(await isFeatureLost(pageActions, logger))) {
            throw error
        }
        logger.warn(
            "Portfolio insights feature lost before submit, no alert created",
            { error }
        )
        return { kind: "not_submitted" }
    }
    let id: string | undefined
    try {
        await pageActions.click(selectors.portfolioInsightsPage_alertSubmit)
        id = await readCreatedAlertId(pageActions, marker, logger)
    } catch (error) {
        // From the submit click on, the alert may exist, so the marker is
        // logged for an operator to find it. A verified loss of the feature
        // ends the visit with that outcome; any other error still propagates.
        logger.warn(unconfirmedMessage(marker), { error })
        if (!(await isFeatureLost(pageActions, logger))) {
            throw error
        }
        return { kind: "unconfirmed", marker }
    }
    if (id === undefined) {
        logger.warn(unconfirmedMessage(marker))
        return { kind: "unconfirmed", marker }
    }
    logger.info(`Created alert [${id}] threshold [${marker}]`)

    let outcome: OwnedAlertOutcome | undefined
    try {
        if (await deleteThroughUi(pageActions, id)) {
            logger.info(`Deleted alert [${id}] via ui`)
            outcome = { kind: "deleted", id, via: "ui" }
        }
    } catch (error) {
        // The id is known, so the API fallback below decides the outcome and
        // the UI error ends here instead of failing a visit already decided.
        logger.warn(`UI deletion of alert [${id}] failed, using the api`, {
            error,
        })
    } finally {
        outcome ??= await deleteThroughApi(
            url,
            id,
            logger,
            fetchFn,
            apiTimeoutMs
        )
    }
    return outcome
}

function unconfirmedMessage(marker: string): string {
    return `Create unconfirmed threshold [${marker}], outcome unknown`
}

/**
 * Runs probe up to MAX_PRESENCE_CHECKS times with a short delay between
 * checks, and returns its first defined result.
 */
async function pollBounded<T>(
    pageActions: IPageActions,
    probe: () => Promise<T | undefined>
): Promise<T | undefined> {
    for (let check = 1; check <= MAX_PRESENCE_CHECKS; check++) {
        const result = await probe()
        if (result !== undefined) {
            return result
        }
        if (check < MAX_PRESENCE_CHECKS) {
            await pageActions.shortDelay()
        }
    }
    return undefined
}

async function waitForPresence(
    pageActions: IPageActions,
    selector: ISelector
): Promise<boolean> {
    const present = await pollBounded(
        pageActions,
        async () => (await pageActions.isSelectorPresent(selector)) || undefined
    )
    return present === true
}

/**
 * A selector whose presence check reads the DOM alone, through the wrapped
 * selector's non-waiting selectAll, and releases the handles it acquired.
 * The stock XPath check waits for a visible element, and an <option> of a
 * closed <select> has no layout box, so only this check can report it. The
 * stock check also answers false for any browser failure, while here a failed
 * DOM query propagates, so a false answer is verified absence. Selecting and
 * the string form are the wrapped selector's own.
 */
export class DomPresenceSelector implements ISelector {
    private readonly wrapped: ISelector

    constructor(wrapped: ISelector) {
        this.wrapped = wrapped
    }

    async isPresent(page: Page): Promise<boolean> {
        const handles = await this.wrapped.selectAll(page)
        await Promise.all(handles.map((handle) => handle.getHandle().dispose()))
        return handles.length > 0
    }

    async select(page: Page): Promise<IHandleWrapper | null> {
        return await this.wrapped.select(page)
    }

    async selectAll(page: Page): Promise<IHandleWrapper[]> {
        return await this.wrapped.selectAll(page)
    }

    toString(): string {
        return this.wrapped.toString()
    }
}

const instrumentOptionPresence = new DomPresenceSelector(
    selectors.portfolioInsightsPage_alertInstrumentOption
)

/** The navigation link as isFeatureLost looks it up: in the DOM alone. */
const navigationLinkPresence = new DomPresenceSelector(
    selectors.navigation_portfolioInsightsPage
)

/**
 * Waits for the first instrument option and returns its value. Each of the
 * bounded checks is an isSelectorPresent of the option selector, answered
 * from the DOM because the options of a closed <select> are never visible;
 * once options are present, the first one's value is read, and an empty or
 * non-string value counts as not yet loaded.
 */
async function waitForInstrumentId(
    pageActions: IPageActions
): Promise<string | undefined> {
    return await pollBounded(pageActions, async () => {
        if (!(await pageActions.isSelectorPresent(instrumentOptionPresence))) {
            return undefined
        }
        const options = await pageActions.getAllHandles(
            selectors.portfolioInsightsPage_alertInstrumentOption
        )
        if (options.length === 0) {
            return undefined
        }
        const value = await pageActions.getPropertyHandle<unknown>(
            options[0],
            "value"
        )
        return typeof value === "string" && value !== "" ? value : undefined
    })
}

function randomDigit(random: () => number, lowest: number): number {
    const span = 10 - lowest
    const offset = Math.floor(random() * span)
    return lowest + Math.min(span - 1, Math.max(0, offset))
}

/**
 * Threshold of `1000000.` followed by 8 digits, the last one non-zero, so the
 * submitted text is already in its normalised form.
 */
function createMarker(random: () => number): string {
    let digits = ""
    for (let index = 0; index < MARKER_RANDOM_DIGITS; index++) {
        digits += randomDigit(random, 0)
    }
    return `${MARKER_PREFIX}${digits}${randomDigit(random, 1)}`
}

async function fillAlertForm(
    pageActions: IPageActions,
    instrumentId: string,
    marker: string
): Promise<void> {
    await pageActions.selectOption(
        selectors.portfolioInsightsPage_alertType,
        "TARGET_PRICE"
    )
    await pageActions.shortDelay()
    await pageActions.selectOption(
        selectors.portfolioInsightsPage_alertInstrument,
        instrumentId
    )
    await pageActions.shortDelay()
    await pageActions.selectOption(
        selectors.portfolioInsightsPage_alertDirection,
        "ABOVE"
    )
    await pageActions.shortDelay()
    await pageActions.input(
        selectors.portfolioInsightsPage_alertThreshold,
        marker
    )
    await pageActions.shortDelay()
}

/**
 * Polls the created-id output of this marker within the presence budget and
 * returns the id it carries; undefined when it never shows a UUID. A read
 * that throws, or yields no UUID, counts as not yet confirmed.
 */
async function readCreatedAlertId(
    pageActions: IPageActions,
    marker: string,
    logger: Logger
): Promise<string | undefined> {
    const output = selectors.portfolioInsightsPage_createdAlert(marker)
    return await pollBounded(pageActions, async () => {
        if (!(await pageActions.isSelectorPresent(output))) {
            return undefined
        }
        try {
            return await readAlertId(pageActions, output)
        } catch (error) {
            logger.debug(
                `Created alert output for threshold [${marker}] unreadable, retrying`,
                { error }
            )
            return undefined
        }
    })
}

/**
 * Reads the id from the output's value and, failing that, from its value
 * attribute.
 */
async function readAlertId(
    pageActions: IPageActions,
    output: ISelector
): Promise<string | undefined> {
    const value = await pageActions.getProperty<unknown>(output, "value")
    if (typeof value === "string" && UUID_PATTERN.test(value.trim())) {
        return value.trim()
    }
    const outerHtml = await pageActions.getProperty<unknown>(
        output,
        "outerHTML"
    )
    const attribute =
        typeof outerHtml === "string"
            ? VALUE_ATTRIBUTE_PATTERN.exec(outerHtml)?.[1]
            : undefined
    return attribute !== undefined && UUID_PATTERN.test(attribute)
        ? attribute
        : undefined
}

/**
 * Deletes the alert through its own row; true only once the deleted-id
 * output for this id confirms it.
 */
async function deleteThroughUi(
    pageActions: IPageActions,
    id: string
): Promise<boolean> {
    if (
        !(await waitForPresence(
            pageActions,
            selectors.portfolioInsightsPage_alertRow(id)
        ))
    ) {
        return false
    }
    await pageActions.click(selectors.portfolioInsightsPage_alertRowDelete(id))
    return await waitForPresence(
        pageActions,
        selectors.portfolioInsightsPage_deletedAlert(id)
    )
}

/**
 * Deletes the alert through broker REST. Never throws: every outcome is
 * logged and returned.
 *
 * A redirect is never followed: its 3xx is this request's own status, so the
 * alert is left in place with that status, and another target's 204 or 404
 * can never count as this alert deleted or absent.
 *
 * A request that fails before its deadline is left in place with status
 * `error`, a line that carries the error object; a second line names the
 * failure as the flag read does, by reason, error name and cause code from
 * the fixed lists only, never by message, url or body.
 */
async function deleteThroughApi(
    url: URL,
    id: string,
    logger: Logger,
    fetchFn: typeof fetch,
    timeoutMs: number
): Promise<OwnedAlertOutcome> {
    const controller = new AbortController()
    const deadline = setTimeout(() => controller.abort(), timeoutMs)
    try {
        const response = await fetchFn(
            new URL(`${ALERTS_API_PATH}${encodeURIComponent(id)}`, url),
            { method: "DELETE", signal: controller.signal, redirect: "manual" }
        )
        await releaseBody(
            response,
            controller.signal,
            logger,
            `Alert [${id}] delete`
        )
        if (response.status === 204) {
            logger.info(`Deleted alert [${id}] via api`)
            return { kind: "deleted", id, via: "api" }
        }
        if (response.status === 404) {
            logger.info(`Alert [${id}] already absent`)
            return { kind: "absent", id }
        }
        const status = String(response.status)
        logger.warn(`Alert [${id}] left in place: ${status}`)
        return { kind: "left_in_place", id, status }
    } catch (error) {
        const timedOut = controller.signal.aborted
        const status = timedOut ? "timeout" : "error"
        logger.warn(`Alert [${id}] left in place: ${status}`, { error })
        if (!timedOut) {
            // The visit log format prints no error object, so the failure's
            // classified identity follows on a line of its own.
            logger.warn(
                `Alert [${id}] delete request failed: ${unreadableReason(error, false)}`
            )
        }
        return { kind: "left_in_place", id, status }
    } finally {
        clearTimeout(deadline)
    }
}
