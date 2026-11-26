import assert from "node:assert/strict"
import { afterEach, beforeEach, describe, it, mock, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import type { ElementHandle } from "puppeteer"
import { Logger, createLogger, format, transports } from "winston"
import { Config } from "../config"
import { getRegularProviderFunction } from "../provider/regularVisits"
import { selectors } from "../selectors"
import { User, getRandomUser } from "../user"
import { PortfolioInsightsAlertVisit } from "./portfolioInsightsAlert"

const BASE_URL = new URL("http://easytrade.test/")
const OWN_ID = "6f1c2b8e-3d4a-4b5c-9d6e-7f8091a2b3c4"
const MARKER = "1000000.55555555"
const INSTRUMENT_ID = "3d0c7c9a-0f6e-4b8e-a7a1-2b6f1c9d8e70"
const FLAG_REQUEST =
    "GET http://easytrade.test/feature-flag-service/v1/flags/portfolio-insights-enabled"

const USER: User = {
    first_name: "Test",
    last_name: "Visitor",
    username: "test_visitor",
    email: "test.visitor@example.test",
    password: "test-visitor-password",
    user_agent: "loadgen-test",
    ip4: "192.0.2.10",
    address: "1 Test Street",
    credit_card_number: "test-card",
    credit_card_cvv: "000",
    credit_card_provider: "visaDebit",
    visitor_id: "test-visitor-id",
}

function unexpected(action: string): never {
    throw new Error(`Unexpected page action [${action}]`)
}

/**
 * Records a selector with its XPath: every alert row's selectors share one
 * label, so only the XPath shows which alert an action targeted.
 */
function key(selector: ISelector): string {
    return selector.toString()
}

class FakeOptionHandle implements IHandleWrapper {
    readonly value: string

    constructor(value: string) {
        this.value = value
    }

    getHandle(): never {
        return unexpected("getHandle on an option")
    }

    toString(): string {
        return `option[${this.value}]`
    }
}

/**
 * An empty form field acquired through getHandle. Its Puppeteer element
 * records, into the page's calls, what the login step does on it directly.
 */
class FakeFieldHandle implements IHandleWrapper {
    private readonly target: string
    private readonly calls: string[]

    constructor(target: string, calls: string[]) {
        this.target = target
        this.calls = calls
    }

    getHandle(): ElementHandle {
        const element = {
            getProperty: async () => ({
                jsonValue: async () => "",
                dispose: async () => undefined,
            }),
            focus: async () => {
                this.calls.push(`focus ${this.target}`)
            },
            press: async (pressed: string) => {
                this.calls.push(`press ${this.target} ${pressed}`)
            },
            type: async (text: string) => {
                this.calls.push(`type ${this.target}=${text}`)
            },
        }
        return element as unknown as ElementHandle
    }

    toString(): string {
        return this.target
    }
}

/**
 * Records every page action in order. The instrument options, the own
 * created output, the own row and its deleted-id output are present at once.
 */
class RecordingPageActions implements IPageActions {
    readonly calls: string[] = []
    private readonly present = new Set([
        selectors.portfolioInsightsPage_alertInstrumentOption.toString(),
        selectors.portfolioInsightsPage_createdAlert(MARKER).toString(),
        selectors.portfolioInsightsPage_alertRow(OWN_ID).toString(),
        selectors.portfolioInsightsPage_deletedAlert(OWN_ID).toString(),
    ])

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        this.calls.push(`isSelectorPresent ${key(selector)}`)
        return this.present.has(selector.toString())
    }

    async getAllHandles(selector: ISelector): Promise<IHandleWrapper[]> {
        this.calls.push(`getAllHandles ${key(selector)}`)
        return selector ===
            selectors.portfolioInsightsPage_alertInstrumentOption
            ? [new FakeOptionHandle(INSTRUMENT_ID)]
            : []
    }

    async getPropertyHandle<Type = unknown>(
        handle: IHandleWrapper,
        propertyName: string
    ): Promise<Type> {
        this.calls.push(`getPropertyHandle ${handle} ${propertyName}`)
        if (!(handle instanceof FakeOptionHandle) || propertyName !== "value") {
            return unexpected(`getPropertyHandle ${propertyName}`)
        }
        const value: unknown = handle.value
        return value as Type
    }

    async getProperty<Type = unknown>(
        selector: ISelector,
        propertyName: string
    ): Promise<Type> {
        this.calls.push(`getProperty ${key(selector)} ${propertyName}`)
        if (
            selector.toString() !==
                selectors
                    .portfolioInsightsPage_createdAlert(MARKER)
                    .toString() ||
            propertyName !== "value"
        ) {
            return unexpected(`getProperty ${propertyName}`)
        }
        const value: unknown = OWN_ID
        return value as Type
    }

    async gotoPage(url: string): Promise<void> {
        this.calls.push(`gotoPage ${url}`)
    }

    async input(selector: ISelector, value: string): Promise<void> {
        this.calls.push(`input ${key(selector)}=${value}`)
    }

    async selectOption(selector: ISelector, option: string): Promise<void> {
        this.calls.push(`selectOption ${key(selector)}=${option}`)
    }

    async click(selector: ISelector): Promise<void> {
        this.calls.push(`click ${key(selector)}`)
    }

    async navigate(selector: ISelector): Promise<void> {
        this.calls.push(`navigate ${key(selector)}`)
    }

    async endDtSession(): Promise<void> {
        this.calls.push("endDtSession")
    }

    async standardDelay(): Promise<void> {
        this.calls.push("standardDelay")
    }

    async shortDelay(): Promise<void> {
        this.calls.push("shortDelay")
    }

    async longDelay(): Promise<void> {
        this.calls.push("longDelay")
    }

    async setupPage(): Promise<void> {
        return unexpected("setupPage")
    }

    async getHandle(selector: ISelector): Promise<IHandleWrapper> {
        this.calls.push(`getHandle ${key(selector)}`)
        return new FakeFieldHandle(key(selector), this.calls)
    }

    async scrollIntoView(handle: IHandleWrapper): Promise<void> {
        this.calls.push(`scrollIntoView ${handle}`)
    }

    async clickHandle(): Promise<void> {
        return unexpected("clickHandle")
    }

    async inputHandle(): Promise<void> {
        return unexpected("inputHandle")
    }

    async clearInput(): Promise<void> {
        return unexpected("clearInput")
    }

    async navigateHandle(): Promise<void> {
        return unexpected("navigateHandle")
    }

    async selectOptionHandle(): Promise<void> {
        return unexpected("selectOptionHandle")
    }

    async sleep(): Promise<void> {
        return unexpected("sleep")
    }

    async evaluate(): Promise<unknown> {
        return unexpected("evaluate")
    }

    async getInnerText(): Promise<string> {
        return unexpected("getInnerText")
    }
}

