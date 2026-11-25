// The package root, as every loadgen helper imports loadgen-core (Guardrails:
// follow the service's existing conventions), not its lib/ subpaths.
import {
    IPageActions,
    ISelector,
    createLoggerOptions,
} from "@demoability/loadgen-core"
import { Logger, createLogger } from "winston"
import { selectors } from "../selectors"
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

type FlagResponse = { id: string; enabled: boolean }

function isFlagResponse(value: unknown): value is FlagResponse {
    return (
        typeof value === "object" &&
        value !== null &&
        "id" in value &&
        "enabled" in value &&
        value.id === PORTFOLIO_INSIGHTS_FLAG_ID &&
        typeof value.enabled === "boolean"
    )
}

/**
 * Reads the portfolio-insights-enabled flag once, fail-closed: only a 200
 * whose body carries this flag's id and a boolean `enabled` counts as an
 * answer.
 *
 * This is the one place loadgen turns an error into a value instead of
 * propagating it (the documented exception to .claude/rules/typescript.md):
 * the feature defines an unreachable flag service as disabled, so every other
 * outcome, the deadline abort included, is logged in full and read as false.
 *
 * @param url EasyTrade base url
 * @param fetchFn fetch implementation
 * @param timeoutMs abort deadline of the whole read
 * @param logger logger receiving the read's outcomes
 */
export async function isPortfolioInsightsEnabled(
    url: URL,
    fetchFn: typeof fetch = fetch,
    timeoutMs = 2000,
    logger: Logger = fallbackLogger
): Promise<boolean> {
    const controller = new AbortController()
    // Armed before the first await, through the global setTimeout looked up at
    // call time, so a mocked clock drives the deadline.
    const deadline = setTimeout(() => controller.abort(), timeoutMs)
    try {
        const response = await fetchFn(new URL(FLAG_PATH, url), {
            method: "GET",
            signal: controller.signal,
            headers: { accept: "application/json" },
        })
        if (response.status !== 200) {
            logger.warn(
                `Flag [portfolio-insights-enabled] read returned status [${response.status}], treating as disabled`
            )
            return false
        }
        const body: unknown = await response.json()
        if (!isFlagResponse(body)) {
            logger.warn(
                "Flag [portfolio-insights-enabled] response invalid, treating as disabled",
                { body }
            )
            return false
        }
        if (!body.enabled) {
            logger.debug("Flag [portfolio-insights-enabled] is disabled")
        }
        return body.enabled
    } catch (error) {
        logger.warn(
            "Flag [portfolio-insights-enabled] unreadable, treating as disabled",
            { error }
        )
        return false
    } finally {
        clearTimeout(deadline)
    }
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
 * Assumes starting point Portfolio Insights page.
 * Endpoint Portfolio Insights page.
 *
 * Creates one alert, confirms its id from the created-id output and deletes
 * only that id: through its own row, or through the broker REST API when the
 * UI deletion is not confirmed. It never touches an alert it did not create,
 * so visits sharing one preset user cannot disturb each other.
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
    const instrumentId = await waitForInstrumentId(pageActions)
    if (instrumentId === undefined) {
        logger.warn("Alert instrument options did not load, no alert created")
        return { kind: "not_submitted" }
    }

    const marker = createMarker(random)
    await fillAlertForm(pageActions, instrumentId, marker)
    let id: string | undefined
    try {
        await pageActions.click(selectors.portfolioInsightsPage_alertSubmit)
        id = await readCreatedAlertId(pageActions, marker, logger)
    } catch (error) {
        // From the submit click on, the alert may exist, so the marker is
        // logged for an operator to find it; the error still fails the visit.
        logger.warn(unconfirmedMessage(marker), { error })
        throw error
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
 * Waits for the first instrument option and returns its value.
 * Options of a closed <select> have no layout box, so the visibility-based
 * isSelectorPresent never reports them; their presence is read from the DOM.
 */
async function waitForInstrumentId(
    pageActions: IPageActions
): Promise<string | undefined> {
    return await pollBounded(pageActions, async () => {
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
            { method: "DELETE", signal: controller.signal }
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
        const status = controller.signal.aborted ? "timeout" : "error"
        logger.warn(`Alert [${id}] left in place: ${status}`, { error })
        return { kind: "left_in_place", id, status }
    } finally {
        clearTimeout(deadline)
    }
}
