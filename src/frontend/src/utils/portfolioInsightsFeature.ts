import { CancelledError, QueryClient } from "@tanstack/react-query"
import { ApiError } from "../api/http"
import { SESSION_KEY } from "../contexts/AuthContext/storage"
import {
    alertKeys,
    currentLogoutCount,
    featureFlagKeys,
    portfolioKeys,
} from "./queryKeys"

/**
 * Portfolio Insights activation state for this tab, shared by the flag query,
 * the `/insights` loader, the insights and alert hooks and the notification
 * watcher. None of them keeps its own counter or writes its own shutdown.
 *
 * Usage contract:
 * - every feature query and mutation calls `captureFeatureContext()` when it
 *   starts, and applies or toasts its result only while
 *   `isCurrentFeatureContext()` still holds for that capture;
 * - the shared flag query records `currentActivation()` before its read and
 *   publishes `true` only if the counter is unchanged when the read returns.
 */

/** TanStack Query's default retry count, kept for ordinary failures. */
const DEFAULT_QUERY_RETRIES = 3

let activation = 0

// The account and the logout count seen by the latest capture, and how often
// either has changed.
let lastSeenUserId: string | null = null
let lastSeenLogoutCount = 0
let userSession = 0

/**
 * Incremented by every shutdown, so a changed value means the feature was
 * turned off in the meantime.
 */
export function currentActivation(): number {
    return activation
}

/**
 * Turns the feature off in this tab: advances the activation counter,
 * publishes `false` as the flag state, and cancels and drops every insights
 * and alert query. Runs whenever a flag read returns `false` or an insights or
 * alert request answers 403. Repeated calls leave the cache in the same state.
 *
 * The shared flag query passes `fromFlagRead` from its own read, so it never
 * cancels itself; every other caller passes no options.
 */
export function onPortfolioInsightsDisabled(
    client: QueryClient,
    options?: { fromFlagRead?: boolean }
): void {
    activation += 1
    // Cancel before writing. The cancel (default `revert: true`) synchronously
    // restores the state from when the read started, which can still hold
    // `true`; doing it first means the `false` written next is never undone
    // by that revert, and the cancelled read settles on it. `revert: false` is
    // not used because it would put the flag query into an error state.
    if (!options?.fromFlagRead) {
        void client.cancelQueries({
            queryKey: featureFlagKeys.portfolioInsights,
        })
    }
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, false)
    void client.cancelQueries({ queryKey: portfolioKeys.insightsAll })
    client.removeQueries({ queryKey: portfolioKeys.insightsAll })
    void client.cancelQueries({ queryKey: alertKeys.all })
    client.removeQueries({ queryKey: alertKeys.all })
}

/**
 * True for the 403 that every insights and alert endpoint answers while the
 * feature is off.
 */
export function isFeatureDisabledError(error: unknown): boolean {
    return error instanceof ApiError && error.status === 403
}

/**
 * The account and activation a feature request started under.
 *
 * `session` is carried beside `userId` and `activation` because comparing the
 * account id alone would accept a result started before a logout and a
 * re-login as the same account, or a switch to another account and back. It
 * advances whenever a capture sees a different account than the capture
 * before it, or sees that `invalidateOnLogout` ran since that capture. Every
 * logout therefore ends the session, even when the same account logs in again
 * with no feature request in between.
 */
export type FeatureContext = {
    userId: string | null
    activation: number
    session: number
}

/**
 * Captures the account the auth provider stored for this tab, its session and
 * the current activation. An empty id counts as no account, as in
 * `requireUser`.
 */
export function captureFeatureContext(): FeatureContext {
    let userId: string | null = null
    try {
        const stored = sessionStorage.getItem(SESSION_KEY)
        userId = stored === null || stored === "" ? null : stored
    } catch (error) {
        console.error(
            "[captureFeatureContext] could not read the session user",
            error
        )
    }
    const logouts = currentLogoutCount()
    if (userId !== lastSeenUserId || logouts !== lastSeenLogoutCount) {
        lastSeenUserId = userId
        lastSeenLogoutCount = logouts
        userSession += 1
    }
    return { userId, activation: currentActivation(), session: userSession }
}

/**
 * True only while the account, its session and the activation all still match
 * `ctx`. A result is discarded after a logout (even once the same account
 * logged in again), an account switch (a switch back too, once a logout ran
 * or a capture saw the other account) or a shutdown (even after the feature
 * resumed).
 */
export function isCurrentFeatureContext(ctx: FeatureContext): boolean {
    const now = captureFeatureContext()
    return (
        now.userId === ctx.userId &&
        now.session === ctx.session &&
        now.activation === ctx.activation
    )
}

/**
 * `retry` option for feature queries. A cancellation, which the retryer would
 * otherwise re-run, and a 403 are never retried, so the shutdown follows at
 * once instead of after the default back-off. Other failures keep the default
 * three retries; `failureCount` starts at 0.
 */
export function featureQueryRetry(
    failureCount: number,
    error: unknown
): boolean {
    return (
        !(error instanceof CancelledError) &&
        !isFeatureDisabledError(error) &&
        failureCount < DEFAULT_QUERY_RETRIES
    )
}
