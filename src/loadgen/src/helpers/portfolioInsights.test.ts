import assert from "node:assert/strict"
import { TestContext, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import {
    IPageActions,
    PageActions,
    defineConfig,
} from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import type { ElementHandle, Page } from "puppeteer"
import { Logger, createLogger, format, transports } from "winston"
import { selectors } from "../selectors"
import { User } from "../user"
import {
    DomPresenceSelector,
    OwnedAlertOutcome,
    createAndDeleteOwnedAlert,
    gotoPortfolioInsightsPage,
    isPortfolioInsightsEnabled,
    loginWithoutLoggingPassword,
    openPageAndRunOwnedAlert,
    ownedAlertFailure,
    withVisitLogger,
} from "./portfolioInsights"

const BASE_URL = new URL("http://easytrade.test/")
const OWN_ID = "6f1c2b8e-3d4a-4b5c-9d6e-7f8091a2b3c4"
const STALE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
const MARKER = "1000000.55555555"
const STALE_MARKER = "1000000.12345671"
const INSTRUMENT_ID = "3d0c7c9a-0f6e-4b8e-a7a1-2b6f1c9d8e70"
const DELETE_OWN = `DELETE http://easytrade.test/broker-service/v1/alerts/${OWN_ID}`
const UNREADABLE =
    "warn: Flag [portfolio-insights-enabled] unreadable, treating as disabled: "
const INVALID =
    "warn: Flag [portfolio-insights-enabled] response invalid, treating as disabled: "
const flagStatusLine = (status: number): string =>
    `warn: Flag [portfolio-insights-enabled] read returned status [${status}], treating as disabled`
/** Stands in for a credential inside untrusted upstream content. */
const SECRET = "leak-probe-5f2c"
/** Stands in for a credential shaped like an error name or a system code. */
const SECRET_IDENTIFIER = "LEAK_PROBE_5F2C"

const OPTION_KEY =
    selectors.portfolioInsightsPage_alertInstrumentOption.toString()
const SUBMIT_KEY = selectors.portfolioInsightsPage_alertSubmit.toString()
const THRESHOLD_KEY = selectors.portfolioInsightsPage_alertThreshold.toString()
/** The navigation link, whose absence shows the feature was lost. */
const NAV_KEY = selectors.navigation_portfolioInsightsPage.toString()
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
/** The presence checks of the instrument options, up to and with the first hit. */
const findOptionsStep = (times: number): string => checkStep(OPTION_KEY, times)
/** The read of the option values once a check has found options. */
const READ_OPTIONS_STEP = `read ${OPTION_KEY}`

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

const SUBMIT_STEPS = [
    findOptionsStep(1),
    READ_OPTIONS_STEP,
    ...submitSteps(MARKER),
]
const CREATED_OWN = `info: Created alert [${OWN_ID}] threshold [${MARKER}]`

const pageError = new Error("Execution context was destroyed")
const readError = new Error("Node is detached from document")
const networkError = new TypeError("fetch failed")
/** What a presence check throws once the browser target is gone. */
const checkError = new Error("Target closed")

/**
 * Names the error objects this suite throws, so a log entry is checked to carry
 * the very object rather than a copy of its message.
 */
const knownErrors = new Map<unknown, string>([
    [pageError, "pageError"],
    [readError, "readError"],
    [networkError, "networkError"],
    [checkError, "checkError"],
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
    error: unknown
    /** names of the fields the entry carries beside its level and message */
    metadata: string[]
}

/** A winston logger whose format records every entry as it is written. */
function recordingLogger(): { logger: Logger; records: LogRecord[] } {
    const records: LogRecord[] = []
    const record = format((info) => {
        records.push({
            level: info.level,
            message: String(info.message),
            error: info.error,
            metadata: Object.keys(info).filter(
                (field) => field !== "level" && field !== "message"
            ),
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

function textResponse(text: string): Promise<Response> {
    return Promise.resolve(new Response(text, { status: 200 }))
}

/** A 200 whose body stream fails with error when it is read. */
function failingBodyResponse(error: unknown): Promise<Response> {
    const body = new ReadableStream<Uint8Array>({
        pull(controller) {
            controller.error(error)
        },
    })
    return Promise.resolve(new Response(body, { status: 200 }))
}

/** A 200 whose body never ends until the request's signal aborts it. */
function hungBodyResponse(call: FetchCall): Promise<Response> {
    const body = new ReadableStream<Uint8Array>({
        start(controller) {
            call.signal?.addEventListener("abort", () =>
                controller.error(call.signal?.reason)
            )
        },
    })
    return Promise.resolve(new Response(body, { status: 200 }))
}

/** Whether the call under test had settled at each cancel of a body. */
type CancelProbe = {
    settled: boolean
    cancels: string[]
    /** resolves once a body's cancel is called */
    started: Promise<void>
    markStarted: () => void
    /** rejects the cancel of a "rejectsLate" body; a no-op otherwise */
    failLate: () => void
}

function cancelProbe(): CancelProbe {
    const probe: CancelProbe = {
        settled: false,
        cancels: [],
        started: Promise.resolve(),
        markStarted: () => undefined,
        failLate: () => undefined,
    }
    probe.started = new Promise<void>((resolve) => {
        probe.markStarted = resolve
    })
    return probe
}

/**
 * How a body's cancel ends: resolving at once, rejecting at once, never, or
 * rejecting only once the test calls the probe's failLate.
 */
type CancelEnd = "resolves" | "rejects" | "never" | "rejectsLate"

const cancelError = new Error("cancel failed")

/**
 * A response whose body has sent a first chunk, carrying the secret, and
 * never ends. Its cancel is recorded in probe and ends as end says, failing
 * with failure.
 */
function streamingResponse(
    status: number,
    probe: CancelProbe,
    end: CancelEnd,
    failure: Error = cancelError
): Promise<Response> {
    const body = new ReadableStream<Uint8Array>({
        start(controller) {
            controller.enqueue(
                new TextEncoder().encode(`{"password":"${SECRET}"`)
            )
        },
        cancel(): void | Promise<void> {
            probe.cancels.push(
                probe.settled ? "after settling" : "while pending"
            )
            probe.markStarted()
            switch (end) {
                case "resolves":
                    return
                case "rejects":
                    throw failure
                case "never":
                    return new Promise<void>(() => undefined)
                case "rejectsLate":
                    return new Promise<void>((_resolve, reject) => {
                        probe.failLate = () => reject(failure)
                    })
            }
        },
    })
    return Promise.resolve(new Response(body, { status }))
}

/** Answers call with answer only once its signal has aborted. */
function answerAfterAbort(
    call: FetchCall,
    answer: () => Promise<Response>
): Promise<Response> {
    return new Promise((resolve) => {
        call.signal?.addEventListener("abort", () => resolve(answer()))
    })
}

/** Resolves once every queued microtask, and each one it queues, has run. */
function drained(): Promise<void> {
    return new Promise((resolve) => setImmediate(resolve))
}

/**
 * Stands in for the result of a call the deadline did not end, so the test
 * reports it instead of waiting for it forever.
 */
const STILL_PENDING = "still pending"

/**
 * Ticks the mocked clock to deadlineMs in two steps, and tells whether the
 * call under test had settled 1 ms before the deadline and at it.
 */
async function settledAroundDeadline(
    t: TestContext,
    probe: CancelProbe,
    deadlineMs: number
): Promise<{ before: boolean; at: boolean }> {
    t.mock.timers.tick(deadlineMs - 1)
    await drained()
    const before = probe.settled
    t.mock.timers.tick(1)
    await drained()
    return { before, at: probe.settled }
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
    /** instrument options, present once emptyPolls presence checks found none */
    options?: { emptyPolls: number; values: string[] }
    /** selector key whose presence check throws checkError */
    failingCheck?: string
    /** selector key whose click fails */
    failingClick?: string
    /** selector key whose input fails */
    failingInput?: string
    /** selector key whose navigation fails */
    failingNavigate?: string
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

    /** True once more option presence checks have run than emptyPolls. */
    optionsLoaded(): boolean {
        const options = this.page.options
        return (
            options !== undefined &&
            this.count("isSelectorPresent", OPTION_KEY) > options.emptyPolls
        )
    }

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        const key = this.record("isSelectorPresent", selector)
        if (key === this.page.failingCheck) {
            throw checkError
        }
        if (key === OPTION_KEY) {
            return this.optionsLoaded()
        }
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
            !this.optionsLoaded()
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
        const key = this.record("navigate", selector)
        if (key === this.page.failingNavigate) {
            throw pageError
        }
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
 * A page of the enabled feature, whose navigation link stays present, and
 * whose options, the created output of the marker, the own row and the
 * deleted output appear at once.
 */
function ownAlertPage(overrides: FakePage = {}, marker = MARKER): FakePage {
    return {
        options: { emptyPolls: 0, values: [INSTRUMENT_ID] },
        present: {
            [NAV_KEY]: 0,
            [createdKey(marker)]: 0,
            [rowKey(OWN_ID)]: 0,
            [deletedKey(OWN_ID)]: 0,
            ...overrides.present,
        },
        properties: {
            [createdKey(marker)]: { value: OWN_ID },
            ...overrides.properties,
        },
        failingCheck: overrides.failingCheck,
        failingClick: overrides.failingClick,
        failingInput: overrides.failingInput,
        failingNavigate: overrides.failingNavigate,
        failingReads: overrides.failingReads,
    }
}

const STEP_VERBS = new Map<string, string>([
    ["getAllHandles", "read"],
    ["isSelectorPresent", "check"],
    ["selectOption", "select"],
    ["input", "input"],
    ["click", "click"],
    ["navigate", "navigate"],
])
const POLL_VERBS = new Set(["check"])

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
    expected: { enabled: boolean; messages: string[] }
}

/** Ticks the mocked clock to the 2 s deadline, checking it holds until then. */
function reachFlagDeadline(t: TestContext, call: FetchCall): void {
    t.mock.timers.tick(1999)
    assert.equal(call.signal?.aborted, false)
    t.mock.timers.tick(1)
}

/** Transport errors as Node's fetch raises them, with a system code cause. */
const refusedError = new TypeError("fetch failed", {
    cause: Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:9"), {
        code: "ECONNREFUSED",
    }),
})
const socketError = new TypeError("terminated", {
    cause: Object.assign(new Error("other side closed"), {
        code: "UND_ERR_SOCKET",
    }),
})

/** error, with its property key turned into a getter that throws. */
function withThrowingGetter<E extends Error>(error: E, key: string): E {
    return Object.defineProperty(error, key, {
        get(): never {
            throw new Error(`getter of ${key} failed: ${SECRET}`)
        },
    })
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
        expected: { enabled: true, messages: [] },
    },
    {
        name: "enabledFalse_false",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: false }),
        expected: {
            enabled: false,
            messages: ["debug: Flag [portfolio-insights-enabled] is disabled"],
        },
    },
    {
        name: "status404_false",
        respond: () => statusResponse(404),
        expected: { enabled: false, messages: [flagStatusLine(404)] },
    },
    {
        name: "networkError_false",
        respond: () => Promise.reject(networkError),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [TypeError]`],
        },
    },
    {
        name: "nonBooleanEnabled_false",
        respond: () =>
            jsonResponse({ id: "portfolio-insights-enabled", enabled: "true" }),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [enabled_not_boolean] status [200]`],
        },
    },
    {
        name: "hungRead_abortedAt2s_false",
        respond: untilAborted,
        whilePending: reachFlagDeadline,
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [timeout]`],
        },
    },
    {
        name: "otherId_false",
        respond: () =>
            jsonResponse({ id: "portfolio_insights_enabled", enabled: true }),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [id_mismatch] status [200]`],
        },
    },
    {
        name: "enabledMissing_false",
        respond: () => jsonResponse({ id: "portfolio-insights-enabled" }),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [enabled_not_boolean] status [200]`],
        },
    },
    {
        name: "arrayBody_false",
        respond: () =>
            jsonResponse([{ id: "portfolio-insights-enabled", enabled: true }]),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [not_object] status [200]`],
        },
    },
    {
        name: "nullBody_false",
        respond: () => jsonResponse(null),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [not_object] status [200]`],
        },
    },
    {
        name: "invalidJson_false",
        respond: () => textResponse("<html></html>"),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [invalid_json] status [200]`],
        },
    },
    {
        name: "connectionRefused_falseWithCauseCode",
        respond: () => Promise.reject(refusedError),
        expected: {
            enabled: false,
            messages: [
                `${UNREADABLE}reason [transport] error [TypeError] cause [ECONNREFUSED]`,
            ],
        },
    },
    {
        name: "bodyReadSocketError_falseWithCauseCode",
        respond: () => failingBodyResponse(socketError),
        expected: {
            enabled: false,
            messages: [
                `${UNREADABLE}reason [transport] error [TypeError] cause [UND_ERR_SOCKET]`,
            ],
        },
    },
    {
        name: "hungBodyRead_abortedAt2s_false",
        respond: hungBodyResponse,
        whilePending: reachFlagDeadline,
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [timeout]`],
        },
    },
    {
        name: "causeCodeNotSystemCode_falseWithoutCause",
        respond: () =>
            Promise.reject(
                new TypeError("fetch failed", {
                    cause: { code: `connect ${SECRET}` },
                })
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [TypeError]`],
        },
    },
    {
        name: "errorNameNotIdentifier_falseUnknownName",
        respond: () =>
            Promise.reject(
                Object.assign(new Error("fetch failed"), {
                    name: `Error] [${SECRET}`,
                })
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [unknown]`],
        },
    },
    {
        name: "nonErrorRejection_falseUnknownName",
        respond: () => Promise.reject(`fetch failed: ${SECRET}`),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [unknown]`],
        },
    },
    // A name or a code is logged only from the fixed lists; one shaped like an
    // identifier but off the lists is replaced like any other.
    {
        name: "errorNameUnknownIdentifier_falseUnknownName",
        respond: () =>
            Promise.reject(
                Object.assign(new Error("fetch failed"), {
                    name: SECRET_IDENTIFIER,
                })
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [unknown]`],
        },
    },
    {
        name: "causeCodeUnknownIdentifier_falseWithoutCause",
        respond: () =>
            Promise.reject(
                new TypeError("fetch failed", {
                    cause: { code: SECRET_IDENTIFIER },
                })
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [TypeError]`],
        },
    },
    // Reading the error never throws: an accessor that does is read as absent.
    {
        name: "nameGetterThrows_falseUnknownName",
        respond: () =>
            Promise.reject(
                withThrowingGetter(new TypeError("fetch failed"), "name")
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [unknown]`],
        },
    },
    {
        name: "causeGetterThrows_falseWithoutCause",
        respond: () =>
            Promise.reject(
                withThrowingGetter(new TypeError("fetch failed"), "cause")
            ),
        expected: {
            enabled: false,
            messages: [`${UNREADABLE}reason [transport] error [TypeError]`],
        },
    },
]

test("isPortfolioInsightsEnabled_response_mapsToBoolean", async (t) => {
    for (const row of flagRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn, firstCall } = recordingFetch(row.respond)
            const { logger, records } = recordingLogger()

            const pending = withVisitLogger(logger, () =>
                isPortfolioInsightsEnabled(BASE_URL, fetchFn)
            )
            if (row.whilePending !== undefined) {
                const call = await requestSent(firstCall, pending)
                if (call !== undefined) {
                    row.whilePending(st, call)
                }
            }
            const enabled = await pending

            // Each outcome is told by its message alone: no entry carries a
            // body, an error object or any other field.
            assert.deepEqual(
                {
                    enabled,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    metadata: records.flatMap((record) => record.metadata),
                },
                { ...row.expected, metadata: [] }
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

    await withVisitLogger(logger, () =>
        isPortfolioInsightsEnabled(
            new URL("http://easytrade.test:8080/home"),
            fetchFn
        )
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

test("isPortfolioInsightsEnabled_untrustedContent_neverLogged", async (t) => {
    const rows: {
        name: string
        respond: (call: FetchCall) => Promise<Response>
    }[] = [
        {
            name: "secretFieldInInvalidBody",
            respond: () =>
                jsonResponse({
                    id: "portfolio-insights-enabled",
                    enabled: "yes",
                    password: SECRET,
                }),
        },
        {
            name: "secretAsOtherId",
            respond: () => jsonResponse({ id: SECRET, enabled: true }),
        },
        {
            name: "invalidJsonCarryingSecret",
            respond: () => textResponse(`<html>${SECRET}</html>`),
        },
        {
            name: "statusBodyCarryingSecret",
            respond: () => jsonResponse({ password: SECRET }, 500),
        },
        {
            name: "errorQuotingCredentialUrl",
            respond: () =>
                Promise.reject(
                    new TypeError(
                        `Request cannot be constructed from a URL that includes credentials: http://user:${SECRET}@easytrade.test/`
                    )
                ),
        },
        {
            name: "bodyReadErrorQuotingSecret",
            respond: () =>
                failingBodyResponse(
                    new SyntaxError(`Unexpected token in [${SECRET}]`)
                ),
        },
        {
            name: "secretAsErrorNameAndCauseCode",
            respond: () =>
                Promise.reject(
                    Object.assign(
                        new TypeError("fetch failed", {
                            cause: { code: SECRET_IDENTIFIER },
                        }),
                        { name: SECRET_IDENTIFIER }
                    )
                ),
        },
        {
            name: "statusBodyCancelErrorNamedLikeSecret",
            respond: () =>
                streamingResponse(
                    500,
                    cancelProbe(),
                    "rejects",
                    Object.assign(new Error("cancel failed"), {
                        name: SECRET_IDENTIFIER,
                    })
                ),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn } = recordingFetch(row.respond)
            const { logger, records } = recordingLogger()

            await withVisitLogger(logger, () =>
                isPortfolioInsightsEnabled(BASE_URL, fetchFn)
            )

            assert.deepEqual(
                {
                    logged: records.length > 0,
                    leaking: records
                        .map((record) => record.message)
                        .filter(
                            (message) =>
                                message.includes(SECRET) ||
                                message.includes(SECRET_IDENTIFIER)
                        ),
                    metadata: records.flatMap((record) => record.metadata),
                },
                { logged: true, leaking: [], metadata: [] }
            )
        })
    }
})

