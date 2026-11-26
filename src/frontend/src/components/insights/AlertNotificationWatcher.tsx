import { useEffect } from "react"
import { useQueryClient } from "@tanstack/react-query"
import type { Alert } from "../../api/alerts/types"
import { loggableError } from "../../api/http"
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
import {
    findInstrumentName,
    formatAlertNumber,
} from "../../utils/alertValidation"
import {
    featureResultContext,
    isCurrentFeatureContext,
    isFeatureDisabledError,
} from "../../utils/portfolioInsightsFeature"
import { featureFlagKeys, instrumentKeys } from "../../utils/queryKeys"

function toastMessage(
    notification: Alert,
    instruments: Instrument[] | undefined
): string {
    const instrument =
        findInstrumentName(instruments, notification.instrumentId) ??
        `instrument ${notification.instrumentId.slice(0, 8)}`
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
 * reach `data`: the shared notifications query discards them. A poll it did
 * publish carries the account, session and activation of the request that
 * produced it, and the Toast effect delivers it only while those still hold.
 * That covers a change landing after a render commits a poll and before
 * React runs its effects, and a poll still cached from an earlier session,
 * shown again after a switch away and back, which is never toasted under the
 * later one. A current 403 is shut down by the shared feature request guard;
 * any other poll failure is logged and the next poll retries.
 */
export function AlertNotificationWatcher(): null {
    const { userId } = useAuthUser()
    const flag = usePortfolioInsightsFlag()
    const queryClient = useQueryClient()
    const { showToast } = useToast()
    const { data, dataUpdatedAt, error } = useAlertNotificationsQuery(
        userId,
        flag && userId !== ""
    )

    // `dataUpdatedAt` re-runs delivery when a poll returns equal
    // notifications, which keep their reference but carry the context of the
    // poll that just returned them.
    useEffect(() => {
        if (!flag || data === undefined) return
        // Checked against the poll's own request, through the shared
        // activation owner, and against the shared flag state, so a poll
        // that is no longer current for the account shown is neither toasted
        // nor recorded as shown.
        const produced = featureResultContext(data)
        if (
            produced === undefined ||
            produced.userId !== userId ||
            !isCurrentFeatureContext(produced) ||
            queryClient.getQueryData<boolean>(
                featureFlagKeys.portfolioInsights
            ) !== true
        ) {
            return
        }
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
    }, [data, dataUpdatedAt, flag, userId, queryClient, showToast])

    // A 403 ends in the feature shutdown that the notifications query runs
    // itself, so only other poll failures are logged here.
    useEffect(() => {
        if (error && !isFeatureDisabledError(error)) {
            console.error(
                "[AlertNotificationWatcher] notification poll failed",
                loggableError(error, userId)
            )
        }
    }, [error])

    return null
}
