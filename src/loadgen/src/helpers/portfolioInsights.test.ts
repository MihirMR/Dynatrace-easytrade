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
const THRESHOLD_KEY = selectors.portfolioInsightsPage_alertThreshold.toString()
const createdKey = (marker: string): string =>
    selectors.portfolioInsightsPage_createdAlert(marker).toString()
const deletedKey = (id: string): string =>
    selectors.portfolioInsightsPage_deletedAlert(id).toString()
const rowKey = (id: string): string =>
    selectors.portfolioInsightsPage_alertRow(id).toString()
const rowDeleteKey = (id: string): string =>
    selectors.portfolioInsightsPage_alertRowDelete(id).toString()

/** Entries of the ordered page trace that steps() builds. */
const clickStep = (key: string): string => `click ${key}`
const checkStep = (key: string, times: number): string =>
    `check ${key} x${times}`
const findOptionsStep = (times: number): string =>
    `find ${OPTION_KEY} x${times}`

/** The form as the helper fills it for a marker, up to the submit click. */
function submitSteps(marker: string): string[] {
    return [
        `select ${selectors.portfolioInsightsPage_alertType} = TARGET_PRICE`,
        `select ${selectors.portfolioInsightsPage_alertInstrument} = ${INSTRUMENT_ID}`,
        `select ${selectors.portfolioInsightsPage_alertDirection} = ABOVE`,
        `input ${THRESHOLD_KEY} = ${marker}`,
        clickStep(SUBMIT_KEY),
    ]
}

const SUBMIT_STEPS = [findOptionsStep(1), ...submitSteps(MARKER)]
const CREATED_OWN = `info: Created alert [${OWN_ID}] threshold [${MARKER}]`

const pageError = new Error("Execution context was destroyed")
const readError = new Error("Node is detached from document")
const networkError = new TypeError("fetch failed")

/**
 * Names the error objects this suite throws, so a log entry is checked to carry
 * the very object rather than a copy of its message.
 */
const knownErrors = new Map<unknown, string>([
    [pageError, "pageError"],
    [readError, "readError"],
    [networkError, "networkError"],
])

function describeError(error: unknown): string {
    return (
        knownErrors.get(error) ??
        (error instanceof Error
            ? error.name
            : `not an error object: ${String(error)}`)
    )
}

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
    /** resolves with the first request as soon as it is sent */
    firstCall: Promise<FetchCall>
} {
    const calls: FetchCall[] = []
    let sent: (call: FetchCall) => void = () => undefined
    const firstCall = new Promise<FetchCall>((resolve) => {
        sent = resolve
    })
    const fetchFn: typeof fetch = async (input, init) => {
        const call: FetchCall = {
            url: input instanceof Request ? input.url : String(input),
            method: init?.method ?? "GET",
            signal: init?.signal ?? undefined,
        }
        calls.push(call)
        sent(call)
        return await respond(call)
    }
    return { fetchFn, calls, firstCall }
}

/**
 * Resolves with the first request once it is sent, or with undefined when the
 * call under test settles without sending one, so a test drives the mocked
 * clock only while a request is really pending.
 */
