import "@testing-library/jest-dom/vitest"
import type * as TrackerModule from "../../utils/alertNotificationTracker"
import type { Alert } from "../../api/alerts/types"

const STORAGE_KEY = "portfolio-insights.notified"
const ALERT_ID = "b0000000-0000-4000-8000-000000000001"

/** The key `notificationKey(alert)` gives. */
const SHOWN_KEY = `1:${ALERT_ID}:1`

/** Text a corrupt record carries; no console line may repeat it. */
const SENTINEL = "SENTINEL-R13F01"

const alert: Alert = {
    id: ALERT_ID,
    accountId: "1",
    instrumentId: "c0000000-0000-4000-8000-000000000001",
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: 10,
    enabled: true,
    armingRevision: 1,
    triggeredAt: "2026-01-01T12:00:00.000Z",
    triggerValue: 10.5,
    acknowledged: false,
    createdAt: "2026-01-01T11:00:00.000Z",
}

let tracker: typeof TrackerModule

/** Evaluates the tracker module afresh, as a newly loaded page does. */
async function loadTracker(): Promise<typeof TrackerModule> {
    vi.resetModules()
    return import("../../utils/alertNotificationTracker")
}

/**
 * Ends the current synchronous run: lets the tracker's end-of-run microtasks
 * (the deferred write, the read refresh) run before the case goes on.
 */
async function nextRun(): Promise<void> {
    await Promise.resolve()
}

/**
 * Reloads the tab: the current run ends, as it does before the browser
 * handles a reload, then a fresh page keeps the tab's `sessionStorage`.
 */
async function reload(): Promise<void> {
    await nextRun()
    tracker = await loadTracker()
}

/** Marks `key`, then ends the run, so the deferred write runs too. */
async function markShownAndEndRun(key: string): Promise<void> {
    tracker.markShown(key)
    await nextRun()
}

/** Keys of three successive armings of `alert`. */
function revisionKeys(): string[] {
    return [1, 2, 3].map((armingRevision) =>
        tracker.notificationKey({ ...alert, armingRevision })
    )
}

function silenceConsoleError() {
    return vi.spyOn(console, "error").mockImplementation(() => undefined)
}

function quotaExceeded(): DOMException {
    return new DOMException(
        "The quota has been exceeded.",
        "QuotaExceededError"
    )
}

/** Makes every `sessionStorage` write throw `failure`, as a full store does. */
function failWrites(failure: DOMException = quotaExceeded()) {
    return vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw failure
    })
}

/** Makes `sessionStorage` reads and writes throw, as disabled storage does. */
function disableStorage(): void {
    const denied = (): never => {
        throw new DOMException("Storage is disabled.", "SecurityError")
    }
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(denied)
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(denied)
}

/** One console argument as it would read in the console. */
function renderArgument(value: unknown): string {
    if (typeof value === "string") return value
    if (value instanceof Error) {
        return `${value.name} ${value.message} ${value.stack ?? ""}`
    }
    const json: string | undefined = JSON.stringify(value)
    return json ?? String(value)
}

/** Every console call as one line of its rendered arguments. */
function renderCalls(calls: unknown[][]): string[] {
    return calls.map((args) => args.map(renderArgument).join(" "))
}

// Each case gets a fresh page, so no case sees what another kept in memory.
beforeEach(async () => {
    sessionStorage.clear()
    tracker = await loadTracker()
})

afterEach(() => {
    sessionStorage.clear()
    vi.restoreAllMocks()
})

it("tracker_markShown_hasBeenShownTrue", () => {
    tracker.markShown(tracker.notificationKey(alert))

    expect(tracker.hasBeenShown(tracker.notificationKey(alert))).toBe(true)
})

it.each<{ scenario: string; other: Alert }>([
    { scenario: "next revision", other: { ...alert, armingRevision: 2 } },
    { scenario: "other account", other: { ...alert, accountId: "2" } },
])("tracker_otherRevisionOrAccount_notShown ($scenario)", ({ other }) => {
    tracker.markShown(tracker.notificationKey(alert))

    expect(tracker.hasBeenShown(tracker.notificationKey(other))).toBe(false)
})

it("tracker_storage_usesSessionStorageKey", async () => {
    tracker.markShown(tracker.notificationKey(alert))
    await nextRun()

    const stored = JSON.parse(
        sessionStorage.getItem(STORAGE_KEY) ?? "[]"
    ) as string[]
    expect(stored).toContain(`1:${ALERT_ID}:1`)
})