/**
 * A winston logger whose format records every entry as it is written, and
 * the error object of each entry that carries one.
 */
function recordingLogger(): {
    logger: Logger
    messages: string[]
    errors: unknown[]
} {
    const messages: string[] = []
    const errors: unknown[] = []
    const record = format((info) => {
        messages.push(`${info.level}: ${String(info.message)}`)
        if (info.error !== undefined) {
            errors.push(info.error)
        }
        return info
    })
    const logger = createLogger({
        level: "debug",
        format: record(),
        transports: [new transports.Console({ silent: true })],
    })
    return { logger, messages, errors }
}

/** Answers the flag read with the given state and fails any other request. */
function flagFetch(enabled: boolean): {
    fetchFn: typeof fetch
    requests: string[]
} {
    const requests: string[] = []
    const fetchFn: typeof fetch = async (input, init) => {
        const url = input instanceof Request ? input.url : String(input)
        const method = init?.method ?? "GET"
        requests.push(`${method} ${url}`)
        if (`${method} ${url}` !== FLAG_REQUEST) {
            throw new Error(`Unexpected request [${method} ${url}]`)
        }
        return new Response(
            JSON.stringify({ id: "portfolio-insights-enabled", enabled }),
            { status: 200 }
        )
    }
    return { fetchFn, requests }
}

