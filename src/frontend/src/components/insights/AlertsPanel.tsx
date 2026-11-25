import { useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo } from "react"
import type {
    AlertDirection,
    AlertFormInput,
    AlertType,
    CreateAlertRequest,
} from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import {
    useAcknowledgeAlertMutation,
    useAlertNotificationsQuery,
    useAlertsQuery,
    useCreateAlertMutation,
    useDeleteAlertMutation,
    useUpdateAlertEnabledMutation,
} from "../../hooks/useAlerts"
import {
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import { AlertForm } from "./AlertForm"
import { AlertList } from "./AlertList"
import { AlertNotifications } from "./AlertNotifications"

type AlertsPanelProps = {
    accountId: string
    instruments: Instrument[]
}

function isAlertType(value: string): value is AlertType {
    return value === "TARGET_PRICE" || value === "PROFIT_LOSS"
}

function isAlertDirection(value: string): value is AlertDirection {
    return value === "ABOVE" || value === "BELOW"
}

/**
 * Builds the create request from the form's text. The threshold is passed on
 * exactly as typed: `createAlert` normalises it, and the typed text is what
 * `output#alert-created-id` reports back as `data-threshold` for loadgen.
 */
function toCreateAlertRequest(
    accountId: string,
    input: AlertFormInput
): CreateAlertRequest | null {
    if (!isAlertType(input.type) || !isAlertDirection(input.direction)) {
        return null
    }
    return {
        accountId,
        type: input.type,
        instrumentId: input.instrumentId,
        direction: input.direction,
        threshold: input.threshold,
    }
}

/**
 * The alerts section of the `/insights` page: create form, alert list and
 * unacknowledged notifications. Wiring only. The shared hooks own the
 * requests, invalidation, the activation check, the business event, the
 * mutation 403 shutdown and every error message; the list and notification
 * queries share their cache entries with `AlertNotificationWatcher`.
 */
export function AlertsPanel({ accountId, instruments }: AlertsPanelProps) {
    const queryClient = useQueryClient()
    const alertsResult = useAlertsQuery(accountId, true)
    const notificationsResult = useAlertNotificationsQuery(accountId, true)

    const create = useCreateAlertMutation(accountId)
    const update = useUpdateAlertEnabledMutation(accountId)
    const remove = useDeleteAlertMutation(accountId)
    const acknowledge = useAcknowledgeAlertMutation(accountId)

    useEffect(() => {
        if (
            isFeatureDisabledError(alertsResult.error) ||
            isFeatureDisabledError(notificationsResult.error)
        ) {
            onPortfolioInsightsDisabled(queryClient)
        }
    }, [alertsResult.error, notificationsResult.error, queryClient])

    // Only the list failure is logged here: `AlertNotificationWatcher` logs
    // failures of the notifications poll this panel shares with it.
    useEffect(() => {
        if (alertsResult.error && !isFeatureDisabledError(alertsResult.error)) {
            console.error(
                "[AlertsPanel] could not load alerts",
                alertsResult.error
            )
        }
    }, [alertsResult.error])

    const createdAlert = create.created
    const created = useMemo(
        () =>
            createdAlert === null
                ? null
                : {
                      id: createdAlert.alert.id,
                      threshold: createdAlert.thresholdText,
                  },
        [createdAlert]
    )

    const pendingIds = useMemo<ReadonlySet<string>>(() => {
        const ids = new Set<string>()
        if (update.isPending && update.variables !== undefined) {
            ids.add(update.variables.id)
        }
        if (remove.isPending && remove.variables !== undefined) {
            ids.add(remove.variables)
        }
        if (acknowledge.isPending && acknowledge.variables !== undefined) {
            ids.add(acknowledge.variables)
        }
        return ids
    }, [
        update.isPending,
        update.variables,
        remove.isPending,
        remove.variables,
        acknowledge.isPending,
        acknowledge.variables,
    ])

    // An acknowledge failure is keyed by the alert id as well, so it shows
    // beside that alert's list row.
    const rowErrors = useMemo<Record<string, string>>(() => {
        const errors: Record<string, string> = {}
        for (const rowError of [
            update.rowError,
            remove.rowError,
            acknowledge.rowError,
        ]) {
            if (rowError !== null) errors[rowError.id] = rowError.message
        }
        return errors
    }, [update.rowError, remove.rowError, acknowledge.rowError])

    function handleCreate(input: AlertFormInput) {
        const request = toCreateAlertRequest(accountId, input)
        if (request === null) {
            // `AlertForm` validates type and direction before calling back,
            // so this only completes the type narrowing.
            console.error(
                "[AlertsPanel] invalid alert type or direction",
                input
            )
            return
        }
        create.mutate(request)
    }

    function handleSetEnabled(id: string, enabled: boolean) {
        update.mutate({ id, enabled })
    }

    function handleDelete(id: string) {
        remove.mutate(id)
    }

    function handleAcknowledge(id: string) {
        acknowledge.mutate(id)
    }

    // A 403 renders nothing: the effect above runs the feature shutdown.
    function renderAlertList() {
        if (isFeatureDisabledError(alertsResult.error)) return null
        if (alertsResult.isError) {
            return (
                <div className="status-message status-error">
                    Could not load alerts. Please try again later.
                </div>
            )
        }
        if (alertsResult.isPending) {
            return <p className="empty-state">Loading alerts…</p>
        }
        return (
            <AlertList
                alerts={alertsResult.data}
                instruments={instruments}
                onSetEnabled={handleSetEnabled}
                onDelete={handleDelete}
                pendingIds={pendingIds}
                rowErrors={rowErrors}
                deletedId={remove.deletedId}
            />
        )
    }

    function renderNotifications() {
        if (isFeatureDisabledError(notificationsResult.error)) return null
        if (notificationsResult.isError) {
            return (
                <div className="status-message status-error">
                    Could not load notifications. Please try again later.
                </div>
            )
        }
        if (notificationsResult.isPending) return null
        // The heading and list share one block, so only the heading's own
        // margin separates them; with nothing to show, no block takes a gap.
        if (notificationsResult.data.length === 0) return null
        return (
            <div>
                <AlertNotifications
                    notifications={notificationsResult.data}
                    instruments={instruments}
                    onAcknowledge={handleAcknowledge}
                    pendingIds={pendingIds}
                />
            </div>
        )
    }

    return (
        <section
            id="alerts-panel"
            className="card"
            aria-labelledby="alerts-panel-heading"
        >
            <h3 id="alerts-panel-heading" className="section-heading">
                Price and P/L alerts
            </h3>
            {/* Regions are direct children of the stack, so a region that
                renders nothing adds no gap. */}
            <div className="form">
                <AlertForm
                    instruments={instruments}
                    onCreate={handleCreate}
                    isPending={create.isPending}
                    serverError={create.errorMessage}
                    created={created}
                />
                {renderAlertList()}
                {renderNotifications()}
            </div>
        </section>
    )
}
