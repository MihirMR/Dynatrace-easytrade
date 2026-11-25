import assert from "node:assert/strict"
import { TestContext, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import { Logger, createLogger, format, transports } from "winston"
import { selectors } from "../selectors"
import {
    OwnedAlertOutcome,
    createAndDeleteOwnedAlert,
    gotoPortfolioInsightsPage,
    isPortfolioInsightsEnabled,
} from "./portfolioInsights"

const BASE_URL = new URL("http://easytrade.test/")
const OWN_ID = "6f1c2b8e-3d4a-4b5c-9d6e-7f8091a2b3c4"
const STALE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
const MARKER = "1000000.55555555"
const STALE_MARKER = "1000000.12345671"
const INSTRUMENT_ID = "3d0c7c9a-0f6e-4b8e-a7a1-2b6f1c9d8e70"
const DELETE_OWN = `DELETE http://easytrade.test/broker-service/v1/alerts/${OWN_ID}`
const UNREADABLE =
    "warn: Flag [portfolio-insights-enabled] unreadable, treating as disabled"
const INVALID =
    "warn: Flag [portfolio-insights-enabled] response invalid, treating as disabled"

const OPTION_KEY =
    selectors.portfolioInsightsPage_alertInstrumentOption.toString()
const SUBMIT_KEY = selectors.portfolioInsightsPage_alertSubmit.toString()
const createdKey = (marker: string): string =>
    selectors.portfolioInsightsPage_createdAlert(marker).toString()
const deletedKey = (id: string): string =>
    selectors.portfolioInsightsPage_deletedAlert(id).toString()
const rowKey = (id: string): string =>
    selectors.portfolioInsightsPage_alertRow(id).toString()
const rowDeleteKey = (id: string): string =>
    selectors.portfolioInsightsPage_alertRowDelete(id).toString()

const SUBMITTED_FORM = [
    `${selectors.portfolioInsightsPage_alertType}=TARGET_PRICE`,
    `${selectors.portfolioInsightsPage_alertInstrument}=${INSTRUMENT_ID}`,
    `${selectors.portfolioInsightsPage_alertDirection}=ABOVE`,
    `${selectors.portfolioInsightsPage_alertThreshold}=${MARKER}`,
]
const CREATED_OWN = `info: Created alert [${OWN_ID}] threshold [${MARKER}]`

const pageError = new Error("Execution context was destroyed")
const readError = new Error("Node is detached from document")

type LogRecord = {
    level: string
    message: string
    body: unknown
    error: unknown
}

/** A winston logger whose format records every entry as it is written. */
function recordingLogger(): { logger: Logger; records: LogRecord[] } {
    const records: LogRecord[] = []
    const record = format((info) => {
        records.push({
            level: info.level,
            message: String(info.message),
            body: info.body,
            error: info.error,
        })
        return info
    })
    const logger = createLogger({
        level: "debug",
        format: record(),
        transports: [new transports.Console({ silent: true })],
    })
    return { logger, records }
}

type FetchCall = { url: string; method: string; signal?: AbortSignal }

function recordingFetch(respond: (call: FetchCall) => Promise<Response>): {
    fetchFn: typeof fetch
    calls: FetchCall[]
} {
    const calls: FetchCall[] = []
    const fetchFn: typeof fetch = async (input, init) => {
        const call: FetchCall = {
            url: input instanceof Request ? input.url : String(input),
            method: init?.method ?? "GET",
            signal: init?.signal ?? undefined,
        }
        calls.push(call)
        return await respond(call)
    }
    return { fetchFn, calls }
}

function untilAborted(call: FetchCall): Promise<Response> {
    return new Promise((_resolve, reject) => {
        call.signal?.addEventListener("abort", () =>
            reject(call.signal?.reason)
        )
    })
}

function jsonResponse(body: unknown, status = 200): Promise<Response> {
    return Promise.resolve(new Response(JSON.stringify(body), { status }))
}

function statusResponse(status: number): Promise<Response> {
    return Promise.resolve(new Response(null, { status }))
}

function unexpected(action: string): never {
    throw new Error(`Unexpected page action [${action}]`)
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

type FakePage = {
    /** selector key -> failed checks before the element is present */
    present?: Record<string, number>
    /** selector key -> property name -> value */
    properties?: Record<string, Record<string, unknown>>
    /** instrument options, returned once emptyPolls polls have found none */
    options?: { emptyPolls: number; values: string[] }
    /** selector key whose click fails */
    failingClick?: string
    /** selector key whose input fails */
    failingInput?: string
    /** selector key -> property reads that fail before it answers */
    failingReads?: Record<string, number>
}

type PageCall = { action: string; target: string; value?: string }

class FakePageActions implements IPageActions {
    readonly calls: PageCall[] = []
    private readonly page: FakePage
    private readonly failedChecks = new Map<string, number>()

    constructor(page: FakePage) {
        this.page = page
    }

    count(action: string, target: string): number {
        return this.calls.filter(
            (call) => call.action === action && call.target === target
        ).length
    }

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        const key = this.record("isSelectorPresent", selector)
        const failed = this.failedChecks.get(key) ?? 0
        const appearsAfter = this.page.present?.[key]
        if (appearsAfter !== undefined && failed >= appearsAfter) {
            return true
        }
        this.failedChecks.set(key, failed + 1)
        return false
    }

    async getAllHandles(selector: ISelector): Promise<IHandleWrapper[]> {
        const key = this.record("getAllHandles", selector)
        const options = this.page.options
        if (
            key !== OPTION_KEY ||
            options === undefined ||
            this.count("getAllHandles", key) <= options.emptyPolls
        ) {
            return []
        }
        return options.values.map((value) => new FakeOptionHandle(value))
    }

    async getPropertyHandle<Type = unknown>(
        handle: IHandleWrapper,
        propertyName: string
    ): Promise<Type> {
        this.calls.push({
            action: "getPropertyHandle",
            target: handle.toString(),
            value: propertyName,
        })
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
        const key = this.record("getProperty", selector, propertyName)
        if (
            this.count("getProperty", key) <=
            (this.page.failingReads?.[key] ?? 0)
        ) {
            throw readError
        }
        const properties = this.page.properties?.[key]
        if (properties === undefined || !(propertyName in properties)) {
            return unexpected(`getProperty ${propertyName} of ${key}`)
        }
        const value: unknown = properties[propertyName]
        return value as Type
    }

    async click(selector: ISelector): Promise<void> {
        const key = this.record("click", selector)
        if (key === this.page.failingClick) {
            throw pageError
        }
    }

    async input(selector: ISelector, value: string): Promise<void> {
        const key = this.record("input", selector, value)
        if (key === this.page.failingInput) {
            throw pageError
        }
    }

    async selectOption(selector: ISelector, option: string): Promise<void> {
        this.record("selectOption", selector, option)
    }

    async navigate(selector: ISelector): Promise<void> {
        this.record("navigate", selector)
    }

    async standardDelay(): Promise<void> {
        this.calls.push({ action: "standardDelay", target: "" })
    }

    async shortDelay(): Promise<void> {
        this.calls.push({ action: "shortDelay", target: "" })
    }

    async longDelay(): Promise<void> {
        return unexpected("longDelay")
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

    async endDtSession(): Promise<void> {
        return unexpected("endDtSession")
    }

    async evaluate(): Promise<unknown> {
        return unexpected("evaluate")
    }

    async getInnerText(): Promise<string> {
        return unexpected("getInnerText")
    }

    async gotoPage(): Promise<void> {
        return unexpected("gotoPage")
    }

    private record(
        action: string,
        selector: ISelector,
        value?: string
    ): string {
        const target = selector.toString()
        this.calls.push({ action, target, value })
        return target
    }
}

/** A page whose options, own created output, own row and deleted output appear at once. */
function ownAlertPage(overrides: FakePage = {}): FakePage {
    return {
        options: { emptyPolls: 0, values: [INSTRUMENT_ID] },
        present: {
            [createdKey(MARKER)]: 0,
            [rowKey(OWN_ID)]: 0,
            [deletedKey(OWN_ID)]: 0,
            ...overrides.present,
        },
        properties: {
            [createdKey(MARKER)]: { value: OWN_ID },
            ...overrides.properties,
        },
        failingClick: overrides.failingClick,
        failingInput: overrides.failingInput,
        failingReads: overrides.failingReads,
    }
}

function observed(
    page: FakePageActions,
    fetches: FetchCall[],
    records: LogRecord[]
) {
    return {
        form: page.calls
            .filter(
                (call) =>
                    call.action === "selectOption" || call.action === "input"
            )
            .map((call) => `${call.target}=${call.value}`),
        clicks: page.calls
            .filter((call) => call.action === "click")
            .map((call) => call.target),
        optionPolls: page.count("getAllHandles", OPTION_KEY),
        requests: fetches.map((call) => `${call.method} ${call.url}`),
        messages: records.map((record) => `${record.level}: ${record.message}`),
        errors: records
            .map((record) => record.error)
            .filter((error) => error !== undefined)
            .map((error) =>
                error instanceof Error
                    ? `${error.name}: ${error.message}`
                    : `not an error object: ${String(error)}`
            ),
    }
}

type FlagRow = {
    name: string
    respond: (call: FetchCall) => Promise<Response>
    /** drives the mocked clock while the read is pending */
    whilePending?: (t: TestContext, call: FetchCall) => void
    expected: { enabled: boolean; messages: string[]; meta: string[] }
}

/** What a log entry carries beside its message: the error, the body or none. */
function describeMeta(record: LogRecord): string {
    if (record.error !== undefined) {
        return record.error instanceof Error
            ? `error ${record.error.name}`
            : `not an error object: ${String(record.error)}`
    }
    if (record.body !== undefined) {
        return `body ${JSON.stringify(record.body)}`
    }
    return "none"
}

const networkError = new TypeError("fetch failed")

const flagRows: FlagRow[] = [
    {
        name: "enabled true -> true",
        respond: () =>
            jsonResponse({
                id: "portfolio-insights-enabled",
                enabled: true,
                isModifiable: true,
                tag: "feature",
            }),
        expected: { enabled: true, messages: [], meta: [] },
    },
    {
        name: "enabled false -> false",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: false }),
        expected: {
            enabled: false,
            messages: ["debug: Flag [portfolio-insights-enabled] is disabled"],
            meta: ["none"],
        },
    },
    {
        name: "404 -> false, logged",
        respond: () => statusResponse(404),
        expected: {
            enabled: false,
            messages: [
                "warn: Flag [portfolio-insights-enabled] read returned status [404], treating as disabled",
            ],
            meta: ["none"],
        },
    },
    {
        name: "network error -> false, logged",
        respond: () => Promise.reject(networkError),
        expected: {
            enabled: false,
            messages: [UNREADABLE],
            meta: ["error TypeError"],
        },
    },
    {
        name: "non-boolean enabled -> false, logged",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: "true" }),
        expected: {
            enabled: false,
            messages: [INVALID],
            meta: ['body {"id":"portfolio-insights-enabled","enabled":"true"}'],
        },
    },
    {
        name: "another id -> false, logged",
        respond: () =>
            jsonResponse({ id: "portfolio_insights_enabled", enabled: true }),
        expected: {
            enabled: false,
            messages: [INVALID],
            meta: ['body {"id":"portfolio_insights_enabled","enabled":true}'],
        },
    },
    {
        name: "unparsable body -> false, logged",
        respond: () =>
            Promise.resolve(new Response("<html></html>", { status: 200 })),
        expected: {
            enabled: false,
            messages: [UNREADABLE],
            meta: ["error SyntaxError"],
        },
    },
    {
        name: "hung read aborted at 2 s -> false, logged",
        respond: untilAborted,
        whilePending: (t, call) => {
            t.mock.timers.tick(1999)
            assert.equal(call.signal?.aborted, false)
            t.mock.timers.tick(1)
        },
        expected: {
            enabled: false,
            messages: [UNREADABLE],
            meta: ["error AbortError"],
        },
    },
]