beforeEach(() => {
    mock.timers.enable({ apis: ["setTimeout"] })
})

afterEach(() => {
    mock.timers.reset()
})

test("run_flagOff_skipsBeforeGotoPage", async () => {
    const page = new RecordingPageActions()
    const { fetchFn, requests } = flagFetch(false)
    const { logger, messages } = recordingLogger()
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        BASE_URL,
        USER,
        { fetchFn }
    )

    await visit.run(page, logger)

    assert.deepEqual(
        { pageCalls: page.calls, requests, messages },
        {
            pageCalls: [],
            requests: [FLAG_REQUEST],
            messages: [
                "debug: Flag [portfolio-insights-enabled] is disabled",
                "info: Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit",
            ],
        }
    )
})

test("run_flagOn_runsLoginLifecycleLogoutInOrder", async () => {
    const page = new RecordingPageActions()
    const { fetchFn, requests } = flagFetch(true)
    const { logger, messages } = recordingLogger()
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        BASE_URL,
        USER,
        { fetchFn, random: () => 0.5 }
    )

    await visit.run(page, logger)

    const steps = page.calls.filter(
        (call) =>
            !call.startsWith("isSelectorPresent") &&
            !call.startsWith("getAllHandles") &&
            !call.startsWith("getProperty") &&
            !call.endsWith("Delay")
    )
    // The password is typed on its element, not through a logging page action.
    assert.deepEqual(
        { steps, requests, messages },
        {
            steps: [
                "gotoPage http://easytrade.test/",
                `input ${key(selectors.loginPage_username)}=test_visitor`,
                `getHandle ${key(selectors.loginPage_password)}`,
                `scrollIntoView ${key(selectors.loginPage_password)}`,
                `focus ${key(selectors.loginPage_password)}`,
                `type ${key(selectors.loginPage_password)}=test-visitor-password`,
                `navigate ${key(selectors.loginPage_loginButton)}`,
                `navigate ${key(selectors.navigation_portfolioInsightsPage)}`,
                `selectOption ${key(selectors.portfolioInsightsPage_alertType)}=TARGET_PRICE`,
                `selectOption ${key(selectors.portfolioInsightsPage_alertInstrument)}=${INSTRUMENT_ID}`,
                `selectOption ${key(selectors.portfolioInsightsPage_alertDirection)}=ABOVE`,
                `input ${key(selectors.portfolioInsightsPage_alertThreshold)}=${MARKER}`,
                `click ${key(selectors.portfolioInsightsPage_alertSubmit)}`,
                `click ${key(selectors.portfolioInsightsPage_alertRowDelete(OWN_ID))}`,
                `click ${key(selectors.navigation_dropdownToggler)}`,
                `navigate ${key(selectors.navigation_logout)}`,
                "endDtSession",
            ],
            requests: [FLAG_REQUEST],
            messages: [
                "info: Going to EasyTrade frontend at [http://easytrade.test/]",
                "info: Logging in as user [test_visitor]",
                "info: Opening portfolio insights page",
                `info: Created alert [${OWN_ID}] threshold [${MARKER}]`,
                `info: Deleted alert [${OWN_ID}] via ui`,
                "info: Logging out user [test_visitor]",
                "info: Attempting to end dynatrace session",
            ],
        }
    )
})

const NAV_KEY = key(selectors.navigation_portfolioInsightsPage)
const SUBMIT_KEY = key(selectors.portfolioInsightsPage_alertSubmit)
const DROPDOWN_KEY = key(selectors.navigation_dropdownToggler)
const LOGOUT_KEY = key(selectors.navigation_logout)
const DELETE_OWN = `DELETE http://easytrade.test/broker-service/v1/alerts/${OWN_ID}`
const pageError = new Error("Execution context was destroyed")
const logoutError = new Error("Node is not clickable")
const knownErrors = new Map<unknown, string>([
    [pageError, "pageError"],
    [logoutError, "logoutError"],
])

