import assert from "node:assert/strict"
import { TestContext, test } from "node:test"
import { IHandleWrapper } from "@demoability/loadgen-core/lib/handles"
import {
    IPageActions,
    PageActions,
    PageSetup,
    defineConfig,
} from "@demoability/loadgen-core/lib/pageActions"
import { ISelector } from "@demoability/loadgen-core/lib/selectors"
import type { ClickOptions, ElementHandle, Page } from "puppeteer"
import { Logger, createLogger, format, transports } from "winston"
import { selectors } from "../selectors"
import { User } from "../user"
import {
    BoundedPageActions,
    DOCUMENT_ORIGIN_UNVERIFIED,
    DomPresenceSelector,
    OwnedAlertOutcome,
    PAGE_ACTION_TIMEOUT_MS,
    createAndDeleteOwnedAlert,
    featureLossPresence,
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
/**
 * The navigation link, whose absence from a shown navigation shows the
 * feature was lost.
 */
const NAV_KEY = selectors.navigation_portfolioInsightsPage.toString()
/** The home link, present while the navigation of a protected page is shown. */
const HOME_NAV_KEY = selectors.navigation_homePage.toString()
/**
 * The one DOM query of the feature check, answered from the page's home and
 * Portfolio Insights link entries in one state.
 */
const FEATURE_LOSS_KEY = featureLossPresence.toString()
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
/** What releasing a handle throws once its session is gone. */
const disposeError = new Error("Protocol error (Runtime.releaseObject)")

/**
 * Names the error objects this suite throws, so a log entry is checked to carry
 * the very object rather than a copy of its message.
 */
const knownErrors = new Map<unknown, string>([
    [pageError, "pageError"],
    [readError, "readError"],
    [networkError, "networkError"],
    [checkError, "checkError"],
    [disposeError, "disposeError"],
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

type FetchCall = {
    url: string
    method: string
    signal?: AbortSignal
    /** the request's redirect mode, undefined when the init sets none */
    redirect?: string
}

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
            redirect: init?.redirect,
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
            return recordCancel(probe, end, failure)
        },
    })
    return Promise.resolve(new Response(body, { status }))
}

/**
 * A body's cancel: recorded in probe, as made while the call under test was
 * pending or after it settled, and ending as end says, failing with failure.
 */
function recordCancel(
    probe: CancelProbe,
    end: CancelEnd,
    failure: Error
): void | Promise<void> {
    probe.cancels.push(probe.settled ? "after settling" : "while pending")
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
}

/** The helper's limit on a flag answer's body, in bytes. */
const MAX_FLAG_BODY_BYTES = 16 * 1024
/** A valid answer of the enabled flag. */
const ENABLED_ANSWER = JSON.stringify({
    id: "portfolio-insights-enabled",
    enabled: true,
})
/** 1 KiB of JSON whitespace, each chunk of an endless body. */
const KIB_CHUNK = new TextEncoder().encode(" ".repeat(1024))

/**
 * A 200 whose body never ends: each pull sends one more KIB_CHUNK and is
 * counted in pulls. Its cancel is recorded in probe and ends as end says.
 */
function endlessResponse(
    probe: CancelProbe,
    end: CancelEnd,
    pulls: { count: number }
): Promise<Response> {
    const body = new ReadableStream<Uint8Array>({
        pull(controller) {
            pulls.count++
            controller.enqueue(KIB_CHUNK)
        },
        cancel(): void | Promise<void> {
            return recordCancel(probe, end, cancelError)
        },
    })
    return Promise.resolve(new Response(body, { status: 200 }))
}

