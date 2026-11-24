import assert from "node:assert/strict"
import { afterEach, beforeEach, mock, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import {
    ISelector,
    XpathSelector,
} from "@demoability/loadgen-core/lib/selectors"
import { Logger, createLogger, format, transports } from "winston"
import { selectors } from "../selectors"
import { User } from "../user"
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

function label(selector: ISelector): string {
    return selector instanceof XpathSelector
        ? selector.label
        : selector.toString()
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
 * Records every page action in order. The instrument options, the own
 * created output, the own row and its deleted-id output are present at once.
 */
class RecordingPageActions implements IPageActions {
    readonly calls: string[] = []
    private readonly present = new Set([
        selectors.portfolioInsightsPage_createdAlert(MARKER).toString(),
        selectors.portfolioInsightsPage_alertRow(OWN_ID).toString(),
        selectors.portfolioInsightsPage_deletedAlert(OWN_ID).toString(),
    ])

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        this.calls.push(`isSelectorPresent ${label(selector)}`)
        return this.present.has(selector.toString())
    }

    async getAllHandles(selector: ISelector): Promise<IHandleWrapper[]> {
        this.calls.push(`getAllHandles ${label(selector)}`)
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
        this.calls.push(`getProperty ${label(selector)} ${propertyName}`)
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
        this.calls.push(`input ${label(selector)}=${value}`)
    }

    async selectOption(selector: ISelector, option: string): Promise<void> {
        this.calls.push(`selectOption ${label(selector)}=${option}`)
    }

    async click(selector: ISelector): Promise<void> {
        this.calls.push(`click ${label(selector)}`)
    }

    async navigate(selector: ISelector): Promise<void> {
        this.calls.push(`navigate ${label(selector)}`)
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

    async getHandle(): Promise<IHandleWrapper> {
        return unexpected("getHandle")
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

/** A winston logger whose format records every entry as it is written. */
function recordingLogger(): { logger: Logger; messages: string[] } {
    const messages: string[] = []
    const record = format((info) => {
        messages.push(`${info.level}: ${String(info.message)}`)
        return info
    })
    const logger = createLogger({
        level: "debug",
        format: record(),
        transports: [new transports.Console({ silent: true })],
    })
    return { logger, messages }
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
    assert.deepEqual(
        { steps, requests, messages },
        {
            steps: [
                "gotoPage http://easytrade.test/",
                "input username-input=test_visitor",
                "input password-input=test-visitor-password",
                "navigate login-button",
                "navigate portfolio-insights-page-nav",
                "selectOption alert-type-select=TARGET_PRICE",
                `selectOption alert-instrument-select=${INSTRUMENT_ID}`,
                "selectOption alert-direction-select=ABOVE",
                `input alert-threshold-input=${MARKER}`,
                "click alert-submit-button",
                "click alert-row-delete-button",
                "click dropdown-toggler",
                "navigate logout-button",
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
