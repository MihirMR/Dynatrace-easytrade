import { AsyncLocalStorage } from "node:async_hooks"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { createLoggerOptions } from "@demoability/loadgen-core/lib/logger"
import {
    IPageActions,
    PageSetup,
} from "@demoability/loadgen-core/lib/pageActions"
import {
    ISelector,
    XpathSelector,
} from "@demoability/loadgen-core/lib/selectors"
import { ClickOptions, ElementHandle, EvaluateFunc, Page } from "puppeteer"
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
export function errorName(error: unknown): string {
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
 * What BoundedPageActions.enterCredential throws when it writes nothing. It
 * names no part of either origin: the configured URL can carry a secret, and
 * the document's origin is untrusted.
 */
export const DOCUMENT_ORIGIN_UNVERIFIED =
    "Browser document not verified at the configured EasyTrade origin; credentials not entered"

/**
 * Assumes starting point on login screen.
 * End point on user Dashboard
 *
 * The steps and selectors of helpers/login.ts, except for how the two fields
 * are filled. Neither credential passes through a loadgen-core page action:
 * PageActions.inputHandle logs the value it types, and clearInput the value it
 * clears, at debug level. And the browser follows HTTP and script redirects,
 * so a credential must reach only a document at the url's origin. Each field
 * is therefore filled by BoundedPageActions.enterCredential, which checks the
 * field's document and writes the credential in one synchronous step in the
 * page, so no navigation or focus change can come between the check and the
 * write. A field in a document anywhere else gets nothing written, and the
 * login throws DOCUMENT_ORIGIN_UNVERIFIED before any later step: a refusal at
 * the username leaves the password field unwritten.
 *
 * @param pageActions the visit's bounded page actions; their deadline also
 * bounds the login button's navigation
 * @param user
 * @param url EasyTrade base url, whose origin the login document must be at
 */
export async function loginWithoutLoggingPassword(
    pageActions: BoundedPageActions,
    user: User,
    url: URL
): Promise<void> {
    const username = await pageActions.getHandle(selectors.loginPage_username)
    await pageActions.enterCredential(username, user.username, url.origin)
    await pageActions.shortDelay()
    const password = await pageActions.getHandle(selectors.loginPage_password)
    await pageActions.enterCredential(password, user.password, url.origin)
    await pageActions.shortDelay()
    await pageActions.navigate(selectors.loginPage_loginButton)
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
 * The frontend renders the Portfolio Insights navigation link only while the
 * flag reads true, beside the home link that the navigation of every
 * protected page shows, and its shutdown sends an open /insights page to
 * /home. So only a page whose navigation is shown, its home link present,
 * without the Portfolio Insights link proves that the flag turned off during
 * the visit.
 *
 * Both facts come from one DOM query, featureLossPresence, whose single XPath
 * evaluation reads them from one state of the document. Two lookups could
 * each read a different page, the home link on the protected page and then
 * no Portfolio Insights link on an error page that replaced it, and combine
 * into a loss that neither page shows.
 *
 * Any other answer proves nothing about the flag: either the link is still
 * there, or the page shows no navigation, as an error page that replaced the
 * layout, the login page or a page still loading. It answers false, so the
 * caller rethrows the error of its own page step. The flag itself is not read
 * again, because the visit reads it once, at its start.
 *
 * The query reads the DOM through DomPresenceSelector, which lets browser
 * failures through; the stock check would read any of them, a closed target
 * included, as absence. A failed query verifies no loss either: it is logged
 * at debug, the message naming only the error's name and the entry carrying
 * the error object, and answers false.
 *
 * @param pageActions
 * @param logger
 */
async function isFeatureLost(
    pageActions: IPageActions,
    logger: Logger
): Promise<boolean> {
    try {
        return await pageActions.isSelectorPresent(featureLossPresence)
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
 * verifiably lost (see isFeatureLost), the navigation still shown without the
 * Portfolio Insights link, ends with nothing submitted. Any other navigation
 * error propagates unchanged, also when the page shows no navigation at all
 * and when the loss check fails.
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
 * Deadline of each element action of BoundedPageActions. It equals the 30 s
 * default wait of Puppeteer that already bounds getHandle and navigation, so a
 * healthy action is never cut short.
 */
export const PAGE_ACTION_TIMEOUT_MS = 30_000

/** The longest delay setTimeout honours; it fires a longer one at once. */
const MAX_TIMER_DELAY_MS = 2_147_483_647

/** How often a viewport wait checks intersection, as loadgen-core's does. */
const VIEWPORT_POLL_MS = 500

/** The stages of one BoundedPageActions element action, under its deadline. */
type ActionStages = {
    /**
     * Waits for one stage of the action; when the deadline passes first, it
     * rejects with the action's TimeoutError instead.
     */
    within<T>(stage: Promise<T>): Promise<T>
    /** Waits ms within the deadline; its timer ends with the action. */
    pause(ms: number): Promise<void>
    /**
     * Throws the action's TimeoutError once the deadline has passed. It is
     * synchronous, so a dispatch started right after it, in the same run,
     * cannot start once the deadline has passed.
     */
    gate(): void
    /** Whether error is the action's TimeoutError. */
    isTimeout(error: unknown): boolean
}

/**
 * Runs in the page, as one synchronous step: sets the value of element
 * through the value setter of its prototype chain, then dispatches bubbling
 * input and change events, as typing does. React's controlled inputs see the
 * change, which an assignment to the element's own value property, tracked by
 * React, would hide from them. The value is never returned.
 *
 * When origin is not null, it first requires element to be connected to the
 * document of the frame it runs in and that document to be at origin, and
 * otherwise writes nothing and answers false. The origin is read from the
 * global document: Window.document, Document.location and every member of
 * Location are unforgeable, so no script of the page can change the answer,
 * as it could through a prototype getter such as ownerDocument.
 *
 * Puppeteer sends this function's source to the page, so it uses nothing
 * outside itself but the page's own globals.
 *
 * @param element the field
 * @param text the value the field ends with
 * @param origin the origin the field's document must be at, or null
 * @returns whether the value was written
 */
function writeValueInPage(
    element: Element,
    text: string,
    origin: string | null
): boolean {
    if (
        origin !== null &&
        !(
            element.isConnected &&
            element.ownerDocument === document &&
            document.location.origin === origin
        )
    ) {
        return false
    }
    let prototype: object | null = Object.getPrototypeOf(element)
    let setter: ((value: string) => void) | undefined
    while (prototype !== null && setter === undefined) {
        setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set
        prototype = Object.getPrototypeOf(prototype)
    }
    if (setter === undefined) {
        throw new Error("Element has no value to write")
    }
    setter.call(element, text)
    element.dispatchEvent(new Event("input", { bubbles: true }))
    element.dispatchEvent(new Event("change", { bubbles: true }))
    return true
}

/**
 * Page actions whose element actions end at a deadline and dispatch nothing
 * after it. Before it clicks, types into, selects in or navigates through an
 * element, loadgen-core's PageActions polls until the element intersects the
 * viewport, with no deadline of its own, so a control that is present but
 * never intersects would hold the visit, and the cleanup after it, forever.
 * And a Puppeteer action that is merely abandoned still goes on to click,
 * select or type once its pending step answers, its element disposed or not.
 *
 * So each click, input, selectOption and navigate, in its selector and its
 * handle form, each scrollIntoView and each enterCredential runs its own
 * stages on the Puppeteer element, under one deadline per action. A selector
 * form first acquires the handle through the wrapped getHandle, which
 * Puppeteer's visible wait already bounds. Then comes loadgen-core's viewport
 * wait, which focuses the element and checks every 500 ms until it intersects
 * the viewport, and for a click the element's clickable point. Every stage is
 * raced against the deadline, and the dispatch, the mouse click, the option
 * selection or the one write of the value, starts in the same synchronous run
 * as a check of the deadline, so none is dispatched once the deadline has
 * passed. A navigate starts its navigation wait before its click, as
 * loadgen-core's does, and waits for the navigation within the same deadline.
 *
 * At the deadline the action fails with an error named TimeoutError whose
 * message names the action and the element, never the value written or
 * selected, and how the stage it abandoned ends is logged at debug. When an
 * action fails, at its deadline or otherwise, its element handle is disposed.
 * Every other member delegates unchanged.
 */
export class BoundedPageActions implements IPageActions {
    private readonly inner: IPageActions
    private readonly logger: Logger
    private readonly timeoutMs: number

    /**
     * @param inner the page actions of the visit's worker
     * @param logger receives the debug lines of abandoned actions and of
     * handles that could not be disposed
     * @param timeoutMs deadline of each element action, in whole milliseconds
     * from 1 to the longest delay setTimeout honours
     */
    constructor(
        inner: IPageActions,
        logger: Logger,
        timeoutMs = PAGE_ACTION_TIMEOUT_MS
    ) {
        if (
            !Number.isInteger(timeoutMs) ||
            timeoutMs < 1 ||
            timeoutMs > MAX_TIMER_DELAY_MS
        ) {
            throw new RangeError(
                `Page action deadline must be whole milliseconds from 1 to ${MAX_TIMER_DELAY_MS}, was [${timeoutMs}]`
            )
        }
        this.inner = inner
        this.logger = logger
        this.timeoutMs = timeoutMs
    }

    async click(selector: ISelector): Promise<void> {
        await this.clickHandle(await this.inner.getHandle(selector))
    }

    /** Clicks the element at its clickable point, as Puppeteer's click does. */
    async clickHandle(
        handle: IHandleWrapper,
        options?: ClickOptions
    ): Promise<void> {
        await this.bounded("click", handle, async (stages, element) => {
            await this.clickWithin(stages, element, options)
        })
    }

    async input(selector: ISelector, value: string): Promise<void> {
        await this.inputHandle(await this.inner.getHandle(selector), value)
    }

    /**
     * Replaces the field's value with value in one write in the page, through
     * writeValueInPage, instead of clearing and typing it key by key, and
     * never logs it.
     */
    async inputHandle(handle: IHandleWrapper, value: string): Promise<void> {
        await this.bounded("input", handle, async (stages, element) => {
            await this.waitInViewport(stages, element, VIEWPORT_POLL_MS)
            stages.gate()
            await stages.within(element.evaluate(writeValueInPage, value, null))
        })
    }

    /**
     * Writes a credential into the field, as inputHandle writes a value, but
     * only while the field is connected to a document at origin. The check and
     * the write are one synchronous step in the page, through
     * writeValueInPage, so no navigation or focus change can come between
     * them, and the credential never reaches the page's keyboard or a log.
     *
     * Throws DOCUMENT_ORIGIN_UNVERIFIED, having written nothing, when the
     * field's document is anywhere else; when origin is the opaque "null",
     * which every about:blank or data: document shares; and when a stage
     * fails, as the write does once a navigation destroyed the field's
     * document. At the deadline it fails with its TimeoutError, like any
     * action, and the stage it abandoned is logged by its error's name only.
     *
     * @param handle the field
     * @param value the credential
     * @param origin the origin the field's document must be at, as URL.origin
     * gives it
     */
    async enterCredential(
        handle: IHandleWrapper,
        value: string,
        origin: string
    ): Promise<void> {
        const enter = async (
            stages: ActionStages,
            element: ElementHandle
        ): Promise<void> => {
            if (origin === "null") {
                throw new Error(DOCUMENT_ORIGIN_UNVERIFIED)
            }
            let written: boolean
            try {
                await this.waitInViewport(stages, element, VIEWPORT_POLL_MS)
                stages.gate()
                written = await stages.within(
                    element.evaluate(writeValueInPage, value, origin)
                )
            } catch (error) {
                if (stages.isTimeout(error)) {
                    throw error
                }
                // Replaced by the fixed error, not propagated or logged whole
                // as .claude/rules/typescript.md asks: Puppeteer quotes the
                // frame's URL in its errors once the frame is detached, and
                // that URL is the untrusted document's.
                throw new Error(DOCUMENT_ORIGIN_UNVERIFIED)
            }
            if (!written) {
                throw new Error(DOCUMENT_ORIGIN_UNVERIFIED)
            }
        }
        await this.bounded("enterCredential", handle, enter, true)
    }

    async selectOption(selector: ISelector, option: string): Promise<void> {
        await this.selectOptionHandle(
            await this.inner.getHandle(selector),
            option
        )
    }

    async selectOptionHandle(
        handle: IHandleWrapper,
        option: string
    ): Promise<void> {
        await this.bounded("selectOption", handle, async (stages, element) => {
            await this.waitInViewport(stages, element, VIEWPORT_POLL_MS)
            stages.gate()
            // Puppeteer selects in its isolated world, into which the viewport
            // wait's focus already adopted the element, so the selection is
            // sent in this same run.
            await stages.within(element.select(option))
        })
    }

    async navigate(selector: ISelector): Promise<void> {
        await this.navigateHandle(await this.inner.getHandle(selector))
    }

    /**
     * Clicks the element as clickHandle does and waits, within the same
     * deadline, for the navigation the click causes.
     */
    async navigateHandle(handle: IHandleWrapper): Promise<void> {
        await this.bounded("navigate", handle, async (stages, element) => {
            // Started before the click, as loadgen-core starts it, so the
            // navigation the click causes cannot be missed; Puppeteer's own
            // navigation timeout ends it. Its rejection reaches the action
            // through the stage that waits for it; this handler only keeps a
            // wait the action abandons, after a failed click or at the
            // deadline, from ending as an unhandled rejection.
            const navigation = element.frame.waitForNavigation()
            navigation.catch(() => undefined)
            await this.clickWithin(stages, element)
            await stages.within(navigation)
        })
    }

    /** The viewport wait alone, checking every waitInterval ms. */
    async scrollIntoView(
        handle: IHandleWrapper,
        waitInterval = VIEWPORT_POLL_MS
    ): Promise<void> {
        await this.bounded(
            "scrollIntoView",
            handle,
            async (stages, element) => {
                await this.waitInViewport(stages, element, waitInterval)
            }
        )
    }

    async setupPage(setup: PageSetup): Promise<void> {
        await this.inner.setupPage(setup)
    }

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        return await this.inner.isSelectorPresent(selector)
    }

    async getHandle(selector: ISelector): Promise<IHandleWrapper> {
        return await this.inner.getHandle(selector)
    }

    async getAllHandles(selector: ISelector): Promise<IHandleWrapper[]> {
        return await this.inner.getAllHandles(selector)
    }

    async clearInput(handle: IHandleWrapper): Promise<void> {
        await this.inner.clearInput(handle)
    }

    async sleep(milliseconds: number, noiseProportion?: number): Promise<void> {
        await this.inner.sleep(milliseconds, noiseProportion)
    }

    async getProperty<Type = unknown>(
        selector: ISelector,
        propertyName: string
    ): Promise<Type> {
        return await this.inner.getProperty<Type>(selector, propertyName)
    }

    async getPropertyHandle<Type = unknown>(
        handle: IHandleWrapper,
        propertyName: string
    ): Promise<Type> {
        return await this.inner.getPropertyHandle<Type>(handle, propertyName)
    }

    async endDtSession(): Promise<void> {
        await this.inner.endDtSession()
    }

    async evaluate(
        func: string | EvaluateFunc<unknown[]>,
        ...args: unknown[]
    ): Promise<unknown> {
        return await this.inner.evaluate(func, ...args)
    }

    async getInnerText(selector: ISelector): Promise<string> {
        return await this.inner.getInnerText(selector)
    }

    async gotoPage(url: string): Promise<void> {
        await this.inner.gotoPage(url)
    }

    async standardDelay(): Promise<void> {
        await this.inner.standardDelay()
    }

    async shortDelay(): Promise<void> {
        await this.inner.shortDelay()
    }

    async longDelay(): Promise<void> {
        await this.inner.longDelay()
    }

    /**
     * loadgen-core's viewport wait, within the action's deadline: focuses the
     * element, then checks every waitInterval ms until it intersects the
     * viewport.
     */
    private async waitInViewport(
        stages: ActionStages,
        element: ElementHandle,
        waitInterval: number
    ): Promise<void> {
        await stages.within(element.focus())
        while (
            (await stages.within(element.isIntersectingViewport())) === false
        ) {
            await stages.pause(waitInterval)
        }
    }

    /**
     * Clicks the element at its clickable point after the viewport wait. The
     * mouse click starts right after the gate, and Puppeteer sends its mouse
     * events as the click starts, so none is sent once the deadline has
     * passed.
     */
    private async clickWithin(
        stages: ActionStages,
        element: ElementHandle,
        options?: ClickOptions
    ): Promise<void> {
        await this.waitInViewport(stages, element, VIEWPORT_POLL_MS)
        const point = await stages.within(
            element.clickablePoint(options?.offset)
        )
        stages.gate()
        await stages.within(
            element.frame.page().mouse.click(point.x, point.y, options)
        )
    }

    /**
     * Runs the stages of action on the element of handle under one deadline,
     * and disposes the handle when the action fails, at its deadline or
     * otherwise.
     *
     * @param redacted whether a stage abandoned at the deadline is logged by
     * its error's name only, without the error object
     */
    private async bounded(
        action: string,
        handle: IHandleWrapper,
        run: (stages: ActionStages, element: ElementHandle) => Promise<void>,
        redacted = false
    ): Promise<void> {
        const target = handle.toString()
        const timeout = new Error(
            `Page action [${action}] on [${target}] did not finish within [${this.timeoutMs}] ms`
        )
        timeout.name = "TimeoutError"
        let expired = false
        let expire: (error: Error) => void = () => undefined
        const expiry = new Promise<never>((_resolve, reject) => {
            expire = reject
        })
        // Handled from the start: the deadline can pass between two stages,
        // while no stage races it; the next stage or gate then fails.
        expiry.catch(() => undefined)
        let inFlight: Promise<unknown> | undefined
        let pauseTimer: ReturnType<typeof setTimeout> | undefined
        const stages: ActionStages = {
            within: async <T>(stage: Promise<T>): Promise<T> => {
                inFlight = stage
                return await Promise.race([stage, expiry])
            },
            pause: async (ms: number): Promise<void> => {
                // No browser work runs during a pause, so a deadline that
                // passes in it abandons no stage.
                inFlight = undefined
                const pause = new Promise<void>((resolve) => {
                    pauseTimer = setTimeout(resolve, ms)
                })
                await Promise.race([pause, expiry])
            },
            gate: (): void => {
                if (expired) {
                    throw timeout
                }
            },
            isTimeout: (error: unknown): boolean => error === timeout,
        }
        // Armed before the first stage, through the global setTimeout looked
        // up at call time, so a mocked clock drives the deadline.
        const deadline = setTimeout(() => {
            expired = true
            expire(timeout)
        }, this.timeoutMs)
        try {
            await run(stages, handle.getHandle())
        } catch (error) {
            this.dispose(action, target, handle)
            if (error === timeout && inFlight !== undefined) {
                this.logAbandoned(action, target, inFlight, redacted)
            }
            throw error
        } finally {
            clearTimeout(deadline)
            if (pauseTimer !== undefined) {
                clearTimeout(pauseTimer)
            }
        }
    }

    /**
     * Starts disposing the element handle without waiting for it: Puppeteer
     * marks the handle disposed as the call starts, and its release of the
     * remote object must not hold the caller past the deadline. A failure is
     * logged at debug, never thrown.
     */
    private dispose(
        action: string,
        target: string,
        handle: IHandleWrapper
    ): void {
        let disposal: Promise<void>
        try {
            disposal = Promise.resolve(handle.getHandle().dispose())
        } catch (error) {
            disposal = Promise.reject(error)
        }
        disposal.catch((error: unknown) => {
            this.logger.debug(
                `Page action [${action}] on [${target}] handle not disposed: error [${errorName(error)}]`,
                { error }
            )
        })
    }

    /**
     * Logs at debug how the stage an action abandoned at its deadline ends: a
     * failure by its error's name, and with the error object unless redacted.
     */
    private logAbandoned(
        action: string,
        target: string,
        stage: Promise<unknown>,
        redacted: boolean
    ): void {
        stage.then(
            () => {
                this.logger.debug(
                    `Page action [${action}] on [${target}] finished after its deadline`
                )
            },
            (error: unknown) => {
                const message = `Page action [${action}] on [${target}] failed after its deadline: error [${errorName(error)}]`
                if (redacted) {
                    // Without the whole error object .claude/rules/typescript.md
                    // asks for: a credential field's stage fails with errors
                    // that quote the untrusted document's URL.
                    this.logger.debug(message)
                } else {
                    this.logger.debug(message, { error })
                }
            }
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
 * isFeatureLost), the navigation still shown without the Portfolio Insights
 * link, ends with the owned-id outcome reached so far: not_submitted before
 * the submit click, unconfirmed from it until the id is read. Any other page
 * error before the id is read propagates unchanged, also when the page shows
 * no navigation at all and when the loss check fails. Once the id is known, a
 * failing UI deletion is logged and the API fallback decides the outcome, so
 * nothing is thrown after the outcome is decided.
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
        const instrumentId = await waitForInstrumentId(pageActions, logger)
        if (instrumentId === undefined) {
            logger.warn(
                "Alert instrument options did not load, no alert created"
            )
            return { kind: "not_submitted" }
        }

        marker = createMarker(random)
        await fillAlertForm(pageActions, instrumentId, marker)
    } catch (error) {
        // Nothing is submitted yet: a verified loss of the feature, the
        // navigation shown without its link, ends the visit without an
        // alert, and any other error, a page without navigation included,
        // propagates without an outcome line.
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
        // logged for an operator to find it. A verified loss of the feature,
        // the navigation shown without its link, ends the visit with that
        // outcome; any other error, a page without navigation included,
        // still propagates.
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

/**
 * The home link of the navigation every protected page shows, matched only
 * while no Portfolio Insights link is anywhere in the document: present only
 * on a page that has lost the feature, and looked up by isFeatureLost in the
 * DOM alone. Its XPath is the home link's selector filtered by the absence of
 * the Portfolio Insights link's selector, both single location paths, so one
 * evaluation reads both facts from the same document state.
 */
export const featureLossPresence = new DomPresenceSelector(
    new XpathSelector(
        "nav-without-portfolio-insights",
        `${selectors.navigation_homePage.baseValue}[not(${selectors.navigation_portfolioInsightsPage.baseValue})]`
    )
)

/**
 * Waits for the first instrument option and returns its value. Each of the
 * bounded checks is an isSelectorPresent of the option selector, answered
 * from the DOM because the options of a closed <select> are never visible;
 * once options are present, the first one's value is read, and an empty or
 * non-string value counts as not yet loaded.
 *
 * Each check releases the handles it acquired before it answers: the element
 * handle of every option it found and the handle of the value property it
 * read, so none is left to the page's close. They are released also when the
 * read fails, whose error then propagates, and a release that fails is logged
 * without replacing the check's answer or the read's error.
 *
 * @param pageActions
 * @param logger receives the debug line of a release that fails
 */
async function waitForInstrumentId(
    pageActions: IPageActions,
    logger: Logger
): Promise<string | undefined> {
    return await pollBounded(pageActions, async () => {
        if (!(await pageActions.isSelectorPresent(instrumentOptionPresence))) {
            return undefined
        }
        const options = await pageActions.getAllHandles(
            selectors.portfolioInsightsPage_alertInstrumentOption
        )
        try {
            if (options.length === 0) {
                return undefined
            }
            const value = await readOptionValue(options[0], logger)
            return typeof value === "string" && value !== "" ? value : undefined
        } finally {
            await releaseHandles(
                options.map((option) => () => option.getHandle().dispose()),
                logger
            )
        }
    })
}

/**
 * Reads the value property of option through its element, as
 * PageActions.getPropertyHandle does, but disposes the property's handle,
 * which getPropertyHandle leaves to the page's close, also when the read
 * fails.
 */
async function readOptionValue(
    option: IHandleWrapper,
    logger: Logger
): Promise<unknown> {
    const property = await option.getHandle().getProperty("value")
    try {
        return await property.jsonValue()
    } finally {
        await releaseHandles([() => property.dispose()], logger)
    }
}

/**
 * Runs every disposal, each whether or not another fails, and logs each one
 * that fails at debug, the message naming only the error's name and the entry
 * carrying the error object, instead of throwing: a failed release must not
 * replace the answer or the error of the read the handles served.
 */
async function releaseHandles(
    disposals: readonly (() => Promise<void>)[],
    logger: Logger
): Promise<void> {
    const results = await Promise.allSettled(
        disposals.map(async (dispose) => await dispose())
    )
    for (const result of results) {
        if (result.status === "rejected") {
            const error: unknown = result.reason
            logger.debug(
                `Instrument option handle not released: error [${errorName(error)}]`,
                { error }
            )
        }
    }
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