/** A 200 whose body arrives as chunks, one per pull, and then ends. */
function chunkedResponse(chunks: Uint8Array[]): Promise<Response> {
    let next = 0
    const body = new ReadableStream<Uint8Array>({
        pull(controller) {
            const chunk = chunks[next++]
            if (chunk === undefined) {
                controller.close()
            } else {
                controller.enqueue(chunk)
            }
        },
    })
    return Promise.resolve(new Response(body, { status: 200 }))
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

/**
 * The instrument options of a fake page: present once emptyPolls presence
 * checks found none, and how reading the first one's value behaves.
 */
type FakeOptions = {
    emptyPolls: number
    values: string[]
    /** value reads that answer "" before the first option's own value */
    blankReads?: number
    /** the step of the value read that throws readError */
    failingRead?: "getProperty" | "jsonValue"
    /** whether disposing any option or value handle throws disposeError */
    failingDispose?: boolean
}

/**
 * The Puppeteer handles the fake options hand out, each under its own name,
 * the dispose calls each receives, and the value reads they answer.
 */
class HandleLedger {
    readonly acquired: string[] = []
    valueReads = 0
    private readonly disposals: string[] = []

    acquire(kind: string): string {
        const name = `${kind} #${this.acquired.length + 1}`
        this.acquired.push(name)
        return name
    }

    dispose(name: string, fails: boolean): void {
        this.disposals.push(name)
        if (fails) {
            throw disposeError
        }
    }

    /** The acquired handles not disposed exactly once. */
    unreleased(): string[] {
        return this.acquired.filter(
            (name) =>
                this.disposals.filter((disposed) => disposed === name)
                    .length !== 1
        )
    }
}

/**
 * An option as getAllHandles wraps it. Its Puppeteer element answers the
 * value property through a JSHandle, as a real option does, and the ledger
 * records the element, each property handle, and their disposals.
 */
class FakeOptionHandle implements IHandleWrapper {
    readonly value: string
    private readonly element: ElementHandle

    constructor(value: string, ledger: HandleLedger, options: FakeOptions) {
        this.value = value
        const name = ledger.acquire(`option[${value}]`)
        const fails = options.failingDispose ?? false
        const element = {
            getProperty: async (propertyName: string) => {
                if (propertyName !== "value") {
                    return unexpected(
                        `getProperty ${propertyName} of an option`
                    )
                }
                if (options.failingRead === "getProperty") {
                    throw readError
                }
                const property = ledger.acquire(`${name} value`)
                return {
                    jsonValue: async (): Promise<unknown> => {
                        if (options.failingRead === "jsonValue") {
                            throw readError
                        }
                        ledger.valueReads++
                        return ledger.valueReads <= (options.blankReads ?? 0)
                            ? ""
                            : value
                    },
                    dispose: async () => ledger.dispose(property, fails),
                }
            },
            dispose: async () => ledger.dispose(name, fails),
        }
        this.element = element as unknown as ElementHandle
    }

    getHandle(): ElementHandle {
        return this.element
    }

    toString(): string {
        return `option[${this.value}]`
    }
}

type FakePage = {
    /**
     * selector key -> failed checks before the element is present; the
     * feature-loss query reads the home and Portfolio Insights link entries
     */
    present?: Record<string, number>
    /** selector key -> property name -> value */
    properties?: Record<string, Record<string, unknown>>
    options?: FakeOptions
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
    /** the handles of the options getAllHandles returned */
    readonly handles = new HandleLedger()
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
        if (key === FEATURE_LOSS_KEY) {
            // One query reads both links from the page as it stands.
            return this.shown(HOME_NAV_KEY) && !this.shown(NAV_KEY)
        }
        if (this.shown(key)) {
            return true
        }
        this.failedChecks.set(key, (this.failedChecks.get(key) ?? 0) + 1)
        return false
    }

    /** Whether the element of key is present now, without counting a check. */
    private shown(key: string): boolean {
        const appearsAfter = this.page.present?.[key]
        return (
            appearsAfter !== undefined &&
            (this.failedChecks.get(key) ?? 0) >= appearsAfter
        )
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
        return options.values.map(
            (value) => new FakeOptionHandle(value, this.handles, options)
        )
    }

    /** Leaves its property handle undisposed, so the helper never calls it. */
    async getPropertyHandle<Type = unknown>(): Promise<Type> {
        return unexpected("getPropertyHandle")
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
 * A page of the enabled feature, whose navigation stays shown with its home
 * and Portfolio Insights links, and whose options, the created output of the
 * marker, the own row and the deleted output appear at once.
 */
function ownAlertPage(overrides: FakePage = {}, marker = MARKER): FakePage {
    return {
        options: { emptyPolls: 0, values: [INSTRUMENT_ID] },
        present: {
            [HOME_NAV_KEY]: 0,
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
    // The body limit is inclusive: a valid answer padded to it is accepted,
    // and one byte more is not.
    {
        name: "bodyAtSizeLimit_true",
        respond: () =>
            textResponse(ENABLED_ANSWER.padEnd(MAX_FLAG_BODY_BYTES, " ")),
        expected: { enabled: true, messages: [] },
    },
    {
        name: "bodyOverSizeLimit_falseTooLarge",
        respond: () =>
            textResponse(ENABLED_ANSWER.padEnd(MAX_FLAG_BODY_BYTES + 1, " ")),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [body_too_large] status [200]`],
        },
    },
    {
        name: "noBody_falseInvalidJson",
        respond: () => statusResponse(200),
        expected: {
            enabled: false,
            messages: [`${INVALID}reason [invalid_json] status [200]`],
        },
    },
    // Chunks split inside the byte order mark and inside a character: decoded
    // chunk by chunk, the mark would become text that is not JSON.
    {
        name: "charactersSplitAcrossChunks_true",
        respond: () => {
            const bytes = new TextEncoder().encode(
                `\uFEFF{"id":"portfolio-insights-enabled","enabled":true,"label":"\u20AC"}`
            )
            const euro = bytes.indexOf(0xe2)
            return chunkedResponse([
                bytes.subarray(0, 1),
                bytes.subarray(1, euro + 1),
                bytes.subarray(euro + 1),
            ])
        },
        expected: { enabled: true, messages: [] },
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

    // The base url's own path is replaced, its origin kept, the read is
    // abortable so the deadline can end it, and a redirect is never followed.
    assert.deepEqual(
        calls.map((call) => ({
            request: `${call.method} ${call.url}`,
            abortable: call.signal instanceof AbortSignal,
            redirect: call.redirect,
        })),
        [
            {
                request:
                    "GET http://easytrade.test:8080/feature-flag-service/v1/flags/portfolio-insights-enabled",
                abortable: true,
                redirect: "manual",
            },
        ]
    )
})

/** Where the redirects of the redirect cases point: another endpoint. */
const REDIRECT_TARGET = "http://elsewhere.test/other-endpoint"
const REDIRECT_STATUSES = [301, 302, 303, 307, 308]

/**
 * A redirect to REDIRECT_TARGET whose body never ends; its cancel is
 * recorded in probe and resolves.
 */
function redirectResponse(status: number, probe: CancelProbe): Response {
    const body = new ReadableStream<Uint8Array>({
        cancel(): void | Promise<void> {
            return recordCancel(probe, "resolves", cancelError)
        },
    })
    return new Response(body, {
        status,
        headers: { location: REDIRECT_TARGET },
    })
}

/**
 * Answers a request whose redirect mode is "manual" with a redirect of
 * status. Any other request is followed as Node's fetch follows a redirect by
 * default: a 303 turns every method but HEAD into a GET, and a 301 or 302
 * turns a POST into one. The followed request is recorded in followed and
 * answered by target, so following it shows as another endpoint's answer.
 */
function redirectingAnswer(
    status: number,
    probe: CancelProbe,
    followed: string[],
    target: () => Promise<Response>
): (call: FetchCall) => Promise<Response> {
    return async (call) => {
        if (call.redirect === "manual") {
            return redirectResponse(status, probe)
        }
        const turnsIntoGet =
            (status === 303 && call.method !== "HEAD") ||
            ((status === 301 || status === 302) && call.method === "POST")
        followed.push(
            `${turnsIntoGet ? "GET" : call.method} ${REDIRECT_TARGET}`
        )
        return await target()
    }
}

test("isPortfolioInsightsEnabled_redirect_notFollowedDisabled", async (t) => {
    for (const status of REDIRECT_STATUSES) {
        await t.test(`status${status}_false`, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const probe = cancelProbe()
            const followed: string[] = []
            // The other endpoint would answer as this flag, enabled.
            const { fetchFn, calls } = recordingFetch(
                redirectingAnswer(status, probe, followed, () =>
                    jsonResponse({
                        id: "portfolio-insights-enabled",
                        enabled: true,
                    })
                )
            )
            const { logger, records } = recordingLogger()

            const enabled = await withVisitLogger(logger, () =>
                isPortfolioInsightsEnabled(BASE_URL, fetchFn)
            ).finally(() => {
                probe.settled = true
            })

            // The 3xx is the read's status: its body is released, the other
            // endpoint is never asked, and no url is logged.
            assert.deepEqual(
                {
                    enabled,
                    requests: calls.map((call) => `${call.method} ${call.url}`),
                    followed,
                    cancels: probe.cancels,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    enabled: false,
                    requests: [
                        "GET http://easytrade.test/feature-flag-service/v1/flags/portfolio-insights-enabled",
                    ],
                    followed: [],
                    cancels: ["while pending"],
                    messages: [flagStatusLine(status)],
                }
            )
        })
    }
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
            name: "oversizedBodyCarryingSecret",
            respond: () =>
                textResponse(
                    `{"password":"${SECRET}",${" ".repeat(MAX_FLAG_BODY_BYTES)}}`
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

const TOO_LARGE = `${INVALID}reason [body_too_large] status [200]`

test("isPortfolioInsightsEnabled_oversizedBody_cancelledBeforeResolving", async (t) => {
    const rows: {
        name: string
        cancel: CancelEnd
        /** the clock is driven to the 2 s deadline once the cancel started */
        heldToDeadline?: boolean
        messages: string[]
    }[] = [
        {
            name: "endlessBody_cancelledFalse",
            cancel: "resolves",
            messages: [TOO_LARGE],
        },
        {
            name: "endlessBodyCancelRejects_stillFalse",
            cancel: "rejects",
            messages: [FLAG_CANCEL_FAILED, TOO_LARGE],
        },
        // A cancel that never settles is waited for until the deadline only.
        {
            name: "endlessBodyCancelPending_falseAtDeadline",
            cancel: "never",
            heldToDeadline: true,
            messages: [TOO_LARGE],
        },
        {
            name: "endlessBodyCancelRejectsAfterDeadline_loggedLate",
            cancel: "rejectsLate",
            heldToDeadline: true,
            messages: [TOO_LARGE, FLAG_CANCEL_FAILED],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const probe = cancelProbe()
            const pulls = { count: 0 }
            const { fetchFn } = recordingFetch(() =>
                endlessResponse(probe, row.cancel, pulls)
            )
            const { logger, records } = recordingLogger()

            const pending = withVisitLogger(logger, () =>
                isPortfolioInsightsEnabled(BASE_URL, fetchFn)
            ).finally(() => {
                probe.settled = true
            })
            let settled: { before: boolean; at: boolean } | undefined
            if (row.heldToDeadline === true) {
                await probe.started
                settled = await settledAroundDeadline(st, probe, 2000)
            }
            const enabled =
                settled?.at === false ? STILL_PENDING : await pending
            // A cancel failing after the read settled is still logged.
            probe.failLate()
            await drained()

            // The body is cancelled once it passes the limit, so no more than
            // a chunk beyond it, and the one the stream queues ahead, is sent.
            assert.deepEqual(
                {
                    enabled,
                    cancels: probe.cancels,
                    pulledWithinBound:
                        pulls.count * KIB_CHUNK.byteLength <=
                        MAX_FLAG_BODY_BYTES + 2 * KIB_CHUNK.byteLength,
                    settled,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    enabled: false,
                    cancels: ["while pending"],
                    pulledWithinBound: true,
                    settled:
                        row.heldToDeadline === true
                            ? { before: false, at: true }
                            : undefined,
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

/** A page on which the own alert is created, but its UI deletion never confirmed. */
function uiDeleteUnconfirmedPage(): FakePageActions {
    return new FakePageActions(
        ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        })
    )
}

test("createAndDeleteOwnedAlert_apiRequest_ownIdPathWithoutRedirects", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const { fetchFn, calls } = recordingFetch(() => statusResponse(204))
    const { logger } = recordingLogger()

    await createAndDeleteOwnedAlert(
        uiDeleteUnconfirmedPage(),
        BASE_URL,
        logger,
        {
            fetchFn,
            random: () => 0.5,
        }
    )

    // One abortable DELETE of the own id, which never follows a redirect.
    assert.deepEqual(
        calls.map((call) => ({
            request: `${call.method} ${call.url}`,
            abortable: call.signal instanceof AbortSignal,
            redirect: call.redirect,
        })),
        [{ request: DELETE_OWN, abortable: true, redirect: "manual" }]
    )
})

test("createAndDeleteOwnedAlert_apiRedirect_notFollowedLeftInPlace", async (t) => {
    // Followed, a 303 turns the DELETE into a GET, whose 404 would read as the
    // alert already absent; the other redirects keep the DELETE, whose 204
    // from the other endpoint would read as the alert deleted.
    const rows = REDIRECT_STATUSES.map((status) => ({
        status,
        target: status === 303 ? 404 : 204,
    }))
    for (const row of rows) {
        await t.test(`status${row.status}_leftInPlace`, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const probe = cancelProbe()
            const followed: string[] = []
            const { fetchFn, calls } = recordingFetch(
                redirectingAnswer(row.status, probe, followed, () =>
                    statusResponse(row.target)
                )
            )
            const { logger, records } = recordingLogger()

            const outcome = await createAndDeleteOwnedAlert(
                uiDeleteUnconfirmedPage(),
                BASE_URL,
                logger,
                { fetchFn, random: () => 0.5 }
            ).finally(() => {
                probe.settled = true
            })

            assert.deepEqual(
                {
                    outcome,
                    requests: calls.map((call) => `${call.method} ${call.url}`),
                    followed,
                    cancels: probe.cancels,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    outcome: {
                        kind: "left_in_place",
                        id: OWN_ID,
                        status: `${row.status}`,
                    },
                    requests: [DELETE_OWN],
                    followed: [],
                    cancels: ["while pending"],
                    messages: [
                        CREATED_OWN,
                        `warn: Alert [${OWN_ID}] left in place: ${row.status}`,
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

/** The configured origin, as the login step takes it from BASE_URL. */
const LOGIN_ORIGIN = BASE_URL.origin
/** Where a redirect left the browser instead. */
const ELSEWHERE_ORIGIN = "http://elsewhere.test"

/** A document of the page under test, as far as its location's origin. */
type FakeDocument = { location: { origin: string } }

function fakeDocument(origin: string): FakeDocument {
    return { location: { origin } }
}

/**
 * Makes doc the page's global document, the one a page function checks a
 * field's own document against, until the test ends.
 */
function showDocument(t: TestContext, doc: FakeDocument): void {
    Reflect.defineProperty(globalThis, "document", {
        value: doc,
        configurable: true,
        writable: true,
    })
    t.after(() => {
        Reflect.deleteProperty(globalThis, "document")
    })
}

/**
 * A text field as a page function finds it in the page. Like an
 * HTMLInputElement it has its value accessor on its prototype. Each write
 * through that accessor and each event dispatched on the field is recorded.
 */
class FakeField {
    isConnected = true
    ownerDocument: FakeDocument
    private readonly record: (entry: string) => void
    private text: string

    constructor(
        record: (entry: string) => void,
        ownerDocument: FakeDocument,
        text: string
    ) {
        this.record = record
        this.ownerDocument = ownerDocument
        this.text = text
    }

    get value(): string {
        return this.text
    }

    set value(text: string) {
        this.record(`set value ${text}`)
        this.text = text
    }

    dispatchEvent(event: Event): boolean {
        this.record(`${event.type} event${event.bubbles ? ", bubbling" : ""}`)
        return true
    }
}

/** The calls of a FakeElement that a test can hold or make fail. */
type ElementStage =
    | "focus"
    | "isIntersectingViewport"
    | "clickablePoint"
    | "evaluate"
    | "waitForNavigation"
    | "dispose"

/** Where a FakeElement's clickable point lies. */
const CLICK_POINT = { x: 12, y: 34 }

type FakeElementOptions = {
    /** prefixes each entry the element records */
    name?: string
    /** the trace the element records into, shared with other elements */
    trace?: string[]
    /** the document the element's field is in, by default at LOGIN_ORIGIN */
    document?: FakeDocument
    /** the field's text before the action */
    text?: string
    /** the intersection check from which on the element is in the viewport */
    intersectsFromCheck?: number
    /** stage -> the promise the stage answers with, settled by the test */
    held?: Partial<Record<ElementStage, Promise<unknown>>>
    /** stage -> the error the stage rejects with */
    failing?: Partial<Record<ElementStage, Error>>
}

/**
 * A Puppeteer element as BoundedPageActions drives it, over a FakeField. It
 * is in the viewport from its intersectsFromCheck-th check on, its clickable
 * point is CLICK_POINT, and its evaluate runs the page function on node, the
 * field unless a test replaces it. A held stage answers with the very promise
 * it is given, so the test decides when it settles, and a failing stage
 * rejects; a navigation wait otherwise ends with the next click. Each call is
 * recorded as it is made, so a dispatch shows in trace exactly when it was
 * sent.
 */
class FakeElement {
    readonly trace: string[]
    readonly field: FakeField
    /** what evaluate runs page functions on */
    node: object
    disposed = false
    /** resolves once the element is first focused, as an action starts */
    readonly focused: Promise<void>
    private readonly name: string | undefined
    private readonly intersectsFromCheck: number
    private readonly held: Partial<Record<ElementStage, Promise<unknown>>>
    private readonly failing: Partial<Record<ElementStage, Error>>
    private checks = 0
    private markFocused: () => void = () => undefined
    private navigated: () => void = () => undefined

    constructor(options: FakeElementOptions = {}) {
        this.name = options.name
        this.trace = options.trace ?? []
        this.intersectsFromCheck = options.intersectsFromCheck ?? 1
        this.held = options.held ?? {}
        this.failing = options.failing ?? {}
        this.field = new FakeField(
            (entry) => this.record(entry),
            options.document ?? fakeDocument(LOGIN_ORIGIN),
            options.text ?? ""
        )
        this.node = this.field
        this.focused = new Promise((resolve) => {
            this.markFocused = resolve
        })
    }

    focus(): Promise<void> {
        this.record("focus")
        this.markFocused()
        return this.answer("focus", undefined)
    }

    isIntersectingViewport(): Promise<boolean> {
        this.record("isIntersectingViewport")
        this.checks++
        return this.answer(
            "isIntersectingViewport",
            this.checks >= this.intersectsFromCheck
        )
    }

    clickablePoint(offset?: {
        x: number
        y: number
    }): Promise<typeof CLICK_POINT> {
        this.record(
            offset === undefined
                ? "clickablePoint"
                : `clickablePoint ${offset.x},${offset.y}`
        )
        return this.answer("clickablePoint", CLICK_POINT)
    }

    async select(...values: string[]): Promise<string[]> {
        this.record(`select ${values.join(",")}`)
        return values
    }

    evaluate(
        pageFunction: (node: object, ...args: unknown[]) => unknown,
        ...args: unknown[]
    ): Promise<unknown> {
        this.record("evaluate")
        const failure = this.failing.evaluate
        if (failure !== undefined) {
            return Promise.reject(failure)
        }
        // A page function that throws rejects, as in the page.
        return new Promise((resolve) =>
            resolve(pageFunction(this.node, ...args))
        )
    }

    get frame(): unknown {
        return {
            waitForNavigation: (): Promise<unknown> => {
                this.record("waitForNavigation")
                const navigation = new Promise((resolve) => {
                    this.navigated = () => resolve(null)
                })
                return this.answer("waitForNavigation", navigation)
            },
            page: () => ({
                mouse: {
                    click: (x: number, y: number, options?: ClickOptions) =>
                        this.click(x, y, options),
                },
            }),
        }
    }

    async dispose(): Promise<void> {
        this.disposed = true
        const failure = this.failing.dispose
        if (failure !== undefined) {
            throw failure
        }
    }

    /** The field's text. */
    text(): string {
        return this.field.value
    }

    asHandle(): ElementHandle {
        return this as unknown as ElementHandle
    }

    private async click(
        x: number,
        y: number,
        options?: ClickOptions
    ): Promise<void> {
        const shown = options === undefined ? "" : ` ${JSON.stringify(options)}`
        this.record(`mouse.click ${x},${y}${shown}`)
        this.navigated()
    }

    private answer<T>(stage: ElementStage, value: T): Promise<T> {
        const failure = this.failing[stage]
        if (failure !== undefined) {
            return Promise.reject(failure)
        }
        const held = this.held[stage]
        return held === undefined
            ? Promise.resolve(value)
            : (held as Promise<T>)
    }

    private record(entry: string): void {
        this.trace.push(
            this.name === undefined ? entry : `${this.name} ${entry}`
        )
    }
}

/** A handle over a fake Puppeteer element, printed as label. */
class FakeHandle implements IHandleWrapper {
    private readonly element: { asHandle(): ElementHandle }
    private readonly label: string

    constructor(element: { asHandle(): ElementHandle }, label: string) {
        this.element = element
        this.label = label
    }

    getHandle(): ElementHandle {
        return this.element.asHandle()
    }

    toString(): string {
        return this.label
    }
}

/**
 * The login screen: its username and password fields and its login button,
 * FakeElements in one document at LOGIN_ORIGIN that record into one trace.
 * As a Puppeteer page it fakes only the visible wait PageActions finds them
 * with.
 */
class FakeLoginPage {
    readonly trace: string[] = []
    readonly document = fakeDocument(LOGIN_ORIGIN)
    readonly username = this.element("username", "")
    readonly password = this.element("password", STALE_PASSWORD)
    private readonly elements = new Map<string, FakeElement>([
        [selectors.loginPage_username.value, this.username],
        [selectors.loginPage_password.value, this.password],
        [
            selectors.loginPage_loginButton.value,
            this.element("loginButton", ""),
        ],
    ])

    /** The element of an XPath query, recorded as found. */
    find(query: string): FakeElement {
        const element = this.elements.get(query)
        if (element === undefined) {
            throw new Error(`Unexpected selector [${query}]`)
        }
        this.trace.push(`find ${query}`)
        return element
    }

    async waitForSelector(query: string): Promise<ElementHandle> {
        return this.find(query).asHandle()
    }

    asPage(): Page {
        return this as unknown as Page
    }

    private element(name: string, text: string): FakeElement {
        return new FakeElement({
            name,
            trace: this.trace,
            document: this.document,
            text,
        })
    }
}

const LOGIN_SELECTORS = [
    selectors.loginPage_username,
    selectors.loginPage_password,
    selectors.loginPage_loginButton,
]

/**
 * The page actions the login step reaches through BoundedPageActions: a
 * getHandle over the fake login page's elements, and a shortDelay during
 * which onDelay can move the page, as a redirect would. Both are recorded in
 * the page's trace.
 */
class LoginInnerActions extends FakePageActions {
    private readonly login: FakeLoginPage
    private readonly onDelay: () => void

    constructor(login: FakeLoginPage, onDelay: () => void) {
        super({})
        this.login = login
        this.onDelay = onDelay
    }

    // The parameter is optional, so this override stays assignable to the
    // parameterless member of FakePageActions it replaces.
    override async getHandle(selector?: ISelector): Promise<IHandleWrapper> {
        const field = LOGIN_SELECTORS.find((known) => known === selector)
        if (field === undefined) {
            return unexpected(`getHandle ${String(selector)}`)
        }
        return new FakeHandle(this.login.find(field.value), field.toString())
    }

    override async shortDelay(): Promise<void> {
        this.login.trace.push("shortDelay")
        this.onDelay()
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

const USERNAME_FOUND = `find ${selectors.loginPage_username.value}`
const PASSWORD_FOUND = `find ${selectors.loginPage_password.value}`

/** What a field records as BoundedPageActions writes text into it. */
function writtenSteps(text: string, name?: string): string[] {
    const steps = [
        "focus",
        "isIntersectingViewport",
        "evaluate",
        `set value ${text}`,
        "input event, bubbling",
        "change event, bubbling",
    ]
    return steps.map((step) => (name === undefined ? step : `${name} ${step}`))
}

test("loginWithoutLoggingPassword_debugLogging_credentialsInNoEntry", async (t) => {
    const page = new FakeLoginPage()
    showDocument(t, page.document)
    const { logger, entries } = wholeEntryLogger()
    const pageActions = new PageActions(
        page.asPage(),
        logger,
        defineConfig({ disableDelay: true })
    )
    t.mock.method(pageActions, "shortDelay", async () => {
        page.trace.push("shortDelay")
    })

    await loginWithoutLoggingPassword(
        new BoundedPageActions(pageActions, logger),
        LOGIN_USER,
        BASE_URL
    )

    // loadgen-core's debug entries reach the logger, as its lookups show, yet
    // none carries either credential or the stale text the password replaced.
    // Each credential is written into its field in one step in the page, and
    // the login button is clicked once the navigation wait has started.
    assert.deepEqual(
        {
            trace: page.trace,
            fields: [page.username.text(), page.password.text()],
            credentialEntries: entries.filter(
                (entry) =>
                    entry.includes(LOGIN_USER.username) ||
                    entry.includes(LOGIN_USER.password) ||
                    entry.includes(STALE_PASSWORD)
            ),
            lookupEntries: entries.filter((entry) =>
                entry.includes("action [getHandle]")
            ).length,
        },
        {
            trace: [
                USERNAME_FOUND,
                ...writtenSteps(LOGIN_USER.username, "username"),
                "shortDelay",
                PASSWORD_FOUND,
                ...writtenSteps(LOGIN_USER.password, "password"),
                "shortDelay",
                `find ${selectors.loginPage_loginButton.value}`,
                "loginButton waitForNavigation",
                "loginButton focus",
                "loginButton isIntersectingViewport",
                "loginButton clickablePoint",
                `loginButton mouse.click ${CLICK_POINT.x},${CLICK_POINT.y}`,
            ],
            fields: [LOGIN_USER.username, LOGIN_USER.password],
            credentialEntries: [],
            lookupEntries: 3,
        }
    )
})

/**
 * What Puppeteer throws for an evaluate in a detached frame: its message
 * quotes the frame's URL, here a redirect target carrying a token.
 */
const detachedFrameError = new Error(
    `Execution context is not available in detached frame or worker "${ELSEWHERE_ORIGIN}/login?token=${SECRET}" (are you trying to evaluate?)`
)

/** The rejection for a document not verified at the configured origin. */
const ORIGIN_UNVERIFIED = {
    name: "Error",
    message: DOCUMENT_ORIGIN_UNVERIFIED,
    cause: undefined,
}

/** "resolved", or the rejection's name, message and cause. */
async function settledStep(step: Promise<void>): Promise<unknown> {
    return await step.then(
        () => "resolved",
        (error: unknown) =>
            error instanceof Error
                ? {
                      name: error.name,
                      message: error.message,
                      cause: error.cause,
                  }
                : `not an error object: ${String(error)}`
    )
}

/** The first steps of a field as BoundedPageActions refuses to write it. */
const refusedSteps = (name: string): string[] => [
    `${name} focus`,
    `${name} isIntersectingViewport`,
    `${name} evaluate`,
]

const loginRedirectRows: {
    name: string
    /** when the page moves to ELSEWHERE_ORIGIN, as a redirect would */
    redirect: "beforeLogin" | "duringFirstDelay"
    /** FakeLoginPage's trace up to the rejection */
    trace: string[]
    /** the username and password fields' text afterwards */
    fields: string[]
}[] = [
    {
        name: "redirectedBeforeUsername_writesNothing",
        redirect: "beforeLogin",
        trace: [USERNAME_FOUND, ...refusedSteps("username")],
        fields: ["", STALE_PASSWORD],
    },
    {
        name: "redirectedBetweenFields_writesNoPassword",
        redirect: "duringFirstDelay",
        trace: [
            USERNAME_FOUND,
            ...writtenSteps(LOGIN_USER.username, "username"),
            "shortDelay",
            PASSWORD_FOUND,
            ...refusedSteps("password"),
        ],
        fields: [LOGIN_USER.username, STALE_PASSWORD],
    },
]

test("loginWithoutLoggingPassword_documentLeftOrigin_rejectsWithNothingFurtherWritten", async (t) => {
    for (const row of loginRedirectRows) {
        await t.test(row.name, async (st) => {
            const page = new FakeLoginPage()
            showDocument(st, page.document)
            const redirect = (): void => {
                page.document.location.origin = ELSEWHERE_ORIGIN
            }
            if (row.redirect === "beforeLogin") {
                redirect()
            }
            const inner = new LoginInnerActions(page, () => {
                if (row.redirect === "duringFirstDelay") {
                    redirect()
                }
            })
            const { logger, entries } = wholeEntryLogger()

            const settled = await settledStep(
                loginWithoutLoggingPassword(
                    new BoundedPageActions(inner, logger),
                    LOGIN_USER,
                    BASE_URL
                )
            )

            // Neither origin reaches the error or any log entry, and nothing
            // after the refused field runs: no password, no login click.
            const exposed = [...entries, JSON.stringify(settled)].filter(
                (text) =>
                    text.includes(BASE_URL.hostname) ||
                    text.includes(new URL(ELSEWHERE_ORIGIN).hostname)
            )
            assert.deepEqual(
                {
                    settled,
                    trace: page.trace,
                    fields: [page.username.text(), page.password.text()],
                    exposed,
                },
                {
                    settled: ORIGIN_UNVERIFIED,
                    trace: row.trace,
                    fields: row.fields,
                    exposed: [],
                }
            )
        })
    }
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
/** The classified diagnostic that follows a failed API DELETE's outcome line. */
const DELETE_FAILED = `warn: Alert [${OWN_ID}] delete request failed: `
/**
 * The navigation link is gone from the shown navigation, as once the flag
 * turned off mid-visit.
 */
const FEATURE_LOST = { [NAV_KEY]: Number.POSITIVE_INFINITY }
/**
 * The whole navigation is gone, as once an error page replaced the layout:
 * nothing shows whether the flag changed.
 */
const NAVIGATION_GONE = {
    [HOME_NAV_KEY]: Number.POSITIVE_INFINITY,
    [NAV_KEY]: Number.POSITIVE_INFINITY,
}
/** The feature check that follows a failed page step: one DOM query. */
const FEATURE_CHECK = checkStep(FEATURE_LOSS_KEY, 1)
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
                `${DELETE_FAILED}reason [transport] error [TypeError]`,
            ],
            errors: ["networkError"],
        },
    },
    {
        name: "apiConnectionRefused_leftInPlaceErrorWithCauseCode",
        page: ownAlertPage({
            present: { [deletedKey(OWN_ID)]: Number.POSITIVE_INFINITY },
        }),
        respond: () => Promise.reject(refusedError),
        expected: {
            outcome: { kind: "left_in_place", id: OWN_ID, status: "error" },
            steps: UI_DELETE_UNCONFIRMED_STEPS,
            requests: [DELETE_OWN],
            messages: [
                CREATED_OWN,
                `warn: Alert [${OWN_ID}] left in place: error`,
                `${DELETE_FAILED}reason [transport] error [TypeError] cause [ECONNREFUSED]`,
            ],
            errors: ["TypeError"],
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
            steps: [...SUBMIT_STEPS, FEATURE_CHECK],
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
            steps: [...SUBMIT_STEPS, FEATURE_CHECK],
            requests: [],
            messages: [UNCONFIRMED],
            errors: ["pageError"],
        },
    },
    // The navigation is gone with the link, as on an error page: no loss is
    // verified, so the page step's own error propagates.
    {
        name: "submitClickThrows_navigationGone_logsOutcomeUnknownAndRejects",
        page: ownAlertPage({
            failingClick: SUBMIT_KEY,
            present: NAVIGATION_GONE,
        }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS, FEATURE_CHECK],
            requests: [],
            messages: [UNCONFIRMED],
            errors: ["pageError"],
        },
    },
    // The feature check fails too, as once the target is closed: no loss is
    // verified, so the page step's own error propagates.
    {
        name: "submitClickThrows_featureCheckFails_logsOutcomeUnknownAndRejects",
        page: ownAlertPage({
            failingClick: SUBMIT_KEY,
            failingCheck: FEATURE_LOSS_KEY,
        }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS, FEATURE_CHECK],
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
            steps: [...SUBMIT_STEPS.slice(0, -1), FEATURE_CHECK],
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
            steps: [...SUBMIT_STEPS.slice(0, -1), FEATURE_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "formInputThrows_navigationGone_rejectsWithoutOutcomeLine",
        page: ownAlertPage({
            failingInput: THRESHOLD_KEY,
            present: NAVIGATION_GONE,
        }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS.slice(0, -1), FEATURE_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "formInputThrows_featureCheckFails_rejectsWithoutOutcomeLine",
        page: ownAlertPage({
            failingInput: THRESHOLD_KEY,
            failingCheck: FEATURE_LOSS_KEY,
        }),
        rejects: pageError,
        expected: {
            steps: [...SUBMIT_STEPS.slice(0, -1), FEATURE_CHECK],
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

const RELEASE_FAILED_MESSAGE = "Instrument option handle not released"
/** The debug line of a failed handle release, with the error it carries. */
const RELEASE_FAILED = `debug: ${RELEASE_FAILED_MESSAGE}: error [Error] disposeError`

type OptionReadRow = {
    name: string
    options: FakeOptions
    expected: {
        /** the outcome's kind, or the rejection as describeError names it */
        settled: string
        /** presence checks of the options, one per probe of the value */
        checks: number
        /** option element and value property handles the probes acquired */
        acquired: number
        /** acquired handles not disposed exactly once */
        unreleased: string[]
        /** the failed releases logged, each with the error it carries */
        releaseFailures: string[]
    }
}

const TWO_OPTIONS = { emptyPolls: 0, values: [INSTRUMENT_ID, "other"] }

const optionReadRows: OptionReadRow[] = [
    {
        name: "valueRead_submittedEveryHandleReleased",
        options: TWO_OPTIONS,
        expected: {
            settled: "deleted",
            checks: 1,
            acquired: 3,
            unreleased: [],
            releaseFailures: [],
        },
    },
    {
        name: "blankValueThenValue_pollsOnEveryHandleReleased",
        options: { ...TWO_OPTIONS, blankReads: 2 },
        expected: {
            settled: "deleted",
            checks: 3,
            acquired: 9,
            unreleased: [],
            releaseFailures: [],
        },
    },
    {
        name: "blankValueEveryCheck_stopsAfter20EveryHandleReleased",
        options: { emptyPolls: 0, values: [""] },
        expected: {
            settled: "not_submitted",
            checks: 20,
            acquired: 40,
            unreleased: [],
            releaseFailures: [],
        },
    },
    // The read fails before or after its property handle exists; the error
    // still propagates as the lifecycle's own.
    ...[
        { failingRead: "getProperty" as const, acquired: 2 },
        { failingRead: "jsonValue" as const, acquired: 3 },
    ].map((row): OptionReadRow => ({
        name: `${row.failingRead}Throws_rejectsEveryHandleReleased`,
        options: { ...TWO_OPTIONS, failingRead: row.failingRead },
        expected: {
            settled: "rejects readError",
            checks: 1,
            acquired: row.acquired,
            unreleased: [],
            releaseFailures: [],
        },
    })),
    // Every dispose throws: each is still attempted and logged, and neither
    // the value read nor the read's error is replaced.
    {
        name: "disposeThrowsAfterValue_submittedFailuresLogged",
        options: { ...TWO_OPTIONS, failingDispose: true },
        expected: {
            settled: "deleted",
            checks: 1,
            acquired: 3,
            unreleased: [],
            releaseFailures: [RELEASE_FAILED, RELEASE_FAILED, RELEASE_FAILED],
        },
    },
    {
        name: "disposeThrowsAfterReadError_rejectsWithReadError",
        options: {
            ...TWO_OPTIONS,
            failingRead: "jsonValue",
            failingDispose: true,
        },
        expected: {
            settled: "rejects readError",
            checks: 1,
            acquired: 3,
            unreleased: [],
            releaseFailures: [RELEASE_FAILED, RELEASE_FAILED, RELEASE_FAILED],
        },
    },
]

test("createAndDeleteOwnedAlert_instrumentOptionRead_releasesEveryHandle", async (t) => {
    for (const row of optionReadRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn } = recordingFetch(() =>
                Promise.reject(new Error("Unexpected request"))
            )
            const { logger, records } = recordingLogger()
            const page = new FakePageActions({
                ...ownAlertPage(),
                options: row.options,
            })

            const settled = await createAndDeleteOwnedAlert(
                page,
                BASE_URL,
                logger,
                { fetchFn, random: () => 0.5 }
            ).then(
                (outcome) => outcome.kind,
                (error: unknown) => `rejects ${describeError(error)}`
            )

            assert.deepEqual(
                {
                    settled,
                    checks: page.count("isSelectorPresent", OPTION_KEY),
                    acquired: page.handles.acquired.length,
                    unreleased: page.handles.unreleased(),
                    releaseFailures: records
                        .filter((record) =>
                            record.message.startsWith(RELEASE_FAILED_MESSAGE)
                        )
                        .map(
                            (record) =>
                                `${record.level}: ${record.message} ${describeError(record.error)}`
                        ),
                },
                row.expected
            )
        })
    }
})

test("createAndDeleteOwnedAlert_apiErrorCarryingSecret_diagnosticClassifiedOnly", async (t) => {
    const rows: { name: string; error: unknown }[] = [
        {
            name: "secretInNameCauseAndMessage_unknownNameNoCause",
            error: Object.assign(
                new TypeError(
                    `fetch failed: http://user:${SECRET}@easytrade.test/`,
                    { cause: { code: SECRET_IDENTIFIER, message: SECRET } }
                ),
                { name: SECRET_IDENTIFIER }
            ),
        },
        {
            name: "nonErrorRejectionCarryingSecret_unknownName",
            error: `fetch failed: ${SECRET}`,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn } = recordingFetch(() => Promise.reject(row.error))
            const { logger, records } = recordingLogger()

            const outcome = await createAndDeleteOwnedAlert(
                uiDeleteUnconfirmedPage(),
                BASE_URL,
                logger,
                { fetchFn, random: () => 0.5 }
            )

            // Only the outcome line's error field holds the error itself; no
            // message carries its name, cause, message or url.
            assert.deepEqual(
                {
                    outcome,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    leaking: records
                        .map((record) => record.message)
                        .filter(
                            (message) =>
                                message.includes(SECRET) ||
                                message.includes(SECRET_IDENTIFIER)
                        ),
                },
                {
                    outcome: {
                        kind: "left_in_place",
                        id: OWN_ID,
                        status: "error",
                    },
                    messages: [
                        CREATED_OWN,
                        `warn: Alert [${OWN_ID}] left in place: error`,
                        `${DELETE_FAILED}reason [transport] error [unknown]`,
                    ],
                    leaking: [],
                }
            )
        })
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
            steps: [NAVIGATE_STEP, FEATURE_CHECK],
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
            steps: [NAVIGATE_STEP, FEATURE_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    // An error page replaced the layout while the flag may still be on, as
    // when the home page's data fails to load: the navigation error itself
    // propagates, and no outcome line claims the feature was lost.
    {
        name: "navigationThrows_navigationGone_rejectsWithoutOutcomeLine",
        page: ownAlertPage({
            failingNavigate: NAV_KEY,
            present: NAVIGATION_GONE,
        }),
        rejects: pageError,
        expected: {
            steps: [NAVIGATE_STEP, FEATURE_CHECK],
            requests: [],
            messages: [],
            errors: [],
        },
    },
    {
        name: "navigationThrows_featureCheckFails_rejectsWithoutOutcomeLine",
        page: ownAlertPage({
            failingNavigate: NAV_KEY,
            failingCheck: FEATURE_LOSS_KEY,
        }),
        rejects: pageError,
        expected: {
            steps: [NAVIGATE_STEP, FEATURE_CHECK],
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

/** One state of a page's DOM: query -> matching elements, or its error. */
type DomState = Record<string, number | Error>

/**
 * A Puppeteer page on which the navigation to the insights page fails: every
 * visible wait rejects with waitError. Its DOM passes through states in
 * order: each DOM query reads the current state, after which the page moves
 * on to the next one, staying at the last. A query rejects with its entry
 * when that is an error, or else finds that many matching elements. It fakes
 * only the two page members the real navigation and the feature check call.
 */
class NavigationFailurePage {
    readonly waitedFor: string[] = []
    readonly queried: string[] = []
    disposed = 0
    private readonly waitError: Error
    private readonly states: DomState[]

    constructor(waitError: Error, states: DomState[]) {
        this.waitError = waitError
        this.states = states
    }

    async waitForSelector(selector: string): Promise<never> {
        this.waitedFor.push(selector)
        throw this.waitError
    }

    async $$(selector: string): Promise<ElementHandle[]> {
        const state =
            this.states[Math.min(this.queried.length, this.states.length - 1)]
        this.queried.push(selector)
        const found = state?.[selector]
        if (found === undefined) {
            throw new Error(`Unexpected DOM query [${selector}]`)
        }
        if (found instanceof Error) {
            throw found
        }
        return Array.from({ length: found }, () => this.linkHandle())
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
const HOME_NAV_QUERY = selectors.navigation_homePage.value
/**
 * The feature check's one DOM query, spelled out: the home link, matched only
 * while no Portfolio Insights link is anywhere in the document.
 */
const FEATURE_LOSS_QUERY =
    '::-p-xpath(//a[@id="nav-home"][not(//a[@id="nav-portfolio-insights"])])'
/**
 * Pages as each of the three navigation queries finds them: one state
 * answers all three consistently, the feature-loss query matching the home
 * link only while the Portfolio Insights link is absent.
 */
const ERROR_PAGE: DomState = {
    [HOME_NAV_QUERY]: 0,
    [NAV_QUERY]: 0,
    [FEATURE_LOSS_QUERY]: 0,
}
const NAVIGATION_WITH_LINK: DomState = {
    [HOME_NAV_QUERY]: 1,
    [NAV_QUERY]: 1,
    [FEATURE_LOSS_QUERY]: 0,
}
const NAVIGATION_WITHOUT_LINK: DomState = {
    [HOME_NAV_QUERY]: 1,
    [NAV_QUERY]: 0,
    [FEATURE_LOSS_QUERY]: 1,
}

test("openPageAndRunOwnedAlert_navigationFailsOnRealPage_lossOnlyFromOneDomQuery", async (t) => {
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
        /** the DOM states the page passes through, one per query */
        states: DomState[]
        outcome?: OwnedAlertOutcome
        rejects?: Error
        /** the DOM queries the feature check runs, in order */
        queried: string[]
        messages: string[]
        /** the error objects the log entries carry */
        loggedErrors: Error[]
        disposed: number
    }[] = [
        {
            name: "targetClosed_rejectsWithNavigationError",
            waitError: closedOnWait,
            states: [
                {
                    [HOME_NAV_QUERY]: closedOnQuery,
                    [NAV_QUERY]: closedOnQuery,
                    [FEATURE_LOSS_QUERY]: closedOnQuery,
                },
            ],
            rejects: closedOnWait,
            queried: [FEATURE_LOSS_QUERY],
            messages: [CHECK_FAILED],
            loggedErrors: [closedOnQuery],
            disposed: 0,
        },
        // An error page replaced the layout, so neither link is in the DOM:
        // nothing shows the flag changed, and the navigation error propagates.
        {
            name: "navigationAbsentFromDom_rejectsWithNavigationError",
            waitError: waitTimedOut,
            states: [ERROR_PAGE],
            rejects: waitTimedOut,
            queried: [FEATURE_LOSS_QUERY],
            messages: [],
            loggedErrors: [],
            disposed: 0,
        },
        {
            name: "linkAbsentFromDom_notSubmitted",
            waitError: waitTimedOut,
            states: [NAVIGATION_WITHOUT_LINK],
            outcome: { kind: "not_submitted" },
            queried: [FEATURE_LOSS_QUERY],
            messages: [
                "warn: Portfolio insights page unavailable, no alert created",
            ],
            loggedErrors: [waitTimedOut],
            disposed: 1,
        },
        // A visible wait misses a link that is in the DOM but hidden; the DOM
        // query finds it, so no loss is verified.
        {
            name: "linkInDomButHidden_rejectsWithNavigationError",
            waitError: waitTimedOut,
            states: [NAVIGATION_WITH_LINK],
            rejects: waitTimedOut,
            queried: [FEATURE_LOSS_QUERY],
            messages: [],
            loggedErrors: [],
            disposed: 0,
        },
        // The protected page with its link gives way to an error page after
        // the first DOM query. Lookups of the home link and then of the
        // Portfolio Insights link would each read a different page and claim
        // a loss; the one query reads one page, so the error propagates.
        {
            name: "protectedPageReplacedByErrorPage_rejectsWithNavigationError",
            waitError: waitTimedOut,
            states: [NAVIGATION_WITH_LINK, ERROR_PAGE],
            rejects: waitTimedOut,
            queried: [FEATURE_LOSS_QUERY],
            messages: [],
            loggedErrors: [],
            disposed: 0,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const page = new NavigationFailurePage(row.waitError, row.states)
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
                    queried: row.queried,
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

/** How often BoundedPageActions checks intersection by default. */
const VIEWPORT_POLL_MS = 500
/** The control the bounded action cases act on. */
const BOUNDED_TARGET = selectors.portfolioInsightsPage_alertSubmit
/** The handle of BOUNDED_TARGET as targetHandle prints it. */
const TARGET_HANDLE = SUBMIT_KEY
/** A written or selected value that no error or log line may carry. */
const TYPED_VALUE = "typed-value-probe-7d1e"

/**
 * Page actions that record each call with its arguments and answer at once:
 * getHandle and getAllHandles with handle, every other member with a fixed
 * value. BoundedPageActions acts on elements itself, so the element actions
 * it wraps must never be called.
 */
class RecordingInnerActions implements IPageActions {
    readonly calls: string[] = []
    private readonly handle: IHandleWrapper

    constructor(handle: IHandleWrapper) {
        this.handle = handle
    }

    async setupPage(setup: PageSetup): Promise<void> {
        this.record("setupPage", setup.name)
    }

    async isSelectorPresent(selector: ISelector): Promise<boolean> {
        this.record("isSelectorPresent", selector)
        return true
    }

    async getHandle(selector: ISelector): Promise<IHandleWrapper> {
        this.record("getHandle", selector)
        return this.handle
    }

    async getAllHandles(selector: ISelector): Promise<IHandleWrapper[]> {
        this.record("getAllHandles", selector)
        return [this.handle]
    }

    async scrollIntoView(): Promise<void> {
        return unexpected("scrollIntoView")
    }

    async clickHandle(): Promise<void> {
        return unexpected("clickHandle")
    }

    async click(): Promise<void> {
        return unexpected("click")
    }

    async inputHandle(): Promise<void> {
        return unexpected("inputHandle")
    }

    async clearInput(handle: IHandleWrapper): Promise<void> {
        this.record("clearInput", handle)
    }

    async input(): Promise<void> {
        return unexpected("input")
    }

    async navigateHandle(): Promise<void> {
        return unexpected("navigateHandle")
    }

    async navigate(): Promise<void> {
        return unexpected("navigate")
    }

    async selectOptionHandle(): Promise<void> {
        return unexpected("selectOptionHandle")
    }

    async selectOption(): Promise<void> {
        return unexpected("selectOption")
    }

    async sleep(milliseconds: number, noiseProportion?: number): Promise<void> {
        this.record("sleep", milliseconds, noiseProportion)
    }

    async getProperty<Type = unknown>(
        selector: ISelector,
        propertyName: string
    ): Promise<Type> {
        this.record("getProperty", selector, propertyName)
        const value: unknown = "property"
        return value as Type
    }

    async getPropertyHandle<Type = unknown>(
        handle: IHandleWrapper,
        propertyName: string
    ): Promise<Type> {
        this.record("getPropertyHandle", handle, propertyName)
        const value: unknown = "property"
        return value as Type
    }

    async endDtSession(): Promise<void> {
        this.record("endDtSession")
    }

    async evaluate(func: unknown, ...args: unknown[]): Promise<unknown> {
        this.record("evaluate", func, ...args)
        return "evaluated"
    }

    async getInnerText(selector: ISelector): Promise<string> {
        this.record("getInnerText", selector)
        return "inner text"
    }

    async gotoPage(url: string): Promise<void> {
        this.record("gotoPage", url)
    }

    async standardDelay(): Promise<void> {
        this.record("standardDelay")
    }

    async shortDelay(): Promise<void> {
        this.record("shortDelay")
    }

    async longDelay(): Promise<void> {
        this.record("longDelay")
    }

    private record(name: string, ...args: unknown[]): void {
        const shown = args.filter((arg) => arg !== undefined).map(String)
        this.calls.push([name, ...shown].join(" "))
    }
}

/** A handle over element, by default one in the viewport at once. */
function targetHandle(element = new FakeElement()): FakeHandle {
    return new FakeHandle(element, TARGET_HANDLE)
}

/** The rejection as `<name>: <message>`, or the value it settled with. */
function describeSettled(settled: unknown): unknown {
    return settled instanceof Error
        ? `${settled.name}: ${settled.message}`
        : settled
}

/**
 * Ticks the mocked clock by ms in steps of the viewport poll, running the
 * microtasks each step queues, so a polling action really polls.
 */
async function advance(t: TestContext, ms: number): Promise<void> {
    for (let elapsed = 0; elapsed < ms; elapsed += VIEWPORT_POLL_MS) {
        t.mock.timers.tick(Math.min(VIEWPORT_POLL_MS, ms - elapsed))
        await drained()
    }
}

/** The viewport wait every element action starts with, its element in view. */
const IN_VIEW = ["focus", "isIntersectingViewport"]
/** A click at the element's clickable point, as the element records it. */
const CLICKED = [
    "clickablePoint",
    `mouse.click ${CLICK_POINT.x},${CLICK_POINT.y}`,
]
const ACQUIRED = [`getHandle ${SUBMIT_KEY}`]

/** One bounded action of a case, on its target or on handle. */
type BoundedRun = (
    actions: BoundedPageActions,
    handle: IHandleWrapper
) => Promise<void>

const boundedActionRows: {
    name: string
    /** the action as its TimeoutError names it */
    action: string
    run: BoundedRun
    /** the calls the wrapped page actions receive */
    inner: string[]
    /** what the element records as the action runs to its end */
    trace: string[]
    /** the stage the action dispatches after; unset when it dispatches none */
    lastStage?: ElementStage
    /** what lastStage answers with */
    answer?: unknown
}[] = [
    {
        name: "click",
        action: "click",
        run: (actions) => actions.click(BOUNDED_TARGET),
        inner: ACQUIRED,
        trace: [...IN_VIEW, ...CLICKED],
        lastStage: "clickablePoint",
        answer: CLICK_POINT,
    },
    {
        name: "clickHandle",
        action: "click",
        run: (actions, handle) =>
            actions.clickHandle(handle, { count: 2, offset: { x: 1, y: 2 } }),
        inner: [],
        trace: [
            ...IN_VIEW,
            "clickablePoint 1,2",
            `mouse.click ${CLICK_POINT.x},${CLICK_POINT.y} {"count":2,"offset":{"x":1,"y":2}}`,
        ],
        lastStage: "clickablePoint",
        answer: CLICK_POINT,
    },
    {
        name: "input",
        action: "input",
        run: (actions) => actions.input(BOUNDED_TARGET, TYPED_VALUE),
        inner: ACQUIRED,
        trace: writtenSteps(TYPED_VALUE),
        lastStage: "isIntersectingViewport",
        answer: true,
    },
    {
        name: "inputHandle",
        action: "input",
        run: (actions, handle) => actions.inputHandle(handle, TYPED_VALUE),
        inner: [],
        trace: writtenSteps(TYPED_VALUE),
        lastStage: "isIntersectingViewport",
        answer: true,
    },
    {
        name: "selectOption",
        action: "selectOption",
        run: (actions) => actions.selectOption(BOUNDED_TARGET, TYPED_VALUE),
        inner: ACQUIRED,
        trace: [...IN_VIEW, `select ${TYPED_VALUE}`],
        lastStage: "isIntersectingViewport",
        answer: true,
    },
    {
        name: "selectOptionHandle",
        action: "selectOption",
        run: (actions, handle) =>
            actions.selectOptionHandle(handle, TYPED_VALUE),
        inner: [],
        trace: [...IN_VIEW, `select ${TYPED_VALUE}`],
        lastStage: "isIntersectingViewport",
        answer: true,
    },
    {
        name: "navigate",
        action: "navigate",
        run: (actions) => actions.navigate(BOUNDED_TARGET),
        inner: ACQUIRED,
        trace: ["waitForNavigation", ...IN_VIEW, ...CLICKED],
        lastStage: "clickablePoint",
        answer: CLICK_POINT,
    },
    {
        name: "navigateHandle",
        action: "navigate",
        run: (actions, handle) => actions.navigateHandle(handle),
        inner: [],
        trace: ["waitForNavigation", ...IN_VIEW, ...CLICKED],
        lastStage: "clickablePoint",
        answer: CLICK_POINT,
    },
    {
        name: "scrollIntoView",
        action: "scrollIntoView",
        run: (actions, handle) => actions.scrollIntoView(handle),
        inner: [],
        trace: IN_VIEW,
    },
    {
        name: "enterCredential",
        action: "enterCredential",
        run: (actions, handle) =>
            actions.enterCredential(handle, TYPED_VALUE, LOGIN_ORIGIN),
        inner: [],
        trace: writtenSteps(TYPED_VALUE),
        lastStage: "isIntersectingViewport",
        answer: true,
    },
]

test("BoundedPageActions_elementAction_dispatchesOnElementWithinDeadline", async (t) => {
    for (const row of boundedActionRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const element = new FakeElement()
            showDocument(st, element.field.ownerDocument)
            const inner = new RecordingInnerActions(targetHandle(element))
            const { logger, records } = recordingLogger()
            const bounded = new BoundedPageActions(inner, logger)

            await row.run(bounded, targetHandle(element))
            // A deadline left armed would now fire and dispose the handle.
            await advance(st, PAGE_ACTION_TIMEOUT_MS)

            assert.deepEqual(
                {
                    calls: inner.calls,
                    trace: element.trace,
                    disposed: element.disposed,
                    messages: records.map((record) => record.message),
                },
                {
                    calls: row.inner,
                    trace: row.trace,
                    disposed: false,
                    messages: [],
                }
            )
        })
    }
})

/** The intersection checks element has recorded. */
function intersectionChecks(element: FakeElement): number {
    return element.trace.filter((step) => step === "isIntersectingViewport")
        .length
}

test("BoundedPageActions_elementEntersViewportLate_checksEachIntervalThenActs", async (t) => {
    const rows: {
        name: string
        interval: number
        run: BoundedRun
        /** what the action records once the element is in view */
        acts: string[]
    }[] = [
        {
            name: "clickDefaultInterval_checksEvery500ms",
            interval: VIEWPORT_POLL_MS,
            run: (actions, handle) => actions.clickHandle(handle),
            acts: CLICKED,
        },
        {
            name: "scrollIntoViewGivenInterval_checksEveryInterval",
            interval: 200,
            run: (actions, handle) => actions.scrollIntoView(handle, 200),
            acts: [],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const element = new FakeElement({ intersectsFromCheck: 3 })
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                recordingLogger().logger
            )
            let settled: unknown = STILL_PENDING
            const pending = row.run(bounded, targetHandle(element)).then(() => {
                settled = "resolved"
            })

            await drained()
            st.mock.timers.tick(row.interval - 1)
            await drained()
            const beforeInterval = intersectionChecks(element)
            st.mock.timers.tick(1)
            await drained()
            const atInterval = intersectionChecks(element)
            st.mock.timers.tick(row.interval)
            await pending

            assert.deepEqual(
                { beforeInterval, atInterval, settled, trace: element.trace },
                {
                    beforeInterval: 1,
                    atInterval: 2,
                    settled: "resolved",
                    trace: [
                        "focus",
                        "isIntersectingViewport",
                        "isIntersectingViewport",
                        "isIntersectingViewport",
                        ...row.acts,
                    ],
                }
            )
        })
    }
})

async function pageSetupProbe(): Promise<void> {}

test("BoundedPageActions_otherMember_delegatesUnchanged", async (t) => {
    const handle = targetHandle()
    const rows: {
        name: string
        call: (actions: IPageActions) => Promise<unknown>
        calls: string[]
        result?: unknown
    }[] = [
        {
            name: "setupPage",
            call: (actions) => actions.setupPage(pageSetupProbe),
            calls: ["setupPage pageSetupProbe"],
        },
        {
            name: "isSelectorPresent",
            call: (actions) => actions.isSelectorPresent(BOUNDED_TARGET),
            calls: [`isSelectorPresent ${SUBMIT_KEY}`],
            result: true,
        },
        {
            name: "getHandle",
            call: (actions) => actions.getHandle(BOUNDED_TARGET),
            calls: [`getHandle ${SUBMIT_KEY}`],
            result: handle,
        },
        {
            name: "getAllHandles",
            call: (actions) => actions.getAllHandles(BOUNDED_TARGET),
            calls: [`getAllHandles ${SUBMIT_KEY}`],
            result: [handle],
        },
        {
            name: "clearInput",
            call: (actions) => actions.clearInput(handle),
            calls: [`clearInput ${TARGET_HANDLE}`],
        },
        {
            name: "sleep",
            call: (actions) => actions.sleep(250, 0.5),
            calls: ["sleep 250 0.5"],
        },
        {
            name: "getProperty",
            call: (actions) => actions.getProperty(BOUNDED_TARGET, "value"),
            calls: [`getProperty ${SUBMIT_KEY} value`],
            result: "property",
        },
        {
            name: "getPropertyHandle",
            call: (actions) => actions.getPropertyHandle(handle, "value"),
            calls: [`getPropertyHandle ${TARGET_HANDLE} value`],
            result: "property",
        },
        {
            name: "endDtSession",
            call: (actions) => actions.endDtSession(),
            calls: ["endDtSession"],
        },
        {
            name: "evaluate",
            call: (actions) => actions.evaluate("1 + 1", 2, 3),
            calls: ["evaluate 1 + 1 2 3"],
            result: "evaluated",
        },
        {
            name: "getInnerText",
            call: (actions) => actions.getInnerText(BOUNDED_TARGET),
            calls: [`getInnerText ${SUBMIT_KEY}`],
            result: "inner text",
        },
        {
            name: "gotoPage",
            call: (actions) => actions.gotoPage(BASE_URL.href),
            calls: [`gotoPage ${BASE_URL.href}`],
        },
        {
            name: "standardDelay",
            call: (actions) => actions.standardDelay(),
            calls: ["standardDelay"],
        },
        {
            name: "shortDelay",
            call: (actions) => actions.shortDelay(),
            calls: ["shortDelay"],
        },
        {
            name: "longDelay",
            call: (actions) => actions.longDelay(),
            calls: ["longDelay"],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            const inner = new RecordingInnerActions(handle)
            const bounded = new BoundedPageActions(
                inner,
                recordingLogger().logger
            )

            const result = await row.call(bounded)

            assert.deepEqual(
                { calls: inner.calls, result },
                { calls: row.calls, result: row.result }
            )
        })
    }
})

/** The TimeoutError of action on BOUNDED_TARGET, as describeSettled shows it. */
const timedOut = (action: string): string =>
    `TimeoutError: Page action [${action}] on [${TARGET_HANDLE}] did not finish within [${PAGE_ACTION_TIMEOUT_MS}] ms`

test("BoundedPageActions_elementNeverInViewport_timeoutErrorAtDeadlineAndNothingDispatched", async (t) => {
    for (const row of boundedActionRows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const element = new FakeElement({
                intersectsFromCheck: Number.POSITIVE_INFINITY,
            })
            showDocument(st, element.field.ownerDocument)
            const { logger, records } = recordingLogger()
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                logger
            )
            let settled: unknown = STILL_PENDING
            const pending = row.run(bounded, targetHandle(element)).then(
                () => {
                    settled = "resolved"
                },
                (error: unknown) => {
                    settled = error
                }
            )

            // Lets the action acquire its handle and arm its deadline at 0.
            await drained()
            await advance(st, PAGE_ACTION_TIMEOUT_MS - 1)
            const beforeDeadline = settled
            await advance(st, 1)
            const atDeadline = describeSettled(settled)
            await advance(st, 10 * VIEWPORT_POLL_MS)
            await pending

            // One check every 500 ms up to the deadline and none after it;
            // nothing is dispatched, and the abandoned pause between two
            // checks ends with the action, so no line follows the deadline.
            assert.deepEqual(
                {
                    beforeDeadline,
                    atDeadline,
                    disposed: element.disposed,
                    steps: element.trace.filter(
                        (step) => step !== "isIntersectingViewport"
                    ),
                    checks: intersectionChecks(element),
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                },
                {
                    beforeDeadline: STILL_PENDING,
                    atDeadline: timedOut(row.action),
                    disposed: true,
                    steps: row.trace.filter(
                        (step) =>
                            step === "waitForNavigation" || step === "focus"
                    ),
                    checks: PAGE_ACTION_TIMEOUT_MS / VIEWPORT_POLL_MS,
                    messages: [],
                }
            )
        })
    }
})

/** Whether a held stage settles after the deadline or in the deadline's tick. */
const STAGE_RELEASES = ["afterDeadline", "inDeadlineTick"] as const

test("BoundedPageActions_stageSettlesAtOrAfterDeadline_timeoutErrorAndNothingDispatched", async (t) => {
    for (const row of boundedActionRows) {
        const lastStage = row.lastStage
        if (lastStage === undefined) {
            continue
        }
        for (const release of STAGE_RELEASES) {
            await t.test(`${row.name}_${release}`, async (st) => {
                st.mock.timers.enable({ apis: ["setTimeout"] })
                let releaseStage: () => void = () => undefined
                // In the deadline's tick, the stage settles through a timer
                // armed before the deadline's, so it runs just before it, and
                // the action resumes only after the deadline has passed.
                const held = new Promise((resolve) => {
                    if (release === "inDeadlineTick") {
                        setTimeout(
                            () => resolve(row.answer),
                            PAGE_ACTION_TIMEOUT_MS
                        )
                    } else {
                        releaseStage = () => resolve(row.answer)
                    }
                })
                const element = new FakeElement({ held: { [lastStage]: held } })
                showDocument(st, element.field.ownerDocument)
                const { logger, records } = recordingLogger()
                const bounded = new BoundedPageActions(
                    new RecordingInnerActions(targetHandle(element)),
                    logger
                )
                let settled: unknown = STILL_PENDING
                const pending = row.run(bounded, targetHandle(element)).then(
                    () => {
                        settled = "resolved"
                    },
                    (error: unknown) => {
                        settled = error
                    }
                )

                await drained()
                st.mock.timers.tick(PAGE_ACTION_TIMEOUT_MS - 1)
                await drained()
                const beforeDeadline = settled
                st.mock.timers.tick(1)
                await drained()
                const atDeadline = describeSettled(settled)
                releaseStage()
                await drained()
                await pending

                // The element records nothing after the held stage: no click,
                // selection or write was sent once the deadline had passed.
                const heldAt = row.trace.findIndex((step) =>
                    step.startsWith(lastStage)
                )
                assert.deepEqual(
                    {
                        beforeDeadline,
                        atDeadline,
                        trace: element.trace,
                        disposed: element.disposed,
                        messages: records.map(
                            (record) => `${record.level}: ${record.message}`
                        ),
                    },
                    {
                        beforeDeadline: STILL_PENDING,
                        atDeadline: timedOut(row.action),
                        trace: row.trace.slice(0, heldAt + 1),
                        disposed: true,
                        messages: [
                            `debug: Page action [${row.action}] on [${TARGET_HANDLE}] finished after its deadline`,
                        ],
                    }
                )
            })
        }
    }
})

test("BoundedPageActions_actionFails_disposesHandleAndRethrows", async (t) => {
    const disposeFailure = new Error("Protocol error: Target closed")
    const notDisposed = (action: string): string =>
        `debug: Page action [${action}] on [${TARGET_HANDLE}] handle not disposed: error [Error]`
    const unavailable: IHandleWrapper = {
        getHandle: () => {
            throw disposeFailure
        },
        toString: () => TARGET_HANDLE,
    }
    const rows: {
        name: string
        run: BoundedRun
        failing?: FakeElementOptions["failing"]
        /** a handle whose element cannot be had, instead of the element's */
        handle?: IHandleWrapper
        rethrown: Error
        disposed: boolean
        messages: string[]
        loggedErrors: Error[]
    }[] = [
        {
            name: "clickStageFails_disposedNothingLogged",
            run: (actions, handle) => actions.clickHandle(handle),
            failing: { clickablePoint: pageError },
            rethrown: pageError,
            disposed: true,
            messages: [],
            loggedErrors: [],
        },
        // The click is sent; the navigation it was to cause fails.
        {
            name: "navigationFails_disposedNothingLogged",
            run: (actions, handle) => actions.navigateHandle(handle),
            failing: { waitForNavigation: pageError },
            rethrown: pageError,
            disposed: true,
            messages: [],
            loggedErrors: [],
        },
        {
            name: "disposeRejects_failureLoggedAtDebug",
            run: (actions, handle) => actions.clickHandle(handle),
            failing: { clickablePoint: pageError, dispose: disposeFailure },
            rethrown: pageError,
            disposed: true,
            messages: [notDisposed("click")],
            loggedErrors: [disposeFailure],
        },
        {
            name: "elementUnavailable_rethrownAndLoggedAtDebug",
            run: (actions, handle) => actions.clickHandle(handle),
            handle: unavailable,
            rethrown: disposeFailure,
            disposed: false,
            messages: [notDisposed("click")],
            loggedErrors: [disposeFailure],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const element = new FakeElement({ failing: row.failing })
            const handle = row.handle ?? targetHandle(element)
            const { logger, records } = recordingLogger()
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(handle),
                logger
            )

            const thrown = await row.run(bounded, handle).then(
                () => "resolved",
                (error: unknown) => error
            )
            await drained()

            assert.deepEqual(
                {
                    rethrown: thrown === row.rethrown,
                    disposed: element.disposed,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    loggedErrors: records
                        .map((record) => record.error)
                        .filter((error) => error !== undefined)
                        .map(
                            (error, index) => error === row.loggedErrors[index]
                        ),
                },
                {
                    rethrown: true,
                    disposed: row.disposed,
                    messages: row.messages,
                    loggedErrors: row.loggedErrors.map(() => true),
                }
            )
        })
    }
})

