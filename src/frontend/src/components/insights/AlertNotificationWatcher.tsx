import { useEffect } from "react"
import { useQueryClient } from "@tanstack/react-query"
import type { Alert } from "../../api/alerts/types"
import type { Instrument } from "../../api/instrument/types"
import { useToast } from "../../contexts/ToastContext/context"
import { useAuthUser } from "../../contexts/UserContext/context"
import { useAlertNotificationsQuery } from "../../hooks/useAlerts"
import { usePortfolioInsightsFlag } from "../../hooks/useFeatureFlags"
import {
    hasBeenShown,
    markShown,
    notificationKey,
} from "../../utils/alertNotificationTracker"
import { formatAlertNumber } from "../../utils/alertValidation"
import {
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"
import { instrumentKeys } from "../../utils/queryKeys"

function toastMessage(
    notification: Alert,
    instruments: Instrument[] | undefined
): string {
    const instrument =
        instruments?.find(
            (i) => String(i.id) === String(notification.instrumentId)
        )?.name ?? `instrument ${notification.instrumentId.slice(0, 8)}`
    const kind = notification.type === "TARGET_PRICE" ? "Price" : "P/L"
    const direction = notification.direction === "ABOVE" ? "above" : "below"
    const threshold = formatAlertNumber(notification.threshold)
    const now = formatAlertNumber(notification.triggerValue ?? 0)
    return `Alert triggered: ${instrument} ${kind} ${direction} ${threshold} (now ${now})`
}

/**
 * Polls the account's unacknowledged notifications while Portfolio Insights
 * is on and shows one info Toast per triggered arming. Renders no markup.
 *
 * Results that arrive after a logout, an account switch or a shutdown never
 * reach `data`: the shared notifications query discards them. A 403 runs the
 * feature shutdown; any other poll failure is logged and the next poll
 * retries.
 */
export function AlertNotificationWatcher(): null {
    const { userId } = useAuthUser()
    const flag = usePortfolioInsightsFlag()
    const queryClient = useQueryClient()
    const { showToast } = useToast()
    const { data, error } = useAlertNotificationsQuery(
        userId,
        flag && userId !== ""
    )

    useEffect(() => {
        if (!flag || !data) return
        // Names come from the instruments query the pages already fill; the
        // watcher never requests them itself.
        const instruments = queryClient.getQueryData<Instrument[]>(
            instrumentKeys.byUser(userId)
        )
        for (const notification of data) {
            if (notification.triggeredAt === null) continue
            const key = notificationKey(notification)
            if (hasBeenShown(key)) continue
            // Recorded before the Toast, so a repeated effect run (StrictMode,
            // a re-render with the same poll) never shows it twice.
            markShown(key)
            showToast(toastMessage(notification, instruments), "info")
        }
    }, [data, flag, userId, queryClient, showToast])

    useEffect(() => {
        if (isFeatureDisabledError(error)) {
            onPortfolioInsightsDisabled(queryClient)
        } else if (error) {
            console.error(
                "[AlertNotificationWatcher] notification poll failed",
                error
            )
        }
    }, [error, queryClient])

    return null
}