/** Names a known error object, or another error by its message. */
function describeError(error: unknown): string {
    return (
        knownErrors.get(error) ??
        (error instanceof Error
            ? `Error: ${error.message}`
            : `not an error object: ${String(error)}`)
    )
}

type VisitScenario = {
    /** selector keys present beyond RecordingPageActions' own */
    present?: string[]
    /** selector keys never present */
    absent?: string[]
    /** `click <key>` or `navigate <key>` actions that throw */
    failing?: Map<string, Error>
    /** status of the API DELETE of the own alert; unset fails the request */
    deleteStatus?: number
}

/** RecordingPageActions with the presence and failures of one scenario. */
class ScenarioPageActions extends RecordingPageActions {
    private readonly scenario: VisitScenario

    constructor(scenario: VisitScenario) {
        super()
        this.scenario = scenario
    }

    override async isSelectorPresent(selector: ISelector): Promise<boolean> {
        const present = await super.isSelectorPresent(selector)
        const target = key(selector)
        if (this.scenario.absent?.includes(target)) {
            return false
        }
        return present || (this.scenario.present?.includes(target) ?? false)
    }

    override async click(selector: ISelector): Promise<void> {
        await super.click(selector)
        this.fail(`click ${key(selector)}`)
    }

    override async navigate(selector: ISelector): Promise<void> {
        await super.navigate(selector)
        this.fail(`navigate ${key(selector)}`)
    }

    private fail(action: string): void {
        const error = this.scenario.failing?.get(action)
        if (error !== undefined) {
            throw error
        }
    }
}

/** Answers the flag read with true and the own alert's DELETE with status. */
function enabledFetch(deleteStatus?: number): {
    fetchFn: typeof fetch
    requests: string[]
} {
    const requests: string[] = []
    const fetchFn: typeof fetch = async (input, init) => {
        const url = input instanceof Request ? input.url : String(input)
        const request = `${init?.method ?? "GET"} ${url}`
        requests.push(request)
        if (request === FLAG_REQUEST) {
            return new Response(
                JSON.stringify({
                    id: "portfolio-insights-enabled",
                    enabled: true,
                }),
                { status: 200 }
            )
        }
        if (request === DELETE_OWN && deleteStatus !== undefined) {
            return new Response(null, { status: deleteStatus })
        }
        throw new Error(`Unexpected request [${request}]`)
    }
    return { fetchFn, requests }
}

const OPENING = [
    "info: Going to EasyTrade frontend at [http://easytrade.test/]",
    "info: Logging in as user [test_visitor]",
    "info: Opening portfolio insights page",
]
const CREATED = `info: Created alert [${OWN_ID}] threshold [${MARKER}]`
const UNCONFIRMED = `warn: Create unconfirmed threshold [${MARKER}], outcome unknown`
const CLOSING = [
    "info: Logging out user [test_visitor]",
    "info: Attempting to end dynatrace session",
]
const CLOSED = [
    `click ${DROPDOWN_KEY}`,
    `navigate ${LOGOUT_KEY}`,
    "endDtSession",
]