/** A flag read whose request is held until release, then answered. */
function heldFlagRead(status: number) {
    let release: () => void = () => undefined
    const released = new Promise<void>((resolve) => {
        release = resolve
    })
    const { fetchFn, firstCall } = recordingFetch(async () => {
        await released
        return new Response(null, { status })
    })
    return { fetchFn, firstCall, release: () => release() }
}

/** A promise opened from outside. */
function gate(): { opened: Promise<void>; open: () => void } {
    let resolveGate: () => void = () => undefined
    const opened = new Promise<void>((resolve) => {
        resolveGate = resolve
    })
    return { opened, open: () => resolveGate() }
}

test("withVisitLogger_interleavedScopes_eachReadLogsToOwnLogger", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const scopes = [404, 503].map((status) => ({
        recorder: recordingLogger(),
        read: heldFlagRead(status),
        start: gate(),
    }))
    const results = scopes.map((scope) =>
        withVisitLogger(scope.recorder.logger, async () => {
            await scope.start.opened
            return await isPortfolioInsightsEnabled(
                BASE_URL,
                scope.read.fetchFn
            )
        })
    )

    // Both scopes are entered before either read starts; the later scope
    // starts its read first and is answered first. A logger kept anywhere but
    // in the scope itself would route one visit's line to the other visit.
    const [first, second] = scopes
    second.start.open()
    await second.read.firstCall
    first.start.open()
    await first.read.firstCall
    second.read.release()
    first.read.release()
    const enabled = await Promise.all(results)

    assert.deepEqual(
        {
            enabled,
            lines: scopes.map(({ recorder }) =>
                recorder.records.map(
                    (record) => `${record.level}: ${record.message}`
                )
            ),
        },
        {
            enabled: [false, false],
            lines: [[flagStatusLine(404)], [flagStatusLine(503)]],
        }
    )
})