test("isPortfolioInsightsEnabled_response_mapsToBoolean", async (t) => {
    for (const row of flagRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn, calls } = recordingFetch(row.respond)
            const { logger, records } = recordingLogger()

            const pending = isPortfolioInsightsEnabled(
                BASE_URL,
                fetchFn,
                undefined,
                logger
            )
            row.whilePending?.(st, calls[0])
            const enabled = await pending

            assert.deepEqual(
                {
                    enabled,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    meta: records.map(describeMeta),
                },
                row.expected
            )
        })
    }
})

test("isPortfolioInsightsEnabled_request_usesHyphenatedPath", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const { fetchFn, calls } = recordingFetch(() =>
        jsonResponse({ id: "portfolio-insights-enabled", enabled: true })
    )
    const { logger } = recordingLogger()

    await isPortfolioInsightsEnabled(
        new URL("http://easytrade.test:8080/home"),
        fetchFn,
        undefined,
        logger
    )

    assert.deepEqual(
        calls.map((call) => `${call.method} ${call.url}`),
        [
            "GET http://easytrade.test:8080/feature-flag-service/v1/flags/portfolio-insights-enabled",
        ]
    )
})

test("gotoPortfolioInsightsPage_called_navigatesThroughNavBar", async () => {
    const page = new FakePageActions({})

    await gotoPortfolioInsightsPage(page)

    assert.deepEqual(page.calls, [
        {
            action: "navigate",
            target: selectors.navigation_portfolioInsightsPage.toString(),
            value: undefined,
        },
        { action: "standardDelay", target: "" },
    ])
})

