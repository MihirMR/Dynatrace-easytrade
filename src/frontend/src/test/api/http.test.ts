import "@testing-library/jest-dom/vitest"
import {
    ApiError,
    del,
    delExactStatus,
    getJsonWithSignal,
    getJsonWithTimeout,
    isReadDeadlineAbort,
    loggableError,
    MalformedJsonError,
    patchJson,
    postJsonText,
    services,
    withStackFramesOf,
} from "../../api/http"

// Transport-level cases for http.ts itself, chiefly the caller-signal paths of
// getJsonWithTimeout, which the feature API suites never pass a signal through.

type Respond = (init: RequestInit | undefined) => Promise<Response>

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
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

/** Resolves with the rejection reason, or a marker when the call succeeded. */
function settle(pending: Promise<unknown>): Promise<unknown> {
    return pending.then(
        (value) => ({ resolved: value }),
        (error: unknown) => error
    )
}

const url = `${services.featureFlag()}/flags/portfolio-insights-enabled`

afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
})

it("getJsonWithSignal_signal_forwardedToFetch", async () => {
    let sent: RequestInit | undefined
    stubFetch((init) => {
        sent = init
        return Promise.resolve(jsonResponse({ results: [] }))
    })
    const caller = new AbortController()

    const value = await getJsonWithSignal(url, caller.signal)

    expect({
        value,
        sameSignal: sent?.signal === caller.signal,
        headers: sent?.headers,
    }).toEqual({
        value: { results: [] },
        sameSignal: true,
        headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
        },
    })
})

it.each<{ source: string; run: (caller: AbortController) => Promise<unknown> }>(
    [
        {
            source: "pre-aborted signal",
            run: (caller) => {
                caller.abort()
                return settle(getJsonWithSignal(url, caller.signal))
            },
        },
        {
            source: "signal aborted mid-request",
            run: (caller) => {
                const pending = settle(getJsonWithSignal(url, caller.signal))
                caller.abort()
                return pending
            },
        },
    ]
)(
    "getJsonWithSignal_callerAborts_rejectsAbortError ($source)",
    async ({ run }) => {
        stubFetch(hangUntilAborted)

        const error = await run(new AbortController())

        expect((error as Error).name).toBe("AbortError")
    }
)

it("getJsonWithSignal_non2xx_throwsApiErrorBeforeBodyRead", async () => {
    const response = jsonResponse({ error: "feature_disabled" }, 403)
    stubFetch(() => Promise.resolve(response))

    const error = await settle(getJsonWithSignal(url))

    expect({
        isApiError: error instanceof ApiError,
        status: error instanceof ApiError ? error.status : undefined,
        bodyRead: response.bodyUsed,
    }).toEqual({ isApiError: true, status: 403, bodyRead: false })
})

const abortSources: {
    source: string
    run: () => Promise<unknown>
}[] = [
    {
        source: "deadline",
        run: async () => {
            const pending = settle(getJsonWithTimeout(url, 2000))
            await vi.advanceTimersByTimeAsync(2000)
            return pending
        },
    },
    {
        source: "pre-aborted signal",
        run: () => {
            const caller = new AbortController()
            caller.abort()
            return settle(getJsonWithTimeout(url, 2000, caller.signal))
        },
    },
    {
        source: "signal aborted mid-request",
        run: async () => {
            const caller = new AbortController()
            const pending = settle(getJsonWithTimeout(url, 2000, caller.signal))
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return pending
        },
    },
    {
        source: "deadline, required status",
        run: async () => {
            const pending = settle(
                getJsonWithTimeout(url, 2000, undefined, 200)
            )
            await vi.advanceTimersByTimeAsync(2000)
            return pending
        },
    },
    {
        source: "pre-aborted signal, required status",
        run: () => {
            const caller = new AbortController()
            caller.abort()
            return settle(getJsonWithTimeout(url, 2000, caller.signal, 200))
        },
    },
    {
        source: "signal aborted mid-request, required status",
        run: async () => {
            const caller = new AbortController()
            const pending = settle(
                getJsonWithTimeout(url, 2000, caller.signal, 200)
            )
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return pending
        },
    },
]

