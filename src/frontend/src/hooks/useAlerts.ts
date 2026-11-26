import {
    type Mutation,
    type MutationKey,
    type QueryClient,
    queryOptions,
    useMutation,
    useMutationState,
    useQuery,
    useQueryClient,
} from "@tanstack/react-query"
import { useCallback, useState } from "react"
import {
    acknowledgeAlert,
    createAlert,
    deleteAlert,
    listAlertNotifications,
    listAlerts,
    updateAlertEnabled,
} from "../api/alerts"
import type { Alert, CreateAlertRequest } from "../api/alerts/types"
import { BizEvents } from "../api/bizEvents"
import { ApiError } from "../api/http"
import {
    type FeatureContext,
    captureFeatureContext,
    featureQueryRetry,
    isCurrentFeatureContext,
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
    shareFeatureResult,
} from "../utils/portfolioInsightsFeature"
import { alertKeys } from "../utils/queryKeys"
import { guardFeatureRequest } from "./usePortfolioInsights"

/**
 * Every alert of one account, newest first. Each attempt sends its request
 * only while that account is signed in and the shared flag state reads
 * `true`; otherwise it ends unfetched. A 403 runs the feature shutdown from
 * the query itself, whoever observes it, and is never retried. The cached
 * result keeps the context of the request that produced it. It neither polls
 * nor refetches on focus: mutations refresh it, and so does the alerts panel
 * after a successful notifications poll that shows a trigger the list lacks
 * or that lands after the list failed. The query's signal reaches `fetch`, so
 * a cancellation aborts the HTTP read.
 */
export function alertsQuery(accountId: string) {
    return queryOptions({
        queryKey: alertKeys.list(accountId),
        queryFn: (context) =>
            guardFeatureRequest(context, accountId, () =>
                listAlerts(accountId, context.signal)
            ),
        retry: featureQueryRetry,
        structuralSharing: shareFeatureResult,
        refetchOnWindowFocus: false,
    })
}

/**
 * The account's triggered, unacknowledged alerts, polled every 15 s while the
 * tab is visible. A hidden tab polls nothing, and focus starts no read of its
 * own. `AlertNotificationWatcher` schedules the poll; the alerts panel only
 * reads the same cache entry, so the list and the Toasts always read the
 * same poll and one timer drives it. As for `alertsQuery`, each attempt sends
 * its request only while the account is signed in and the shared flag state
 * reads `true`, so a poll due after a shutdown sends nothing, and a 403 runs
 * the feature shutdown from the query itself. The cached poll keeps the
 * context of the request that produced it, which the watcher checks before
 * it toasts. The query's signal reaches `fetch`, so a cancellation, such as
 * the shutdown, aborts the HTTP read.
 */
export function alertNotificationsQuery(accountId: string) {
    return queryOptions({
        queryKey: alertKeys.notifications(accountId),
        queryFn: (context) =>
            guardFeatureRequest(context, accountId, () =>
                listAlertNotifications(accountId, true, context.signal)
            ),
        retry: featureQueryRetry,
        structuralSharing: shareFeatureResult,
        refetchInterval: 15_000,
        refetchIntervalInBackground: false,
        refetchOnWindowFocus: false,
    })
}

export function useAlertsQuery(accountId: string, enabled: boolean) {
    return useQuery({ ...alertsQuery(accountId), enabled })
}

/**
 * The notifications poll. Query-core arms one interval timer per observer
 * that sets `refetchInterval`, so only `AlertNotificationWatcher` calls this.
 */
export function useAlertNotificationsQuery(
    accountId: string,
    enabled: boolean
) {
    return useQuery({ ...alertNotificationsQuery(accountId), enabled })
}

/**
 * The notifications cache entry the watcher polls, read without a timer of
 * its own: same key, request and retry, but `refetchInterval: false`.
 */