const visitRows: {
    name: string
    scenario: VisitScenario
    expected: {
        /** "resolved", or the rejection as describeError names it */
        settled: string
        requests: string[]
        messages: string[]
        errors: string[]
        /** the logout and session-end actions, in order */
        closed: string[]
    }
}[] = [
    {
        name: "deletedViaApi_resolves",
        scenario: {
            absent: [key(selectors.portfolioInsightsPage_deletedAlert(OWN_ID))],
            deleteStatus: 204,
        },
        expected: {
            settled: "resolved",
            requests: [FLAG_REQUEST, DELETE_OWN],
            messages: [
                ...OPENING,
                CREATED,
                `info: Deleted alert [${OWN_ID}] via api`,
                ...CLOSING,
            ],
            errors: [],
            closed: CLOSED,
        },
    },
    {
        name: "alreadyAbsent_resolves",
        scenario: {
            absent: [key(selectors.portfolioInsightsPage_deletedAlert(OWN_ID))],
            deleteStatus: 404,
        },
        expected: {
            settled: "resolved",
            requests: [FLAG_REQUEST, DELETE_OWN],
            messages: [
                ...OPENING,
                CREATED,
                `info: Alert [${OWN_ID}] already absent`,
                ...CLOSING,
            ],
            errors: [],
            closed: CLOSED,
        },
    },
    {
        name: "leftInPlace_rejectsAfterClosingSession",
        scenario: {
            absent: [key(selectors.portfolioInsightsPage_deletedAlert(OWN_ID))],
            deleteStatus: 500,
        },
        expected: {
            settled: `Error: Owned alert outcome [left_in_place]: alert [${OWN_ID}] not deleted, status [500]`,
            requests: [FLAG_REQUEST, DELETE_OWN],
            messages: [
                ...OPENING,
                CREATED,
                `warn: Alert [${OWN_ID}] left in place: 500`,
                ...CLOSING,
            ],
            errors: [],
            closed: CLOSED,
        },
    },
    {
        name: "createUnconfirmed_rejectsAfterClosingSession",
        scenario: {
            absent: [key(selectors.portfolioInsightsPage_createdAlert(MARKER))],
        },
        expected: {
            settled: `Error: Owned alert outcome [unconfirmed]: create of threshold [${MARKER}] not confirmed`,
            requests: [FLAG_REQUEST],
            messages: [...OPENING, UNCONFIRMED, ...CLOSING],
            errors: [],
            closed: CLOSED,
        },
    },
    {
        name: "featureLostAtNavigation_notSubmittedRejectsAfterClosingSession",
        scenario: { failing: new Map([[`navigate ${NAV_KEY}`, pageError]]) },
        expected: {
            settled:
                "Error: Owned alert outcome [not_submitted]: no alert was submitted",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                "warn: Portfolio insights page unavailable, no alert created",
                ...CLOSING,
            ],
            errors: ["pageError"],
            closed: CLOSED,
        },
    },
    {
        name: "featureLostAtSubmit_unconfirmedRejectsAfterClosingSession",
        scenario: { failing: new Map([[`click ${SUBMIT_KEY}`, pageError]]) },
        expected: {
            settled: `Error: Owned alert outcome [unconfirmed]: create of threshold [${MARKER}] not confirmed`,
            requests: [FLAG_REQUEST],
            messages: [...OPENING, UNCONFIRMED, ...CLOSING],
            errors: ["pageError"],
            closed: CLOSED,
        },
    },
    {
        name: "unrelatedLifecycleError_rejectsWithItAfterClosingSession",
        scenario: {
            present: [NAV_KEY],
            failing: new Map([[`click ${SUBMIT_KEY}`, pageError]]),
        },
        expected: {
            settled: "pageError",
            requests: [FLAG_REQUEST],
            messages: [...OPENING, UNCONFIRMED, ...CLOSING],
            errors: ["pageError"],
            closed: CLOSED,
        },
    },
    {
        name: "logoutThrowsAfterLifecycleError_keepsLifecycleError",
        scenario: {
            present: [NAV_KEY],
            failing: new Map([
                [`click ${SUBMIT_KEY}`, pageError],
                [`click ${DROPDOWN_KEY}`, logoutError],
            ]),
        },
        expected: {
            settled: "pageError",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                UNCONFIRMED,
                ...CLOSING,
                "warn: Closing the session after a failed visit failed",
            ],
            errors: ["pageError", "logoutError"],
            closed: [`click ${DROPDOWN_KEY}`, "endDtSession"],
        },
    },
    {
        name: "logoutThrowsAfterCleanLifecycle_rejectsWithLogoutError",
        scenario: {
            failing: new Map([[`click ${DROPDOWN_KEY}`, logoutError]]),
        },
        expected: {
            settled: "logoutError",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                CREATED,
                `info: Deleted alert [${OWN_ID}] via ui`,
                ...CLOSING,
            ],
            errors: [],
            closed: [`click ${DROPDOWN_KEY}`, "endDtSession"],
        },
    },
]

