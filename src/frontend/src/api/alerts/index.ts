import {
    delExactStatus,
    getJsonWithSignal,
    InvalidResponseError,
    patchJson,
    postExactStatus,
    postJsonText,
    services,
} from "../http"
import {
    isAlertDirection,
    isAlertType,
    validateThreshold,
} from "../../utils/alertValidation"
import { Alert, CreateAlertRequest, CreatedAlert } from "./types"
export * from "./types"

type AlertsDto = {
    results: Alert[]
}

type JsonObject = Record<string, unknown>

function isJsonObject(value: unknown): value is JsonObject {
    return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isNonEmptyText(value: unknown): value is string {
    return typeof value === "string" && value !== ""
}

const GUID_PATTERN =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** True for a canonical 8-4-4-4-12 hex GUID string, in either case. */
function isGuid(value: unknown): value is string {
    return typeof value === "string" && GUID_PATTERN.test(value)
}

function isFiniteNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value)
}

/**
 * The entry at `path` as an `Alert`, its values unchanged, or an
 * `InvalidResponseError` naming the first field, in contract order, that
 * breaks the broker's `AlertDTO` shape. The `id` must be the canonical GUID
 * string the broker writes, so every decoded alert can address the
 * `{id:guid}` update, delete and acknowledge routes.
 */
function toAlert(value: unknown, path: string): Alert {
    if (!isJsonObject(value)) throw new InvalidResponseError(path)
    const invalid = (key: string) => new InvalidResponseError(`${path}.${key}`)
    const {
        id,
        accountId,
        instrumentId,
        type,
        direction,
        threshold,
        enabled,
        armingRevision,
        triggeredAt,
        triggerValue,
        acknowledged,
        createdAt,
    } = value
    if (!isGuid(id)) throw invalid("id")
    if (!isNonEmptyText(accountId)) throw invalid("accountId")
    if (!isNonEmptyText(instrumentId)) throw invalid("instrumentId")
    if (!isAlertType(type)) throw invalid("type")
    if (!isAlertDirection(direction)) throw invalid("direction")
    if (!isFiniteNumber(threshold)) throw invalid("threshold")
    if (typeof enabled !== "boolean") throw invalid("enabled")
    if (
        typeof armingRevision !== "number" ||
        !Number.isInteger(armingRevision) ||
        armingRevision < 1
    ) {
        throw invalid("armingRevision")
    }
    if (triggeredAt !== null && typeof triggeredAt !== "string") {
        throw invalid("triggeredAt")
    }
    if (triggerValue !== null && !isFiniteNumber(triggerValue)) {
        throw invalid("triggerValue")
    }
    if (typeof acknowledged !== "boolean") throw invalid("acknowledged")
    if (typeof createdAt !== "string") throw invalid("createdAt")
    return {
        id,
        accountId,
        instrumentId,
        type,
        direction,
        threshold,
        enabled,
        armingRevision,
        triggeredAt,
        triggerValue,
        acknowledged,
        createdAt,
    }
}

/**
 * The entry at `path` as a notification: an alert whose current arming has
 * triggered, so its `triggeredAt` and `triggerValue` are set. The alert fields
 * are checked first, so a row that breaks them names the same field in both
 * reads.
 */
function toNotification(value: unknown, path: string): Alert {
    const alert = toAlert(value, path)
    if (alert.triggeredAt === null) {
        throw new InvalidResponseError(`${path}.triggeredAt`)
    }
    if (alert.triggerValue === null) {
        throw new InvalidResponseError(`${path}.triggerValue`)
    }
    return alert
}

/**
 * Checks a 200 body against the `{"results": [...]}` alert envelope that the
 * list and the notification reads share, decoding each entry with `toEntry`,
 * before anything renders or toasts an entry.
 */
function toAlertsDto(
    body: unknown,
    toEntry: (value: unknown, path: string) => Alert
): AlertsDto {
    if (!isJsonObject(body)) throw new InvalidResponseError("body")
    const { results } = body
    if (!Array.isArray(results)) throw new InvalidResponseError("results")
    const entries: readonly unknown[] = results
    return {
        results: entries.map((entry, index) =>
            toEntry(entry, `results[${index}]`)
        ),
    }
}