test("BoundedPageActions_abandonedStageEndsLate_loggedAtDebug", async (t) => {
    const rows: {
        name: string
        action: string
        run: BoundedRun
        /** the stage held past the deadline, and what it answers with */
        stage: ElementStage
        answer: unknown
        ends: "resolves" | "rejects"
        messages: string[]
        /** the error objects the entries carry, as describeError names them */
        errors: string[]
    }[] = [
        {
            name: "clickStageResolvesLate_finishLogged",
            action: "click",
            run: (actions, handle) => actions.clickHandle(handle),
            stage: "clickablePoint",
            answer: CLICK_POINT,
            ends: "resolves",
            messages: [
                `debug: Page action [click] on [${TARGET_HANDLE}] finished after its deadline`,
            ],
            errors: [],
        },
        {
            name: "clickStageRejectsLate_failureLoggedWithError",
            action: "click",
            run: (actions, handle) => actions.clickHandle(handle),
            stage: "clickablePoint",
            answer: CLICK_POINT,
            ends: "rejects",
            messages: [
                `debug: Page action [click] on [${TARGET_HANDLE}] failed after its deadline: error [Error]`,
            ],
            errors: ["readError"],
        },
        // A credential field's stage fails with errors that can quote the
        // untrusted document's URL, so only the error's name is logged.
        {
            name: "credentialStageRejectsLate_failureLoggedByNameOnly",
            action: "enterCredential",
            run: (actions, handle) =>
                actions.enterCredential(handle, TYPED_VALUE, LOGIN_ORIGIN),
            stage: "isIntersectingViewport",
            answer: true,
            ends: "rejects",
            messages: [
                `debug: Page action [enterCredential] on [${TARGET_HANDLE}] failed after its deadline: error [Error]`,
            ],
            errors: [],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            let end: () => void = () => undefined
            const held = new Promise((resolve, reject) => {
                end = () =>
                    row.ends === "resolves"
                        ? resolve(row.answer)
                        : reject(readError)
            })
            const element = new FakeElement({ held: { [row.stage]: held } })
            const { logger, records } = recordingLogger()
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                logger
            )

            const settled = row.run(bounded, targetHandle(element)).then(
                () => "resolved",
                (error: unknown) => describeSettled(error)
            )
            await drained()
            st.mock.timers.tick(PAGE_ACTION_TIMEOUT_MS)
            const atDeadline = await settled
            end()
            await drained()

            assert.deepEqual(
                {
                    atDeadline,
                    messages: records.map(
                        (record) => `${record.level}: ${record.message}`
                    ),
                    errors: records
                        .map((record) => record.error)
                        .filter((error) => error !== undefined)
                        .map(describeError),
                },
                {
                    atDeadline: timedOut(row.action),
                    messages: row.messages,
                    errors: row.errors,
                }
            )
        })
    }
})

