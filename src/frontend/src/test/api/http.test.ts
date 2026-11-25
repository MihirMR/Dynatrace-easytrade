import "@testing-library/jest-dom/vitest"
import {
    ApiError,
    getJsonWithTimeout,
    getJsonWithTimeoutExactStatus,
    isReadDeadlineAbort,
    patchJson,
    postJsonText,
    services,
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
    "getJsonWithTimeoutExactStatus_otherStatus_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = jsonResponse(
            { id: "portfolio-insights-enabled", enabled: true },
            status
        )
        stubFetch(() => Promise.resolve(response))

        const error = await settle(
            getJsonWithTimeoutExactStatus(url, 2000, 200)
        )

        expect({
            isApiError: error instanceof ApiError,
            status: error instanceof ApiError ? error.status : undefined,
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)

it.each([200, 203])(
    "getJsonWithTimeoutExactStatus_matchingStatus_resolvesBody (%i)",
    async (status) => {
        stubFetch(() => Promise.resolve(jsonResponse({ version: "1" }, status)))

        const value = await getJsonWithTimeoutExactStatus(url, 2000, status)

        expect(value).toEqual({ version: "1" })
    }
)

const exactStatusAbortSources: {
    source: string
    run: () => Promise<unknown>
}[] = [
    {
        source: "deadline",
        run: async () => {
            const pending = settle(
                getJsonWithTimeoutExactStatus(url, 2000, 200)
            )
            await vi.advanceTimersByTimeAsync(2000)
            return pending
        },
    },
    {
        source: "pre-aborted signal",
        run: () => {
            const caller = new AbortController()
            caller.abort()
            return settle(
                getJsonWithTimeoutExactStatus(url, 2000, 200, caller.signal)
            )
        },
    },
    {
        source: "signal aborted mid-request",
        run: async () => {
            const caller = new AbortController()
            const pending = settle(
                getJsonWithTimeoutExactStatus(url, 2000, 200, caller.signal)
            )
            await vi.advanceTimersByTimeAsync(100)
            caller.abort()
            return pending
        },
    },
]

it.each(exactStatusAbortSources)(
    "getJsonWithTimeoutExactStatus_abortSource_rejectsAbortErrorWithoutPendingTimer ($source)",
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
