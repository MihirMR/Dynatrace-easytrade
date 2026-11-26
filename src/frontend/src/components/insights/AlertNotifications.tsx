import type { Alert, AlertDirection, AlertType } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import {
    findInstrumentName,
    formatAlertNumber,
} from "../../utils/alertValidation"

type AlertNotificationsProps = {
    notifications: Alert[]
    instruments: Instrument[]
    onAcknowledge: (id: string) => void
    pendingIds: ReadonlySet<string>
    /** The acknowledge failure to show beside each item, by alert id. */
    errors: ReadonlyMap<string, string>
}

// The wording of the triggered-alert Toast, so the list and the Toast read alike.
const TYPE_LABELS: Record<AlertType, string> = {
    TARGET_PRICE: "Price",
    PROFIT_LOSS: "P/L",
}

const DIRECTION_LABELS: Record<AlertDirection, string> = {
    ABOVE: "above",
    BELOW: "below",
}

/**
 * Triggered, unacknowledged alerts with an Acknowledge action, rendered in the
 * order given (most recently triggered first) and hidden when there are none.
 * A failed acknowledge is shown inside its own item.
 * Items never carry `data-alert-id` or `alert-item`: loadgen binds those to
 * the alert list rows only.
 */
export function AlertNotifications({
    notifications,
    instruments,
    onAcknowledge,
    pendingIds,
    errors,
}: AlertNotificationsProps) {
    if (notifications.length === 0) return null

    return (
        <>
            <h4 className="section-heading">Notifications</h4>
            <ul id="alert-notifications">
                {notifications.map((n) => {
                    const textId = `alert-notification-text-${n.id}`
                    // Same lookup and fallback as the alert list rows.
                    const name =
                        findInstrumentName(instruments, n.instrumentId) ??
                        n.instrumentId.slice(0, 8)
                    const error = errors.get(n.id)
                    return (
                        <li
                            key={n.id}
                            className="alert-notification"
                            data-notification-id={n.id}
                        >
                            {/* Two flex children only, as in the alert list
                                rows, so the button stays at the end with or
                                without an error. */}
                            <div>
                                <span id={textId}>
                                    <strong>{name}</strong>{" "}
                                    {TYPE_LABELS[n.type]}{" "}
                                    {DIRECTION_LABELS[n.direction]}{" "}
                                    {formatAlertNumber(n.threshold)}{" "}
                                    <span className="text-secondary">
                                        {`(now ${formatAlertNumber(n.triggerValue ?? 0)})`}
                                    </span>
                                </span>
                                {error === undefined ? null : (
                                    <span className="field-error" role="alert">
                                        {error}
                                    </span>
                                )}
                            </div>
                            <button
                                type="button"
                                className="btn btn-secondary btn-sm alert-acknowledge"
                                aria-describedby={textId}
                                disabled={pendingIds.has(n.id)}
                                onClick={() => onAcknowledge(n.id)}
                            >
                                Acknowledge
                            </button>
                        </li>
                    )
                })}
            </ul>
        </>
    )
}