test("BoundedPageActions_navigateAbandonsNavigationWait_noUnhandledRejection", async (t) => {
    const rows: {
        name: string
        failing?: FakeElementOptions["failing"]
        held?: FakeElementOptions["held"]
        settled: unknown
    }[] = [
        {
            name: "clickFails_rejectsWithClickError",
            failing: { clickablePoint: pageError },
            settled: `Error: ${pageError.message}`,
        },
        {
            name: "deadlinePassesBeforeClick_rejectsWithTimeoutError",
            held: { clickablePoint: new Promise(() => undefined) },
            settled: timedOut("navigate"),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const unhandled: unknown[] = []
            const onUnhandled = (reason: unknown): void => {
                unhandled.push(reason)
            }
            process.on("unhandledRejection", onUnhandled)
            st.after(() => {
                process.off("unhandledRejection", onUnhandled)
            })
            let failNavigation: (error: Error) => void = () => undefined
            const navigation = new Promise((_resolve, reject) => {
                failNavigation = reject
            })
            const element = new FakeElement({
                failing: row.failing,
                held: { ...row.held, waitForNavigation: navigation },
            })
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                recordingLogger().logger
            )

            const pending = bounded.navigateHandle(targetHandle(element)).then(
                () => "resolved",
                (error: unknown) => describeSettled(error)
            )
            await drained()
            st.mock.timers.tick(PAGE_ACTION_TIMEOUT_MS)
            const settled = await pending
            // Puppeteer's own navigation timeout ends the abandoned wait.
            failNavigation(new Error("Navigation timeout of 30000 ms exceeded"))
            await drained()

            assert.deepEqual(
                { settled, unhandled },
                { settled: row.settled, unhandled: [] }
            )
        })
    }
})

