import type { Alert } from "../api/alerts/types"

/**
 * `sessionStorage` key of the notifications already toasted in this tab. While
 * storage works, the record survives a reload and is discarded with the tab.
 * When storage rejects a write (quota, storage disabled), the key is kept in
 * memory for the open page instead, so the same arming still toasts only once
 * there, but a reload can toast it once more. Logout leaves the record in
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

/**
 * The stored record as last read: its raw text and the keys it holds. It is
 * read at most once per synchronous run, such as the lookups and marks of one
 * poll, and its text is parsed only when it changes, so a lookup does not
 * re-parse the whole history and a corrupt record is reported once, not on
 * every lookup.
 */
let stored: { text: string | null; keys: ReadonlySet<string> } = {
    text: null,
    keys: new Set(),
}

/**
 * True once the current synchronous run has read the record; a microtask
 * clears it when the run ends, so the next run sees any change to storage.
 */
let readInThisRun = false

/**
 * Keys marked in this page that `sessionStorage` does not hold yet: waiting
 * for the write at the end of the run that marked them, or kept after that
 * write failed. They count as shown for the life of the page and join the
 * next write.
 */
const unpersisted = new Set<string>()

/** True while the end-of-run write is queued. */
let flushScheduled = false

/** The keys a stored record holds; a corrupt record holds none. */
function parseStored(text: string | null): ReadonlySet<string> {
    if (text === null) return new Set()
    let parsed: unknown
    try {
        parsed = JSON.parse(text)
    } catch {
        // The SyntaxError is not logged, because its message quotes the
        // stored record. Storage errors still log the full error object, as
        // .claude/rules/typescript.md requires.
        console.error(
            "[alertNotificationTracker] ignoring a shown-notifications record that is not valid JSON"
        )
        return new Set()
    }
    if (!Array.isArray(parsed)) {
        console.error(
            "[alertNotificationTracker] ignoring a shown-notifications record that is not a list"
        )
        return new Set()
    }
    const items: unknown[] = parsed
    return new Set(
        items.filter((item): item is string => typeof item === "string")
    )
}

// The record is read once per synchronous run; later lookups and marks in the
// run reuse that read. Storage errors are logged in full, not rethrown, so a
// failure never breaks the notification watcher: an unreadable record counts
// as the last one read, and a key that cannot be stored stays shown in this
// page's memory.
function readStored(): ReadonlySet<string> {
    if (readInThisRun) return stored.keys
    readInThisRun = true
    queueMicrotask(() => {
        readInThisRun = false
    })
    let text: string | null
    try {
        text = sessionStorage.getItem(NOTIFIED_STORAGE_KEY)
    } catch (error) {
        console.error(
            "[alertNotificationTracker] could not read shown notifications",
            error
        )
        return stored.keys
    }
    if (text !== stored.text) stored = { text, keys: parseStored(text) }
    return stored.keys
}

/**
 * Stores the keys `sessionStorage` does not hold yet with one write, after
 * the keys of the record this run read, in their order; a corrupt record is
 * replaced by its valid keys. Only `markShown` queues it, as a microtask at
 * the end of its run and after adding a key, so at least one key is pending.
 * Never throws: when the write fails, the keys stay shown in this page's
 * memory and the next mark retries them.
 */
function flush(): void {
    flushScheduled = false
    const keys = stored.keys
    const next = [...keys, ...[...unpersisted].filter((k) => !keys.has(k))]
    const text = JSON.stringify(next)
    try {
        sessionStorage.setItem(NOTIFIED_STORAGE_KEY, text)
    } catch (error) {
        console.error(
            "[alertNotificationTracker] could not store shown notifications; they count as shown until the page reloads",
            error
        )
        return
    }
    stored = { text, keys: new Set(next) }
    unpersisted.clear()
}

/**
 * True once `markShown(key)` has run in this tab: the stored record holds
 * `key`, or this page holds it in memory, because its write is still queued
 * for the end of the run or failed.
 */
export function hasBeenShown(key: string): boolean {
    return unpersisted.has(key) || readStored().has(key)
}

/**
 * Records `key` as shown in this tab, at once for this page. Every key one
 * synchronous run marks is stored by a single write when the run ends, which
 * also carries the keys earlier writes in this page could not store. When
 * that write fails, the keys count as shown until the page reloads. Never
 * throws.
 */
export function markShown(key: string): void {
    if (readStored().has(key)) return
    // Remembered first, so this page counts it as shown whatever storage does.
    unpersisted.add(key)
    if (flushScheduled) return
    flushScheduled = true
    // A microtask runs before the browser handles a reload or navigation, so
    // working storage holds the key by the time the page can reload.
    queueMicrotask(flush)
}