test("isPortfolioInsightsEnabled_noVisitLoggerScope_logsThroughVisitFormatFallback", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const { fetchFn } = recordingFetch(() => statusResponse(503))
    const printed: string[] = []
    const write = process.stdout.write
    // Only the read's own line is held back; every other write, the test
    // runner's reports included, goes through unchanged.
    const stdout = t.mock.method(
        process.stdout,
        "write",
        (chunk: unknown, ...rest: unknown[]): boolean => {
            if (
                typeof chunk === "string" &&
                chunk.includes("Flag [portfolio-insights-enabled]")
            ) {
                printed.push(chunk)
                return true
            }
            return Reflect.apply(write, process.stdout, [chunk, ...rest])
        }
    )

    // The console transport writes the line while the read logs it.
    const enabled = await isPortfolioInsightsEnabled(BASE_URL, fetchFn)
    stdout.mock.restore()

    assert.deepEqual(
        {
            enabled,
            printed: printed.map((line) =>
                line.replace(/^\[[^\]]+\]/, "[<time>]").trimEnd()
            ),
        },
        {
            enabled: false,
            printed: [
                "[<time>][WARN]: Flag [portfolio-insights-enabled] read returned status [503], treating as disabled",
            ],
        }
    )
})

const FLAG_CANCEL_FAILED =
    "debug: Flag [portfolio-insights-enabled] response body not cancelled: error [Error]"

