import "@testing-library/jest-dom/vitest"
import {
    getPortfolioInsightsFlag,
    PortfolioInsightsFlagId,
} from "../../api/featureFlags"

// Status, validity and logging cases of the fail-closed flag read. The flag
// service's reply is untrusted, so no part of it may reach the browser log.

type Respond = (init: RequestInit | undefined) => Promise<Response>

const READ_FAILED = "[getPortfolioInsightsFlag] flag read failed"
const INVALID_RESPONSE = "[getPortfolioInsightsFlag] invalid flag response"

// Short and at the start of each body: V8 quotes only about ten characters
// around the failing position in a JSON parse error's message.
const LEAK_MARKER = "LEAK7f3a"

const enabledFlag = {
    id: PortfolioInsightsFlagId,
    enabled: true,
    name: "Portfolio insights",
    description: "Demo feature",
    isModifiable: true,
    tag: "feature",
}

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

function textResponse(text: string, status = 200): Response {
    return new Response(text, {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

/** Never settles on its own; rejects with AbortError once its signal aborts. */
function hangUntilAborted(init: RequestInit | undefined): Promise<Response> {
    return new Promise<Response>((_, reject) => {
        const signal = init?.signal
        const abort = (): void =>
            reject(new DOMException("Aborted", "AbortError"))
        if (signal?.aborted) {
            abort()
            return
        }
        signal?.addEventListener("abort", abort, { once: true })
    })
}

function stubFetch(respond: Respond) {
    return vi
        .spyOn(window, "fetch")
        .mockImplementation((_input, init) => respond(init))
}

function requestUrl(input: RequestInfo | URL): string {
    if (typeof input === "string") {
        return input
    }
    return input instanceof URL ? input.href : input.url
}

function respondWith(response: Response): Respond {
    return () => Promise.resolve(response)
}

function spyConsole() {
    return {
        error: vi.spyOn(console, "error").mockImplementation(() => undefined),
        warn: vi.spyOn(console, "warn").mockImplementation(() => undefined),
        info: vi.spyOn(console, "info").mockImplementation(() => undefined),
    }
}

type ConsoleSpies = ReturnType<typeof spyConsole>

/** Deep text of a logged value, including the non-enumerable error fields. */
function serialise(value: unknown): string {
    const text = JSON.stringify(value, (_key, item: unknown) =>
        item instanceof Error || item instanceof DOMException
            ? {
                  ...item,
                  name: item.name,
                  message: item.message,
                  stack: item.stack,
                  cause: item.cause,
              }
            : item
    )
    return text ?? String(value)
}

/** Every argument of every console.error, warn and info call, as text. */
function loggedText(spies: ConsoleSpies): string {
    const args: unknown[] = [spies.error, spies.warn, spies.info].flatMap(
        (spy): unknown[] => spy.mock.calls.flat()
    )
    return args.map(serialise).join("\n")
}

/** A logged diagnostic with its error reduced to its name and cause flag. */
function withErrorShape(diagnostic: unknown): unknown {
    if (typeof diagnostic !== "object" || diagnostic === null) {
        return diagnostic
    }
    const { error } = diagnostic as { error?: unknown }
    return error instanceof Error || error instanceof DOMException
        ? {
              ...diagnostic,
              error: { name: error.name, hasCause: "cause" in error },
          }
        : diagnostic
}

const FLAG_RESPONSE_ERROR = { name: "FlagResponseError", hasCause: false }

afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
})

it.each([201, 202, 203, 206])(
    "getPortfolioInsightsFlag_non200Success_returnsFalse (%i)",
    async (status) => {
        const spies = spyConsole()
        stubFetch(respondWith(jsonResponse(enabledFlag, status)))

        const enabled = await getPortfolioInsightsFlag()

        expect({ enabled, logged: spies.error.mock.calls }).toEqual({
            enabled: false,
            logged: [
                [
                    READ_FAILED,
                    expect.objectContaining({ reason: "status", status }),
                ],
            ],
        })
    }
)

it("getPortfolioInsightsFlag_exact200Enabled_returnsTrue", async () => {
    const spies = spyConsole()
    stubFetch(respondWith(jsonResponse(enabledFlag)))

    const enabled = await getPortfolioInsightsFlag()

    expect({ enabled, errors: spies.error.mock.calls.length }).toEqual({
        enabled: true,
        errors: 0,
    })
})

it("getPortfolioInsightsFlag_exact200Disabled_returnsFalseAndLogsInfo", async () => {
    const spies = spyConsole()
    stubFetch(respondWith(jsonResponse({ ...enabledFlag, enabled: false })))

    const enabled = await getPortfolioInsightsFlag()

    expect({
        enabled,
        info: spies.info.mock.calls,
        errors: spies.error.mock.calls.length,
    }).toEqual({
        enabled: false,
        info: [["[getPortfolioInsightsFlag] flag disabled"]],
        errors: 0,
    })
})

it("getPortfolioInsightsFlag_request_usesHyphenatedFlagPath", async () => {
    spyConsole()
    const fetchSpy = stubFetch(respondWith(jsonResponse(enabledFlag)))

    await getPortfolioInsightsFlag()

    expect(fetchSpy.mock.calls.map(([input]) => requestUrl(input))).toEqual([
        `${window.location.origin}/feature-flag-service/v1/flags/portfolio-insights-enabled`,
    ])
})

const failures: {
    label: string
    read: () => Promise<boolean>
    message: string
    diagnostic: Record<string, unknown>
}[] = [
    {
        label: "404",
        read: () => {
            stubFetch(respondWith(jsonResponse({ error: "not found" }, 404)))
            return getPortfolioInsightsFlag()
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "status",
            status: 404,
            error: { name: "ApiError", hasCause: false },
        },
    },
    {
        label: "network error",
        read: () => {
            stubFetch(() => Promise.reject(new TypeError("Failed to fetch")))
            return getPortfolioInsightsFlag()
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "network",
            error: { name: "TypeError", hasCause: false },
        },
    },
    {
        label: "unrecognised error",
        read: () => {
            stubFetch(() => Promise.reject(new RangeError("unexpected")))
            return getPortfolioInsightsFlag()
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "error",
            errorName: "RangeError",
            error: FLAG_RESPONSE_ERROR,
        },
    },
    {
        label: "non-Error thrown value",
        read: () => {
            stubFetch(() => {
                throw "unexpected"
            })
            return getPortfolioInsightsFlag()
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "error",
            errorName: "string",
            error: FLAG_RESPONSE_ERROR,
        },
    },
    {
        label: "hung read aborted at the 2 s deadline",
        read: async () => {
            vi.useFakeTimers()
            stubFetch(hangUntilAborted)
            const pending = getPortfolioInsightsFlag()
            await vi.advanceTimersByTimeAsync(2000)
            return pending
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "timeout",
            error: { name: "AbortError", hasCause: false },
        },
    },
    {
        label: "caller signal aborted",
        read: () => {
            stubFetch(hangUntilAborted)
            const caller = new AbortController()
            const pending = getPortfolioInsightsFlag(caller.signal)
            caller.abort()
            return pending
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "aborted",
            error: { name: "AbortError", hasCause: false },
        },
    },
    {
        label: "malformed JSON on 200",
        read: () => {
            stubFetch(respondWith(textResponse("<html>not json</html>")))
            return getPortfolioInsightsFlag()
        },
        message: READ_FAILED,
        diagnostic: {
            reason: "unreadable_json",
            status: 200,
            errorName: "SyntaxError",
            error: FLAG_RESPONSE_ERROR,
        },
    },
    {
        label: "array body",
        read: () => {
            stubFetch(respondWith(jsonResponse([enabledFlag])))
            return getPortfolioInsightsFlag()
        },
        message: INVALID_RESPONSE,
        diagnostic: {
            reason: "invalid_response",
            status: 200,
            check: "not_object",
        },
    },
    {
        label: "another id",
        read: () => {
            stubFetch(
                respondWith(jsonResponse({ ...enabledFlag, id: "other" }))
            )
            return getPortfolioInsightsFlag()
        },
        message: INVALID_RESPONSE,
        diagnostic: {
            reason: "invalid_response",
            status: 200,
            check: "id_mismatch",
        },
    },
    {
        label: "non-boolean enabled",
        read: () => {
            stubFetch(
                respondWith(jsonResponse({ ...enabledFlag, enabled: "true" }))
            )
            return getPortfolioInsightsFlag()
        },
        message: INVALID_RESPONSE,
        diagnostic: {
            reason: "invalid_response",
            status: 200,
            check: "enabled_not_boolean",
        },
    },
]

it.each(failures)(
    "getPortfolioInsightsFlag_failure_logsFixedReason ($label)",
    async ({ read, message, diagnostic }) => {
        const spies = spyConsole()

        const enabled = await read()

        expect({
            enabled,
            logged: spies.error.mock.calls.map(
                ([logMessage, logged]: unknown[]) => [
                    logMessage,
                    withErrorShape(logged),
                ]
            ),
        }).toEqual({
            enabled: false,
            logged: [[message, expect.objectContaining(diagnostic)]],
        })
    }
)

const untrustedResponses: { label: string; response: () => Response }[] = [
    {
        label: "markup body",
        response: () => textResponse(`<${LEAK_MARKER}>secret</html>`),
    },
    {
        label: "unquoted token",
        response: () => textResponse(`{"id":${LEAK_MARKER}}`),
    },
    {
        label: "truncated JSON",
        response: () => textResponse(`{"id":"${LEAK_MARKER}`),
    },
    {
        label: "id carries the marker",
        response: () => jsonResponse({ ...enabledFlag, id: LEAK_MARKER }),
    },
    {
        label: "enabled carries the marker",
        response: () => jsonResponse({ ...enabledFlag, enabled: LEAK_MARKER }),
    },
    {
        label: "array body",
        response: () => jsonResponse([LEAK_MARKER]),
    },
    {
        label: "string body",
        response: () => jsonResponse(LEAK_MARKER),
    },
    {
        label: "non-200 body",
        response: () => jsonResponse({ message: LEAK_MARKER }, 503),
    },
]

it.each(untrustedResponses)(
    "getPortfolioInsightsFlag_untrustedResponse_logsNoResponseContent ($label)",
    async ({ response }) => {
        const spies = spyConsole()
        stubFetch(() => Promise.resolve(response()))

        const enabled = await getPortfolioInsightsFlag()

        expect({
            enabled,
            leaked: loggedText(spies).includes(LEAK_MARKER),
        }).toEqual({ enabled: false, leaked: false })
    }
)