test("BoundedPageActions_inputHandle_writesThroughPrototypeValueSetter", async (t) => {
    const rows: {
        name: string
        /** changes the element before the write */
        prepare: (element: FakeElement) => void
        settled: unknown
        trace: string[]
    }[] = [
        // React tracks a controlled input through a value setter on the
        // element itself, which an assignment would run, hiding the change.
        {
            name: "reactTrackedField_ownSetterBypassed",
            prepare: (element) => {
                Object.defineProperty(element.field, "value", {
                    configurable: true,
                    get: () => "tracked",
                    set: (text: string) => {
                        element.trace.push(`own setter ${text}`)
                    },
                })
            },
            settled: "resolved",
            trace: writtenSteps(TYPED_VALUE),
        },
        {
            name: "elementWithoutValue_rejectsWritingNothing",
            prepare: (element) => {
                element.node = {
                    isConnected: true,
                    dispatchEvent: (): boolean => {
                        element.trace.push("event")
                        return true
                    },
                }
            },
            settled: "Error: Element has no value to write",
            trace: [...IN_VIEW, "evaluate"],
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async () => {
            const element = new FakeElement()
            row.prepare(element)
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                recordingLogger().logger
            )

            const settled = await bounded
                .inputHandle(targetHandle(element), TYPED_VALUE)
                .then(
                    () => "resolved",
                    (error: unknown) => describeSettled(error)
                )

            assert.deepEqual(
                { settled, trace: element.trace },
                { settled: row.settled, trace: row.trace }
            )
        })
    }
})