// Each record names the key in some form, so only its shape keeps it unshown.
it.each<{ scenario: string; record: string }>([
    { scenario: "invalid JSON", record: `[${SHOWN_KEY}` },
    {
        scenario: "a JSON object",
        record: JSON.stringify({ [SHOWN_KEY]: true }),
    },
    { scenario: "a JSON string", record: JSON.stringify(SHOWN_KEY) },
])("hasBeenShown_corruptStorage_returnsFalse ($scenario)", ({ record }) => {
    silenceConsoleError()
    sessionStorage.setItem(STORAGE_KEY, record)

    expect(tracker.hasBeenShown(tracker.notificationKey(alert))).toBe(false)
})

it.each<{ scenario: string; record: string }>([
    { scenario: "invalid JSON", record: SENTINEL },
    {
        scenario: "JSON that is not a list",
        record: JSON.stringify({ [`${SENTINEL}-shape`]: "acct:secret" }),
    },
])(
    "hasBeenShown_corruptStorage_logsNoRecordContent ($scenario)",
    ({ record }) => {
        const consoleError = silenceConsoleError()
        sessionStorage.setItem(STORAGE_KEY, record)

        tracker.hasBeenShown(tracker.notificationKey(alert))

        expect(renderCalls(consoleError.mock.calls)).toEqual([
            expect.not.stringContaining(SENTINEL),
        ])
    }
)

it("hasBeenShown_corruptStorageReadTwice_logsOnce", async () => {
    const consoleError = silenceConsoleError()
    sessionStorage.setItem(STORAGE_KEY, "not-json")

    tracker.hasBeenShown(tracker.notificationKey(alert))
    // A later run reads the record again; its unchanged text is not re-parsed.
    await nextRun()
    tracker.hasBeenShown(tracker.notificationKey(alert))

    expect(consoleError).toHaveBeenCalledTimes(1)
})

it.each<{ scenario: string; record: string; expected: string[] }>([
    {
        scenario: "a list with other entries",
        record: JSON.stringify(["1:x:1", 7, null, { a: 1 }, "2:y:3"]),
        expected: ["1:x:1", "2:y:3", SHOWN_KEY],
    },
    {
        scenario: "a JSON object",
        record: JSON.stringify({ "1:x:1": true }),
        expected: [SHOWN_KEY],
    },
    { scenario: "invalid JSON", record: "not-json", expected: [SHOWN_KEY] },
])(
    "markShown_storedRecord_keepsOnlyValidKeys ($scenario)",
    async ({ record, expected }) => {
        silenceConsoleError()
        sessionStorage.setItem(STORAGE_KEY, record)

        tracker.markShown(tracker.notificationKey(alert))
        await nextRun()

        expect(JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "")).toEqual(
            expected
        )
    }
)

it("markShown_alreadyStored_writesNothing", async () => {
    const key = tracker.notificationKey(alert)
    tracker.markShown(key)
    await nextRun()
    const writes = vi.spyOn(Storage.prototype, "setItem")

    tracker.markShown(key)
    await nextRun()

    expect(writes).not.toHaveBeenCalled()
})

it("markShown_severalKeysInOneRun_writesOnce", async () => {
    const writes = vi.spyOn(Storage.prototype, "setItem")
    const keys = revisionKeys()

    for (const key of keys) tracker.markShown(key)
    await nextRun()

    expect(writes.mock.calls).toEqual([[STORAGE_KEY, JSON.stringify(keys)]])
})

it("hasBeenShown_severalLookupsInOneRun_readsOnce", async () => {
    const reads = vi.spyOn(Storage.prototype, "getItem")

    // One poll: each notification is looked up, then marked.
    for (const key of revisionKeys()) {
        if (!tracker.hasBeenShown(key)) tracker.markShown(key)
    }
    await nextRun()

    expect(reads).toHaveBeenCalledTimes(1)
})

it("hasBeenShown_storageClearedInLaterRun_returnsFalse", async () => {
    const key = tracker.notificationKey(alert)
    tracker.markShown(key)
    await nextRun()

    sessionStorage.clear()
    await nextRun()

    expect(tracker.hasBeenShown(key)).toBe(false)
})

it("markShown_storageThrows_doesNotThrow", () => {
    silenceConsoleError()
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new Error("quota exceeded")
    })
    // Holds the end-of-run work, so a throw from the deferred write fails
    // this case instead of surfacing as an unhandled error.
    const deferred: VoidFunction[] = []
    vi.spyOn(globalThis, "queueMicrotask").mockImplementation((callback) => {
        deferred.push(callback)
    })

    expect(() => {
        tracker.markShown(tracker.notificationKey(alert))
        for (const callback of deferred) callback()
    }).not.toThrow()
})

