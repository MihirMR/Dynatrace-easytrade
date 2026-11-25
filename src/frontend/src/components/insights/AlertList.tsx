import type { Alert, AlertDirection, AlertType } from "../../api/alerts"
import type { Instrument } from "../../api/instrument"
import { useFormatter } from "../../contexts/FormatterContext/context"
import { formatAlertNumber } from "../../utils/alertValidation"

type AlertListProps = {
    alerts: Alert[]
    instruments: Instrument[]
    onSetEnabled: (id: string, enabled: boolean) => void
    onDelete: (id: string) => void
    pendingIds: ReadonlySet<string>
    rowErrors: Record<string, string>
    deletedId: string | null
}

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
    deletedId,
}: AlertListProps) {
    const { formatDate } = useFormatter()

    function instrumentName(alert: Alert): string {
        return (
            instruments.find((i) => String(i.id) === String(alert.instrumentId))
                ?.name ?? alert.instrumentId.slice(0, 8)
        )
    }

    function statusText(alert: Alert): string {
        if (!alert.enabled) return "Disabled"
        if (alert.triggeredAt === null) return "Armed"
        const triggeredMs = Date.parse(alert.triggeredAt)
        // Intl rejects NaN with a RangeError, which would unmount the page;
        // an unparsable timestamp is shown as received instead.
        const when = Number.isNaN(triggeredMs)
            ? alert.triggeredAt
            : formatDate(triggeredMs)
        return `Triggered at ${when} (${formatAlertNumber(alert.triggerValue ?? 0)})`
    }

    // `@types/react` 18 does not declare `value` on <output>; the spread
    // passes it through, so loadgen can match `[@value="<id>"]`.
    const deletedOutput =
        deletedId === null ? null : (
            <output id="alert-deleted-id" {...{ value: deletedId }}>
                {deletedId}
            </output>
        )

    if (alerts.length === 0) {
        return (
            <>
                <p id="alerts-empty" className="empty-state">
                    No alerts yet.
                </p>
                {deletedOutput}
            </>
        )
    }

    return (
        <>
            <ul id="alerts-list">
                {alerts.map((a) => {
                    const state = rowStateOf(a)
                    const pending = pendingIds.has(a.id)
                    const rowError = rowErrors[a.id]
                    // Gives the repeated button labels their row as an
                    // accessible description, without changing their names.
                    const summaryId = `alert-summary-${a.id}`

                    return (
                        <li
                            key={a.id}
                            className="alert-item"
                            data-alert-id={a.id}
                        >
                            {/* Two flex children only, so `.alert-item`'s
                                space-between keeps the actions at the end of
                                every row, with or without a row error. */}
                            <div>
                                <div id={summaryId}>
                                    <span>{instrumentName(a)}</span>{" "}
                                    <span>{TYPE_LABELS[a.type]}</span>{" "}
                                    <span>{DIRECTION_LABELS[a.direction]}</span>{" "}
                                    <span className="font-mono">
                                        {formatAlertNumber(a.threshold)}
                                    </span>
                                </div>
                                <span className="text-sm text-secondary">
                                    {statusText(a)}
                                </span>
                                {rowError ? (
                                    <span className="field-error" role="alert">
                                        {rowError}
                                    </span>
                                ) : null}
                            </div>
                            <div className="form-actions">
                                {state === "armed" && (
                                    <button
                                        type="button"
                                        className="btn btn-secondary btn-sm alert-toggle"
                                        disabled={pending}
                                        aria-describedby={summaryId}
                                        onClick={() =>
                                            onSetEnabled(a.id, false)
                                        }
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
                                            onClick={() =>
                                                onSetEnabled(a.id, true)
                                            }
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
            {deletedOutput}
        </>
    )
}