it.each(abortSources)(
    "getJsonWithTimeout_abortSource_rejectsAbortErrorWithoutPendingTimer ($source)",
    async ({ run }) => {
        vi.useFakeTimers()
        stubFetch(hangUntilAborted)

        const error = await run()

        expect({
            name: (error as Error).name,
            pendingTimers: vi.getTimerCount(),
        }).toEqual({ name: "AbortError", pendingTimers: 0 })
    }
)

it("getJsonWithTimeout_callerAbortsAfterSettling_requestUnaffected", async () => {
    vi.useFakeTimers()
    let sent: RequestInit | undefined
    stubFetch((init) => {
        sent = init
        return Promise.resolve(jsonResponse({ enabled: true }))
    })
    const caller = new AbortController()

    const value = await getJsonWithTimeout(url, 2000, caller.signal)
    caller.abort()
    await vi.advanceTimersByTimeAsync(2000)

    expect({
        value,
        requestAborted: sent?.signal?.aborted,
        pendingTimers: vi.getTimerCount(),
    }).toEqual({
        value: { enabled: true },
        requestAborted: false,
        pendingTimers: 0,
    })
})

it("getJsonWithTimeout_noSignal_sendsAcceptHeaderOnly", async () => {
    let sent: RequestInit | undefined
    stubFetch((init) => {
        sent = init
        return Promise.resolve(jsonResponse({ version: "1" }))
    })

    const value = await getJsonWithTimeout(url, 2000)

    expect({ value, method: sent?.method, headers: sent?.headers }).toEqual({
        value: { version: "1" },
        method: undefined,
        headers: { Accept: "application/json" },
    })
})

it.each([201, 202, 203, 206])(
    "getJsonWithTimeout_anyOkStatus_resolvesBody (%i)",
    async (status) => {
        stubFetch(() => Promise.resolve(jsonResponse({ version: "1" }, status)))

        const value = await getJsonWithTimeout(url, 2000)

        expect(value).toEqual({ version: "1" })
    }
)

