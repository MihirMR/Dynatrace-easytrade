export class ApiError extends Error {
    readonly status: number
    readonly url: string

    constructor(status: number, url: string) {
        super(`HTTP ${status} for ${url}`)
        this.name = "ApiError"
        this.status = status
        this.url = url
    }
}

export const services = {
    featureFlag: () => `${window.location.origin}/feature-flag-service/v1`,
    user: () => `${window.location.origin}/user-service/api`,
    broker: () => `${window.location.origin}/broker-service/v1`,
    pricing: () => `${window.location.origin}/pricing-service/v1`,
    creditCard: () => `${window.location.origin}/credit-card-order-service/v1`,
}

const JSON_HEADERS = {
    Accept: "application/json",
    "Content-Type": "application/json",
}

const XML_HEADERS = {
    Accept: "application/xml",
    "Content-Type": "application/xml",
}

async function request(
    url: string,
    init: RequestInit,
    /** Statuses to treat as a normal response rather than an error. */
    allowStatus: readonly number[] = []
): Promise<Response> {
    const response = await fetch(url, init)
    if (!response.ok && !allowStatus.includes(response.status)) {
        throw new ApiError(response.status, url)
    }
    return response
}

export async function getJson<T>(url: string): Promise<T> {
    const response = await request(url, { headers: JSON_HEADERS })
    return (await response.json()) as T
}

export async function postJson<T>(url: string, body: unknown): Promise<T> {
    const response = await request(url, {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
    })
    return (await response.json()) as T
}

/** POST for endpoints that return no body. */
export async function post(url: string, body: unknown): Promise<void> {
    await request(url, {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
    })
}

/**
 * POST a body that is already serialised JSON text, sent unchanged. Lets a
 * caller send a number token exactly as typed, without a round trip through a
 * JavaScript number; the caller is responsible for producing valid JSON.
 */
export async function postJsonText<T>(
    url: string,
    bodyText: string
): Promise<T> {
    const response = await request(url, {
        method: "POST",
        headers: JSON_HEADERS,
        body: bodyText,
    })
    return (await response.json()) as T
}

export async function put<T>(
    url: string,
    body: unknown
): Promise<T | undefined> {
    const response = await request(url, {
        method: "PUT",
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
    })
    const text = await response.text()
    return text ? (JSON.parse(text) as T) : undefined
}

export async function patchJson<T>(url: string, body: unknown): Promise<T> {
    const response = await request(url, {
        method: "PATCH",
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
    })
    return (await response.json()) as T
}

export async function del(url: string): Promise<void> {
    await request(url, { method: "DELETE", headers: JSON_HEADERS })
}

/** Returns the raw body so the caller can hand it to its own XML parser. */
export async function getXml(
    url: string,
    allowStatus: readonly number[] = []
): Promise<string> {
    const response = await request(url, { headers: XML_HEADERS }, allowStatus)
    return await response.text()
}

/**
 * GET JSON, aborted after `timeoutMs` or when the optional caller `signal`
 * aborts, whichever comes first. Both paths abort one internal controller, so
 * the rejection is always the standard `AbortError`; `isReadDeadlineAbort`
 * tells which one aborted it. The caller signal is linked by hand because
 * `AbortSignal.any` is missing from older browsers; its listener is removed
 * once the request settles.
 */
export async function getJsonWithTimeout<T>(
    url: string,
    timeoutMs: number,
    signal?: AbortSignal
): Promise<T> {
    return await readJsonWithTimeout<T>(url, timeoutMs, signal, undefined)
}

/**
 * GET JSON with the same deadline and caller-signal handling as
 * `getJsonWithTimeout`, but any status other than `status`, 2xx included,
 * rejects with `ApiError` before the body is read.
 */
export async function getJsonWithTimeoutExactStatus<T>(
    url: string,
    timeoutMs: number,
    status: number,
    signal?: AbortSignal
): Promise<T> {
    return await readJsonWithTimeout<T>(url, timeoutMs, signal, status)
}

/** Rejections of timed reads that their own deadline aborted first. */
const deadlineAborts = new WeakSet<object>()

/** True when a timed read's own deadline, not its caller, aborted it. */
export function isReadDeadlineAbort(error: unknown): boolean {
    return (
        typeof error === "object" && error !== null && deadlineAborts.has(error)
    )
}

/** Shared timed read; a given `requiredStatus` narrows `response.ok`. */
async function readJsonWithTimeout<T>(
    url: string,
    timeoutMs: number,
    signal: AbortSignal | undefined,
    requiredStatus: number | undefined
): Promise<T> {
    const controller = new AbortController()
    // Decided when the deadline fires, since the caller may also abort before
    // the rejection is handled.
    let deadlineAbortedFirst = false
    const timer = setTimeout(() => {
        deadlineAbortedFirst = !controller.signal.aborted
        controller.abort()
    }, timeoutMs)
    const onAbort = (): void => controller.abort()
    if (signal?.aborted) {
        controller.abort()
    } else {
        signal?.addEventListener("abort", onAbort, { once: true })
    }
    try {
        const response = await request(url, {
            headers: { Accept: "application/json" },
            signal: controller.signal,
        })
        if (
            requiredStatus !== undefined &&
            response.status !== requiredStatus
        ) {
            throw new ApiError(response.status, url)
        }
        return (await response.json()) as T
    } catch (error) {
        if (
            deadlineAbortedFirst &&
            typeof error === "object" &&
            error !== null
        ) {
            deadlineAborts.add(error)
        }
        throw error
    } finally {
        clearTimeout(timer)
        signal?.removeEventListener("abort", onAbort)
    }
}