/** What a field records as enterCredential refuses to write into it. */
const CREDENTIAL_REFUSED = [...IN_VIEW, "evaluate"]

const credentialRows: {
    name: string
    /** the origin of the document the field and the page show */
    documentOrigin: string
    /** the origin enterCredential requires; LOGIN_ORIGIN when unset */
    origin?: string
    /** changes the element before the write */
    prepare?: (element: FakeElement) => void
    failing?: FakeElementOptions["failing"]
    settled: unknown
    trace: string[]
}[] = [
    {
        name: "documentAtOrigin_written",
        documentOrigin: LOGIN_ORIGIN,
        settled: "resolved",
        trace: writtenSteps(TYPED_VALUE),
    },
    {
        name: "otherHost_nothingWritten",
        documentOrigin: ELSEWHERE_ORIGIN,
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    {
        name: "otherPort_nothingWritten",
        documentOrigin: "http://easytrade.test:8080",
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    {
        name: "otherScheme_nothingWritten",
        documentOrigin: "https://easytrade.test",
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    {
        name: "opaqueDocument_nothingWritten",
        documentOrigin: "null",
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    // Every about:blank or data: document has the opaque origin, so an
    // expected opaque origin matches none of them: nothing is even waited for.
    {
        name: "opaqueExpectedOrigin_refusedBeforeAnyStage",
        documentOrigin: "null",
        origin: "null",
        settled: ORIGIN_UNVERIFIED,
        trace: [],
    },
    {
        name: "fieldDetached_nothingWritten",
        documentOrigin: LOGIN_ORIGIN,
        prepare: (element) => {
            element.field.isConnected = false
        },
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    // The field's own document is at the origin, but it is not the document
    // of the frame the write runs in.
    {
        name: "fieldInOtherDocument_nothingWritten",
        documentOrigin: LOGIN_ORIGIN,
        prepare: (element) => {
            element.field.ownerDocument = fakeDocument(LOGIN_ORIGIN)
        },
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    {
        name: "fieldWithoutValue_nothingWritten",
        documentOrigin: LOGIN_ORIGIN,
        prepare: (element) => {
            element.node = {
                isConnected: true,
                ownerDocument: element.field.ownerDocument,
                dispatchEvent: (): boolean => true,
            }
        },
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    // A failure quotes the frame's URL, so it is not passed on as cause.
    {
        name: "writeFails_rejectsWithoutWriteError",
        documentOrigin: LOGIN_ORIGIN,
        failing: { evaluate: detachedFrameError },
        settled: ORIGIN_UNVERIFIED,
        trace: CREDENTIAL_REFUSED,
    },
    {
        name: "focusFails_rejectsWithoutFocusError",
        documentOrigin: LOGIN_ORIGIN,
        failing: { focus: detachedFrameError },
        settled: ORIGIN_UNVERIFIED,
        trace: ["focus"],
    },
]

test("BoundedPageActions_enterCredential_writesOnlyIntoFieldOfDocumentAtOrigin", async (t) => {
    for (const row of credentialRows) {
        await t.test(row.name, async (st) => {
            const doc = fakeDocument(row.documentOrigin)
            const element = new FakeElement({
                document: doc,
                text: STALE_PASSWORD,
                failing: row.failing,
            })
            row.prepare?.(element)
            showDocument(st, doc)
            const { logger, entries } = wholeEntryLogger()
            const bounded = new BoundedPageActions(
                new RecordingInnerActions(targetHandle(element)),
                logger
            )

            const settled = await settledStep(
                bounded.enterCredential(
                    targetHandle(element),
                    TYPED_VALUE,
                    row.origin ?? LOGIN_ORIGIN
                )
            )
            await drained()

            // No origin, no URL a failure quotes and not the credential
            // reaches the error or a log entry. A refused field keeps its
            // text, and its handle is released.
            const written = row.settled === "resolved"
            const exposed = [...entries, JSON.stringify(settled)].filter(
                (text) =>
                    text.includes(BASE_URL.hostname) ||
                    text.includes(new URL(ELSEWHERE_ORIGIN).hostname) ||
                    text.includes(SECRET) ||
                    text.includes(TYPED_VALUE)
            )
            assert.deepEqual(
                {
                    settled,
                    trace: element.trace,
                    text: element.text(),
                    disposed: element.disposed,
                    exposed,
                },
                {
                    settled: row.settled,
                    trace: row.trace,
                    text: written ? TYPED_VALUE : STALE_PASSWORD,
                    disposed: !written,
                    exposed: [],
                }
            )
        })
    }
})

test("BoundedPageActions_deadline_acceptedOnlyInTimerRange", async (t) => {
    const rows: { name: string; timeoutMs: number; accepted: boolean }[] = [
        { name: "zero_rangeError", timeoutMs: 0, accepted: false },
        { name: "negative_rangeError", timeoutMs: -1, accepted: false },
        { name: "fraction_rangeError", timeoutMs: 1.5, accepted: false },
        {
            name: "notANumber_rangeError",
            timeoutMs: Number.NaN,
            accepted: false,
        },
        {
            name: "infinite_rangeError",
            timeoutMs: Number.POSITIVE_INFINITY,
            accepted: false,
        },
        {
            name: "aboveTimerMaximum_rangeError",
            timeoutMs: 2_147_483_648,
            accepted: false,
        },
        { name: "oneMillisecond_accepted", timeoutMs: 1, accepted: true },
        {
            name: "timerMaximum_accepted",
            timeoutMs: 2_147_483_647,
            accepted: true,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const construct = () =>
                new BoundedPageActions(
                    new RecordingInnerActions(targetHandle()),
                    recordingLogger().logger,
                    row.timeoutMs
                )

            const outcome = (() => {
                try {
                    construct()
                    return "accepted"
                } catch (error) {
                    return error instanceof RangeError
                        ? "RangeError"
                        : describeSettled(error)
                }
            })()

            assert.equal(outcome, row.accepted ? "accepted" : "RangeError")
        })
    }
})

/**
 * A Puppeteer element, in the viewport at once, whose dispatches run the
 * FakePageActions action of its selector: a mouse click runs its click, a
 * selection its selectOption and a write in the page its input.
 */
class RoutedElement {
    private readonly page: FakePageActions
    private readonly selector: ISelector

    constructor(page: FakePageActions, selector: ISelector) {
        this.page = page
        this.selector = selector
    }

    async focus(): Promise<void> {}

    async isIntersectingViewport(): Promise<boolean> {
        return true
    }

    async clickablePoint(): Promise<typeof CLICK_POINT> {
        return CLICK_POINT
    }

    async select(option: string): Promise<string[]> {
        await this.page.selectOption(this.selector, option)
        return [option]
    }

    async evaluate(_pageFunction: unknown, text: string): Promise<boolean> {
        await this.page.input(this.selector, text)
        return true
    }

    get frame(): unknown {
        return {
            page: () => ({
                mouse: { click: () => this.page.click(this.selector) },
            }),
        }
    }

    async dispose(): Promise<void> {}

    asHandle(): ElementHandle {
        return this as unknown as ElementHandle
    }
}

/**
 * FakePageActions behind BoundedPageActions: getHandle hands out, for each
 * selector, a RoutedElement that runs the FakePageActions action of that
 * selector, except for the selector of stalledKey, whose element never
 * intersects the viewport.
 */
class StallingPageActions extends FakePageActions {
    readonly stalled = new FakeElement({
        intersectsFromCheck: Number.POSITIVE_INFINITY,
    })
    private readonly stalledKey: string

    constructor(page: FakePage, stalledKey: string) {
        super(page)
        this.stalledKey = stalledKey
    }

    // The parameter is optional, so this override stays assignable to the
    // parameterless member of FakePageActions it replaces.
    override async getHandle(selector?: ISelector): Promise<IHandleWrapper> {
        if (selector === undefined) {
            return unexpected("getHandle without a selector")
        }
        const key = selector.toString()
        const element =
            key === this.stalledKey
                ? this.stalled
                : new RoutedElement(this, selector)
        return new FakeHandle(element, key)
    }
}

const TYPE_KEY = selectors.portfolioInsightsPage_alertType.toString()

test("createAndDeleteOwnedAlert_boundedActionNeverInViewport_outcome", async (t) => {
    const rows: {
        name: string
        stalledKey: string
        deleteStatus?: number
        expected: {
            /** the outcome, or the rejection as `<name>: <message>` */
            settled: unknown
            /** the page actions that ran, in order, without checks and reads */
            actions: string[]
            requests: string[]
            messages: string[]
            errors: string[]
        }
    }[] = [
        // The id is known, so the cleanup still reaches the API fallback.
        {
            name: "ownRowDeleteStalls_deletedViaApi",
            stalledKey: rowDeleteKey(OWN_ID),
            deleteStatus: 204,
            expected: {
                settled: { kind: "deleted", id: OWN_ID, via: "api" },
                actions: submitSteps(MARKER),
                requests: [DELETE_OWN],
                messages: [
                    CREATED_OWN,
                    UI_DELETE_FAILED,
                    `info: Deleted alert [${OWN_ID}] via api`,
                ],
                errors: ["TimeoutError"],
            },
        },
        {
            name: "formSelectStalls_rejectsWithNothingSubmitted",
            stalledKey: TYPE_KEY,
            expected: {
                settled: `TimeoutError: Page action [selectOption] on [${TYPE_KEY}] did not finish within [${PAGE_ACTION_TIMEOUT_MS}] ms`,
                actions: [],
                requests: [],
                messages: [],
                errors: [],
            },
        },
        {
            name: "submitClickStalls_logsOutcomeUnknownAndRejects",
            stalledKey: SUBMIT_KEY,
            expected: {
                settled: `TimeoutError: Page action [click] on [${SUBMIT_KEY}] did not finish within [${PAGE_ACTION_TIMEOUT_MS}] ms`,
                actions: submitSteps(MARKER).slice(0, -1),
                requests: [],
                messages: [UNCONFIRMED],
                errors: ["TimeoutError"],
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, async (st) => {
            st.mock.timers.enable({ apis: ["setTimeout"] })
            const { fetchFn, calls } = recordingFetch(() =>
                row.deleteStatus === undefined
                    ? Promise.reject(new Error("Unexpected request"))
                    : statusResponse(row.deleteStatus)
            )
            const { logger, records } = recordingLogger()
            const page = new StallingPageActions(ownAlertPage(), row.stalledKey)
            // The wrapper's own debug lines go to a logger of their own.
            const bounded = new BoundedPageActions(
                page,
                recordingLogger().logger
            )
            let settled: unknown = STILL_PENDING
            const pending = createAndDeleteOwnedAlert(
                bounded,
                BASE_URL,
                logger,
                { fetchFn, random: () => 0.5 }
            ).then(
                (outcome) => {
                    settled = outcome
                },
                (error: unknown) => {
                    settled = describeSettled(error)
                }
            )

            await Promise.race([page.stalled.focused, pending])
            st.mock.timers.tick(PAGE_ACTION_TIMEOUT_MS - 1)
            await drained()
            const beforeDeadline = settled
            st.mock.timers.tick(1)
            await pending

            const observation = observed(page, calls, records)
            assert.deepEqual(
                {
                    beforeDeadline,
                    settled,
                    actions: observation.steps.filter(
                        (step) =>
                            !step.startsWith("check ") &&
                            !step.startsWith("read ")
                    ),
                    requests: observation.requests,
                    messages: observation.messages,
                    errors: observation.errors,
                },
                { beforeDeadline: STILL_PENDING, ...row.expected }
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