/**
 * Every alert of the account, newest first. Aborting `signal` cancels the
 * HTTP read; a 200 whose body breaks the alert contract rejects with
 * `InvalidResponseError`.
 */
export async function listAlerts(
    accountId: string,
    signal?: AbortSignal
): Promise<Alert[]> {
    const { results } = toAlertsDto(
        await getJsonWithSignal<unknown>(
            `${services.broker()}/alerts?accountId=${accountId}`,
            signal
        ),
        toAlert
    )
    return results
}

/**
 * Alerts whose current arming has triggered, most recently triggered first;
 * `unacknowledged` keeps only those not yet acknowledged. Aborting `signal`
 * cancels the HTTP read; a 200 whose body breaks the alert contract, or lists
 * an alert without its trigger time and value, rejects with
 * `InvalidResponseError`, so the poll fails instead of its consumers.
 */
export async function listAlertNotifications(
    accountId: string,
    unacknowledged = true,
    signal?: AbortSignal
): Promise<Alert[]> {
    const { results } = toAlertsDto(
        await getJsonWithSignal<unknown>(
            `${services.broker()}/alerts/notifications?accountId=${accountId}&unacknowledged=${unacknowledged}`,
            signal
        ),
        toNotification
    )
    return results
}

/**
 * Creates an alert. The threshold is spliced into the body as an unquoted
 * JSON number token: a JavaScript number would round `9999999999.99999999`
 * to `10000000000`, and the broker rejects a quoted number. Before any
 * request, the shared `validateThreshold` enforces the plain decimal grammar,
 * the 10 integer and 8 fractional digit domain and a target price above 0, and
 * rejects with its message otherwise. Only the token it returns is spliced, so
 * the body is always valid JSON. Resolves with the created alert and that
 * token, the threshold exactly as the body carried it. Only the broker's 201
 * with an `AlertDTO` body resolves; any other status, 2xx included, rejects
 * with `ApiError`, a body that is not valid JSON with `MalformedJsonError`,
 * and one that breaks the alert contract with `InvalidResponseError`, so
 * nothing reports a create the broker did not confirm. Aborting `signal`
 * cancels the HTTP request and its body read, as for each alert write below.
 */
export async function createAlert(
    req: CreateAlertRequest,
    signal?: AbortSignal
): Promise<CreatedAlert> {
    const threshold = validateThreshold(req.type, req.threshold)
    if (!threshold.ok) {
        throw new Error(`Invalid alert threshold: ${threshold.message}`)
    }
    const token = threshold.token
    const head = JSON.stringify({
        accountId: req.accountId,
        type: req.type,
        instrumentId: req.instrumentId,
        direction: req.direction,
    })
    const bodyText = `${head.slice(0, -1)},"threshold":${token}}`
    const body = await postJsonText<unknown>(
        `${services.broker()}/alerts`,
        bodyText,
        201,
        signal
    )
    return { alert: toAlert(body, "body"), threshold: token }
}

/**
 * Enables (re-arming it) or disables an alert; returns this update's state.
 * Only the broker's 200 with an `AlertDTO` body resolves; any other status,
 * 2xx included, rejects with `ApiError` before the body is read, a body that
 * is not valid JSON with `MalformedJsonError`, and one that breaks the alert
 * contract with `InvalidResponseError`.
 */
export async function updateAlertEnabled(
    id: string,
    enabled: boolean,
    signal?: AbortSignal
): Promise<Alert> {
    const body = await patchJson<unknown>(
        `${services.broker()}/alerts/${id}`,
        { enabled },
        200,
        signal
    )
    return toAlert(body, "body")
}

/**
 * Deletes an alert together with its notification. Only the broker's 204
 * resolves; any other status, 2xx included, rejects with `ApiError`.
 */
export async function deleteAlert(
    id: string,
    signal?: AbortSignal
): Promise<void> {
    await delExactStatus(`${services.broker()}/alerts/${id}`, 204, signal)
}

/**
 * Acknowledges the notification of the alert's current arming, if any. The
 * request is id-only, with no body. Only the broker's 204 resolves; any other
 * status, 2xx included, rejects with `ApiError`.
 */
export async function acknowledgeAlert(
    id: string,
    signal?: AbortSignal
): Promise<void> {
    await postExactStatus(
        `${services.broker()}/alerts/${id}/acknowledge`,
        204,
        signal
    )
}
