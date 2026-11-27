import assert from "node:assert/strict"
import { afterEach, beforeEach, describe, it, mock, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import type { ElementHandle, Page } from "puppeteer"
import { Logger, createLogger, format, transports } from "winston"
import { Config } from "../config"
import {
    DOCUMENT_ORIGIN_UNVERIFIED,
    PAGE_ACTION_TIMEOUT_MS,
    featureLossPresence,
} from "../helpers/portfolioInsights"
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

/** The page methods pageSetup calls, which the fake page actions record. */
type SetupPage = Pick<Page, "setExtraHTTPHeaders" | "setCookie"> & {
    setUserAgent(userAgent: string): Promise<void>
}

/**
 * An instrument option as getAllHandles wraps it. Its Puppeteer element
 * answers the value property through a JSHandle, as a real option does, and
 * both accept the dispose the helper releases them with.
 */
class FakeOptionHandle implements IHandleWrapper {
    readonly value: string

    constructor(value: string) {
        this.value = value
    }

    getHandle(): ElementHandle {
        const element = {
            getProperty: async (propertyName: string) => {
                if (propertyName !== "value") {
                    return unexpected(
                        `getProperty ${propertyName} of an option`
                    )
                }
                return {
                    jsonValue: async () => this.value,
                    dispose: async () => undefined,
                }
            },
            dispose: async () => undefined,
        }
        return element as unknown as ElementHandle
    }

    toString(): string {
        return `option[${this.value}]`
    }
}

/**
 * A form control acquired through getHandle. Its Puppeteer element is in the
 * viewport at once and dispatches through the page: a mouse click as
 * `click <key>`, or as `navigate <key>` once a navigation wait has started,
 * which the click then ends; a selection as `selectOption <key>=<option>`; a
 * write as `input <key>=<text>`, or, for a credential, as
 * `credential <key>=<text>` when the page's document is at the origin the
 * write requires, and as nothing when it is not.
 */
class FakeFieldHandle implements IHandleWrapper {
    private readonly target: string
    private readonly page: RecordingPageActions

    constructor(target: string, page: RecordingPageActions) {
        this.target = target
        this.page = page
    }

    getHandle(): ElementHandle {
        let navigating = false
        let navigated: () => void = () => undefined
        const click = async (): Promise<void> => {
            this.page.dispatched(
                `${navigating ? "navigate" : "click"} ${this.target}`
            )
            navigated()
        }
        const element = {
            focus: async () => undefined,
            isIntersectingViewport: async () => true,
            clickablePoint: async () => ({ x: 1, y: 1 }),
            select: async (option: string) => {
                this.page.dispatched(`selectOption ${this.target}=${option}`)
                return [option]
            },
            evaluate: async (
                _write: unknown,
                text: string,
                origin: string | null
            ) => {
                if (origin === null) {
                    this.page.dispatched(`input ${this.target}=${text}`)
                    return true
                }
                if (origin !== this.page.documentOrigin) {
                    return false
                }
                this.page.dispatched(`credential ${this.target}=${text}`)
                return true
            },
            frame: {
                waitForNavigation: () => {
                    navigating = true
                    return new Promise((resolve) => {
                        navigated = () => resolve(null)
                    })
                },
                page: () => ({ mouse: { click } }),
            },
            dispose: async () => undefined,
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
 * The visit bounds its element actions, so each one arrives as getHandle,
 * then as what the handle's element dispatches, recorded by the handle's
 * selector key; the selector and handle forms are never called. Its document
 * is at the origin of the last gotoPage URL, or at landingOrigin once a
 * redirect led there instead.
 */
class RecordingPageActions implements IPageActions {
    readonly calls: string[] = []
    /** The opaque origin of the blank page a new page starts on, at first. */
    documentOrigin = "null"
    private readonly present = new Set([
        selectors.portfolioInsightsPage_alertInstrumentOption.toString(),
        selectors.portfolioInsightsPage_createdAlert(MARKER).toString(),
        selectors.portfolioInsightsPage_alertRow(OWN_ID).toString(),
        selectors.portfolioInsightsPage_deletedAlert(OWN_ID).toString(),
    ])
    private readonly landingOrigin: string | undefined

    /** @param landingOrigin where every gotoPage ends, when not at its URL */
    constructor(landingOrigin?: string) {
        this.landingOrigin = landingOrigin
    }

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

    /** Leaves its property handle undisposed, so the visit never calls it. */
    async getPropertyHandle<Type = unknown>(): Promise<Type> {
        return unexpected("getPropertyHandle")
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
        this.documentOrigin = this.landingOrigin ?? new URL(url).origin
    }

    async input(): Promise<void> {
        return unexpected("input")
    }

    async selectOption(): Promise<void> {
        return unexpected("selectOption")
    }

    async click(): Promise<void> {
        return unexpected("click")
    }

    async navigate(): Promise<void> {
        return unexpected("navigate")
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

    async setupPage(setup: (page: Page) => Promise<void>): Promise<void> {
        this.calls.push("setupPage")
        const page: SetupPage = {
            setUserAgent: async (userAgent) => {
                this.calls.push(`setUserAgent ${userAgent}`)
            },
            setExtraHTTPHeaders: async (headers) => {
                this.calls.push(
                    `setExtraHTTPHeaders ${JSON.stringify(headers)}`
                )
            },
            setCookie: async (...cookies) => {
                this.calls.push(`setCookie ${JSON.stringify(cookies)}`)
            },
        }
        // pageSetup calls no other page method, so this page serves it.
        await setup(page as Page)
    }

    async getHandle(selector: ISelector): Promise<IHandleWrapper> {
        this.calls.push(`getHandle ${key(selector)}`)
        return new FakeFieldHandle(key(selector), this)
    }

    /** Records step, a click, selection or write an element dispatched. */
    dispatched(step: string): void {
        this.calls.push(step)
    }

    async scrollIntoView(): Promise<void> {
        return unexpected("scrollIntoView")
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
function flagFetch(
    enabled: boolean,
    flagRequest: string = FLAG_REQUEST
): {
    fetchFn: typeof fetch
    requests: string[]
} {
    const requests: string[] = []
    const fetchFn: typeof fetch = async (input, init) => {
        const url = input instanceof Request ? input.url : String(input)
        const method = init?.method ?? "GET"
        requests.push(`${method} ${url}`)
        if (`${method} ${url}` !== flagRequest) {
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

    // Lookups are left out, the handle each bounded action acquires included.
    const steps = page.calls.filter(
        (call) =>
            !call.startsWith("isSelectorPresent") &&
            !call.startsWith("getAllHandles") &&
            !call.startsWith("getProperty") &&
            !call.startsWith("getHandle") &&
            !call.endsWith("Delay")
    )
    // Both credentials are written on their elements, each only into a
    // document at the visit's origin, never through a logging page action.
    assert.deepEqual(
        { steps, requests, messages },
        {
            steps: [
                "gotoPage http://easytrade.test/",
                `credential ${key(selectors.loginPage_username)}=test_visitor`,
                `credential ${key(selectors.loginPage_password)}=test-visitor-password`,
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
                "info: Going to EasyTrade frontend at [http://easytrade.test]",
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

// A redirect at the configured origin left the browser elsewhere: the visit
// fails with no credential written, with no session to close, and neither the
// error nor any line names where the browser ended up.
test("run_gotoPageLandsElsewhere_rejectsBeforeWritingCredentials", async () => {
    const elsewhere = "http://elsewhere.test"
    const page = new RecordingPageActions(elsewhere)
    const { fetchFn, requests } = flagFetch(true)
    const { logger, messages } = recordingLogger()
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        BASE_URL,
        USER,
        { fetchFn, random: () => 0.5 }
    )

    const settled = await visit.run(page, logger).then(
        () => "resolved",
        (error: unknown) =>
            error instanceof Error
                ? `${error.name}: ${error.message}`
                : `not an error object: ${String(error)}`
    )

    assert.deepEqual(
        {
            settled,
            pageCalls: page.calls,
            requests,
            messages,
            exposed: [...messages, settled].filter((text) =>
                text.includes("elsewhere.test")
            ),
            urlInError: settled.includes(BASE_URL.hostname),
        },
        {
            settled: `Error: ${DOCUMENT_ORIGIN_UNVERIFIED}`,
            pageCalls: [
                "gotoPage http://easytrade.test/",
                `getHandle ${key(selectors.loginPage_username)}`,
            ],
            requests: [FLAG_REQUEST],
            messages: [
                "info: Going to EasyTrade frontend at [http://easytrade.test]",
                "info: Logging in as user [test_visitor]",
            ],
            exposed: [],
            urlInError: false,
        }
    )
})

// Each row puts a secret where a misconfigured EASYTRADE_URL could carry one,
// or breaks the origin shape the visit relies on.
const URL_SECRET = "s3cret-token-value"
const NOT_ORIGIN_URLS = [
    ["userAndPassword", `http://visitor:${URL_SECRET}@easytrade.test/`],
    ["usernameOnly", `http://${URL_SECRET}@easytrade.test/`],
    ["query", `http://easytrade.test/?token=${URL_SECRET}`],
    ["fragment", `http://easytrade.test/#${URL_SECRET}`],
    ["emptyQuery", "http://easytrade.test/?"],
    ["emptyFragment", "http://easytrade.test/#"],
    ["path", "http://easytrade.test/app"],
    ["nonHttpScheme", "ftp://easytrade.test/"],
] as const

/**
 * Calls one visit step with a URL it must refuse. Returns what it threw,
 * the page actions and requests it made, what it logged, and each of those
 * texts that shows the secret or any part of the URL.
 */
async function refuse(
    rawUrl: string,
    step: (
        visit: PortfolioInsightsAlertVisit,
        page: IPageActions,
        logger: Logger
    ) => Promise<void>
): Promise<Record<string, unknown>> {
    const page = new RecordingPageActions()
    const { fetchFn, requests } = flagFetch(true)
    const { logger, messages } = recordingLogger()
    const url = new URL(rawUrl)
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        url,
        USER,
        { fetchFn }
    )

    const outcome: unknown = await step(visit, page, logger).then(
        () => "resolved",
        (error: unknown) => error
    )

    const thrown = outcome instanceof Error ? outcome.message : outcome
    const exposed = [...messages, String(thrown)].filter(
        (text) =>
            text.includes(URL_SECRET) ||
            text.includes(rawUrl) ||
            text.includes(url.href) ||
            text.includes("easytrade.test")
    )
    return { thrown, pageCalls: page.calls, requests, messages, exposed }
}

const REFUSED = {
    thrown: "EASYTRADE_URL must be an http or https origin without credentials, path, query or fragment; portfolio insights visit not run",
    pageCalls: [],
    requests: [],
    messages: [],
    exposed: [],
}

for (const [scenario, rawUrl] of NOT_ORIGIN_URLS) {
    test(`run_urlNotCredentialFreeOrigin_throwsBeforeAnyRequest (${scenario})`, async () => {
        const refused = await refuse(rawUrl, (visit, page, logger) =>
            visit.run(page, logger)
        )

        assert.deepEqual(refused, REFUSED)
    })

    // The worker calls setup before run, so setup refuses the URL before the
    // page cookie takes its host and before setup logs anything.
    test(`setup_urlNotCredentialFreeOrigin_throwsBeforePageSetup (${scenario})`, async () => {
        const refused = await refuse(rawUrl, (visit, page, logger) =>
            visit.setup(page, logger)
        )

        assert.deepEqual(refused, REFUSED)
    })
}

// The EASYTRADE_URL values Compose and the Helm chart ship (the chart's with
// a port) are origins: setup sets the page cookie for their host, and run logs
// them exactly as configured and keeps them in every request.
const SHIPPED_ORIGINS = [
    ["compose", "http://reverse-proxy", "reverse-proxy"],
    [
        "helmWithPort",
        "http://easytrade-reverse-proxy:8080",
        "easytrade-reverse-proxy",
    ],
] as const

for (const [scenario, origin, host] of SHIPPED_ORIGINS) {
    test(`setup_shippedOrigin_setsUpPageWithCookieForHost (${scenario})`, async () => {
        const page = new RecordingPageActions()
        const { logger, messages } = recordingLogger()
        const visit = new PortfolioInsightsAlertVisit(
            "portfolio_insights_alert",
            new URL(origin),
            USER
        )

        await visit.setup(page, logger)

        assert.deepEqual(
            { pageCalls: page.calls, messages },
            {
                pageCalls: [
                    "setupPage",
                    "setUserAgent loadgen-test",
                    'setExtraHTTPHeaders {"x-forwarded-for":"192.0.2.10"}',
                    `setCookie [{"name":"rxVisitor","value":"test-visitor-id","domain":"${host}","path":"/"}]`,
                ],
                messages: [
                    "info: Setting up page for user [test_visitor|192.0.2.10]",
                ],
            }
        )
    })

    test(`run_shippedOrigin_logsOriginAndOpensIt (${scenario})`, async () => {
        const page = new RecordingPageActions()
        const flagRequest = `GET ${origin}/feature-flag-service/v1/flags/portfolio-insights-enabled`
        const { fetchFn, requests } = flagFetch(true, flagRequest)
        const { logger, messages } = recordingLogger()
        const visit = new PortfolioInsightsAlertVisit(
            "portfolio_insights_alert",
            new URL(origin),
            USER,
            { fetchFn, random: () => 0.5 }
        )

        await visit.run(page, logger)

        assert.deepEqual(
            {
                requests,
                firstMessage: messages[0],
                gotoCalls: page.calls.filter((call) =>
                    call.startsWith("gotoPage")
                ),
            },
            {
                requests: [flagRequest],
                firstMessage: `info: Going to EasyTrade frontend at [${origin}]`,
                gotoCalls: [`gotoPage ${origin}/`],
            }
        )
    })
}

const NAV_KEY = key(selectors.navigation_portfolioInsightsPage)
/** The home link, present while the navigation of a protected page is shown. */
const HOME_NAV_KEY = key(selectors.navigation_homePage)
/** The feature check's one DOM query of both links. */
const FEATURE_LOSS_KEY = key(featureLossPresence)
const SUBMIT_KEY = key(selectors.portfolioInsightsPage_alertSubmit)
const DROPDOWN_KEY = key(selectors.navigation_dropdownToggler)
const LOGOUT_KEY = key(selectors.navigation_logout)
const DELETE_OWN = `DELETE http://easytrade.test/broker-service/v1/alerts/${OWN_ID}`
const pageError = new Error("Execution context was destroyed")
const logoutError = new Error("Node is not clickable")
/** A TypeError, so the line naming its class differs from a plain Error's. */
const sessionEndError = new TypeError(
    "Cannot read properties of null (reading 'evaluate')"
)
const knownErrors = new Map<unknown, string>([
    [pageError, "pageError"],
    [logoutError, "logoutError"],
    [sessionEndError, "sessionEndError"],
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
    /**
     * selector keys present beyond RecordingPageActions' own; the feature-loss
     * query reads the home and Portfolio Insights link keys
     */
    present?: string[]
    /** selector keys never present */
    absent?: string[]
    /** `click <key>`, `navigate <key>` or `endDtSession` actions that throw */
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
        if (target === FEATURE_LOSS_KEY) {
            // One query reads both links from the scenario's one page state.
            const shown = this.scenario.present ?? []
            return shown.includes(HOME_NAV_KEY) && !shown.includes(NAV_KEY)
        }
        if (this.scenario.absent?.includes(target)) {
            return false
        }
        return present || (this.scenario.present?.includes(target) ?? false)
    }

    /** Records step, then fails as the scenario has it fail. */
    override dispatched(step: string): void {
        super.dispatched(step)
        this.fail(step)
    }

    override async endDtSession(): Promise<void> {
        await super.endDtSession()
        this.fail("endDtSession")
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
    "info: Going to EasyTrade frontend at [http://easytrade.test]",
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
/** Names sessionEndError by its class only, never by its message. */
const SESSION_END_FAILED =
    "warn: Ending the dynatrace session failed after the logout failed: error [TypeError]"

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
        scenario: {
            present: [HOME_NAV_KEY],
            failing: new Map([[`navigate ${NAV_KEY}`, pageError]]),
        },
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
    // An error page replaced the whole layout, the flag still on: the
    // navigation's own error fails the visit, and no line claims the feature
    // was lost.
    {
        name: "navigationGoneAtNavigation_rejectsWithPageErrorAfterClosingSession",
        scenario: { failing: new Map([[`navigate ${NAV_KEY}`, pageError]]) },
        expected: {
            settled: "pageError",
            requests: [FLAG_REQUEST],
            messages: [...OPENING, ...CLOSING],
            errors: [],
            closed: CLOSED,
        },
    },
    {
        name: "featureLostAtSubmit_unconfirmedRejectsAfterClosingSession",
        scenario: {
            present: [HOME_NAV_KEY],
            failing: new Map([[`click ${SUBMIT_KEY}`, pageError]]),
        },
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
            present: [HOME_NAV_KEY, NAV_KEY],
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
            present: [HOME_NAV_KEY, NAV_KEY],
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
    // The session end still runs after the failed logout, and its own failure
    // is logged by its class while the logout's error fails the visit.
    {
        name: "logoutAndSessionEndThrowAfterCleanLifecycle_rejectsWithLogoutError",
        scenario: {
            failing: new Map<string, Error>([
                [`click ${DROPDOWN_KEY}`, logoutError],
                ["endDtSession", sessionEndError],
            ]),
        },
        expected: {
            settled: "logoutError",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                CREATED,
                `info: Deleted alert [${OWN_ID}] via ui`,
                ...CLOSING,
                SESSION_END_FAILED,
            ],
            errors: ["sessionEndError"],
            closed: [`click ${DROPDOWN_KEY}`, "endDtSession"],
        },
    },
    {
        name: "logoutAndSessionEndThrowAfterLifecycleError_keepsLifecycleError",
        scenario: {
            present: [HOME_NAV_KEY, NAV_KEY],
            failing: new Map<string, Error>([
                [`click ${SUBMIT_KEY}`, pageError],
                [`click ${DROPDOWN_KEY}`, logoutError],
                ["endDtSession", sessionEndError],
            ]),
        },
        expected: {
            settled: "pageError",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                UNCONFIRMED,
                ...CLOSING,
                SESSION_END_FAILED,
                "warn: Closing the session after a failed visit failed",
            ],
            errors: ["pageError", "sessionEndError", "logoutError"],
            closed: [`click ${DROPDOWN_KEY}`, "endDtSession"],
        },
    },
    {
        name: "sessionEndThrowsAfterCleanLifecycle_rejectsWithSessionEndError",
        scenario: {
            failing: new Map([["endDtSession", sessionEndError]]),
        },
        expected: {
            settled: "sessionEndError",
            requests: [FLAG_REQUEST],
            messages: [
                ...OPENING,
                CREATED,
                `info: Deleted alert [${OWN_ID}] via ui`,
                ...CLOSING,
            ],
            errors: [],
            closed: CLOSED,
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

/**
 * The submit button as a Puppeteer element that never intersects the
 * viewport. Like Puppeteer's element handle it refuses every call once
 * disposed.
 */
class OffscreenElement {
    /** resolves once the element is focused, as an action on it starts */
    readonly focused: Promise<void>
    private disposed = false
    private markFocused: () => void = () => undefined

    constructor() {
        this.focused = new Promise((resolve) => {
            this.markFocused = resolve
        })
    }

    async focus(): Promise<void> {
        this.use()
        this.markFocused()
    }

    async isIntersectingViewport(): Promise<boolean> {
        this.use()
        return false
    }

    async dispose(): Promise<void> {
        this.disposed = true
    }

    private use(): void {
        if (this.disposed) {
            throw new Error("Attempted to use disposed CdpElementHandle.")
        }
    }
}

/** The handle of the offscreen submit button. */
class OffscreenHandle implements IHandleWrapper {
    readonly element = new OffscreenElement()

    getHandle(): ElementHandle {
        return this.element as unknown as ElementHandle
    }

    toString(): string {
        return SUBMIT_KEY
    }
}

/**
 * ScenarioPageActions whose submit button never scrolls into view, so the
 * bounded click on it waits for it until its deadline.
 */
class OffscreenSubmitPageActions extends ScenarioPageActions {
    readonly submit = new OffscreenHandle()

    override async getHandle(selector: ISelector): Promise<IHandleWrapper> {
        const handle = await super.getHandle(selector)
        return key(selector) === SUBMIT_KEY ? this.submit : handle
    }
}

test("run_submitNeverInViewport_failsAtDeadlineAfterClosingSession", async () => {
    // The navigation is shown with the Portfolio Insights link, so the stall
    // is no loss of the feature.
    const page = new OffscreenSubmitPageActions({
        present: [HOME_NAV_KEY, NAV_KEY],
    })
    const { fetchFn } = enabledFetch()
    const { logger, messages, errors } = recordingLogger()
    const visit = new PortfolioInsightsAlertVisit(
        "portfolio_insights_alert",
        BASE_URL,
        USER,
        { fetchFn, random: () => 0.5 }
    )
    const describeSettled = (error: unknown): string =>
        error instanceof Error
            ? `${error.name}: ${error.message}`
            : `not an error object: ${String(error)}`
    let settled = "pending"
    const run = visit.run(page, logger).then(
        () => {
            settled = "resolved"
        },
        (error: unknown) => {
            settled = describeSettled(error)
        }
    )

    await Promise.race([page.submit.element.focused, run])
    mock.timers.tick(PAGE_ACTION_TIMEOUT_MS - 1)
    await new Promise((resolve) => setImmediate(resolve))
    const beforeDeadline = settled
    mock.timers.tick(1)
    await run

    const timeout = `TimeoutError: Page action [click] on [${SUBMIT_KEY}] did not finish within [${PAGE_ACTION_TIMEOUT_MS}] ms`
    assert.deepEqual(
        {
            beforeDeadline,
            settled,
            messages,
            errors: errors.map(describeSettled),
            submitted: page.calls.includes(`click ${SUBMIT_KEY}`),
            closed: page.calls.filter(
                (call) =>
                    call === `click ${DROPDOWN_KEY}` ||
                    call === `navigate ${LOGOUT_KEY}` ||
                    call === "endDtSession"
            ),
        },
        {
            beforeDeadline: "pending",
            settled: timeout,
            messages: [...OPENING, UNCONFIRMED, ...CLOSING],
            errors: [timeout],
            submitted: false,
            closed: CLOSED,
        }
    )
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