async function requestSent(
    firstCall: Promise<FetchCall>,
    pending: Promise<unknown>
): Promise<FetchCall | undefined> {
    const settled = pending.then(
        () => undefined,
        () => undefined
    )
    return await Promise.race([firstCall, settled])
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

/**
 * A page whose options, the created output of the marker, the own row and the
 * deleted output appear at once.
 */
function ownAlertPage(overrides: FakePage = {}, marker = MARKER): FakePage {
    return {
        options: { emptyPolls: 0, values: [INSTRUMENT_ID] },
        present: {
            [createdKey(marker)]: 0,
            [rowKey(OWN_ID)]: 0,
            [deletedKey(OWN_ID)]: 0,
            ...overrides.present,
        },
        properties: {
            [createdKey(marker)]: { value: OWN_ID },
            ...overrides.properties,
        },
        failingClick: overrides.failingClick,
        failingInput: overrides.failingInput,
        failingReads: overrides.failingReads,
    }
}

const STEP_VERBS = new Map<string, string>([
    ["getAllHandles", "find"],
    ["isSelectorPresent", "check"],
    ["selectOption", "select"],
    ["input", "input"],
    ["click", "click"],
])
const POLL_VERBS = new Set(["find", "check"])

/**
 * The page interactions in call order, without delays and property reads.
 * Consecutive polls of one selector collapse into one entry with their count,
 * so the trace shows both the order of the steps and every poll budget.
 */
function steps(calls: PageCall[]): string[] {
    const entries: { text: string; poll: boolean; times: number }[] = []
    for (const call of calls) {
        const verb = STEP_VERBS.get(call.action)
        if (verb === undefined) {
            continue
        }
        const text =
            call.value === undefined
                ? `${verb} ${call.target}`
                : `${verb} ${call.target} = ${call.value}`
        const poll = POLL_VERBS.has(verb)
        const last = entries.at(-1)
        if (poll && last !== undefined && last.text === text) {
            last.times++
        } else {
            entries.push({ text, poll, times: 1 })
        }
    }
    return entries.map((entry) =>
        entry.poll ? `${entry.text} x${entry.times}` : entry.text
    )
}

function observed(
    page: FakePageActions,
    fetches: FetchCall[],
    records: LogRecord[]
) {
    return {
        steps: steps(page.calls),
        requests: fetches.map((call) => `${call.method} ${call.url}`),
        messages: records.map((record) => `${record.level}: ${record.message}`),
        errors: records
            .map((record) => record.error)
            .filter((error) => error !== undefined)
            .map(describeError),
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
        return `error ${describeError(record.error)}`
    }
    if (record.body !== undefined) {
        return `body ${JSON.stringify(record.body)}`
    }
    return "none"
}

const flagRows: FlagRow[] = [
    {
        name: "enabledTrue_true",
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
        name: "enabledFalse_false",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: false }),
        expected: {
            enabled: false,
            messages: ["debug: Flag [portfolio-insights-enabled] is disabled"],
            meta: ["none"],
        },
    },
    {
        name: "status404_false",
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
        name: "networkError_false",
        respond: () => Promise.reject(networkError),
        expected: {
            enabled: false,
            messages: [UNREADABLE],
            meta: ["error networkError"],
        },
    },
    {
        name: "nonBooleanEnabled_false",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: "true" }),
        expected: {
            enabled: false,
            messages: [INVALID],
            meta: ['body {"id":"portfolio-insights-enabled","enabled":"true"}'],
        },
    },
    {
        name: "otherId_false",
        respond: () =>
            jsonResponse({ id: "portfolio_insights_enabled", enabled: true }),
        expected: {
            enabled: false,
            messages: [INVALID],
            meta: ['body {"id":"portfolio_insights_enabled","enabled":true}'],
        },
    },
    {
        name: "invalidJson_false",
        respond: () =>
            Promise.resolve(new Response("<html></html>", { status: 200 })),
        expected: {
            enabled: false,
            messages: [UNREADABLE],
            meta: ["error SyntaxError"],
        },
    },
    {
        name: "hungRead_abortedAt2s_false",
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
            const { fetchFn, firstCall } = recordingFetch(row.respond)
            const { logger, records } = recordingLogger()

            const pending = isPortfolioInsightsEnabled(
                BASE_URL,
                fetchFn,
                undefined,
                logger
            )
            if (row.whilePending !== undefined) {
                const call = await requestSent(firstCall, pending)
                if (call !== undefined) {
                    row.whilePending(st, call)
                }
            }
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

    // The base url's own path is replaced, its origin kept, and the read is
    // abortable so the deadline can end it.
    assert.deepEqual(
        calls.map((call) => ({
            request: `${call.method} ${call.url}`,
            abortable: call.signal instanceof AbortSignal,
        })),
        [
            {
                request:
                    "GET http://easytrade.test:8080/feature-flag-service/v1/flags/portfolio-insights-enabled",
                abortable: true,
            },
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
        /** the ordered page trace of steps() */
        steps: string[]
        requests: string[]
        messages: string[]
        errors: string[]
    }
}

/** The own alert's row is found and deleted, and the deletion confirmed. */
const UI_DELETE_STEPS = [
    checkStep(rowKey(OWN_ID), 1),
    clickStep(rowDeleteKey(OWN_ID)),
    checkStep(deletedKey(OWN_ID), 1),
]
const CONFIRMED_STEPS = [...SUBMIT_STEPS, checkStep(createdKey(MARKER), 1)]
/** Created and deleted through its row; the deleted-id output never shows. */
const UI_DELETE_UNCONFIRMED_STEPS = [
    ...CONFIRMED_STEPS,
    checkStep(rowKey(OWN_ID), 1),
    clickStep(rowDeleteKey(OWN_ID)),
    checkStep(deletedKey(OWN_ID), 20),
]
const DELETED_VIA_UI = [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via ui`]
const UNCONFIRMED = `warn: Create unconfirmed threshold [${MARKER}], outcome unknown`

const alertRows: AlertRow[] = [
    {
        name: "success_deletedViaUi",
        page: ownAlertPage({ present: { [rowKey(STALE_ID)]: 0 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            steps: [...CONFIRMED_STEPS, ...UI_DELETE_STEPS],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "lateRow_waitedThenDeleted",
        page: ownAlertPage({ present: { [rowKey(OWN_ID)]: 3 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            steps: [
                ...CONFIRMED_STEPS,
                checkStep(rowKey(OWN_ID), 4),
                clickStep(rowDeleteKey(OWN_ID)),
                checkStep(deletedKey(OWN_ID), 1),
            ],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "lateOptions_waitedThenSubmitted",
        page: {
            ...ownAlertPage(),
            options: { emptyPolls: 4, values: [INSTRUMENT_ID, "other"] },
        },
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            steps: [
                findOptionsStep(5),
                ...submitSteps(MARKER),
                checkStep(createdKey(MARKER), 1),
                ...UI_DELETE_STEPS,
            ],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "staleCreatedOutputThenOwn_ownDeletedViaUi",
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
            steps: [
                ...SUBMIT_STEPS,
                checkStep(createdKey(MARKER), 3),
                ...UI_DELETE_STEPS,
            ],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "staleCreatedOutput_unconfirmed",
        page: ownAlertPage({
            present: {
                [createdKey(STALE_MARKER)]: 0,
                [createdKey(MARKER)]: Number.POSITIVE_INFINITY,
                [rowKey(STALE_ID)]: 0,
                [deletedKey(STALE_ID)]: 0,
            },
            properties: { [createdKey(STALE_MARKER)]: { value: STALE_ID } },
        }),
        expected: {
            outcome: { kind: "unconfirmed", marker: MARKER },
            steps: [...SUBMIT_STEPS, checkStep(createdKey(MARKER), 20)],
            requests: [],
            messages: [UNCONFIRMED],
            errors: [],
        },
    },
    {
        name: "createNeverConfirmed_logsOutcomeUnknownNoDelete",
        page: ownAlertPage({
            present: { [createdKey(MARKER)]: Number.POSITIVE_INFINITY },
        }),
        expected: {
            outcome: { kind: "unconfirmed", marker: MARKER },
            steps: [...SUBMIT_STEPS, checkStep(createdKey(MARKER), 20)],
            requests: [],
            messages: [UNCONFIRMED],
            errors: [],
        },
    },
    {
        name: "createdOutputWithoutId_unconfirmed",
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
            steps: [...SUBMIT_STEPS, checkStep(createdKey(MARKER), 20)],
            requests: [],
            messages: [UNCONFIRMED],
            errors: [],
        },
    },
    {
        name: "valuePropertyNotUuid_readsOuterHtml",
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
            steps: [...CONFIRMED_STEPS, ...UI_DELETE_STEPS],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "createdReadThrows_retriedThenConfirmed",
        page: ownAlertPage({ failingReads: { [createdKey(MARKER)]: 1 } }),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            steps: [
                ...SUBMIT_STEPS,
                checkStep(createdKey(MARKER), 2),
                ...UI_DELETE_STEPS,
            ],
            requests: [],
            messages: [
                `debug: Created alert output for threshold [${MARKER}] unreadable, retrying`,
                ...DELETED_VIA_UI,
            ],
            errors: ["readError"],
        },
    },
    {
        name: "uiDeleteUnconfirmed_apiDelete204_deletedViaApi",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(204),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "api" },
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "rowNeverAppears_apiDelete",
        page: ownAlertPage({
            present: { [rowKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(204),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "api" },
            steps: [...CONFIRMED_STEPS, checkStep(rowKey(OWN_ID), 20)],
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "api404_absent",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(404),
        expected: {
            outcome: { kind: "absent", id: OWN_ID },
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Alert [${OWN_ID}] already absent`],
            errors: [],
        },
    },
    ...[403, 500].map((status): AlertRow => ({
        name: `api${status}_leftInPlace`,
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => statusResponse(status),
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: `${status}` },
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: ${status}`,
            ],
            errors: [],
        },
    })),
    {
        name: "apiNetworkError_leftInPlaceError",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => Promise.reject(networkError),
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: "error" },
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: error`,
            ],
            errors: ["networkError"],
        },
    },
    {
        name: "apiHang_abortedAt5s_leftInPlaceTimeout",
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
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: timeout`,
            ],
            errors: ["AbortError"],
        },
    },
    {
        name: "rowDeleteClickThrows_apiDeleteAndRejects",
        page: ownAlertPage({ failingClick: rowDeleteKey(OWN_ID) }),
        respond: () => statusResponse(204),
        rejects: pageError,
        expected: {
            steps: [
                ...CONFIRMED_STEPS,
                checkStep(rowKey(OWN_ID), 1),
                clickStep(rowDeleteKey(OWN_ID)),
            ],
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, `info: Deleted alert [${OWN_ID}] via api`],
            errors: [],
        },
    },
    {
        name: "submitClickThrows_logsOutcomeUnknownAndRejects",
        page: ownAlertPage({ failingClick: SUBMIT_KEY }),
        rejects: pageError,
        expected: {
            steps: SUBMIT_STEPS,
            requests: [],
            messages: [UNCONFIRMED],
            errors: ["pageError"],
        },
    },
    {
        name: "formInputThrows_rejectsWithoutOutcomeLine",
        page: ownAlertPage({ failingInput: THRESHOLD_KEY }),
        rejects: pageError,
        expected: {
            steps: SUBMIT_STEPS.slice(0, -1),
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "optionsNeverLoad_notSubmitted",
        page: {
            options: {
                emptyPolls: Number.POSITIVE_INFINITY,
                values: [INSTRUMENT_ID],
            },
        },
        expected: {
            outcome: { kind: "not_submitted" },
            steps: [findOptionsStep(20)],
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
            const { fetchFn, calls, firstCall } = recordingFetch((call) =>
                row.respond === undefined
                    ? Promise.reject(new Error("Unexpected request"))
                    : row.respond(call)
            )
            const { logger, records } = recordingLogger()
            const page = new FakePageActions(row.page)

            // random 0.5 yields MARKER, 1000000.55555555.
            const pending = createAndDeleteOwnedAlert(page, BASE_URL, logger, {
                fetchFn,
                random: () => 0.5,
            })
            if (row.whileDeletePending !== undefined) {
                const call = await requestSent(firstCall, pending)
                if (call !== undefined) {
                    row.whileDeletePending(st, call)
                }
            }
            let outcome: OwnedAlertOutcome | undefined
            if (row.rejects === undefined) {
                outcome = await pending
            } else {
                const thrown = row.rejects
                await assert.rejects(pending, (error) => error === thrown)
            }

            assert.deepEqual(
                { outcome, ...observed(page, calls, records) },
                { outcome: undefined, ...row.expected }
            )
        })
    }
})

test("createAndDeleteOwnedAlert_randomBounds_submitsNormalisedMarker", async (t) => {
    // Each marker is `1000000.` and 8 digits whose last one is non-zero, the
    // normalised threshold form; random 1 is clamped to the highest digits.
    const rows = [
        { name: "random0_lowestMarker", random: 0, marker: "1000000.00000001" },
        {
            name: "random0999_highestMarker",
            random: 0.999,
            marker: "1000000.99999999",
        },
        {
            name: "random1_clampedToHighestMarker",
            random: 1,
            marker: "1000000.99999999",
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            // Only the created output of the expected marker exists, so the
            // alert is confirmed only when the typed text is that marker.
            const page = new FakePageActions(ownAlertPage({}, row.marker))
            const { fetchFn } = recordingFetch(() =>
                Promise.reject(new Error("Unexpected request"))
            )
            const { logger } = recordingLogger()

            const outcome = await createAndDeleteOwnedAlert(
                page,
                BASE_URL,
                logger,
                { fetchFn, random: () => row.random }
            )

            assert.deepEqual(
                {
                    typed: page.calls
                        .filter((call) => call.action === "input")
                        .map((call) => call.value),
                    outcome,
                },
                {
                    typed: [row.marker],
                    outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
                }
            )
        })
    }
})
