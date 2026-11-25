import type { Alert, AlertDirection, AlertType } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { formatAlertNumber } from "../../utils/alertValidation"

type AlertNotificationsProps = {
    notifications: Alert[]
    instruments: Instrument[]
    onAcknowledge: (id: string) => void
    pendingIds: ReadonlySet<string>
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

// Same lookup and fallback as the alert list rows.
function instrumentName(
    instruments: Instrument[],
    instrumentId: string
): string {
    return (
        instruments.find((i) => String(i.id) === String(instrumentId))?.name ??
        instrumentId.slice(0, 8)
    )
}

/**
 * Triggered, unacknowledged alerts with an Acknowledge action, rendered in the
 * order given (most recently triggered first) and hidden when there are none.
 * Items never carry `data-alert-id` or `alert-item`: loadgen binds those to
 * the alert list rows only.
 */
export function AlertNotifications({
    notifications,
    instruments,
    onAcknowledge,
    pendingIds,
}: AlertNotificationsProps) {
    if (notifications.length === 0) return null

    return (
        <>
            <h4 className="section-heading">Notifications</h4>
            <ul id="alert-notifications">
                {notifications.map((n) => {
                    const textId = `alert-notification-text-${n.id}`
                    const name = instrumentName(instruments, n.instrumentId)
                    return (
                        <li
                            key={n.id}
                            className="alert-notification"
                            data-notification-id={n.id}
                        >
                            <span id={textId}>
                                <strong>{name}</strong> {TYPE_LABELS[n.type]}{" "}
                                {DIRECTION_LABELS[n.direction]}{" "}
                                {formatAlertNumber(n.threshold)}{" "}
                                <span className="text-muted">
                                    {`(now ${formatAlertNumber(n.triggerValue ?? 0)})`}
                                </span>
                            </span>
                            <button
                                type="button"
                                className="btn btn-primary btn-sm alert-acknowledge"
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
