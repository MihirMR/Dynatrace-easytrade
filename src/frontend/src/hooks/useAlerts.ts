import {
    type MutateOptions,
    type Mutation,
    type MutationKey,
    type QueryClient,
    type UseMutationResult,
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
import { ApiError, loggableError } from "../api/http"
import {
    type FeatureContext,
    StaleFeatureWriteError,
    captureFeatureContext,
    dispatchFeatureWrite,
    featureQueryRetry,
    isCurrentFeatureContext,
    isDiscardedFeatureWrite,
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

/**
 * A feature write as its mutation runs it: the caller's `input` and the
 * context captured when the caller started it. The capture travels in the
 * variables, so the dispatch, which can run long after the call (a mutation
 * paused while offline runs on reconnect), judges the write by the account,
 * session and activation it was made in.
 */
type FeatureWrite<TInput> = { input: TInput; ctx: FeatureContext }

/**
 * A call's own options as the mutation takes them. Each callback the caller
 * gave receives the caller's input as its `variables`, in place of the write
 * the mutation runs on, and its other arguments unchanged; `onMutateResult`
 * is the context captured at that call. A callback the caller left out stays
 * out.
 */
function toWriteOptions<TData, TInput>(
    options: MutateOptions<TData, Error, TInput, FeatureContext> | undefined
):
    | MutateOptions<TData, Error, FeatureWrite<TInput>, FeatureContext>
    | undefined {
    if (options === undefined) return undefined
    const { onSuccess, onError, onSettled } = options
    const writeOptions: MutateOptions<
        TData,
        Error,
        FeatureWrite<TInput>,
        FeatureContext
    > = {}
    if (onSuccess !== undefined) {
        writeOptions.onSuccess = (data, write, onMutateResult, context) =>
            onSuccess(data, write.input, onMutateResult, context)
    }
    if (onError !== undefined) {
        writeOptions.onError = (error, write, onMutateResult, context) =>
            onError(error, write.input, onMutateResult, context)
    }
    if (onSettled !== undefined) {
        writeOptions.onSettled = (
            data,
            error,
            write,
            onMutateResult,
            context
        ) => onSettled(data, error, write.input, onMutateResult, context)
    }
    return writeOptions
}

/**
 * `mutation` as its callers use it: `mutate` and `mutateAsync` take the
 * caller's input and add the context captured at that call, their per-call
 * options speak the caller's input too, and `variables` is the latest call's
 * input.
 */
function useCallContextMutation<TData, TInput>(
    mutation: UseMutationResult<
        TData,
        Error,
        FeatureWrite<TInput>,
        FeatureContext
    >
) {
    const { mutate: mutateWrite, mutateAsync: mutateWriteAsync } = mutation
    const mutate = useCallback(
        (
            input: TInput,
            options?: MutateOptions<TData, Error, TInput, FeatureContext>
        ) =>
            mutateWrite(
                { input, ctx: captureFeatureContext() },
                toWriteOptions(options)
            ),
        [mutateWrite]
    )
    const mutateAsync = useCallback(
        (
            input: TInput,
            options?: MutateOptions<TData, Error, TInput, FeatureContext>
        ) =>
            mutateWriteAsync(
                { input, ctx: captureFeatureContext() },
                toWriteOptions(options)
            ),
        [mutateWriteAsync]
    )
    return {
        ...mutation,
        variables: mutation.variables?.input,
        mutate,
        mutateAsync,
    }
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
function usePendingRowIds<TInput>(
    mutationKey: MutationKey,
    idOf: (input: TInput) => string
): ReadonlySet<string> {
    const pendingCalls = useMutationState<
        FeatureWrite<TInput> | undefined,
        Mutation<unknown, Error, FeatureWrite<TInput>, FeatureContext>
    >({
        filters: { mutationKey, exact: true, status: "pending" },
        select: (mutation) => mutation.state.variables,
    })
    // Checked on every render rather than memoised: a logout or a shutdown
    // ends a call's context without any change in the mutation cache.
    const ids = new Set<string>()
    for (const call of pendingCalls) {
        // Every call carries the capture of the moment it was started.
        if (call !== undefined && isCurrentFeatureContext(call.ctx)) {
            ids.add(idOf(call.input))
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
 * Failure handling shared by the three row mutations. A write that was never
 * sent, or was aborted, because its context ended, is only logged, as a debug
 * entry. A stale failure changes nothing, a 403 shuts the feature down, and
 * any other failure is recorded for its own row only. A 404 also refreshes
 * both lists, because the row may be an alert list row or a notification; the
 * panel keeps showing the message once the refreshed list no longer has the
 * row.
 */
async function applyRowFailure(
    hookName: string,
    client: QueryClient,
    accountId: string,
    error: Error,
    id: string,
    ctx: FeatureContext,
    setRowError: (id: string, message: string) => void
): Promise<void> {
    if (isDiscardedFeatureWrite(error)) {
        console.debug(
            `[${hookName}] discarded`,
            loggableError(error, accountId, id)
        )
        return
    }
    // The original error, whose URL and message name the alert, still decides
    // the outcome below; only its log entry is redacted.
    console.error(`[${hookName}] failed`, loggableError(error, accountId, id))
    if (!isCurrentFeatureContext(ctx)) return
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
 *
 * Each of the four alert mutations captures the feature context when its
 * `mutate` is called and sends its request through `dispatchFeatureWrite`
 * under that capture, so a call that is still waiting, such as one paused
 * while offline, sends nothing once its session, account or activation has
 * ended, and one in flight is aborted by the shutdown or a logout. Such a
 * call shows nothing.
 *
 * A create whose `input.accountId` is not this hook's `accountId` is refused
 * the same way, with `StaleFeatureWriteError` and before any request: the
 * guard checks the hook's account, but the body would name the input's. It
 * shows no message, sends no event and refreshes nothing.
 */
export function useCreateAlertMutation(accountId: string) {
    const client = useQueryClient()
    const [created, setCreated] = useState<CreatedAlertOutput | null>(null)
    const [errorMessage, setErrorMessage] = useState<string | null>(null)

    const mutation = useMutation({
        mutationFn: ({ input, ctx }: FeatureWrite<CreateAlertRequest>) => {
            // The body names `input.accountId`, while the dispatch guard
            // checks this hook's account, so a request for any other account
            // is refused here, before any transport.
            if (input.accountId !== accountId) {
                return Promise.reject(new StaleFeatureWriteError())
            }
            return dispatchFeatureWrite(client, ctx, accountId, (signal) =>
                createAlert(input, signal)
            )
        },
        onMutate: ({ ctx }) => {
            setErrorMessage(null)
            return ctx
        },
        onSuccess: async ({ alert, threshold }, { ctx }) => {
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
        onError: (error, { ctx }) => {
            if (isDiscardedFeatureWrite(error)) {
                console.debug(
                    "[useCreateAlertMutation] discarded",
                    loggableError(error, accountId)
                )
                return
            }
            console.error(
                "[useCreateAlertMutation] failed",
                loggableError(error, accountId)
            )
            if (!isCurrentFeatureContext(ctx)) return
            if (isFeatureDisabledError(error)) {
                onPortfolioInsightsDisabled(client)
                return
            }
            setErrorMessage(alertMutationErrorMessage(error, "create"))
        },
    })

    return { ...useCallContextMutation(mutation), created, errorMessage }
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
        mutationFn: ({
            input: { id, enabled },
            ctx,
        }: FeatureWrite<UpdateAlertEnabledVariables>) =>
            dispatchFeatureWrite(client, ctx, accountId, (signal) =>
                updateAlertEnabled(id, enabled, signal)
            ),
        onMutate: ({ input: { id }, ctx }) => {
            clearRowError(id)
            return ctx
        },
        onSuccess: async (_alert, { ctx }) => {
            if (!isCurrentFeatureContext(ctx)) return
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, { input: { id }, ctx }) =>
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
        ...useCallContextMutation(mutation),
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
        mutationFn: ({ input: id, ctx }: FeatureWrite<string>) =>
            dispatchFeatureWrite(client, ctx, accountId, (signal) =>
                deleteAlert(id, signal)
            ),
        onMutate: ({ input: id, ctx }) => {
            clearRowError(id)
            return ctx
        },
        onSuccess: async (_data, { input: id, ctx }) => {
            if (!isCurrentFeatureContext(ctx)) return
            // Set before the refetch, so the output appears on the 204 and
            // the row disappears once the list has reloaded.
            setDeletedId(id)
            setDeletedIds((ids) => (ids.has(id) ? ids : new Set(ids).add(id)))
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, { input: id, ctx }) =>
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
        ...useCallContextMutation(mutation),
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
        mutationFn: ({ input: id, ctx }: FeatureWrite<string>) =>
            dispatchFeatureWrite(client, ctx, accountId, (signal) =>
                acknowledgeAlert(id, signal)
            ),
        onMutate: ({ input: id, ctx }) => {
            clearRowError(id)
            return ctx
        },
        onSuccess: async (_data, { ctx }) => {
            if (!isCurrentFeatureContext(ctx)) return
            await invalidateAlertQueries(client, accountId)
        },
        onError: (error, { input: id, ctx }) =>
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
        ...useCallContextMutation(mutation),
        pendingIds,
        rowErrors,
        dismissRowError: clearRowError,
    }
}
