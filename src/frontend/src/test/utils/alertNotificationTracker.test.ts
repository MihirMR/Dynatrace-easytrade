import "@testing-library/jest-dom/vitest"
import {
    hasBeenShown,
    markShown,
    notificationKey,
} from "../../utils/alertNotificationTracker"
import type { Alert } from "../../api/alerts/types"

const STORAGE_KEY = "portfolio-insights.notified"
const ALERT_ID = "b0000000-0000-4000-8000-000000000001"

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

beforeEach(() => sessionStorage.clear())

afterEach(() => {
    sessionStorage.clear()
    vi.restoreAllMocks()
})

it("tracker_markShown_hasBeenShownTrue", () => {
    markShown(notificationKey(alert))

    expect(hasBeenShown(notificationKey(alert))).toBe(true)
})

it.each<{ scenario: string; other: Alert }>([
    { scenario: "next revision", other: { ...alert, armingRevision: 2 } },
    { scenario: "other account", other: { ...alert, accountId: "2" } },
])("tracker_otherRevisionOrAccount_notShown ($scenario)", ({ other }) => {
    markShown(notificationKey(alert))

    expect(hasBeenShown(notificationKey(other))).toBe(false)
})

it("tracker_storage_usesSessionStorageKey", () => {
    markShown(notificationKey(alert))

    const stored = JSON.parse(
        sessionStorage.getItem(STORAGE_KEY) ?? "[]"
    ) as string[]
    expect(stored).toContain(`1:${ALERT_ID}:1`)
})

it("hasBeenShown_corruptStorage_returnsFalse", () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    sessionStorage.setItem(STORAGE_KEY, "not-json")

    expect(hasBeenShown(notificationKey(alert))).toBe(false)
})

it("markShown_storageThrows_doesNotThrow", () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new Error("quota exceeded")
    })

    expect(() => markShown(notificationKey(alert))).not.toThrow()
})