// A suite rather than subtests, so the file's beforeEach mocks the clock
// once per row.
describe("run_lifecycleScenario_closesSessionThenSettles", () => {
    for (const row of visitRows) {
        it(row.name, async () => {
            const page = new ScenarioPageActions(row.scenario)
            const { fetchFn, requests } = enabledFetch(
                row.scenario.deleteStatus
            )
            const { logger, messages, errors } = recordingLogger()
            const visit = new PortfolioInsightsAlertVisit(
                "portfolio_insights_alert",
                BASE_URL,
                USER,
                { fetchFn, random: () => 0.5 }
            )

            const settled = await visit.run(page, logger).then(
                () => "resolved",
                (error: unknown) => describeError(error)
            )

            assert.deepEqual(
                {
                    settled,
                    requests,
                    messages,
                    errors: errors.map(describeError),
                    closed: page.calls.filter(
                        (call) =>
                            call === `click ${DROPDOWN_KEY}` ||
                            call === `navigate ${LOGOUT_KEY}` ||
                            call === "endDtSession"
                    ),
                },
                row.expected
            )
        })
    }
})

// The provider constructs the visit with three arguments, so the run must
// fall back to the global fetch and Math.random captured at construction.
test("constructor_depsOmitted_usesGlobalFetchAndMathRandom", async (t) => {
    const page = new RecordingPageActions()
    const { fetchFn, requests } = flagFetch(true)
    t.mock.method(globalThis, "fetch", fetchFn)
    t.mock.method(Math, "random", () => 0.5)
    const { logger } = recordingLogger()
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        BASE_URL,
        USER
    )

    await visit.run(page, logger)

    const thresholdInput = `input ${key(selectors.portfolioInsightsPage_alertThreshold)}=`
    assert.deepEqual(
        {
            requests,
            threshold: page.calls.filter((call) =>
                call.startsWith(thresholdInput)
            ),
        },
        {
            requests: [FLAG_REQUEST],
            threshold: [`${thresholdInput}${MARKER}`],
        }
    )
})

// The provider's dispatch to this visit is tested here, with the visit it
// builds, because provider/ keeps no test file of its own; the Guardrails rule
// requires a unit test for the switch case the provider gains for this visit.
test("getRegularProviderFunction_portfolioInsightsAlert_buildsVisitWithConfigUrlAndUser", (t) => {
    t.mock.method(Math, "random", () => 0)
    const config: Config = {
        concurrent_visits: 1,
        concurrent_browsers: 1,
        browserTimeToLiveMinutes: 60,
        logLevel: "info",
        rareVisitsIntervalMinutes: 30,
        headlessMode: "headless",
        visitsConfig: {
            depositMinValue: 500,
            depositMaxValue: 1500,
            assetSellRatio: 0.1,
            withdrawMinValue: 500,
            transactionMinDuration: 1,
            transactionMaxDuration: 24,
            easytradeUrl: BASE_URL,
        },
        providerConfig: { type: "constant" },
        regularVisitsWeights: {
            deposit_and_buy_success: 1,
            deposit_and_long_buy_error: 1,
            deposit_and_long_buy_success: 1,
            deposit_and_long_buy_timeout: 1,
            long_sell_error: 1,
            long_sell_success: 1,
            long_sell_timeout: 1,
            sell_and_withdraw_success: 1,
            portfolio_insights_alert: 1,
        },
    }

    const visit = getRegularProviderFunction(config)("portfolio_insights_alert")

    assert.ok(visit instanceof PortfolioInsightsAlertVisit)
    assert.deepEqual(
        { name: visit.getName(), url: visit.url, user: visit.user },
        {
            name: "portfolio_insights_alert",
            url: BASE_URL,
            user: getRandomUser(),
        }
    )
})