test("isPortfolioInsightsEnabled_unreadStatusBody_cancelledBeforeResolving", async (t) => {
    const rows: {
        name: string
        status: number
        cancel: CancelEnd
        /** the status is answered only once the deadline aborted the read */
        answeredAfterAbort?: boolean
        /** what the clock is driven to the 2 s deadline after */
        heldUntil?: "cancelStarted" | "requestSent"
        messages: string[]
    }[] = [
        {
            name: "status404_cancelled",
            status: 404,
            cancel: "resolves",
            messages: [flagStatusLine(404)],
        },
        {
            name: "status500_cancelled",
            status: 500,
            cancel: "resolves",
            messages: [flagStatusLine(500)],
        },
        {
            name: "status500CancelRejects_stillDisabled",
            status: 500,
            cancel: "rejects",
            messages: [FLAG_CANCEL_FAILED, flagStatusLine(500)],
        },
        // A cancel that never settles is waited for until the deadline only.
        {
            name: "status500CancelPending_disabledAtDeadline",
            status: 500,
            cancel: "never",
            heldUntil: "cancelStarted",
            messages: [flagStatusLine(500)],
        },
        {
            name: "status500CancelRejectsAfterDeadline_loggedLate",
            status: 500,
            cancel: "rejectsLate",
            heldUntil: "cancelStarted",
            messages: [flagStatusLine(500), FLAG_CANCEL_FAILED],
        },
        // The deadline has already passed: the cancel starts, unawaited.
        {
            name: "status500AnsweredAfterAbort_cancelNotAwaited",
            status: 500,
            cancel: "never",
            answeredAfterAbort: true,
            heldUntil: "requestSent",
            messages: [flagStatusLine(500)],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const probe = cancelProbe()
            const answer = () =>
                streamingResponse(row.status, probe, row.cancel)
            const { fetchFn, firstCall } = recordingFetch((call) =>
                row.answeredAfterAbort === true
                    ? answerAfterAbort(call, answer)
                    : answer()
            )
            const { logger, records } = recordingLogger()

            const pending = withVisitLogger(logger, () =>
                isPortfolioInsightsEnabled(BASE_URL, fetchFn)
            ).finally(() => {
                probe.settled = true
            })
            let settled: { before: boolean; at: boolean } | undefined
            if (row.heldUntil !== undefined) {
                await (row.heldUntil === "cancelStarted"
                    ? probe.started
                    : firstCall)
                settled = await settledAroundDeadline(st, probe, 2000)
            }
            const enabled =
                settled?.at === false ? STILL_PENDING : await pending
            // A cancel failing after the read settled is still logged.
            probe.failLate()
            await drained()

            assert.deepEqual(
                {
                    enabled,
                    cancels: probe.cancels,
                    settled,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    enabled: false,
                    cancels: ["while pending"],
                    settled:
                        row.heldUntil === undefined
                            ? undefined
                            : { before: false, at: true },
                    messages: row.messages,
                }
            )
        })
    }
})