const writeFailures: { failure: string; breakStorage: () => void }[] = [
    {
        failure: "quota exceeded",
        breakStorage: () => {
            failWrites()
        },
    },
    { failure: "storage disabled", breakStorage: disableStorage },
]

/** When a case checks the tracker: before or after the deferred write. */
const checkMoments: { when: string; endRun: boolean }[] = [
    { when: "in the same run", endRun: false },
    { when: "after the failed write", endRun: true },
]

it.each(
    writeFailures.flatMap((failure) =>
        checkMoments.map((moment) => ({ ...failure, ...moment }))
    )
)(
    "markShown_storageWriteFails_hasBeenShownTrue ($failure, $when)",
    async ({ breakStorage, endRun }) => {
        silenceConsoleError()
        breakStorage()

        tracker.markShown(tracker.notificationKey(alert))
        if (endRun) await nextRun()

        expect(tracker.hasBeenShown(tracker.notificationKey(alert))).toBe(true)
    }
)

it.each(checkMoments)(
    "markShown_storageWriteFails_nextRevisionNotShown ($when)",
    async ({ endRun }) => {
        silenceConsoleError()
        failWrites()

        tracker.markShown(tracker.notificationKey(alert))
        if (endRun) await nextRun()

        const next = tracker.notificationKey({ ...alert, armingRevision: 2 })
        expect(tracker.hasBeenShown(next)).toBe(false)
    }
)

type Mark = "first" | "second"

// The key that failed to store is retried by the next mark, whichever key
// that mark records.
it.each<{ scenario: string; nextMark: Mark; stored: Mark[] }>([
    { scenario: "a new key", nextMark: "second", stored: ["first", "second"] },
    { scenario: "the same key again", nextMark: "first", stored: ["first"] },
])(
    "markShown_storageRecovers_storesEarlierKeys ($scenario)",
    async ({ nextMark, stored }) => {
        silenceConsoleError()
        const keys: Record<Mark, string> = {
            first: tracker.notificationKey(alert),
            second: tracker.notificationKey({ ...alert, armingRevision: 2 }),
        }
        const writes = failWrites()
        await markShownAndEndRun(keys.first)
        writes.mockRestore()

        await markShownAndEndRun(keys[nextMark])

        expect(JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "[]")).toEqual(
            stored.map((mark) => keys[mark])
        )
    }
)

it("markShown_storageRecoversWithPendingKeyAlreadyStored_keepsItOnce", async () => {
    silenceConsoleError()
    const pending = tracker.notificationKey(alert)
    const other = tracker.notificationKey({ ...alert, armingRevision: 0 })
    const next = tracker.notificationKey({ ...alert, armingRevision: 2 })
    const writes = failWrites()
    await markShownAndEndRun(pending)
    writes.mockRestore()
    // Meanwhile the tab's storage gained the pending key, as another document
    // of the same origin in this tab can write it.
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify([pending, other]))
    await nextRun()

    await markShownAndEndRun(next)

    expect(JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "[]")).toEqual([
        pending,
        other,
        next,
    ])
})

it("tracker_reload_keepsStoredKeys", async () => {
    const key = tracker.notificationKey(alert)
    tracker.markShown(key)

    await reload()

    expect(tracker.hasBeenShown(key)).toBe(true)
})

it("markShown_storageWriteFails_reloadShowsAgain", async () => {
    silenceConsoleError()
    failWrites()
    const key = tracker.notificationKey(alert)
    tracker.markShown(key)

    await reload()

    expect(tracker.hasBeenShown(key)).toBe(false)
})

it("markShown_storageWriteFails_logsFullError", async () => {
    const consoleError = silenceConsoleError()
    const failure = quotaExceeded()
    failWrites(failure)

    await markShownAndEndRun(tracker.notificationKey(alert))

    const logged = consoleError.mock.calls.find(
        ([message]) =>
            message ===
            "[alertNotificationTracker] could not store shown notifications; they count as shown until the page reloads"
    )
    expect(logged?.[1]).toBe(failure)
})

it("hasBeenShown_storageReadFails_usesLastRecordRead", async () => {
    silenceConsoleError()
    const key = tracker.notificationKey(alert)
    // Stored, so afterwards only the last record read holds the key; the
    // page keeps no pending copy of it.
    await markShownAndEndRun(key)
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
        throw new DOMException("Storage is disabled.", "SecurityError")
    })

    expect(tracker.hasBeenShown(key)).toBe(true)
})