export function useAlertNotificationsWithoutPolling(
    accountId: string,
    enabled: boolean
) {
    return useQuery({
        ...alertNotificationsQuery(accountId),
        enabled,
        refetchInterval: false,
    })
}

const GENERIC_ERROR_MESSAGE = "Something went wrong. Please try again later."

/**
 * The message shown for a failed alert mutation. `ApiError` carries no
 * response body, so only the status decides it. A 403 maps to `null`: the
 * feature shutdown handles it and no message is shown.
 */
export function alertMutationErrorMessage(
    error: unknown,
    scope: "create" | "row"
): string | null {
    if (!(error instanceof ApiError)) return GENERIC_ERROR_MESSAGE
    if (isFeatureDisabledError(error)) return null
    if (error.status === 400 && scope === "create") {
        return "The alert was rejected. Check the values and try again."
    }
    if (error.status === 404) {
        return scope === "create"
            ? "The account or instrument no longer exists."
            : "This alert no longer exists."
    }
    return GENERIC_ERROR_MESSAGE
}

/**
 * The created alert and the threshold token `createAlert` sent in its request
 * body, as text.
 */
export type CreatedAlertOutput = { alert: Alert; thresholdText: string }

/**
 * One row mutation's failure messages, by alert id. Each row keeps its own
 * entry and each row mutation its own map, so a failure never replaces or
 * clears another row's, nor another action's on the same row.
 */
export type AlertRowErrors = ReadonlyMap<string, string>

export type UpdateAlertEnabledVariables = { id: string; enabled: boolean }

/** `onMutate` can throw before it returns, which leaves no context. */
function isCurrentContext(
    ctx: FeatureContext | undefined
): ctx is FeatureContext {
    return ctx !== undefined && isCurrentFeatureContext(ctx)
}

async function invalidateAlertQueries(
    client: QueryClient,
    accountId: string
): Promise<void> {
    await Promise.all([
        client.invalidateQueries({ queryKey: alertKeys.list(accountId) }),
        client.invalidateQueries({
            queryKey: alertKeys.notifications(accountId),
        }),
    ])
}

/**
 * Keys of the three row mutations, per account, so the pending calls of each
 * can be read from the mutation cache.
 */
const rowMutationKeys = {
    updateEnabled: (accountId: string) =>
        ["alerts", "update-enabled", accountId] as const,
    remove: (accountId: string) => ["alerts", "delete", accountId] as const,
    acknowledge: (accountId: string) =>
        ["alerts", "acknowledge", accountId] as const,
}

function updateRowIdOf(variables: UpdateAlertEnabledVariables): string {
    return variables.id
}

function rowIdOf(id: string): string {
    return id
}

/** A pending row mutation call: its variables and its captured context. */
type PendingRowCall<TVariables> = {
    variables: TVariables | undefined
    context: FeatureContext | undefined
}

/**
 * The id of every row with a call of one row mutation still pending in the
 * current account session and activation. A mutation observer reports only
 * its latest call, so a second row's action would hide the first row's; the
 * mutation cache holds every call, so each row stays pending until its own
 * request settles, in whatever order.
 *
 * A call started before a logout or a feature shutdown is left out, even
 * once the same account or the feature is back: its outcome will be
 * discarded, so it must not keep that row's controls disabled.
 */
function usePendingRowIds<TVariables>(
    mutationKey: MutationKey,
    idOf: (variables: TVariables) => string
): ReadonlySet<string> {
    const pendingCalls = useMutationState<
        PendingRowCall<TVariables>,
        Mutation<unknown, Error, TVariables, FeatureContext>
    >({
        filters: { mutationKey, exact: true, status: "pending" },
        select: (mutation) => ({
            variables: mutation.state.variables,
            context: mutation.state.context,
        }),
    })
    // Checked on every render rather than memoised: a logout or a shutdown
    // ends a call's context without any change in the mutation cache.
    const ids = new Set<string>()
    for (const { variables, context } of pendingCalls) {
        if (variables === undefined) continue
        // A call is pending before `onMutate` returns its capture, so a call
        // with no context yet has only just started, in the current context.
        if (context === undefined || isCurrentFeatureContext(context)) {
            ids.add(idOf(variables))
        }
    }
    return ids
}