test("createAndDeleteOwnedAlert_unreadDeleteBody_cancelledBeforeOutcome", async (t) => {
    const absent = {
        outcome: { kind: "absent", id: OWN_ID } as const,
        line: `info: Alert [${OWN_ID}] already absent`,
    }
    const leftInPlace = (status: number) => ({
        outcome: {
            kind: "left_in_place" as const,
            id: OWN_ID,
            status: `${status}`,
        },
        line: `warn: Alert [${OWN_ID}] left in place: ${status}`,
    })
    const rows: {
        name: string
        status: number
        cancel: CancelEnd
        /** the clock is driven to the 5 s deadline once the cancel started */
        heldToDeadline?: boolean
        outcome: OwnedAlertOutcome
        line: string
    }[] = [
        { name: "api404_absent", status: 404, cancel: "resolves", ...absent },
        ...[403, 500].map((status) => ({
            name: `api${status}_leftInPlace`,
            status,
            cancel: "resolves" as const,
            ...leftInPlace(status),
        })),
        {
            name: "api404CancelRejects_stillAbsent",
            status: 404,
            cancel: "rejects",
            ...absent,
        },
        // A cancel that never settles is waited for until the deadline only,
        // and the status still decides the outcome.
        {
            name: "api404CancelPending_absentAtDeadline",
            status: 404,
            cancel: "never",
            heldToDeadline: true,
            ...absent,
        },
        {
            name: "api500CancelPending_leftInPlaceAtDeadline",
            status: 500,
            cancel: "never",
            heldToDeadline: true,
            ...leftInPlace(500),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const probe = cancelProbe()
            const { fetchFn } = recordingFetch(() =>
                streamingResponse(row.status, probe, row.cancel)
            )
            const { logger, records } = recordingLogger()
            const page = new FakePageActions(
                ownAlertPage({
                    present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
                })
            )

            const pending = createAndDeleteOwnedAlert(page, BASE_URL, logger, {
                fetchFn,
                random: () => 0.5,
            }).finally(() => {
                probe.settled = true
            })
            let settled: { before: boolean; at: boolean } | undefined
            if (row.heldToDeadline === true) {
                await probe.started
                settled = await settledAroundDeadline(st, probe, 5000)
            }
            const outcome =
                settled?.at === false ? STILL_PENDING : await pending

            assert.deepEqual(
                {
                    outcome,
                    cancels: probe.cancels,
                    settled,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    outcome: row.outcome,
                    cancels: ["while pending"],
                    settled:
                        row.heldToDeadline === true
                            ? { before: false, at: true }
                            : undefined,
                    messages: [
                        CREATED_OWN,
                        ...(row.cancel === "rejects"
                            ? [
                                  `debug: Alert [${OWN_ID}] delete response body not cancelled: error [Error]`,
                              ]
                            : []),
                        row.line,
                    ],
                }
            )
        })
    }
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

const LOGIN_USER: User = {
    first_name: "Test",
    last_name: "Visitor",
    username: "test_visitor",
    email: "test.visitor@example.test",
    password: "login-step-password",
    user_agent: "loadgen-test",
    ip4: "192.0.2.10",
    address: "1 Test Street",
    credit_card_number: "test-card",
    credit_card_cvv: "000",
    credit_card_provider: "visaDebit",
    visitor_id: "test-visitor-id",
}
/** Text left in the password field, as by browser autofill. */
const STALE_PASSWORD = "stale-pw"

/**
 * One field or button of the login form, as far as PageActions and the login
 * step use a Puppeteer element. Its calls go to the page's trace.
 */
class FakeLoginElement {
    private readonly name: string
    private readonly trace: string[]
    private value: string

    constructor(name: string, trace: string[], value: string) {
        this.name = name
        this.trace = trace
        this.value = value
    }

    async focus(): Promise<void> {
        this.trace.push(`focus ${this.name}`)
    }

    async isIntersectingViewport(): Promise<boolean> {
        return true
    }

    async getProperty(
        propertyName: string
    ): Promise<{ jsonValue(): Promise<unknown>; dispose(): Promise<void> }> {
        const value = propertyName === "value" ? this.value : undefined
        return {
            jsonValue: async () => value,
            dispose: async () => undefined,
        }
    }

    async press(key: string): Promise<void> {
        this.trace.push(`press ${this.name} ${key}`)
        if (key === "Backspace") {
            this.value = this.value.slice(0, -1)
        }
    }

    async type(text: string): Promise<void> {
        this.trace.push(`type ${this.name} ${text}`)
        this.value += text
    }

    async click(): Promise<void> {
        this.trace.push(`click ${this.name}`)
    }

    text(): string {
        return this.value
    }
}

/**
 * The login screen as a Puppeteer page, faking only the members PageActions
 * calls for input and navigate: a visible wait per selector and the
 * navigation wait.
 */
class FakeLoginPage {
    readonly trace: string[] = []
    readonly username = new FakeLoginElement("username", this.trace, "")
    readonly password = new FakeLoginElement(
        "password",
        this.trace,
        STALE_PASSWORD
    )
    private readonly elements = new Map<string, FakeLoginElement>([
        [selectors.loginPage_username.value, this.username],
        [selectors.loginPage_password.value, this.password],
        [
            selectors.loginPage_loginButton.value,
            new FakeLoginElement("loginButton", this.trace, ""),
        ],
    ])

    async waitForSelector(selector: string): Promise<ElementHandle> {
        const element = this.elements.get(selector)
        if (element === undefined) {
            throw new Error(`Unexpected selector [${selector}]`)
        }
        this.trace.push(`find ${selector}`)
        return element as unknown as ElementHandle
    }

    async waitForNavigation(): Promise<null> {
        this.trace.push("waitForNavigation")
        return null
    }

    asPage(): Page {
        return this as unknown as Page
    }
}

/**
 * A debug-level winston logger keeping each entry whole: its message, every
 * metadata field and any stack, errors expanded to name, message and stack.
 */
function wholeEntryLogger(): { logger: Logger; entries: string[] } {
    const entries: string[] = []
    const record = format((info) => {
        entries.push(
            JSON.stringify(info, (_key, value: unknown) =>
                value instanceof Error
                    ? {
                          name: value.name,
                          message: value.message,
                          stack: value.stack,
                      }
                    : value
            )
        )
        return info
    })
    const logger = createLogger({
        level: "debug",
        format: record(),
        transports: [new transports.Console({ silent: true })],
    })
    return { logger, entries }
}

test("loginWithoutLoggingPassword_debugLogging_passwordInNoEntry", async (t) => {
    const page = new FakeLoginPage()
    const { logger, entries } = wholeEntryLogger()
    const pageActions = new PageActions(
        page.asPage(),
        logger,
        defineConfig({ disableDelay: true })
    )
    t.mock.method(pageActions, "shortDelay", async () => {
        page.trace.push("shortDelay")
    })

    await loginWithoutLoggingPassword(pageActions, LOGIN_USER)

    // The username still goes through PageActions.input, whose debug entry
    // shows the logger records the values that action types.
    assert.deepEqual(
        {
            trace: page.trace,
            fields: [page.username.text(), page.password.text()],
            secretEntries: entries.filter(
                (entry) =>
                    entry.includes(LOGIN_USER.password) ||
                    entry.includes(STALE_PASSWORD)
            ),
            usernameEntries: entries.filter((entry) =>
                entry.includes(`with value [${LOGIN_USER.username}]`)
            ).length,
        },
        {
            trace: [
                `find ${selectors.loginPage_username.value}`,
                "focus username",
                "focus username",
                `type username ${LOGIN_USER.username}`,
                "shortDelay",
                `find ${selectors.loginPage_password.value}`,
                "focus password",
                "focus password",
                ...Array.from(STALE_PASSWORD, () => "press password Backspace"),
                `type password ${LOGIN_USER.password}`,
                "shortDelay",
                `find ${selectors.loginPage_loginButton.value}`,
                "waitForNavigation",
                "focus loginButton",
                "click loginButton",
            ],
            fields: [LOGIN_USER.username, LOGIN_USER.password],
            secretEntries: [],
            usernameEntries: 1,
        }
    )
})

/**
 * A Puppeteer page whose instrument options are in the DOM but have no layout
 * box, as in a closed <select>: a visible wait for them times out. It fakes
 * only the two page members the selectors call.
 */
class HiddenOptionsPage {
    readonly queried: string[] = []
    readonly waitedFor: string[] = []
    disposed = 0
    private readonly options: number

    constructor(options: number) {
        this.options = options
    }

    async $$(selector: string): Promise<ElementHandle[]> {
        this.queried.push(selector)
        return Array.from({ length: this.options }, () => this.optionHandle())
    }

    async waitForSelector(selector: string): Promise<never> {
        this.waitedFor.push(selector)
        throw new Error(`Waiting for visible [${selector}] timed out`)
    }

    asPage(): Page {
        return this as unknown as Page
    }

    private optionHandle(): ElementHandle {
        const handle = {
            dispose: async () => {
                this.disposed++
            },
        }
        return handle as unknown as ElementHandle
    }
}

const OPTION_QUERY = selectors.portfolioInsightsPage_alertInstrumentOption.value

test("DomPresenceSelector_isPresent_answersFromDomWithoutVisibleWait", async (t) => {
    const rows = [
        {
            name: "hiddenOptions_trueHandlesDisposed",
            options: 2,
            present: true,
        },
        { name: "noOptions_false", options: 0, present: false },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            const page = new HiddenOptionsPage(row.options)
            const presence = new DomPresenceSelector(
                selectors.portfolioInsightsPage_alertInstrumentOption
            )

            const present = await presence.isPresent(page.asPage())

            assert.deepEqual(
                {
                    present,
                    queried: page.queried,
                    waitedFor: page.waitedFor,
                    disposed: page.disposed,
                },
                {
                    present: row.present,
                    queried: [OPTION_QUERY],
                    waitedFor: [],
                    disposed: row.options,
                }
            )
        })
    }
})

