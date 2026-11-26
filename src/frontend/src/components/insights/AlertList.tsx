import type { Alert, AlertDirection, AlertType } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { useFormatter } from "../../contexts/FormatterContext/context"
import {
    findInstrumentName,
    formatAlertNumber,
} from "../../utils/alertValidation"

type AlertListProps = {
    alerts: Alert[]
    instruments: Instrument[]
    onSetEnabled: (id: string, enabled: boolean) => void
    onDelete: (id: string) => void
    pendingIds: ReadonlySet<string>
    /**
     * Every failure message to show beside each row, by alert id, in the
     * order given. A row shows each distinct message once.
     */
    rowErrors: ReadonlyMap<string, readonly string[]>
}

type DeletedAlertOutputProps = { deletedId: string | null }

type AlertRowState = "armed" | "triggered" | "disabled"

const TYPE_LABELS: Record<AlertType, string> = {
    TARGET_PRICE: "Price",
    PROFIT_LOSS: "P/L %",
}

const DIRECTION_LABELS: Record<AlertDirection, string> = {
    ABOVE: "Above",
    BELOW: "Below",
}

function rowStateOf(alert: Alert): AlertRowState {
    if (!alert.enabled) return "disabled"
    return alert.triggeredAt === null ? "armed" : "triggered"
}

// The shared lookup, with the rows' fallback to the id's first 8 characters.
function instrumentNameOf(alert: Alert, instruments: Instrument[]): string {
    return (
        findInstrumentName(instruments, alert.instrumentId) ??
        alert.instrumentId.slice(0, 8)
    )
}

/**
 * A row's summary as one line of text, worded as the row shows it: instrument,
 * type, direction and threshold. Names an alert in feedback that outlives its
 * row.
 */
export function alertSummaryText(
    alert: Alert,
    instruments: Instrument[]
): string {
    return [
        instrumentNameOf(alert, instruments),
        TYPE_LABELS[alert.type],
        DIRECTION_LABELS[alert.direction],
        formatAlertNumber(alert.threshold),
    ].join(" ")
}

/**
 * The "Deleted alert <id>" receipt of the latest confirmed delete, a
 * `p.form-hint` worded and styled like the form's "Created alert <id>"
 * receipt. Its `output#alert-deleted-id` carries the id as both `value` and
 * text. It is rendered apart from the list, so a refetch that is pending or
 * fails after the 204 keeps the confirmation loadgen waits for.
 */
export function DeletedAlertOutput({ deletedId }: DeletedAlertOutputProps) {
    if (deletedId === null) return null
    return (
        <p className="form-hint">
            Deleted alert{" "}
            {/* `@types/react` 18 does not declare `value` on <output>; the
                spread passes it through, so loadgen can match
                `[@value="<id>"]`. */}
            <output id="alert-deleted-id" {...{ value: deletedId }}>
                {deletedId}
            </output>
        </p>
    )
}

/**
 * The account's alerts, in the order given (newest first from the server),
 * with the actions each row's state allows. Presentational only: every
 * action goes up through a callback. The ids, classes and `data-alert-id`
 * are bound by loadgen selectors.
 */
export function AlertList({
    alerts,
    instruments,
    onSetEnabled,
    onDelete,
    pendingIds,
    rowErrors,
}: AlertListProps) {
    const { formatTime } = useFormatter()

    function statusText(alert: Alert): string {
        if (!alert.enabled) return "Disabled"
        if (alert.triggeredAt === null) return "Armed"
        const triggeredMs = Date.parse(alert.triggeredAt)
        // A point in time, as "at" needs: `formatDate` is relative under a
        // day ("10 minutes ago"). Intl rejects NaN with a RangeError,
        // which would unmount the page; an unparsable timestamp is shown as
        // received instead.
        const when = Number.isNaN(triggeredMs)
            ? alert.triggeredAt
            : formatTime(triggeredMs)
        return `Triggered at ${when} (${formatAlertNumber(alert.triggerValue ?? 0)})`
    }

    if (alerts.length === 0) {
        return (
            <p id="alerts-empty" className="empty-state">
                No alerts yet.
            </p>
        )
    }

    return (
        <ul id="alerts-list">
            {alerts.map((a) => {
                const state = rowStateOf(a)
                const pending = pendingIds.has(a.id)
                const rowMessages = Array.from(new Set(rowErrors.get(a.id)))
                // Gives the repeated button labels their row as an
                // accessible description, without changing their names.
                const summaryId = `alert-summary-${a.id}`

                return (
                    <li key={a.id} className="alert-item" data-alert-id={a.id}>
                        {/* Two flex children only, so `.alert-item`'s
                            space-between keeps the actions at the end of
                            every row, with or without row errors. */}
                        <div>
                            <div id={summaryId}>
                                <span>{instrumentNameOf(a, instruments)}</span>{" "}
                                <span>{TYPE_LABELS[a.type]}</span>{" "}
                                <span>{DIRECTION_LABELS[a.direction]}</span>{" "}
                                <span className="font-mono">
                                    {formatAlertNumber(a.threshold)}
                                </span>
                            </div>
                            <span className="text-sm text-secondary">
                                {statusText(a)}
                            </span>
                            {rowMessages.map((message) => (
                                <span
                                    key={message}
                                    className="field-error"
                                    role="alert"
                                >
                                    {message}
                                </span>
                            ))}
                        </div>
                        <div className="form-actions">
                            {state === "armed" && (
                                <button
                                    type="button"
                                    className="btn btn-secondary btn-sm alert-toggle"
                                    disabled={pending}
                                    aria-describedby={summaryId}
                                    onClick={() => onSetEnabled(a.id, false)}
                                >
                                    Disable
                                </button>
                            )}
                            {state === "triggered" && (
                                <>
                                    <button
                                        type="button"
                                        className="btn btn-secondary btn-sm alert-toggle"
                                        disabled={pending}
                                        aria-describedby={summaryId}
                                        onClick={() => onSetEnabled(a.id, true)}
                                    >
                                        Re-arm
                                    </button>
                                    <button
                                        type="button"
                                        className="btn btn-secondary btn-sm alert-disable"
                                        disabled={pending}
                                        aria-describedby={summaryId}
                                        onClick={() =>
                                            onSetEnabled(a.id, false)
                                        }
                                    >
                                        Disable
                                    </button>
                                </>
                            )}
                            {state === "disabled" && (
                                <button
                                    type="button"
                                    className="btn btn-secondary btn-sm alert-toggle"
                                    disabled={pending}
                                    aria-describedby={summaryId}
                                    onClick={() => onSetEnabled(a.id, true)}
                                >
                                    Enable
                                </button>
                            )}
                            <button
                                type="button"
                                className="btn btn-danger btn-sm alert-delete"
                                disabled={pending}
                                aria-describedby={summaryId}
                                onClick={() => onDelete(a.id)}
                            >
                                Delete
                            </button>
                        </div>
                    </li>
                )
            })}
        </ul>
    )
}
