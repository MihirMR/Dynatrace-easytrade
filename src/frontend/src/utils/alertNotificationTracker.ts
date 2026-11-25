import type { Alert } from "../api/alerts/types"

/**
 * `sessionStorage` key of the notifications already toasted in this tab. The
 * record survives a reload and is discarded with the tab. Logout leaves it in
 * place, because every key names its account.
 */
export const NOTIFIED_STORAGE_KEY = "portfolio-insights.notified"

/**
 * Identifies one notification: the current arming of one alert of one
 * account. A re-armed alert has a new `armingRevision`, so its next trigger
 * is a new key and toasts again.
 */
export function notificationKey(
    alert: Pick<Alert, "accountId" | "id" | "armingRevision">
): string {
    return `${alert.accountId}:${alert.id}:${alert.armingRevision}`
}

// Storage errors are logged in full, not rethrown: a failure degrades to "not
// shown" so it never breaks the notification watcher.
function readShown(): string[] {
    try {
        const stored = sessionStorage.getItem(NOTIFIED_STORAGE_KEY)
        if (stored === null) return []
        const parsed: unknown = JSON.parse(stored)
        if (!Array.isArray(parsed)) {
            console.error(
                "[alertNotificationTracker] ignoring a shown-notifications record that is not a list",
                parsed
            )
            return []
        }
        const items: unknown[] = parsed
        return items.filter((item): item is string => typeof item === "string")
    } catch (error) {
        console.error(
            "[alertNotificationTracker] could not read shown notifications",
            error
        )
        return []
    }
}

/** True once `markShown(key)` has run in this tab; false when unreadable. */
export function hasBeenShown(key: string): boolean {
    return readShown().includes(key)
}

/**
 * Records `key` as shown in this tab. An unreadable record is replaced by one
 * holding only `key`. Never throws.
 */
export function markShown(key: string): void {
    try {
        const shown = readShown()
        if (shown.includes(key)) return
        shown.push(key)
        sessionStorage.setItem(NOTIFIED_STORAGE_KEY, JSON.stringify(shown))
    } catch (error) {
        console.error(
            "[alertNotificationTracker] could not record shown notification",
            error
        )
    }
}
