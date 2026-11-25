import {
    type QueryClient,
    queryOptions,
    useMutation,
    useQuery,
    useQueryClient,
} from "@tanstack/react-query"
import { useState } from "react"
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
} from "../utils/portfolioInsightsFeature"
import { alertKeys } from "../utils/queryKeys"
import { guardFeatureRequest } from "./usePortfolioInsights"

/**
 * Every alert of one account, newest first. A 403 reaches `error` without a
 * retry; the page that observes it runs the feature shutdown.
 */
export function alertsQuery(accountId: string) {
    return queryOptions({
        queryKey: alertKeys.list(accountId),
        queryFn: () => guardFeatureRequest(() => listAlerts(accountId)),
        retry: featureQueryRetry,
    })
}

/**
 * The account's triggered, unacknowledged alerts, polled every 15 s. The
 * alerts panel and the notification watcher share this cache entry, so the
 * list and the Toasts always read the same poll.
 */
export function alertNotificationsQuery(accountId: string) {
    return queryOptions({
        queryKey: alertKeys.notifications(accountId),
        queryFn: () =>
            guardFeatureRequest(() => listAlertNotifications(accountId, true)),
        retry: featureQueryRetry,
        refetchInterval: 15_000,
    })
}

export function useAlertsQuery(accountId: string, enabled: boolean) {
    return useQuery({ ...alertsQuery(accountId), enabled })
}

export function useAlertNotificationsQuery(
    accountId: string,
    enabled: boolean
) {
    return useQuery({ ...alertNotificationsQuery(accountId), enabled })
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

/** The created alert and the threshold text it was submitted with. */
export type CreatedAlertOutput = { alert: Alert; thresholdText: string }

/** A failed action on one alert row. */
export type AlertRowError = { id: string; message: string }

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
 * Failure handling shared by the three row mutations. A stale failure changes
 * nothing, a 403 shuts the feature down, and any other failure is shown
 * beside its row. A 404 also refreshes both lists, because the row may be an
 * alert list row or a notification.
 */
async function applyRowFailure(
    hookName: string,
    client: QueryClient,
    accountId: string,
    error: Error,
    id: string,
    ctx: FeatureContext | undefined,
    setRowError: (rowError: AlertRowError | null) => void
): Promise<void> {
    console.error(`[${hookName}] failed`, error)
    if (!isCurrentContext(ctx)) return
    if (isFeatureDisabledError(error)) {
        onPortfolioInsightsDisabled(client)
        return
    }
    const message = alertMutationErrorMessage(error, "row")
    if (message !== null) setRowError({ id, message })
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
        onSuccess: async (alert, request, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            // Set before the refetch, so the output appears on the 201 and
            // the row once the list has reloaded.
            setCreated({ alert, thresholdText: request.threshold })
            BizEvents.alertCreate({
                accountId,
                alertId: alert.id,
                type: alert.type,
                instrumentId: alert.instrumentId,
                direction: alert.direction,
                threshold: alert.threshold,
            })
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

/** Enables (re-arming it) or disables one alert. */
export function useUpdateAlertEnabledMutation(accountId: string) {
    const client = useQueryClient()
    const [rowError, setRowError] = useState<AlertRowError | null>(null)

    const mutation = useMutation({
        mutationFn: ({ id, enabled }: UpdateAlertEnabledVariables) =>
            updateAlertEnabled(id, enabled),
        onMutate: () => {
            setRowError(null)
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

    return { ...mutation, rowError }
}

/**
 * Deletes one alert. `deletedId` drives `output#alert-deleted-id` and keeps
 * its value until the next successful delete.
 */
export function useDeleteAlertMutation(accountId: string) {
    const client = useQueryClient()
    const [deletedId, setDeletedId] = useState<string | null>(null)
    const [rowError, setRowError] = useState<AlertRowError | null>(null)

    const mutation = useMutation({
        mutationFn: (id: string) => deleteAlert(id),
        onMutate: () => {
            setRowError(null)
            return captureFeatureContext()
        },
        onSuccess: async (_data, id, ctx) => {
            if (!isCurrentFeatureContext(ctx)) return
            // Set before the refetch, so the output appears on the 204 and
            // the row disappears once the list has reloaded.
            setDeletedId(id)
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

    return { ...mutation, deletedId, rowError }
}

/** Acknowledges one notification; the refetch removes it from the list. */
export function useAcknowledgeAlertMutation(accountId: string) {
    const client = useQueryClient()
    const [rowError, setRowError] = useState<AlertRowError | null>(null)

    const mutation = useMutation({
        mutationFn: (id: string) => acknowledgeAlert(id),
        onMutate: () => {
            setRowError(null)
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

    return { ...mutation, rowError }
}
