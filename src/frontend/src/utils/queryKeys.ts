import { QueryClient } from "@tanstack/react-query"

export const userKeys = {
    all: ["users"] as const,
    preset: ["users", "preset"] as const,
    current: ["users", "current"] as const,
    byId: (userId: string) => ["users", "current", userId] as const,
}

export const balanceKeys = {
    current: ["balance"] as const,
    byId: (userId: string) => ["balance", userId] as const,
}

export const transactionKeys = {
    all: ["transactions"] as const,
    byUser: (userId: string) => ["transactions", userId] as const,
}

export const instrumentKeys = {
    all: ["instruments"] as const,
    byUser: (accountId?: string) =>
        ["instruments", accountId ?? "anonymous"] as const,
}

export const priceKeys = {
    all: ["prices"] as const,
    byInstrument: (instrumentId: string) =>
        ["prices", instrumentId.toString()] as const,
}

export const creditCardKeys = {
    all: ["credit-card"] as const,
    status: ["credit-card", "status"] as const,
    history: ["credit-card", "status", "history"] as const,
}

export const featureFlagKeys = {
    all: ["feature-flags"] as const,
    problemPatterns: ["feature-flags", "problem-patterns"] as const,
    config: ["feature-flags", "config"] as const,
    // Kept outside `all`: the /feature-flags Refresh refetches that prefix and
    // must neither read this flag nor run the feature shutdown.
    portfolioInsights: ["portfolio-insights", "feature-flag"] as const,
}

export const portfolioKeys = {
    all: ["portfolio"] as const,
    history: (accountId: string) =>
        ["portfolio", "history", accountId] as const,
    insightsAll: ["portfolio", "insights"] as const,
    insights: (accountId: string) =>
        ["portfolio", "insights", accountId] as const,
}

export const alertKeys = {
    all: ["alerts"] as const,
    list: (accountId: string) => ["alerts", "list", accountId] as const,
    notifications: (accountId: string) =>
        ["alerts", "notifications", accountId] as const,
}

export const versionKeys = {
    all: ["versions"] as const,
}

export async function invalidateBalance(client: QueryClient) {
    await client.invalidateQueries({ queryKey: balanceKeys.current })
    await client.invalidateQueries({ queryKey: portfolioKeys.all })
}

export async function invalidateTransactions(client: QueryClient) {
    await client.invalidateQueries({ queryKey: transactionKeys.all })
}

export async function invalidateQuickTransaction(client: QueryClient) {
    await client.invalidateQueries({ queryKey: balanceKeys.current })
    await client.invalidateQueries({ queryKey: instrumentKeys.all })
    await client.invalidateQueries({ queryKey: transactionKeys.all })
    await client.invalidateQueries({ queryKey: portfolioKeys.all })
}

export async function invalidateCreditCardStatus(client: QueryClient) {
    await client.invalidateQueries({ queryKey: creditCardKeys.status })
}

let logoutCount = 0

/**
 * How many times `invalidateOnLogout` has run in this tab. A changed value
 * means a session ended in the meantime, even if the same account has logged
 * in again since.
 */
export function currentLogoutCount(): number {
    return logoutCount
}

const logoutListeners = new Set<() => void>()

/**
 * Runs `listener` on every later `invalidateOnLogout`, once the logout is
 * counted and before any query is removed, so work that belongs to the ended
 * session can be stopped where no query reaches it. Returns the function that
 * stops listening.
 */
export function onLogout(listener: () => void): () => void {
    logoutListeners.add(listener)
    return () => {
        logoutListeners.delete(listener)
    }
}

export function invalidateOnLogout(client: QueryClient) {
    // Counted before the removals, so any result checked from here on already
    // belongs to an ended session.
    logoutCount += 1
    // A failing listener is logged whole rather than propagated (an exception
    // to the propagate-errors convention): a throw here would stop the
    // existing logout flow before it removes the ended session's queries.
    for (const listener of logoutListeners) {
        try {
            listener()
        } catch (error) {
            console.error("[invalidateOnLogout] logout listener failed", error)
        }
    }
    client.removeQueries({ queryKey: transactionKeys.all })
    client.removeQueries({ queryKey: instrumentKeys.all })
    client.removeQueries({ queryKey: userKeys.current })
    client.removeQueries({ queryKey: balanceKeys.current })
    client.removeQueries({ queryKey: creditCardKeys.all })
    client.removeQueries({ queryKey: portfolioKeys.all })
    client.removeQueries({ queryKey: alertKeys.all })
}