it.each([201, 202, 203, 206, 404])(
    "getJsonWithTimeout_requiredStatusOther_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = jsonResponse(
            { id: "portfolio-insights-enabled", enabled: true },
            status
        )
        stubFetch(() => Promise.resolve(response))

        const error = await settle(
            getJsonWithTimeout(url, 2000, undefined, 200)
        )

        expect({
            isApiError: error instanceof ApiError,
            status: error instanceof ApiError ? error.status : undefined,
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)

it.each([200, 203])(
    "getJsonWithTimeout_requiredStatusMatches_resolvesBody (%i)",
    async (status) => {
        stubFetch(() => Promise.resolve(jsonResponse({ version: "1" }, status)))

        const value = await getJsonWithTimeout(url, 2000, undefined, status)

        expect(value).toEqual({ version: "1" })
    }
)

// Rows that advance timers synchronously let a second source act before the
// rejection is handled; only the source that aborted first may count.
const rejectionSources: {
    source: string
    respond: Respond
    run: () => Promise<unknown>
    expected: { name: string; deadline: boolean }
}[] = [
    {
        source: "deadline",
        respond: hangUntilAborted,
        run: async () => {
            const pending = settle(getJsonWithTimeout(url, 2000))
            await vi.advanceTimersByTimeAsync(2000)
            return pending
        },
        expected: { name: "AbortError", deadline: true },
    },
    {
        source: "caller abort",
        respond: hangUntilAborted,
        run: async () => {
            const caller = new AbortController()
            const pending = settle(getJsonWithTimeout(url, 2000, caller.signal))
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return pending
        },
        expected: { name: "AbortError", deadline: false },
    },
    {
        source: "deadline, then caller abort before handling",
        respond: hangUntilAborted,
        run: () => {
            const caller = new AbortController()
            const pending = settle(getJsonWithTimeout(url, 2000, caller.signal))
            vi.advanceTimersByTime(2000)
            caller.abort()
            return pending
        },
        expected: { name: "AbortError", deadline: true },
    },
    {
        source: "caller abort, then deadline before handling",
        respond: hangUntilAborted,
        run: () => {
            const caller = new AbortController()
            const pending = settle(getJsonWithTimeout(url, 2000, caller.signal))
            caller.abort()
            vi.advanceTimersByTime(2000)
            return pending
        },
        expected: { name: "AbortError", deadline: false },
    },
    {
        source: "network error",
        respond: () => Promise.reject(new TypeError("Failed to fetch")),
        run: () => settle(getJsonWithTimeout(url, 2000)),
        expected: { name: "TypeError", deadline: false },
    },
]

it.each(rejectionSources)(
    "isReadDeadlineAbort_rejectionSource_trueOnlyWhenDeadlineAbortedFirst ($source)",
    async ({ respond, run, expected }) => {
        vi.useFakeTimers()
        stubFetch(respond)

        const error = await run()

        expect({
            name: (error as Error).name,
            deadline: isReadDeadlineAbort(error),
        }).toEqual(expected)
    }
)

// The account id the session holds, in the shape the user service issues.
const SESSION_ID = "be4f7c02-5a7d-4bd0-bac3-10bbf19605cd"

const redactedUrls: {
    label: string
    url: string
    identifiers: string[]
    endpoint: string
}[] = [
    {
        label: "GUID path segment",
        url: `${services.broker()}/portfolio/insights/${SESSION_ID}`,
        identifiers: [],
        endpoint: "/broker-service/v1/portfolio/insights/{id}",
    },
    {
        label: "query values",
        url: `${services.broker()}/alerts/notifications?accountId=${SESSION_ID}&unacknowledged=true`,
        identifiers: [],
        endpoint:
            "/broker-service/v1/alerts/notifications?accountId={value}&unacknowledged={value}",
    },
    {
        label: "non-GUID identifier the caller names",
        url: `${services.broker()}/portfolio/insights/1`,
        identifiers: ["1"],
        endpoint: "/broker-service/v1/portfolio/insights/{id}",
    },
    {
        label: "percent-encoded identifier",
        url: `${services.broker()}/portfolio/insights/acct%201`,
        identifiers: ["acct 1"],
        endpoint: "/broker-service/v1/portfolio/insights/{id}",
    },
    {
        label: "valueless query part named by an identifier",
        url: `${services.broker()}/alerts?acct-1`,
        identifiers: ["acct-1"],
        endpoint: "/broker-service/v1/alerts?{id}",
    },
    {
        label: "relative URL",
        url: "/broker-service/version",
        identifiers: [SESSION_ID],
        endpoint: "/broker-service/version",
    },
    {
        label: "unparsable URL",
        url: `http://[${SESSION_ID}`,
        identifiers: [SESSION_ID],
        endpoint: "{unparsed url}",
    },
]

it.each(redactedUrls)(
    "loggableError_apiError_namesEndpointTemplate ($label)",
    ({ url: requestUrl, identifiers, endpoint }) => {
        const logged = loggableError(
            new ApiError(503, requestUrl),
            ...identifiers
        )

        expect(logged).toMatchObject({
            name: "ApiError",
            status: 503,
            endpoint,
            message: `HTTP 503 for ${endpoint}`,
        })
    }
)

/** An `ApiError` thrown from a named function, so its frames are known. */
function failedInsightsRead(): ApiError {
    return new ApiError(
        503,
        `${services.broker()}/portfolio/insights/${SESSION_ID}`
    )
}

it("loggableError_apiError_keepsOriginalFramesWithoutUrl", () => {
    const original = failedInsightsRead()
    const [, ...frames] = (original.stack ?? "").split("\n")

    const logged = loggableError(original, SESSION_ID)

    expect((logged as Error).stack).toBe(
        [
            "ApiError: HTTP 503 for /broker-service/v1/portfolio/insights/{id}",
            ...frames,
        ].join("\n")
    )
})

it("loggableError_stackHeaderUnlikeMessage_keepsFramesWithoutUrl", () => {
    const original = failedInsightsRead()
    original.stack = `ApiError: request to ${original.url} failed\n    at failedInsightsRead (http://localhost/src/test/api/http.test.ts:439:12)`

    const logged = loggableError(original, SESSION_ID)

    expect((logged as Error).stack).toBe(
        "ApiError: HTTP 503 for /broker-service/v1/portfolio/insights/{id}\n    at failedInsightsRead (http://localhost/src/test/api/http.test.ts:439:12)"
    )
})

it("loggableError_apiError_leavesOriginalUnchanged", () => {
    const original = failedInsightsRead()
    const before = {
        message: original.message,
        url: original.url,
        stack: original.stack,
    }

    const logged = loggableError(original, SESSION_ID)

    expect({
        replaced: logged !== original,
        original: {
            message: original.message,
            url: original.url,
            stack: original.stack,
        },
    }).toEqual({ replaced: true, original: before })
})

it.each<{ label: string; value: unknown }>([
    { label: "TypeError", value: new TypeError("Failed to fetch") },
    { label: "AbortError", value: new DOMException("Aborted", "AbortError") },
    { label: "plain Error", value: new Error("Unexpected response body") },
    { label: "string", value: "unexpected" },
    { label: "null", value: null },
])("loggableError_notApiError_returnsValueUnchanged ($label)", ({ value }) => {
    expect(loggableError(value, SESSION_ID)).toBe(value)
})

// Stacks are set by hand, so each engine's format is covered on any engine.
const stackSources: {
    label: string
    original: () => Error
    stack: string
}[] = [
    {
        label: "V8 header with a multi-line message",
        original: () => {
            const error = new SyntaxError(
                `Unexpected token 'x', "x\n    at ${SESSION_ID}" is not valid JSON`
            )
            error.stack = `SyntaxError: ${error.message}\n    at JSON.parse (<anonymous>)\n    at parse (http.ts:1:1)`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at JSON.parse (<anonymous>)\n    at parse (http.ts:1:1)",
    },
    {
        label: "V8 header with an empty message",
        original: () => {
            const error = new SyntaxError("")
            error.stack = "SyntaxError\n    at parse (http.ts:1:1)"
            return error
        },
        stack: "SyntaxError: Fixed message\n    at parse (http.ts:1:1)",
    },
    {
        label: "header without frames",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack = `SyntaxError: ${SESSION_ID}`
            return error
        },
        stack: "SyntaxError: Fixed message",
    },
    {
        label: "Blink header without the message's binding prefix",
        original: () => {
            const error = new SyntaxError(
                `Failed to execute 'json' on 'Response': Unexpected token '<', "<<${SESSION_ID}"... is not valid JSON`
            )
            error.stack = `SyntaxError: Unexpected token '<', "<<${SESSION_ID}"... is not valid JSON\n    at getJsonWithTimeout (http://localhost/src/api/http.ts:280:31)\n    at async getPortfolioInsightsFlag (http://localhost/src/api/featureFlags/index.ts:170:16)`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at getJsonWithTimeout (http://localhost/src/api/http.ts:280:31)\n    at async getPortfolioInsightsFlag (http://localhost/src/api/featureFlags/index.ts:170:16)",
    },
    {
        label: "Blink header without the message's prefix or frames",
        original: () => {
            const error = new SyntaxError(
                `Failed to execute 'json' on 'Response': Unexpected token '<', "<${SESSION_ID}@x"... is not valid JSON`
            )
            error.stack = `SyntaxError: Unexpected token '<', "<${SESSION_ID}@x"... is not valid JSON`
            return error
        },
        stack: "SyntaxError: Fixed message",
    },
    {
        label: "name-only header without frames",
        original: () => {
            const error = new SyntaxError("")
            error.stack = "SyntaxError"
            return error
        },
        stack: "SyntaxError: Fixed message",
    },
    {
        label: "message whose last line is shaped like a frame",
        original: () => {
            const error = new SyntaxError(
                `Unexpected token 'x', "x\n    at ${SESSION_ID} (evil.ts:9:9)`
            )
            error.stack = `SyntaxError: ${error.message}\n    at parse (http.ts:1:1)`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at parse (http.ts:1:1)",
    },
    {
        label: "prefixed message whose last line is shaped like a frame",
        original: () => {
            const error = new SyntaxError(
                `Failed to execute 'json' on 'Response': Unexpected token 'x', "x\n    at ${SESSION_ID} (evil.ts:9:9)`
            )
            error.stack = `SyntaxError: Unexpected token 'x', "x\n    at ${SESSION_ID} (evil.ts:9:9)\n    at parse (http.ts:1:1)`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at parse (http.ts:1:1)",
    },
    {
        label: "header unlike the message, with a line shaped like a frame",
        original: () => {
            const error = new SyntaxError("Flag read failed")
            error.stack = `SyntaxError: Unexpected token 'x', "x\n    at ${SESSION_ID} (evil.ts:9:9)\n"... is not valid JSON\n    at parse (http.ts:1:1)`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at parse (http.ts:1:1)",
    },
    {
        label: "V8 frames ending in a line break",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack = `SyntaxError: ${SESSION_ID}\n    at parse (http.ts:1:1)\n`
            return error
        },
        stack: "SyntaxError: Fixed message\n    at parse (http.ts:1:1)",
    },
    {
        label: "V8 frames without a header, through an @-scoped package",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack =
                "    at fetchQuery (/app/node_modules/@tanstack/query-core/build/modern/query.js:1:1)"
            return error
        },
        stack: "SyntaxError: Fixed message\n    at fetchQuery (/app/node_modules/@tanstack/query-core/build/modern/query.js:1:1)",
    },
    {
        label: "frames without a header, as in Firefox",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack = "parse@http.ts:1:1\nread@http.ts:2:2"
            return error
        },
        stack: "parse@http.ts:1:1\nread@http.ts:2:2",
    },
    {
        label: "async frames ending in a line break, as in Firefox",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack =
                "getJsonWithTimeout@http://localhost/src/api/http.ts:280:31\nasync*getPortfolioInsightsFlag@http://localhost/src/api/featureFlags/index.ts:170:16\n"
            return error
        },
        stack: "getJsonWithTimeout@http://localhost/src/api/http.ts:280:31\nasync*getPortfolioInsightsFlag@http://localhost/src/api/featureFlags/index.ts:170:16\n",
    },
    {
        label: "frames without a header, as in Safari",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack =
                "json@[native code]\ngetJsonWithTimeout@http://localhost/src/api/http.ts:280:31\nglobal code@http://localhost/src/main.tsx:1:1"
            return error
        },
        stack: "json@[native code]\ngetJsonWithTimeout@http://localhost/src/api/http.ts:280:31\nglobal code@http://localhost/src/main.tsx:1:1",
    },
    {
        label: "no stack",
        original: () => {
            const error = new SyntaxError(SESSION_ID)
            error.stack = undefined
            return error
        },
        stack: "SyntaxError: Fixed message",
    },
]

it.each(stackSources)(
    "withStackFramesOf_originalStack_keepsFramesUnderOwnHeader ($label)",
    ({ original, stack }) => {
        const replacement = withStackFramesOf(
            new SyntaxError("Fixed message"),
            original()
        )

        expect(replacement.stack).toBe(stack)
    }
)

// Short and at the start of the body: V8 quotes only about ten characters of
// a longer body in a JSON parse error's message and stack header.
const BODY_MARKER = "LEAK9b2e"
const MALFORMED_BODY = `<${BODY_MARKER}>`
const MALFORMED_HEADER = "MalformedJsonError: Response body is not valid JSON"

const insightsUrl = `${services.broker()}/portfolio/insights/${SESSION_ID}`

const jsonReaders: {
    helper: string
    read: (target: string) => Promise<unknown>
}[] = [
    {
        helper: "getJsonWithSignal",
        read: (target) => getJsonWithSignal(target),
    },
    {
        helper: "getJsonWithTimeout",
        read: (target) => getJsonWithTimeout(target, 2000),
    },
    {
        helper: "getJsonWithTimeout with required status",
        read: (target) => getJsonWithTimeout(target, 2000, undefined, 200),
    },
]

/** A 200 whose body is `text`, served as JSON. */
function textResponse(text: string): Response {
    return new Response(text, {
        status: 200,
        headers: { "Content-Type": "application/json" },
    })
}

/** A 200 whose body read rejects with `failure`. */
function bodyReadRejecting(failure: unknown): Response {
    const response = jsonResponse({})
    vi.spyOn(response, "json").mockRejectedValue(failure)
    return response
}

it.each(jsonReaders)(
    "jsonReader_malformedBody_rejectsContentSafeSyntaxError ($helper)",
    async ({ read }) => {
        stubFetch(() => Promise.resolve(textResponse(MALFORMED_BODY)))

        const error = await settle(read(insightsUrl))

        const { name, message, stack } = error as Error
        const shown = `${name}\n${message}\n${stack ?? ""}`
        expect({
            isMalformedJson: error instanceof MalformedJsonError,
            isSyntaxError: error instanceof SyntaxError,
            message,
            header: (stack ?? "").split("\n")[0],
            hasFrames: (stack ?? "").includes("\n    at "),
            leaked: [BODY_MARKER, SESSION_ID].filter((part) =>
                shown.includes(part)
            ),
        }).toEqual({
            isMalformedJson: true,
            isSyntaxError: true,
            message: "Response body is not valid JSON",
            header: MALFORMED_HEADER,
            hasFrames: true,
            leaked: [],
        })
    }
)

// Stacks are set by hand, as in `stackSources`. Blink's message gains a
// binding prefix its stack header lacks.
const PARSE_FRAMES =
    "    at readJsonBody (http://localhost/src/api/http.ts:245:33)\n    at async getPortfolioInsights (http://localhost/src/api/portfolioInsights/index.ts:91:18)"

it.each(jsonReaders)(
    "jsonReader_parseErrorWithFrames_keepsFramesUnderFixedHeader ($helper)",
    async ({ read }) => {
        const parseError = new SyntaxError(
            `Failed to execute 'json' on 'Response': Unexpected token '<', "${MALFORMED_BODY}" is not valid JSON`
        )
        parseError.stack = `SyntaxError: Unexpected token '<', "${MALFORMED_BODY}" is not valid JSON\n${PARSE_FRAMES}`
        stubFetch(() => Promise.resolve(bodyReadRejecting(parseError)))

        const error = await settle(read(insightsUrl))

        expect((error as Error).stack).toBe(
            `${MALFORMED_HEADER}\n${PARSE_FRAMES}`
        )
    }
)

// Chrome gives the parse error of a fetched body a header and no frames.
it.each(jsonReaders)(
    "jsonReader_parseErrorWithoutFrames_keepsCallSiteFrames ($helper)",
    async ({ read }) => {
        const parseError = new SyntaxError(
            `Unexpected token '<', "${MALFORMED_BODY}" is not valid JSON`
        )
        parseError.stack = `SyntaxError: ${parseError.message}`
        stubFetch(() => Promise.resolve(bodyReadRejecting(parseError)))

        const error = await settle(read(insightsUrl))

        const [header, ...frames] = ((error as Error).stack ?? "").split("\n")
        expect({
            header,
            namesReader: frames.some((frame) => frame.includes("readJsonBody")),
            leaked: frames.some((frame) => frame.includes(BODY_MARKER)),
        }).toEqual({
            header: MALFORMED_HEADER,
            namesReader: true,
            leaked: false,
        })
    }
)

/**
 * A 200 whose body read rejects with a new AbortError, recorded in `aborts`,
 * once the request's signal aborts, and never settles otherwise.
 */
function bodyReadUntilAborted(
    init: RequestInit | undefined,
    aborts: unknown[]
): Response {
    const response = jsonResponse({})
    vi.spyOn(response, "json").mockImplementation(
        () =>
            new Promise<never>((_, reject) => {
                const abort = (): void => {
                    const error = new DOMException("Aborted", "AbortError")
                    aborts.push(error)
                    reject(error)
                }
                if (init?.signal?.aborted) {
                    abort()
                    return
                }
                init?.signal?.addEventListener("abort", abort, { once: true })
            })
    )
    return response
}

// The abort rows let the response arrive before aborting, so the rejection
// comes from the body read itself.
const bodyReadRejections: {
    label: string
    run: () => Promise<{ error: unknown; thrown: unknown }>
    deadline: boolean
}[] = [
    {
        label: "getJsonWithSignal, TypeError",
        run: async () => {
            const thrown = new TypeError("Body is unusable")
            stubFetch(() => Promise.resolve(bodyReadRejecting(thrown)))
            return {
                error: await settle(getJsonWithSignal(insightsUrl)),
                thrown,
            }
        },
        deadline: false,
    },
    {
        label: "getJsonWithTimeout, TypeError",
        run: async () => {
            const thrown = new TypeError("Body is unusable")
            stubFetch(() => Promise.resolve(bodyReadRejecting(thrown)))
            return {
                error: await settle(getJsonWithTimeout(insightsUrl, 2000)),
                thrown,
            }
        },
        deadline: false,
    },
    {
        label: "getJsonWithSignal, caller abort",
        run: async () => {
            const aborts: unknown[] = []
            stubFetch((init) =>
                Promise.resolve(bodyReadUntilAborted(init, aborts))
            )
            const caller = new AbortController()
            const pending = settle(
                getJsonWithSignal(insightsUrl, caller.signal)
            )
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return { error: await pending, thrown: aborts[0] }
        },
        deadline: false,
    },
    {
        label: "getJsonWithTimeout, deadline",
        run: async () => {
            const aborts: unknown[] = []
            stubFetch((init) =>
                Promise.resolve(bodyReadUntilAborted(init, aborts))
            )
            const pending = settle(getJsonWithTimeout(insightsUrl, 2000))
            await vi.advanceTimersByTimeAsync(100)
            await vi.advanceTimersByTimeAsync(1900)
            return { error: await pending, thrown: aborts[0] }
        },
        deadline: true,
    },
    {
        label: "getJsonWithTimeout, caller abort",
        run: async () => {
            const aborts: unknown[] = []
            stubFetch((init) =>
                Promise.resolve(bodyReadUntilAborted(init, aborts))
            )
            const caller = new AbortController()
            const pending = settle(
                getJsonWithTimeout(insightsUrl, 2000, caller.signal)
            )
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return { error: await pending, thrown: aborts[0] }
        },
        deadline: false,
    },
]

it.each(bodyReadRejections)(
    "jsonReader_bodyReadRejectsOtherwise_rethrowsSameError ($label)",
    async ({ run, deadline }) => {
        vi.useFakeTimers()

        const { error, thrown } = await run()

        expect({
            same: thrown !== undefined && error === thrown,
            deadline: isReadDeadlineAbort(error),
        }).toEqual({ same: true, deadline })
    }
)

const writeHelpers: {
    helper: string
    call: (target: string) => Promise<unknown>
    method: string
    body: string
}[] = [
    {
        helper: "patchJson",
        call: (target) => patchJson(target, { enabled: true }),
        method: "PATCH",
        body: '{"enabled":true}',
    },
    {
        helper: "postJsonText",
        call: (target) =>
            postJsonText(target, '{"threshold":9999999999.99999999}'),
        method: "POST",
        body: '{"threshold":9999999999.99999999}',
    },
    {
        helper: "postJsonText with exact status",
        call: (target) =>
            postJsonText(target, '{"threshold":9999999999.99999999}', 200),
        method: "POST",
        body: '{"threshold":9999999999.99999999}',
    },
]

it.each(writeHelpers)(
    "jsonWriteHelper_success_sendsBodyAndParsesResponse ($helper)",
    async ({ call, method, body }) => {
        const target = `${services.broker()}/alerts`
        let sent: RequestInit | undefined
        stubFetch((init) => {
            sent = init
            return Promise.resolve(jsonResponse({ id: "alert-1" }))
        })

        const value = await call(target)

        expect({
            value,
            method: sent?.method,
            headers: sent?.headers,
            body: sent?.body,
        }).toEqual({
            value: { id: "alert-1" },
            method,
            headers: {
                Accept: "application/json",
                "Content-Type": "application/json",
            },
            body,
        })
    }
)

const alertsUrl = `${services.broker()}/alerts`

/** A response of `status`, with a JSON body unless the status forbids one. */
function statusResponse(status: number): Response {
    return status === 204
        ? new Response(null, { status })
        : jsonResponse({ id: "alert-1" }, status)
}

it.each([200, 201, 202])(
    "postJsonText_noExactStatus_anyOkStatusResolvesBody (%i)",
    async (status) => {
        stubFetch(() => Promise.resolve(statusResponse(status)))

        const value = await postJsonText(alertsUrl, "{}")

        expect(value).toEqual({ id: "alert-1" })
    }
)

it("postJsonText_exactStatusMatches_resolvesBody", async () => {
    stubFetch(() => Promise.resolve(statusResponse(201)))

    const value = await postJsonText(alertsUrl, "{}", 201)

    expect(value).toEqual({ id: "alert-1" })
})

// An exact status outside 2xx never succeeds: `request` rejects it first.
it.each<{ helper: string; call: (status: number) => Promise<unknown> }>([
    {
        helper: "postJsonText",
        call: (status) => postJsonText(alertsUrl, "{}", status),
    },
    {
        helper: "delExactStatus",
        call: (status) => delExactStatus(alertsUrl, status),
    },
])(
    "exactStatusHelper_nonOkExactStatusMatches_rejectsApiErrorBeforeBodyRead ($helper)",
    async ({ call }) => {
        const response = statusResponse(409)
        stubFetch(() => Promise.resolve(response))

        const error = await settle(call(409))

        expect({
            isApiError: error instanceof ApiError,
            status: error instanceof ApiError ? error.status : undefined,
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status: 409, bodyRead: false })
    }
)

it.each([200, 202, 404, 500])(
    "postJsonText_exactStatusOtherResponse_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = statusResponse(status)
        stubFetch(() => Promise.resolve(response))

        const error = await settle(postJsonText(alertsUrl, "{}", 201))

        expect({
            isApiError: error instanceof ApiError,
            status: error instanceof ApiError ? error.status : undefined,
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)

it.each([200, 202, 204])(
    "del_anyOkStatus_resolvesWithoutBodyRead (%i)",
    async (status) => {
        const response = statusResponse(status)
        stubFetch(() => Promise.resolve(response))

        const outcome = await settle(del(alertsUrl))

        expect({ outcome, bodyRead: response.bodyUsed }).toEqual({
            outcome: { resolved: undefined },
            bodyRead: false,
        })
    }
)

it("delExactStatus_matchingStatus_sendsDeleteAndResolves", async () => {
    let sent: RequestInit | undefined
    stubFetch((init) => {
        sent = init
        return Promise.resolve(statusResponse(204))
    })

    const outcome = await settle(delExactStatus(alertsUrl, 204))

    expect({ outcome, method: sent?.method, headers: sent?.headers }).toEqual({
        outcome: { resolved: undefined },
        method: "DELETE",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
        },
    })
})

it.each([200, 202, 404, 500])(
    "delExactStatus_otherResponse_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = statusResponse(status)
        stubFetch(() => Promise.resolve(response))

        const error = await settle(delExactStatus(alertsUrl, 204))

        expect({
            isApiError: error instanceof ApiError,
            status: error instanceof ApiError ? error.status : undefined,
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)
