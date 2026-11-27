import {
    CancelledError,
    QueryClient,
    replaceEqualDeep,
} from "@tanstack/react-query"
import { ApiError } from "../api/http"
import { SESSION_KEY } from "../contexts/AuthContext/storage"
import {
    alertKeys,
    currentLogoutCount,
    featureFlagKeys,
    onLogout,
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
 * - every feature mutation sends its request through `dispatchFeatureWrite`
 *   with the capture taken when the caller started it, so a write that waited,
 *   such as one paused offline, is never sent once that capture has ended, and
 *   one in flight is aborted by the shutdown or a logout;
 * - a feature query's result is cached with the capture of the request that
 *   produced it (`recordFeatureResultContext`, `shareFeatureResult`), so a
 *   consumer that acts on cached data later, such as a Toast or a business
 *   event, checks that capture (`featureResultContext`), never one of its
 *   own;
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

/** The controllers of the feature writes now in flight. */
const writesInFlight = new Set<AbortController>()

/** Rejections of feature writes that `abortFeatureWrites` aborted. */
const abortedWrites = new WeakSet<object>()

/**
 * Aborts every feature write in flight. A write's request may already have
 * reached broker-service, so this stops the transport and the use of its
 * result; it never undoes a committed write.
 */
function abortFeatureWrites(): void {
    const controllers = Array.from(writesInFlight)
    writesInFlight.clear()
    controllers.forEach((controller) => controller.abort())
}

// A logout ends the session every write in flight belongs to.
onLogout(abortFeatureWrites)

/**
 * Turns the feature off in this tab: advances the activation counter,
 * publishes `false` as the flag state, cancels and drops every insights and
 * alert query, and aborts every feature write in flight. Runs whenever a flag
 * read returns `false` or an insights or alert request answers 403. Repeated
 * calls leave the cache in the same state.
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
    abortFeatureWrites()
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
 * A feature write refused before any request was sent: the session, account
 * or activation it was started under has ended, it is for an account other
 * than the tab's, its request names an account other than the one its caller
 * writes for, or the shared flag state no longer reads `true`. Its message is
 * fixed and names no account or alert, so the error can be logged whole.
 */
export class StaleFeatureWriteError extends Error {
    constructor() {
        super("Portfolio Insights write not sent: its context has ended")
        this.name = "StaleFeatureWriteError"
    }
}

/**
 * Sends the feature write that `send` makes for `accountId`, started by its
 * caller under `ctx`.
 *
 * - Before any request, it rejects with `StaleFeatureWriteError` unless `ctx`
 *   is still current, its account is `accountId` and the shared flag state
 *   reads `true`, as `guardFeatureRequest` requires of a feature read. A write
 *   that waited before it was dispatched, such as a mutation paused while
 *   offline and resumed on reconnect, is thereby never sent after a logout,
 *   an account switch or a shutdown.
 * - `send` gets a signal for `fetch` that the shutdown and every logout abort
 *   while the write is in flight. The write then rejects with the transport's
 *   own error, which `isDiscardedFeatureWrite` recognises.
 *
 * Nothing is undone: an aborted request may already have been committed.
 */
export async function dispatchFeatureWrite<T>(
    client: QueryClient,
    ctx: FeatureContext,
    accountId: string,
    send: (signal: AbortSignal) => Promise<T>
): Promise<T> {
    if (
        !isCurrentFeatureContext(ctx) ||
        ctx.userId !== accountId ||
        client.getQueryData<boolean>(featureFlagKeys.portfolioInsights) !== true
    ) {
        throw new StaleFeatureWriteError()
    }
    const controller = new AbortController()
    writesInFlight.add(controller)
    try {
        return await send(controller.signal)
    } catch (error) {
        if (
            controller.signal.aborted &&
            typeof error === "object" &&
            error !== null
        ) {
            abortedWrites.add(error)
        }
        throw error
    } finally {
        writesInFlight.delete(controller)
    }
}

/**
 * True for the rejection of a feature write that `dispatchFeatureWrite` never
 * sent, or that the shutdown or a logout aborted in flight. Its outcome
 * belongs to a context that has ended, so it is discarded, never shown.
 */
export function isDiscardedFeatureWrite(error: unknown): boolean {
    return (
        error instanceof StaleFeatureWriteError ||
        (typeof error === "object" &&
            error !== null &&
            abortedWrites.has(error))
    )
}

/**
 * The context of the request that produced each cached feature result, keyed
 * by the result itself, so an entry lives exactly as long as its data.
 */
const resultContexts = new WeakMap<object, FeatureContext>()

/**
 * Records `ctx` as the context of the request that produced `result`. The
 * feature request guard calls it for every result it hands back as current.
 * Only an object or array can carry one, which every feature query's data is.
 */
export function recordFeatureResultContext(
    result: unknown,
    ctx: FeatureContext
): void {
    if (typeof result === "object" && result !== null) {
        resultContexts.set(result, ctx)
    }
}

/**
 * The context of the request that produced `result`, or `undefined` for data
 * no current feature request produced, such as a `setQueryData` write. A
 * consumer that acts on cached feature data acts only while this exists,
 * `isCurrentFeatureContext` holds for it and its `userId` is the account
 * shown: data cached under an earlier session, activation or account, even
 * one that has since come back, is never acted on under a later one.
 */
export function featureResultContext(
    result: unknown
): FeatureContext | undefined {
    return typeof result === "object" && result !== null
        ? resultContexts.get(result)
        : undefined
}

/**
 * `structuralSharing` for the guarded feature queries. It keeps query-core's
 * default sharing, which caches the previous data when the new data is deeply
 * equal and otherwise a copy that reuses the equal parts, and moves the
 * context recorded for the new data onto whichever value is cached. An equal
 * refetch therefore keeps its reference but carries the context of the
 * request that just returned it. A write with no recorded context, such as
 * `setQueryData`, records none, so it never makes data deliverable.
 */
export function shareFeatureResult(previous: unknown, next: unknown): unknown {
    const shared = replaceEqualDeep(previous, next)
    const ctx = featureResultContext(next)
    if (ctx !== undefined) {
        recordFeatureResultContext(shared, ctx)
    }
    return shared
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