/**
 * One row mutation's failure messages. Updates are functional, so calls that
 * settle together never drop each other's entries.
 */
function useRowErrors() {
    const [rowErrors, setRowErrors] = useState<AlertRowErrors>(() => new Map())
    const setRowError = useCallback((id: string, message: string) => {
        setRowErrors((errors) => new Map(errors).set(id, message))
    }, [])
    const clearRowError = useCallback((id: string) => {
        setRowErrors((errors) => {
            if (!errors.has(id)) return errors
            const next = new Map(errors)
            next.delete(id)
            return next
        })
    }, [])
    return { rowErrors, setRowError, clearRowError }
}

/**
 * Failure handling shared by the three row mutations. A stale failure changes
 * nothing, a 403 shuts the feature down, and any other failure is recorded
 * for its own row only. A 404 also refreshes both lists, because the row may
 * be an alert list row or a notification; the panel keeps showing the message
 * once the refreshed list no longer has the row.
 */
async function applyRowFailure(
    hookName: string,
    client: QueryClient,
    accountId: string,
    error: Error,
    id: string,
    ctx: FeatureContext | undefined,
    setRowError: (id: string, message: string) => void
): Promise<void> {
    console.error(`[${hookName}] failed`, error)
    if (!isCurrentContext(ctx)) return
    if (isFeatureDisabledError(error)) {
        onPortfolioInsightsDisabled(client)
        return
    }
    const message = alertMutationErrorMessage(error, "row")
    if (message !== null) setRowError(id, message)
    if (error instanceof ApiError && error.status === 404) {
        await invalidateAlertQueries(client, accountId)
    }
}

/**
 * Creates an alert. `created` drives `output#alert-created-id` and keeps its
 * value until the next successful create; `errorMessage` is the form's
 * message for the latest failure.
 */
export function useCreateAlertMutation(accountId: string) {
    const client = useQueryClient()
    const [created, setCreated] = useState<CreatedAlertOutput | null>(null)
    const [errorMessage, setErrorMessage] = useState<string | null>(null)

    const mutation = useMutation({
        mutationFn: (request: CreateAlertRequest) => createAlert(request),
        onMutate: () => {
            setErrorMessage(null)
            return captureFeatureContext()
        },
        onSuccess: async ({ alert, threshold }, _request, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            // Set before the refetch, so the output appears on the 201 and
            // the row once the list has reloaded. `threshold` is the token
            // `createAlert` spliced into the body, whatever text the caller
            // passed.
            setCreated({ alert, thresholdText: threshold })
            // The event is best effort, and its `reportError` fallback can
            // throw as well. That throw is logged whole rather than
            // propagated (an exception to the propagate-errors convention):
            // propagating it would report the committed create as failed
            // and skip the refetch.
            try {
                BizEvents.alertCreate({
                    accountId,
                    alertId: alert.id,
                    type: alert.type,
                    instrumentId: alert.instrumentId,
                    direction: alert.direction,
                    threshold: alert.threshold,
                })
            } catch (error) {
                console.error(
                    "[useCreateAlertMutation] alertCreate event failed",
                    error
                )
            }
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, _request, ctx) => {
            console.error("[useCreateAlertMutation] failed", error)
            if (!isCurrentContext(ctx)) return
            if (isFeatureDisabledError(error)) {
                onPortfolioInsightsDisabled(client)
                return
            }
            setErrorMessage(alertMutationErrorMessage(error, "create"))
        },
    })

    return { ...mutation, created, errorMessage }
}