type AlertRow = {
    name: string
    page: FakePage
    respond?: (call: FetchCall) => Promise<Response>
    /** drives the mocked clock once the API DELETE is pending */
    whileDeletePending?: (t: TestContext, call: FetchCall) => void
    /** the error the lifecycle must propagate */
    rejects?: Error
    expected: {
        outcome?: OwnedAlertOutcome
        form: string[]
        clicks: string[]
        optionPolls: number
        requests: string[]
        messages: string[]
        errors: string[]
    }
}

const alertRows: AlertRow[] = [
    {
        name: "success clicks only the own row and confirms by the deleted-id output",
        page: ownAlertPage({ present: { [rowKey(STALE_ID)]: 0 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`],
            errors: [],
        },
    },
    {
        name: "a late row is waited for, then deleted",
        page: ownAlertPage({ present: { [rowKey(OWN_ID)]: 3 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`],
            errors: [],
        },
    },
    {
        name: "late instrument options are waited for",
        page: {
            ...ownAlertPage(),
            options: { emptyPolls: 4, values: [INSTRUMENT_ID, "other"] },
        },
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 5,
            requests: [],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`],
            errors: [],
        },
    },
    {
        name: "a stale created output with another marker is ignored",
        page: ownAlertPage({
            present: {
                [createdKey(STALE_MARKER)]: 0,
                [createdKey(MARKER)]: 2,
                [rowKey(STALE_ID)]: 0,
                [deletedKey(STALE_ID)]: 0,
            },
            properties: { [createdKey(STALE_MARKER)]: { value: STALE_ID } },
        }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`],
            errors: [],
        },
    },
    {
        name: "a create never confirmed logs outcome unknown and deletes nothing",
        page: ownAlertPage({
            present: { [createdKey(MARKER)]: Number.POSITIVE_INFINITY },
        }),
        expected: {
            outcome: { kind: "unconfirmed", marker: MARKER },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY],
            optionPolls: 1,
            requests: [],
            messages: [
                `warn: Create unconfirmed threshold [${MARKER}], outcome unknown`,
            ],
            errors: [],
        },
    },
    {
        name: "a created output without an id logs outcome unknown and deletes nothing",
        page: ownAlertPage({
            properties: {
                [createdKey(MARKER)]: {
                    value: "",
                    outerHTML: `<output id="alert-created-id" data-threshold="${MARKER}"></output>`,
                },
            },
        }),
        expected: {
            outcome: { kind: "unconfirmed", marker: MARKER },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY],
            optionPolls: 1,
            requests: [],
            messages: [
                `warn: Create unconfirmed threshold [${MARKER}], outcome unknown`,
            ],
            errors: [],
        },
    },
    {
        name: "an id held only in the value attribute is read from outerHTML",
        page: ownAlertPage({
            properties: {
                [createdKey(MARKER)]: {
                    value: "Alert created",
                    outerHTML: `<output id="alert-created-id" data-threshold="${MARKER}" value="${OWN_ID}">Alert created</output>`,
                },
            },
        }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`],
            errors: [],
        },
    },
    {
        name: "a created-id read that fails is retried, then confirmed",
        page: ownAlertPage({ failingReads: { [createdKey(MARKER)]: 1 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [],
            messages: [
                `debug: Created alert output for threshold [${MARKER}] unreadable, retrying`,
                CREATED_OWN,
                `info: Deleted alert [${OWN_ID}] via ui`,
            ],
            errors: ["Error: Node is detached from document"],
        },
    },
    {
        name: "a UI delete not confirmed before unmount is followed by an API DELETE (204)",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(204),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "api" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "a row never listed is deleted through the API without a click",
        page: ownAlertPage({
            present: { [rowKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(204),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "api" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "API 404 -> already absent",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(404),
        expected: {
            outcome: { kind: "absent", id: OWN_ID },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Alert [${OWN_ID}] already absent`],
            errors: [],
        },
    },
    ...[403, 500].map((status): AlertRow => ({
        name: `API ${status} -> left in place, logged`,
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(status),
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: `${status}` },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: ${status}`,
            ],
            errors: [],
        },
    })),
    {
        name: "an API DELETE that fails -> left in place, logged with the error",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => Promise.reject(networkError),
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: "error" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: error`,
            ],
            errors: ["TypeError: fetch failed"],
        },
    },
    {
        name: "an API DELETE that hangs is aborted at 5 s and logged",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: untilAborted,
        whileDeletePending: (t, call) => {
            t.mock.timers.tick(4999)
            assert.equal(call.signal?.aborted, false)
            t.mock.timers.tick(1)
        },
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: "timeout" },
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: timeout`,
            ],
            errors: ["AbortError: This operation was aborted"],
        },
    },
    {
        name: "a page error after the create deletes through the API and propagates",
        page: ownAlertPage({ failingClick: rowDeleteKey(OWN_ID) }),
        respond: () => statusResponse(204),
        rejects: pageError,
        expected: {
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY, rowDeleteKey(OWN_ID)],
            optionPolls: 1,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "a page error during the submit logs outcome unknown and propagates",
        page: ownAlertPage({ failingClick: SUBMIT_KEY }),
        rejects: pageError,
        expected: {
            form: SUBMITTED_FORM,
            clicks: [SUBMIT_KEY],
            optionPolls: 1,
            requests: [],
            messages: [
                `warn: Create unconfirmed threshold [${MARKER}], outcome unknown`,
            ],
            errors: ["Error: Execution context was destroyed"],
        },
    },
    {
        name: "a page error before the submit propagates without an unknown-outcome line",
        page: ownAlertPage({
            failingInput:
                selectors.portfolioInsightsPage_alertThreshold.toString(),
        }),
        rejects: pageError,
        expected: {
            form: SUBMITTED_FORM,
            clicks: [],
            optionPolls: 1,
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "options that never load stop after 20 polls",
        page: {
            options: {
                emptyPolls: Number.POSITIVE_INFINITY,
                values: [INSTRUMENT_ID],
            },
        },
        expected: {
            outcome: { kind: "not_submitted" },
            form: [],
            clicks: [],
            optionPolls: 20,
            requests: [],
            messages: [
                "warn: Alert instrument options did not load, no alert created",
            ],
            errors: [],
        },
    },
]

test("createAndDeleteOwnedAlert_scenario_outcome", async (t) => {
    for (const row of alertRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            let deletePending: (call: FetchCall) => void = () => undefined
            const deleteCalled = new Promise<FetchCall>((resolve) => {
                deletePending = resolve
            })
            const { fetchFn, calls } = recordingFetch((call) => {
                deletePending(call)
                return row.respond === undefined
                    ? Promise.reject(new Error("Unexpected request"))
                    : row.respond(call)
            })
            const { logger, records } = recordingLogger()
            const page = new FakePageActions(row.page)

            const pending = createAndDeleteOwnedAlert(page, BASE_URL, logger, {
                fetchFn,
                random: () => 0.5,
            })
            if (row.whileDeletePending !== undefined) {
                const settled = pending.then(
                    () => undefined,
                    () => undefined
                )
                const call = await Promise.race([deleteCalled, settled])
                if (call !== undefined) {
                    row.whileDeletePending(st, call)
                }
            }
            let outcome: OwnedAlertOutcome | undefined
            if (row.rejects === undefined) {
                outcome = await pending
            } else {
                await assert.rejects(pending, row.rejects)
            }

            assert.deepEqual(
                { outcome, ...observed(page, calls, records) },
                { outcome: undefined, ...row.expected }
            )
        })
    }
})

test("createAndDeleteOwnedAlert_randomBounds_submitsNormalisedMarker", async (t) => {
    const rows = [
        { random: 0, marker: "1000000.00000001" },
        { random: 0.999999, marker: "1000000.99999999" },
        { random: 1, marker: "1000000.99999999" },
    ]
    for (const row of rows) {
        await t.test(`random ${row.random} -> ${row.marker}`, async () => {
            const page = new FakePageActions({
                options: { emptyPolls: 0, values: [INSTRUMENT_ID] },
            })
            const { logger } = recordingLogger()

            await createAndDeleteOwnedAlert(page, BASE_URL, logger, {
                random: () => row.random,
            })

            assert.deepEqual(
                page.calls
                    .filter((call) => call.action === "input")
                    .map((call) => call.value),
                [row.marker]
            )
        })
    }
})