test("DomPresenceSelector_otherMembers_delegateToWrapped", async () => {
    const page = new HiddenOptionsPage(1)
    const presence = new DomPresenceSelector(
        selectors.portfolioInsightsPage_alertInstrumentOption
    )

    const text = presence.toString()
    const all = (await presence.selectAll(page.asPage())).map(String)
    const selected = await presence.select(page.asPage()).then(
        () => "resolved",
        (error: unknown) =>
            error instanceof Error ? error.message : String(error)
    )

    // select keeps the wrapped visible wait, and selectAll hands the handles
    // to the caller undisposed.
    assert.deepEqual(
        {
            text,
            all,
            selected,
            waitedFor: page.waitedFor,
            disposed: page.disposed,
        },
        {
            text: OPTION_KEY,
            all: [`{selector: ${OPTION_KEY}}`],
            selected: `Waiting for visible [${OPTION_QUERY}] timed out`,
            waitedFor: [OPTION_QUERY],
            disposed: 0,
        }
    )
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
const UI_DELETE_FAILED = `warn: UI deletion of alert [${OWN_ID}] failed, using the api`
/** The navigation link is gone, as once the flag turned off mid-visit. */
const FEATURE_LOST = { [NAV_KEY]: Number.POSITIVE_INFINITY }
/** The feature check that follows a failed page step. */
const NAV_CHECK = checkStep(NAV_KEY, 1)
/** The feature check itself failed, so no loss is verified. */
const CHECK_FAILED =
    "debug: Portfolio insights feature check failed, loss not verified: error [Error]"

/** API answers to the fallback after a throwing UI deletion. */
const uiDeleteThrowsRows: {
    name: string
    status: number
    outcome: OwnedAlertOutcome
    message: string
}[] = [
    {
        name: "rowDeleteClickThrows_loggedThenDeletedViaApi",
        status: 204,
        outcome: { kind: "deleted", id: OWN_ID, via: "api" },
        message: `info: Deleted alert [${OWN_ID}] via api`,
    },
    {
        name: "rowDeleteClickThrows_api403_leftInPlaceReturned",
        status: 403,
        outcome: { kind: "left_in_place", id: OWN_ID, status: "403" },
        message: `warn: Alert [${OWN_ID}] left in place: 403`,
    },
]

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
                READ_OPTIONS_STEP,
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
    // The UI deletion throws once the id is known: the error is logged and the
    // API fallback's outcome is returned, whether clean or not.
    ...uiDeleteThrowsRows.map((row): AlertRow => ({
        name: row.name,
        page: ownAlertPage({ failingClick: rowDeleteKey(OWN_ID) }),
        respond: () => statusResponse(row.status),
        expected: {
            outcome: row.outcome,
            steps: [
                ...CONFIRMED_STEPS,
                checkStep(rowKey(OWN_ID), 1),
                clickStep(rowDeleteKey(OWN_ID)),
            ],
            requests: [DELETE_OWN],
            messages: [CREATED_OWN, UI_DELETE_FAILED, row.message],
            errors: ["pageError"],
        },
    })),
    {
        name: "submitClickThrows_featureLost_unconfirmed",
        page: ownAlertPage({ failingClick: SUBMIT_KEY, present: FEATURE_LOST }),
        expected: {
            outcome: { kind: "unconfirmed", marker: MARKER },
            steps: [...SUBMIT_STEPS, NAV_CHECK],
            requests: [],
            messages: [UNCONFIRMED],
            errors: ["pageError"],
        },
    },
    {
        name: "submitClickThrows_featureKept_logsOutcomeUnknownAndRejects",
        page: ownAlertPage({ failingClick: SUBMIT_KEY }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS, NAV_CHECK],
            requests: [],
            messages: [UNCONFIRMED],
            errors: ["pageError"],
        },
    },
    // The feature check fails too, as once the target is closed: no loss is
    // verified, so the page step's own error propagates.
    {
        name: "submitClickThrows_featureCheckFails_logsOutcomeUnknownAndRejects",
        page: ownAlertPage({ failingClick: SUBMIT_KEY, failingCheck: NAV_KEY }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS, NAV_CHECK],
            requests: [],
            messages: [UNCONFIRMED, CHECK_FAILED],
            errors: ["pageError", "checkError"],
        },
    },
    {
        name: "formInputThrows_featureLost_notSubmitted",
        page: ownAlertPage({
            failingInput: THRESHOLD_KEY,
            present: FEATURE_LOST,
        }),
        expected: {
            outcome: { kind: "not_submitted" },
            steps: [...SUBMIT_STEPS.slice(0, -1), NAV_CHECK],
            requests: [],
            messages: [
                "warn: Portfolio insights feature lost before submit, no alert created",
            ],
            errors: ["pageError"],
        },
    },
    {
        name: "formInputThrows_featureKept_rejectsWithoutOutcomeLine",
        page: ownAlertPage({ failingInput: THRESHOLD_KEY }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS.slice(0, -1), NAV_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "formInputThrows_featureCheckFails_rejectsWithoutOutcomeLine",
        page: ownAlertPage({
            failingInput: THRESHOLD_KEY,
            failingCheck: NAV_KEY,
        }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS.slice(0, -1), NAV_CHECK],
            requests: [],
            messages: [CHECK_FAILED],
            errors: ["checkError"],
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
    // Every check finds options, but the read that follows finds none, as
    // after a re-render, or only an empty value; neither counts as loaded.
    ...[
        { name: "optionsGoneBeforeRead_notSubmitted", values: [] },
        { name: "optionValueEmpty_notSubmitted", values: [""] },
    ].map((row: { name: string; values: string[] }): AlertRow => ({
        name: row.name,
        page: { options: { emptyPolls: 0, values: row.values } },
        expected: {
            outcome: { kind: "not_submitted" },
            steps: Array.from({ length: 20 }, () => [
                findOptionsStep(1),
                READ_OPTIONS_STEP,
            ]).flat(),
            requests: [],
            messages: [
                "warn: Alert instrument options did not load, no alert created",
            ],
            errors: [],
        },
    })),
]

/**
 * Runs one row through lifecycle on a mocked clock, and checks its outcome or
 * rejection, its page trace, requests, log lines and logged errors.
 */
async function runAlertRow(
    t: TestContext,
    row: AlertRow,
    lifecycle: typeof createAndDeleteOwnedAlert
): Promise<void> {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const { fetchFn, calls, firstCall } = recordingFetch((call) =>
        row.respond === undefined
            ? Promise.reject(new Error("Unexpected request"))
            : row.respond(call)
    )
    const { logger, records } = recordingLogger()
    const page = new FakePageActions(row.page)

    // random 0.5 yields MARKER, 1000000.55555555.
    const pending = lifecycle(page, BASE_URL, logger, {
        fetchFn,
        random: () => 0.5,
    })
    if (row.whileDeletePending !== undefined) {
        const call = await requestSent(firstCall, pending)
        if (call !== undefined) {
            row.whileDeletePending(t, call)
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
}

test("createAndDeleteOwnedAlert_scenario_outcome", async (t) => {
    for (const row of alertRows) {
        await t.test(row.name, (st) =>
            runAlertRow(st, row, createAndDeleteOwnedAlert)
        )
    }
})

const NAVIGATE_STEP = `navigate ${NAV_KEY}`

const openPageRows: AlertRow[] = [
    {
        name: "navigationSucceeds_lifecycleRuns_deletedViaUi",
        page: ownAlertPage(),
        expected: {
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            steps: [NAVIGATE_STEP, ...CONFIRMED_STEPS, ...UI_DELETE_STEPS],
            requests: [],
            messages: DELETED_VIA_UI,
            errors: [],
        },
    },
    {
        name: "navigationThrows_featureLost_notSubmitted",
        page: ownAlertPage({ failingNavigate: NAV_KEY, present: FEATURE_LOST }),
        expected: {
            outcome: { kind: "not_submitted" },
            steps: [NAVIGATE_STEP, NAV_CHECK],
            requests: [],
            messages: [
                "warn: Portfolio insights page unavailable, no alert created",
            ],
            errors: ["pageError"],
        },
    },
    {
        name: "navigationThrows_featureKept_rejectsWithoutOutcomeLine",
        page: ownAlertPage({ failingNavigate: NAV_KEY }),
        rejects: pageError,
        expected: {
            steps: [NAVIGATE_STEP, NAV_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "navigationThrows_featureCheckFails_rejectsWithoutOutcomeLine",
        page: ownAlertPage({ failingNavigate: NAV_KEY, failingCheck: NAV_KEY }),
        rejects: pageError,
        expected: {
            steps: [NAVIGATE_STEP, NAV_CHECK],
            requests: [],
            messages: [CHECK_FAILED],
            errors: ["checkError"],
        },
    },
]

test("openPageAndRunOwnedAlert_scenario_outcome", async (t) => {
    for (const row of openPageRows) {
        await t.test(row.name, (st) =>
            runAlertRow(st, row, openPageAndRunOwnedAlert)
        )
    }
})

/**
 * A Puppeteer page on which the navigation to the insights page fails: every
 * visible wait rejects with waitError, and the DOM query rejects with dom when
 * it is an error, or else finds dom matching elements. It fakes only the two
 * page members the real navigation and the feature check call.
 */
class NavigationFailurePage {
    readonly waitedFor: string[] = []
    readonly queried: string[] = []
    disposed = 0
    private readonly waitError: Error
    private readonly dom: number | Error

    constructor(waitError: Error, dom: number | Error) {
        this.waitError = waitError
        this.dom = dom
    }

    async waitForSelector(selector: string): Promise<never> {
        this.waitedFor.push(selector)
        throw this.waitError
    }

    async $$(selector: string): Promise<ElementHandle[]> {
        this.queried.push(selector)
        if (this.dom instanceof Error) {
            throw this.dom
        }
        return Array.from({ length: this.dom }, () => this.linkHandle())
    }

    asPage(): Page {
        return this as unknown as Page
    }

    private linkHandle(): ElementHandle {
        const handle = {
            dispose: async () => {
                this.disposed++
            },
        }
        return handle as unknown as ElementHandle
    }
}

const NAV_QUERY = selectors.navigation_portfolioInsightsPage.value

test("openPageAndRunOwnedAlert_navigationFailsOnRealPage_lossOnlyFromDomAbsence", async (t) => {
    // Distinct objects with Puppeteer's messages, so a rejection is checked to
    // be the navigation's own error rather than the feature check's.
    const closedOnWait = new Error("Target closed")
    const closedOnQuery = new Error("Target closed")
    const waitTimedOut = new Error(
        `Waiting for selector \`${NAV_QUERY}\` failed`
    )
    const rows: {
        name: string
        waitError: Error
        dom: number | Error
        outcome?: OwnedAlertOutcome
        rejects?: Error
        messages: string[]
        /** the error objects the log entries carry */
        loggedErrors: Error[]
        disposed: number
    }[] = [
        {
            name: "targetClosed_rejectsWithNavigationError",
            waitError: closedOnWait,
            dom: closedOnQuery,
            rejects: closedOnWait,
            messages: [CHECK_FAILED],
            loggedErrors: [closedOnQuery],
            disposed: 0,
        },
        {
            name: "linkAbsentFromDom_notSubmitted",
            waitError: waitTimedOut,
            dom: 0,
            outcome: { kind: "not_submitted" },
            messages: [
                "warn: Portfolio insights page unavailable, no alert created",
            ],
            loggedErrors: [waitTimedOut],
            disposed: 0,
        },
        // A visible wait misses a link that is in the DOM but hidden; the DOM
        // lookup finds it, so no loss is verified.
        {
            name: "linkInDomButHidden_rejectsWithNavigationError",
            waitError: waitTimedOut,
            dom: 1,
            rejects: waitTimedOut,
            messages: [],
            loggedErrors: [],
            disposed: 1,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const page = new NavigationFailurePage(row.waitError, row.dom)
            const pageActions = new PageActions(
                page.asPage(),
                recordingLogger().logger,
                defineConfig({ disableDelay: true })
            )
            const { fetchFn, calls } = recordingFetch(() =>
                Promise.reject(new Error("Unexpected request"))
            )
            const { logger, records } = recordingLogger()

            const pending = openPageAndRunOwnedAlert(
                pageActions,
                BASE_URL,
                logger,
                { fetchFn }
            )
            let outcome: OwnedAlertOutcome | undefined
            if (row.rejects === undefined) {
                outcome = await pending
            } else {
                const thrown = row.rejects
                await assert.rejects(pending, (error) => error === thrown)
            }

            assert.deepEqual(
                {
                    outcome,
                    waitedFor: page.waitedFor,
                    queried: page.queried,
                    disposed: page.disposed,
                    requests: calls.length,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    loggedErrorsMatch: records
                        .map((record) => record.error)
                        .filter((error) => error !== undefined)
                        .map(
                            (error, index) => error === row.loggedErrors[index]
                        ),
                },
                {
                    outcome: row.outcome,
                    waitedFor: [NAV_QUERY],
                    queried: [NAV_QUERY],
                    disposed: row.disposed,
                    requests: 0,
                    messages: row.messages,
                    loggedErrorsMatch: row.loggedErrors.map(() => true),
                }
            )
        })
    }
})

test("ownedAlertFailure_outcome_errorUnlessClean", async (t) => {
    // The messages carry no outcome line marker, so a failed visit's worker
    // error line is never counted as a second outcome.
    const rows: {
        name: string
        outcome: OwnedAlertOutcome
        message: string | undefined
    }[] = [
        {
            name: "deletedViaUi_none",
            outcome: { kind: "deleted", id: OWN_ID, via: "ui" },
            message: undefined,
        },
        {
            name: "deletedViaApi_none",
            outcome: { kind: "deleted", id: OWN_ID, via: "api" },
            message: undefined,
        },
        {
            name: "absent_none",
            outcome: { kind: "absent", id: OWN_ID },
            message: undefined,
        },
        {
            name: "notSubmitted_error",
            outcome: { kind: "not_submitted" },
            message:
                "Owned alert outcome [not_submitted]: no alert was submitted",
        },
        {
            name: "unconfirmed_errorNamesMarker",
            outcome: { kind: "unconfirmed", marker: MARKER },
            message: `Owned alert outcome [unconfirmed]: create of threshold [${MARKER}] not confirmed`,
        },
        {
            name: "leftInPlace_errorNamesIdAndStatus",
            outcome: { kind: "left_in_place", id: OWN_ID, status: "timeout" },
            message: `Owned alert outcome [left_in_place]: alert [${OWN_ID}] not deleted, status [timeout]`,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            assert.equal(ownedAlertFailure(row.outcome)?.message, row.message)
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