/**
 * Enables (re-arming it) or disables one alert. Like the other two row
 * mutations, it returns `pendingIds`, every row with a request in flight, and
 * `rowErrors`, each row's latest failure, kept until the same action on that
 * row starts again or `dismissRowError` drops it.
 */
export function useUpdateAlertEnabledMutation(accountId: string) {
    const client = useQueryClient()
    const { rowErrors, setRowError, clearRowError } = useRowErrors()
    const mutationKey = rowMutationKeys.updateEnabled(accountId)

    const mutation = useMutation({
        mutationKey,
        mutationFn: ({ id, enabled }: UpdateAlertEnabledVariables) =>
            updateAlertEnabled(id, enabled),
        onMutate: ({ id }) => {
            clearRowError(id)
            return captureFeatureContext()
        },
        onSuccess: async (_alert, _variables, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, { id }, ctx) =>
            applyRowFailure(
                "useUpdateAlertEnabledMutation",
                client,
                accountId,
                error,
                id,
                ctx,
                setRowError
            ),
    })
    const pendingIds = usePendingRowIds(mutationKey, updateRowIdOf)

    return {
        ...mutation,
        pendingIds,
        rowErrors,
        dismissRowError: clearRowError,
    }
}

/**
 * Deletes one alert. `deletedId` drives `output#alert-deleted-id` and keeps
 * its value until the next successful delete. `deletedIds` holds every alert
 * this hook confirmed deleted while its context was current, for as long as
 * the hook is mounted. `pendingIds`, `rowErrors` and `dismissRowError` work as
 * in `useUpdateAlertEnabledMutation`.
 */
export function useDeleteAlertMutation(accountId: string) {
    const client = useQueryClient()
    const [deletedId, setDeletedId] = useState<string | null>(null)
    const [deletedIds, setDeletedIds] = useState<ReadonlySet<string>>(
        () => new Set()
    )
    const { rowErrors, setRowError, clearRowError } = useRowErrors()
    const mutationKey = rowMutationKeys.remove(accountId)

    const mutation = useMutation({
        mutationKey,
        mutationFn: (id: string) => deleteAlert(id),
        onMutate: (id) => {
            clearRowError(id)
            return captureFeatureContext()
        },
        onSuccess: async (_data, id, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            // Set before the refetch, so the output appears on the 204 and
            // the row disappears once the list has reloaded.
            setDeletedId(id)
            setDeletedIds((ids) => (ids.has(id) ? ids : new Set(ids).add(id)))
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, id, ctx) =>
            applyRowFailure(
                "useDeleteAlertMutation",
                client,
                accountId,
                error,
                id,
                ctx,
                setRowError
            ),
    })
    const pendingIds = usePendingRowIds(mutationKey, rowIdOf)

    return {
        ...mutation,
        deletedId,
        deletedIds,
        pendingIds,
        rowErrors,
        dismissRowError: clearRowError,
    }
}

/**
 * Acknowledges one notification; the refetch removes it from the list.
 * `pendingIds`, `rowErrors` and `dismissRowError` work as in
 * `useUpdateAlertEnabledMutation`, keyed by the notification's alert id.
 */
export function useAcknowledgeAlertMutation(accountId: string) {
    const client = useQueryClient()
    const { rowErrors, setRowError, clearRowError } = useRowErrors()
    const mutationKey = rowMutationKeys.acknowledge(accountId)

    const mutation = useMutation({
        mutationKey,
        mutationFn: (id: string) => acknowledgeAlert(id),
        onMutate: (id) => {
            clearRowError(id)
            return captureFeatureContext()
        },
        onSuccess: async (_data, _id, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, id, ctx) =>
            applyRowFailure(
                "useAcknowledgeAlertMutation",
                client,
                accountId,
                error,
                id,
                ctx,
                setRowError
            ),
    })
    const pendingIds = usePendingRowIds(mutationKey, rowIdOf)

    return {
        ...mutation,
        pendingIds,
        rowErrors,
        dismissRowError: clearRowError,
    }
}
