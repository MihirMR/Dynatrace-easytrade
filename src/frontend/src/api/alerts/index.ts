import { del, getJson, patchJson, post, postJsonText, services } from "../http"
import { normalizeThresholdText } from "../../utils/alertValidation"
import { Alert, CreateAlertRequest } from "./types"
export * from "./types"

type AlertsDto = {
    results: Alert[]
}

/** Every alert of the account, newest first. */
export async function listAlerts(accountId: string): Promise<Alert[]> {
    const { results } = await getJson<AlertsDto>(
        `${services.broker()}/alerts?accountId=${accountId}`
    )
    return results
}

/**
 * Alerts whose current arming has triggered, most recently triggered first;
 * `unacknowledged` keeps only those not yet acknowledged.
 */
export async function listAlertNotifications(
    accountId: string,
    unacknowledged = true
): Promise<Alert[]> {
    const { results } = await getJson<AlertsDto>(
        `${services.broker()}/alerts/notifications?accountId=${accountId}&unacknowledged=${unacknowledged}`
    )
    return results
}

/**
 * Creates an alert. The threshold is spliced into the body as an unquoted
 * JSON number token: a JavaScript number would round `9999999999.99999999`
 * to `10000000000`, and the broker rejects a quoted number. Only text the
 * shared normaliser accepts is spliced, so the body is always valid JSON.
 */
export async function createAlert(req: CreateAlertRequest): Promise<Alert> {
    const token = normalizeThresholdText(req.threshold)
    if (token === null) {
        throw new Error("Invalid threshold")
    }
    const head = JSON.stringify({
        accountId: req.accountId,
        type: req.type,
        instrumentId: req.instrumentId,
        direction: req.direction,
    })
    const bodyText = `${head.slice(0, -1)},"threshold":${token}}`
    return await postJsonText<Alert>(`${services.broker()}/alerts`, bodyText)
}

/** Enables (re-arming it) or disables an alert; returns this update's state. */
export async function updateAlertEnabled(
    id: string,
    enabled: boolean
): Promise<Alert> {
    return await patchJson<Alert>(`${services.broker()}/alerts/${id}`, {
        enabled,
    })
}

/** Deletes an alert together with its notification. */
export async function deleteAlert(id: string): Promise<void> {
    await del(`${services.broker()}/alerts/${id}`)
}

/** Acknowledges the notification of the alert's current arming, if any. */
export async function acknowledgeAlert(id: string): Promise<void> {
    await post(`${services.broker()}/alerts/${id}/acknowledge`, {})
}
