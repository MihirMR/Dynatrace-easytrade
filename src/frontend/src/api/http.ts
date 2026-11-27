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

/**
 * A V8 stack frame line: indentation and `at`, then text ending in a
 * location, which is a line and column or one V8 writes for code without a
 * source position, and in `)` when the location is in parentheses after a
 * function name. Matching from the end keeps a long line linear to test.
 */
const V8_FRAME_LINE =
    /^[ \t]+at (?=\S).*(?::\d+:\d+\)?|<anonymous>\)?|\((?:native|index \d+)\))$/

/**
 * Index just past the part of the header V8 writes at the start of `stack`
 * (the error's name and message, which may span lines) that the message
 * identifies, or 0 when it identifies none. It cuts through the line holding
 * the last occurrence of the message, so no copy of the message is left in
 * what follows. An engine may rewrite the first line of the message after
 * writing the header, as Blink prefixes the one `Response.json()` rejects
 * with; the message's later lines then still mark where the header ends.
 */
function stackHeaderEnd(error: Error, stack: string): number {
    const { message } = error
    const lineBreak = message.indexOf("\n")
    const texts =
        lineBreak < 0 ? [message] : [message, message.slice(lineBreak)]
    for (const text of texts) {
        const start = text.trim() === "" ? -1 : stack.lastIndexOf(text)
        if (start >= 0) {
            const lineEnd = stack.indexOf("\n", start + text.length)
            return lineEnd < 0 ? stack.length : lineEnd + 1
        }
    }
    return 0
}

/**
 * True for a stack in the Firefox and Safari format, which has no header:
 * every line is a frame, a function name, which may be empty, then `@` and a
 * location. A stack holding the error's message or a V8 frame line is not
 * one, nor is one with a line that has a `:` before its first `@`, as a
 * `Name: message` header has.
 */
function isAtSignFramesStack(error: Error, stack: string): boolean {
    if (error.message !== "" && stack.includes(error.message)) return false
    const lines = stack.split("\n").filter((line) => line !== "")
    return (
        lines.length > 0 &&
        lines.every((line) => {
            const at = line.indexOf("@")
            return (
                at >= 0 &&
                !line.slice(0, at).includes(":") &&
                !V8_FRAME_LINE.test(line)
            )
        })
    )
}

/**
 * The V8 frame lines that end `stack` after the header `stackHeaderEnd`
 * finds: the lines after the last one that is not a frame, and none when the
 * last line is not one. A header the message did not identify is thus
 * dropped whole, including any line inside it that only looks like a frame,
 * unless its last line, which ends the message, is itself shaped like one.
 */
function trailingV8Frames(error: Error, stack: string): string {
    const lines = stack.slice(stackHeaderEnd(error, stack)).split("\n")
    let end = lines.length
    while (end > 0 && lines[end - 1] === "") end--
    let start = end
    while (start > 0 && V8_FRAME_LINE.test(lines[start - 1])) start--
    return lines.slice(start, end).join("\n")
}

/**
 * Gives `replacement` the stack frames of `original`, under the header of
 * `replacement` where the engine writes one. A content-safe stand-in for an
 * error thereby keeps that error's provenance without its message, which may
 * quote a request URL or response text. Only text identified as frames is
 * copied: a Firefox or Safari stack (see `isAtSignFramesStack`) is copied as
 * it is; any other contributes only the V8 frame lines that end it (see
 * `trailingV8Frames`), so a header without frames contributes nothing.
 * Returns `replacement`.
 */
export function withStackFramesOf<E extends Error>(
    replacement: E,
    original: Error
): E {
    const stack = original.stack ?? ""
    if (isAtSignFramesStack(original, stack)) {
        replacement.stack = stack
        return replacement
    }
    const frames = trailingV8Frames(original, stack)
    replacement.stack =
        frames === ""
            ? String(replacement)
            : `${String(replacement)}\n${frames}`
    return replacement
}

/** A path segment shaped like a GUID, with or without dashes or braces. */
const GUID_SEGMENT =
    /^[{(]?[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}[})]?$/i

function decodedUrlPart(part: string): string {
    try {
        return decodeURIComponent(part)
    } catch {
        return part
    }
}

/**
 * The request URL without anything that identifies whom it was for: no
 * origin or fragment, `{id}` for each path segment or query name that is
 * GUID-shaped or equals one of `identifiers`, and `{value}` for every query
 * value. Query names are kept, so the template still names the endpoint.
 */
function endpointTemplate(url: string, identifiers: readonly string[]): string {
    let parsed: URL
    try {
        parsed = new URL(url, window.location.origin)
    } catch {
        return "{unparsed url}"
    }
    const named = new Set(identifiers.filter((id) => id !== ""))
    const redact = (part: string): string =>
        GUID_SEGMENT.test(part) ||
        named.has(part) ||
        named.has(decodedUrlPart(part))
            ? "{id}"
            : part
    const path = parsed.pathname.split("/").map(redact).join("/")
    if (parsed.search === "") return path
    const query = parsed.search
        .slice(1)
        .split("&")
        .map((pair) => {
            const equals = pair.indexOf("=")
            return equals < 0
                ? redact(pair)
                : `${redact(pair.slice(0, equals))}={value}`
        })
        .join("&")
    return `${path}?${query}`
}

/**
 * The `ApiError` that is logged in place of one whose URL may carry the
 * session account id: same name and status, the endpoint template in
 * `endpoint` and the message, and the original stack frames.
 */
class RedactedApiError extends Error {
    readonly status: number
    readonly endpoint: string

    constructor(status: number, endpoint: string) {
        super(`HTTP ${status} for ${endpoint}`)
        this.name = "ApiError"
        this.status = status
        this.endpoint = endpoint
    }
}

/**
 * The value to log for a failed request. An `ApiError` becomes a new error
 * that names its endpoint by template (see `endpointTemplate`), since its
 * URL, message and stack header can carry the session account id; pass that
 * id, and any other identifier the URL may hold, as `identifiers` so it is
 * redacted even when it is not GUID-shaped. The original error is left
 * unchanged, so query state and status checks still see it. Any other value
 * is returned as it is.
 */
export function loggableError(
    error: unknown,
    ...identifiers: string[]
): unknown {
    if (!(error instanceof ApiError)) return error
    return withStackFramesOf(
        new RedactedApiError(
            error.status,
            endpointTemplate(error.url, identifiers)
        ),
        error
    )
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

/**
 * The JSON body of `response`. A body that is not valid JSON rejects with a
 * `MalformedJsonError` that keeps the parse error's stack frames without its
 * message; when the engine gives the parse error no frames, as Chrome does
 * for a fetched body, it keeps the frames of this call instead, so the error
 * still names where it was read. Any other rejection of the read, such as
 * the `AbortError` of an aborted request, is rethrown as it is.
 */
async function readJsonBody<T>(response: Response): Promise<T> {
    try {
        return (await response.json()) as T
    } catch (error) {
        if (!(error instanceof SyntaxError)) throw error
        const parseFailure = new MalformedJsonError()
        const callSite = parseFailure.stack
        withStackFramesOf(parseFailure, error)
        // Only the header is left when the parse error had no frames.
        if (parseFailure.stack === String(parseFailure)) {
            parseFailure.stack = callSite
        }
        throw parseFailure
    }
}

/**
 * GET JSON as `getJson` does, with `signal` passed to `fetch`, so aborting it
 * cancels the request and its body read; the rejection is then the standard
 * `AbortError`. Lets a query hand its cancellation signal to the transport.
 * A body that is not valid JSON rejects with `MalformedJsonError`.
 */
export async function getJsonWithSignal<T>(
    url: string,
    signal?: AbortSignal
): Promise<T> {
    const response = await request(url, { headers: JSON_HEADERS, signal })
    return await readJsonBody<T>(response)
}

/**
 * A successful response whose JSON body does not match the contract its
 * reader decodes. `field` is the path of the first value that failed, such as
 * `allocations[2].percent`, or `body` for the body itself. Neither it nor the
 * message holds the request URL or any response value, so the error can be
 * logged whole without exposing an account id or upstream data.
 */
export class InvalidResponseError extends Error {
    readonly field: string

    constructor(field: string) {
        super(`Invalid response body at ${field}`)
        this.name = "InvalidResponseError"
        this.field = field
    }
}

/**
 * A successful response whose body is not valid JSON, raised in place of the
 * parser's error, whose message and stack header quote the body. Its message
 * is fixed and holds neither the body nor the request URL, so the error can
 * be logged whole. It extends `SyntaxError`, the type the parser rejects
 * with, so a caller that checks for that type still sees one.
 */
export class MalformedJsonError extends SyntaxError {
    constructor() {
        super("Response body is not valid JSON")
        this.name = "MalformedJsonError"
    }
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
 * Given `status`, only a 2xx equal to it resolves: any other response, 2xx
 * included, rejects with `ApiError` before the body is read, and so does a
 * non-2xx `status`; without it, any 2xx resolves. A response body that is not
 * valid JSON rejects with `MalformedJsonError`. `signal` is passed to `fetch`,
 * so aborting it cancels the request and its body read with the standard
 * `AbortError`.
 */
export async function postJsonText<T>(
    url: string,
    bodyText: string,
    status?: number,
    signal?: AbortSignal
): Promise<T> {
    const init: RequestInit = {
        method: "POST",
        headers: JSON_HEADERS,
        body: bodyText,
        signal,
    }
    const response =
        status === undefined
            ? await request(url, init)
            : await requestExactStatus(url, init, status)
    return await readJsonBody<T>(response)
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

/**
 * PATCH `body` as JSON. As for `postJsonText`, given `status` only a 2xx
 * equal to it resolves and any other response rejects with `ApiError` before
 * the body is read; without it, any 2xx resolves. A response body that is not
 * valid JSON rejects with `MalformedJsonError`, and aborting `signal` cancels
 * the request and its body read with the standard `AbortError`.
 */
export async function patchJson<T>(
    url: string,
    body: unknown,
    status?: number,
    signal?: AbortSignal
): Promise<T> {
    const init: RequestInit = {
        method: "PATCH",
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
        signal,
    }
    const response =
        status === undefined
            ? await request(url, init)
            : await requestExactStatus(url, init, status)
    return await readJsonBody<T>(response)
}

export async function del(url: string): Promise<void> {
    await request(url, { method: "DELETE", headers: JSON_HEADERS })
}

/**
 * `request` for a call whose one success is a 2xx equal to `status`. A
 * non-2xx response rejects with `ApiError` as `request` rejects it, even when
 * it equals `status`, and a 2xx other than `status` rejects the same way;
 * either rejection comes before the body is read.
 */
async function requestExactStatus(
    url: string,
    init: RequestInit,
    status: number
): Promise<Response> {
    const response = await request(url, init)
    if (response.status !== status) {
        throw new ApiError(response.status, url)
    }
    return response
}

/**
 * DELETE whose one success is a 2xx equal to `status`: any other response,
 * 2xx included, rejects with `ApiError`, and so does a non-2xx `status`. The
 * body is never read. Aborting `signal` cancels the request with the standard
 * `AbortError`.
 */
export async function delExactStatus(
    url: string,
    status: number,
    signal?: AbortSignal
): Promise<void> {
    await requestExactStatus(
        url,
        { method: "DELETE", headers: JSON_HEADERS, signal },
        status
    )
}

/**
 * POST with no request body, for an action that its URL alone names, whose
 * one success is a 2xx equal to `status`: any other response, 2xx included,
 * rejects with `ApiError`, and so does a non-2xx `status`. It sends no
 * `Content-Type`, since there is no body to describe, and never reads the
 * response body. Aborting `signal` cancels the request with the standard
 * `AbortError`.
 */
export async function postExactStatus(
    url: string,
    status: number,
    signal?: AbortSignal
): Promise<void> {
    await requestExactStatus(
        url,
        { method: "POST", headers: { Accept: "application/json" }, signal },
        status
    )
}

/** Returns the raw body so the caller can hand it to its own XML parser. */
export async function getXml(
    url: string,
    allowStatus: readonly number[] = []
): Promise<string> {
    const response = await request(url, { headers: XML_HEADERS }, allowStatus)
    return await response.text()
}

/** Rejections of timed reads that their own deadline aborted first. */
const deadlineAborts = new WeakSet<object>()

/** True when a timed read's own deadline, not its caller, aborted it. */
export function isReadDeadlineAbort(error: unknown): boolean {
    return (
        typeof error === "object" && error !== null && deadlineAborts.has(error)
    )
}

/**
 * GET for JSON whose result `read` takes from the 2xx response, aborted after
 * `timeoutMs` or when the optional caller `signal` aborts, whichever comes
 * first. `read` runs inside the deadline, so it bounds the body read too. Both
 * paths abort one internal controller, so the rejection is always the
 * standard `AbortError`; `isReadDeadlineAbort` tells which one aborted it. The
 * caller signal is linked by hand because `AbortSignal.any` is missing from
 * older browsers; its listener is removed once the read settles.
 */
async function readWithTimeout<T>(
    url: string,
    timeoutMs: number,
    signal: AbortSignal | undefined,
    read: (response: Response) => Promise<T>
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
        return await read(response)
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

/**
 * GET JSON, aborted after `timeoutMs` or when the optional caller `signal`
 * aborts, whichever comes first (see `readWithTimeout`). Any 2xx resolves. A
 * body that is not valid JSON rejects with the parser's own `SyntaxError`.
 */
export async function getJsonWithTimeout<T>(
    url: string,
    timeoutMs: number,
    signal?: AbortSignal
): Promise<T> {
    return await readWithTimeout(
        url,
        timeoutMs,
        signal,
        async (response) => (await response.json()) as T
    )
}

/**
 * `getJsonWithTimeout` for a read whose one success is a 2xx equal to
 * `status`: any other response, 2xx included, rejects with `ApiError` before
 * the body is read, and so does a non-2xx `status`. A body that is not valid
 * JSON rejects with the content-safe `MalformedJsonError`.
 */
export async function getJsonWithTimeoutExactStatus<T>(
    url: string,
    timeoutMs: number,
    status: number,
    signal?: AbortSignal
): Promise<T> {
    return await readWithTimeout(url, timeoutMs, signal, async (response) => {
        if (response.status !== status) {
            throw new ApiError(response.status, url)
        }
        return await readJsonBody<T>(response)
    })
}
