import { useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import type { Alert, ValidatedAlertInput } from "../../api/alerts/types"
import { loggableError } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import {
    type AlertRowErrors,
    useAcknowledgeAlertMutation,
    useAlertNotificationsWithoutPolling,
    useAlertsQuery,
    useCreateAlertMutation,
    useDeleteAlertMutation,
    useUpdateAlertEnabledMutation,
} from "../../hooks/useAlerts"
import {
    type FeatureContext,
    isCurrentFeatureContext,
    isFeatureDisabledError,
} from "../../utils/portfolioInsightsFeature"
import { alertKeys } from "../../utils/queryKeys"
import { AlertForm } from "./AlertForm"
import { AlertList, DeletedAlertOutput, alertSummaryText } from "./AlertList"
import { AlertNotifications } from "./AlertNotifications"

type AlertsPanelProps = {
    accountId: string
    instruments: Instrument[]
}

/** A row failure the panel shows itself, because its row is not rendered. */
type PanelRowError = {
    key: string
    id: string
    message: string
    dismiss: () => void
}

/**
 * The failures in `rowErrors` whose alert has no row in `renderedIds`: the
 * region that would show them is loading or failed, or a refresh removed the
 * row, as after a 404.
 */
function unplacedRowErrors(
    action: string,
    rowErrors: AlertRowErrors,
    renderedIds: ReadonlySet<string>,
    dismiss: (id: string) => void
): PanelRowError[] {
    const unplaced: PanelRowError[] = []
    for (const [id, message] of rowErrors) {
        if (!renderedIds.has(id)) {
            unplaced.push({
                key: `${action}-${id}`,
                id,
                message,
                dismiss: () => dismiss(id),
            })
        }
    }
    return unplaced
}

function idsOf(alerts: Alert[] | undefined): ReadonlySet<string> {
    return new Set(alerts?.map((a) => a.id))
}

/** `rowErrors` without the entries of the alerts in `ids`. */
function withoutAlerts(
    rowErrors: AlertRowErrors,
    ids: ReadonlySet<string>
): AlertRowErrors {
    if (ids.size === 0) return rowErrors
    return new Map(Array.from(rowErrors).filter(([id]) => !ids.has(id)))
}

/**
 * Each row's messages from several row mutations, in the order the
 * mutations are given. `AlertList` shows a repeated message once.
 */
function messagesByRow(
    ...errorsByAction: AlertRowErrors[]
): ReadonlyMap<string, readonly string[]> {
    const messages = new Map<string, string[]>()
    for (const rowErrors of errorsByAction) {
        for (const [id, message] of rowErrors) {
            const rowMessages = messages.get(id)
            if (rowMessages === undefined) {
                messages.set(id, [message])
            } else {
                rowMessages.push(message)
            }
        }
    }
    return messages
}

/**
 * True when a notification shows a trigger that `alerts` does not hold yet:
 * the list has no row for that alert, its row is from an older arming, or it
 * is from the same arming but not triggered. A row from a newer arming than
 * the notification is current, so an older notification read never makes a
 * newer list look stale.
 */
function listLacksNotifiedTrigger(
    alerts: readonly Alert[],
    notifications: readonly Alert[]
): boolean {
    const rows = new Map(alerts.map((alert) => [alert.id, alert]))
    return notifications.some((notification) => {
        if (notification.triggeredAt === null) return false
        const row = rows.get(notification.id)
        if (row === undefined) return true
        if (row.armingRevision !== notification.armingRevision) {
            return row.armingRevision < notification.armingRevision
        }
        return row.triggeredAt === null
    })
}

/** The two places an alert's actions are rendered: list rows and notifications. */
type ItemRegion = "list" | "notifications"

const ITEM_SELECTORS: Record<ItemRegion, string> = {
    list: "li.alert-item",
    notifications: "li.alert-notification",
}

/** The classes that tell the buttons of one row or notification apart. */
const ACTION_CLASSES = [
    "alert-toggle",
    "alert-disable",
    "alert-delete",
    "alert-acknowledge",
] as const

function itemAlertId(
    item: HTMLElement,
    region: ItemRegion
): string | undefined {
    return region === "list"
        ? item.dataset.alertId
        : item.dataset.notificationId
}

/**
 * Where focus returns once an action settles, captured when it starts: the
 * control a create was submitted from, or the row or notification an action
 * was started from, with its position and the class of its button.
 */
type FocusReturn =
    | { kind: "form"; control: HTMLElement }
    | {
          kind: "item"
          region: ItemRegion
          id: string
          index: number
          actionClass: string | null
      }

/**
 * True when no element holds focus, as after the focused control was
 * disabled or removed; then focus may be moved without taking it from a
 * control the user chose.
 */
function isFocusLost(): boolean {
    const active = document.activeElement
    return active === null || active === document.body
}

/** Focuses `element`; false when it cannot take focus, as when disabled. */
function focusIfAble(element: HTMLElement): boolean {
    element.focus()
    return document.activeElement === element
}

function buttonsOf(item: HTMLElement | undefined): HTMLElement[] {
    return item === undefined
        ? []
        : Array.from(item.querySelectorAll<HTMLElement>("button"))
}

/**
 * The controls `target` hands focus to, best first, as `section` is rendered
 * now. A create returns to the control it was submitted from, else to the
 * submit button. An action returns to its item's button of the same class,
 * else to the item's first button; once the item is gone, to the item that
 * took its place, else to the one before it.
 */
function focusCandidates(
    section: HTMLElement,
    target: FocusReturn
): HTMLElement[] {
    if (target.kind === "form") {
        const submit = section.querySelector<HTMLElement>("#alert-submit")
        return submit === null ? [target.control] : [target.control, submit]
    }
    const items = Array.from(
        section.querySelectorAll<HTMLElement>(ITEM_SELECTORS[target.region])
    )
    const item = items.find(
        (candidate) => itemAlertId(candidate, target.region) === target.id
    )
    if (item !== undefined) {
        const buttons = buttonsOf(item)
        const { actionClass } = target
        const sameAction =
            actionClass === null
                ? []
                : buttons.filter((button) =>
                      button.classList.contains(actionClass)
                  )
        return [...sameAction, ...buttons]
    }
    return [
        ...buttonsOf(items[target.index]),
        ...buttonsOf(items[target.index - 1]),
    ]
}

/**
 * The alerts section of the `/insights` page: create form, alert list and
 * unacknowledged notifications.
 *
 * The shared hooks in `hooks/useAlerts.ts` own the requests, invalidation,
 * the activation check, the business event, every 403 shutdown (each
 * feature query runs it itself) and the mutation error messages. The panel
 * itself renders the loading and error states of the list and notification
 * queries, and refetches the list after a successful notifications read that
 * shows a trigger the list does not hold yet, or that lands after the list
 * failed.
 *
 * Only the notifications cache entry is shared with
 * `AlertNotificationWatcher`, which schedules that poll; the panel reads the
 * entry without a timer of its own.
 *
 * The panel places each row failure: beside its list row or notification
 * while that is rendered, and otherwise in its own announced feedback, which
 * names the alert. Each failure is kept per alert and action, and stays until
 * it is dismissed or the same action starts again on that alert; once the
 * alert's delete succeeds, its update and acknowledge failures are dropped.
 *
 * A control is disabled, replaced or removed while its action runs, which
 * drops keyboard focus. Once the latest action started from inside the panel
 * settles, and only while no element holds focus, the panel hands focus to
 * the control `focusCandidates` picks, else to its heading.
 */
function AlertsPanelContent({ accountId, instruments }: AlertsPanelProps) {
    const queryClient = useQueryClient()
    const alertsResult = useAlertsQuery(accountId, true)
    const notificationsResult = useAlertNotificationsWithoutPolling(
        accountId,
        true
    )

    const create = useCreateAlertMutation(accountId)
    const update = useUpdateAlertEnabledMutation(accountId)
    const remove = useDeleteAlertMutation(accountId)
    const acknowledge = useAcknowledgeAlertMutation(accountId)

    // The list has no poll of its own, so a successful notifications read
    // refetches it for either of two reasons. When the read shows a trigger
    // the list does not hold yet, the row turns to "Triggered" beside its
    // notification. When the list failed before the read landed, whether it
    // never loaded or a refresh failed, the read shows the alert backend
    // answering again, so the list leaves its error state within one poll of
    // a recovery, without any user action. A 403 is left to the feature
    // shutdown, which owns it. The refetch passes the same activation check
    // as every list read. The two reads are compared only once neither is in
    // flight: a mutation refetches both at once, and a list that lands
    // first, without a deleted alert, beside notifications that still hold
    // it would otherwise read as stale and be fetched again. A list read
    // that started before the trigger and lands after the notifications is
    // compared when it settles. Each successful notifications read refetches
    // the list at most once, so a list that still lacks the trigger after
    // its refetch, because the alert was deleted meanwhile, or whose refetch
    // failed again, is fetched again only after the next successful poll,
    // not whenever a read settles. Reads are told apart by `dataUpdatedAt`,
    // which advances on every successful read even when structural sharing
    // keeps the same alerts array; a list failure is ordered against them by
    // `errorUpdatedAt`.
    const listRefetchedFor = useRef<number | null>(null)
    useEffect(() => {
        if (alertsResult.isFetching || notificationsResult.isFetching) return
        if (
            notificationsResult.data === undefined ||
            notificationsResult.dataUpdatedAt === listRefetchedFor.current
        ) {
            return
        }
        const listFailedBeforeRead =
            alertsResult.isError &&
            !isFeatureDisabledError(alertsResult.error) &&
            notificationsResult.dataUpdatedAt > alertsResult.errorUpdatedAt
        const listLacksTrigger =
            alertsResult.data !== undefined &&
            listLacksNotifiedTrigger(
                alertsResult.data,
                notificationsResult.data
            )
        if (!listFailedBeforeRead && !listLacksTrigger) return
        listRefetchedFor.current = notificationsResult.dataUpdatedAt
        void queryClient.invalidateQueries({
            queryKey: alertKeys.list(accountId),
        })
    }, [
        alertsResult.data,
        alertsResult.error,
        alertsResult.errorUpdatedAt,
        alertsResult.isError,
        alertsResult.isFetching,
        notificationsResult.data,
        notificationsResult.dataUpdatedAt,
        notificationsResult.isFetching,
        accountId,
        queryClient,
    ])

    // Only the list failure is logged here: `AlertNotificationWatcher` logs
    // failures of the notifications poll this panel shares with it.
    useEffect(() => {
        if (alertsResult.error && !isFeatureDisabledError(alertsResult.error)) {
            console.error(
                "[AlertsPanel] could not load alerts",
                loggableError(alertsResult.error, accountId)
            )
        }
    }, [alertsResult.error])

    const createdAlert = create.created
    const created = useMemo(
        () =>
            createdAlert === null
                ? null
                : {
                      id: createdAlert.alert.id,
                      threshold: createdAlert.thresholdText,
                  },
        [createdAlert]
    )

    // Every alert with any of its requests in flight. The list row and the
    // notification of one alert read the same set, so an action started in
    // either disables both until it settles.
    const pendingIds = useMemo<ReadonlySet<string>>(
        () =>
            new Set([
                ...update.pendingIds,
                ...remove.pendingIds,
                ...acknowledge.pendingIds,
            ]),
        [update.pendingIds, remove.pendingIds, acknowledge.pendingIds]
    )

    // The alerts whose list row, or notification item, is rendered now.
    const listedAlerts = alertsResult.isSuccess ? alertsResult.data : undefined
    const notifiedAlerts = notificationsResult.isSuccess
        ? notificationsResult.data
        : undefined
    const listedIds = useMemo(() => idsOf(listedAlerts), [listedAlerts])
    const notifiedIds = useMemo(() => idsOf(notifiedAlerts), [notifiedAlerts])

    // Once a delete of an alert has succeeded, the alert no longer exists, so
    // the failures of its other actions are no longer shown anywhere: kept,
    // they would outlive the row as panel feedback and make the successful
    // delete read as a failed one.
    const updateErrors = useMemo(
        () => withoutAlerts(update.rowErrors, remove.deletedIds),
        [update.rowErrors, remove.deletedIds]
    )
    const acknowledgeErrors = useMemo(
        () => withoutAlerts(acknowledge.rowErrors, remove.deletedIds),
        [acknowledge.rowErrors, remove.deletedIds]
    )

    // Update and delete failures show beside their list row, acknowledge
    // failures beside their notification. A row shows the failure of each of
    // its two list actions, the update's first; each stays until that same
    // action starts again on the row, or its panel feedback is dismissed.
    const listRowErrors = useMemo(
        () => messagesByRow(updateErrors, remove.rowErrors),
        [updateErrors, remove.rowErrors]
    )

    const unplacedErrors = [
        ...unplacedRowErrors(
            "update",
            updateErrors,
            listedIds,
            update.dismissRowError
        ),
        ...unplacedRowErrors(
            "delete",
            remove.rowErrors,
            listedIds,
            remove.dismissRowError
        ),
        ...unplacedRowErrors(
            "acknowledge",
            acknowledgeErrors,
            notifiedIds,
            acknowledge.dismissRowError
        ),
    ]

    // A Dismiss removes the focused button, so focus moves to the entry that
    // takes its place, else to the one before it, else to the panel heading.
    // Only a Dismiss sets `dismissed`, so feedback that appears or goes for
    // any other reason moves no focus. Each Dismiss sets a new object, so a
    // repeat at the same position acts again.
    const [dismissed, setDismissed] = useState<{ index: number } | null>(null)
    const headingRef = useRef<HTMLHeadingElement>(null)
    const focusAfterDismissRef = useRef<HTMLButtonElement>(null)
    const focusAfterDismissKey =
        dismissed === null || unplacedErrors.length === 0
            ? null
            : unplacedErrors[
                  Math.min(dismissed.index, unplacedErrors.length - 1)
              ].key

    useEffect(() => {
        if (dismissed === null) return
        setDismissed(null)
        const target = focusAfterDismissRef.current ?? headingRef.current
        target?.focus()
    }, [dismissed])

    // Every action that starts takes the next token and replaces the record,
    // so only the latest action's settle moves focus; an earlier call that
    // settles later finds another token and leaves focus alone. An action
    // started while focus was outside the panel records nothing. A per-call
    // `onSettled` runs only for the latest call of its hook, which is enough:
    // a later call of the same hook has replaced the record. It runs after
    // the hook's own handling, the refresh of the list and notifications
    // included, so the render that `settledFocus` causes shows the regions
    // as that handling left them. Like every other outcome, focus is applied
    // only while the call's account session and activation are current:
    // after a shutdown, a render of the panel would rebuild the alert
    // queries the shutdown dropped.
    const sectionRef = useRef<HTMLElement>(null)
    const focusTokenRef = useRef(0)
    const focusReturnRef = useRef<{
        token: number
        target: FocusReturn
    } | null>(null)
    const [settledFocus, setSettledFocus] = useState<{ token: number } | null>(
        null
    )

    useEffect(() => {
        if (settledFocus === null) return
        setSettledFocus(null)
        const record = focusReturnRef.current
        const section = sectionRef.current
        if (record?.token !== settledFocus.token || section === null) return
        focusReturnRef.current = null
        if (!isFocusLost()) return
        if (!focusCandidates(section, record.target).some(focusIfAble)) {
            headingRef.current?.focus()
        }
    }, [settledFocus])

    /** The focused element while it is inside the panel, else null. */
    function focusedInPanel(): HTMLElement | null {
        const active = document.activeElement
        const section = sectionRef.current
        return active instanceof HTMLElement &&
            section !== null &&
            section.contains(active)
            ? active
            : null
    }

    /**
     * Where focus returns after an action on the row or notification of
     * `id`: the item's position, and the class of its button that holds
     * focus. Null while focus is outside the panel or the item is not shown.
     */
    function itemFocusReturn(
        region: ItemRegion,
        id: string
    ): FocusReturn | null {
        const active = focusedInPanel()
        const section = sectionRef.current
        if (active === null || section === null) return null
        const items = Array.from(
            section.querySelectorAll<HTMLElement>(ITEM_SELECTORS[region])
        )
        const index = items.findIndex(
            (item) => itemAlertId(item, region) === id
        )
        if (index === -1) return null
        const actionClass = items[index].contains(active)
            ? (ACTION_CLASSES.find((name) => active.classList.contains(name)) ??
              null)
            : null
        return { kind: "item", region, id, index, actionClass }
    }

    /** Records where focus returns for the action starting now; its token. */
    function startFocusReturn(target: FocusReturn | null): number {
        focusTokenRef.current += 1
        const token = focusTokenRef.current
        focusReturnRef.current = target === null ? null : { token, target }
        return token
    }

    /**
     * Run when the call of `token`, started under `ctx`, settles. A later
     * action's record stays, and a call whose context ended moves no focus.
     */
    function settleFocusReturn(token: number, ctx: FeatureContext | undefined) {
        if (ctx === undefined || !isCurrentFeatureContext(ctx)) return
        if (focusReturnRef.current?.token === token) {
            setSettledFocus({ token })
        }
    }

    // Each alert's summary, captured when an action on it starts, so feedback
    // that outlives its row still names the alert.
    const [actionLabels, setActionLabels] = useState<
        ReadonlyMap<string, string>
    >(() => new Map())

    function rememberLabel(id: string, alerts: Alert[] | undefined) {
        const alert = alerts?.find((a) => a.id === id)
        if (alert === undefined) return
        const label = alertSummaryText(alert, instruments)
        setActionLabels((labels) =>
            labels.get(id) === label ? labels : new Map(labels).set(id, label)
        )
    }

    function labelOf(id: string): string {
        return actionLabels.get(id) ?? `Alert ${id.slice(0, 8)}`
    }

    // Held from the first submit until its create settles. The form shows
    // `disabled` only once the panel re-renders, so a second submit before
    // then, as from a fast double-click, would send a second create.
    const createInFlightRef = useRef(false)

    function handleCreate(input: ValidatedAlertInput) {
        if (createInFlightRef.current) return
        createInFlightRef.current = true
        const control = focusedInPanel()
        const token = startFocusReturn(
            control === null ? null : { kind: "form", control }
        )
        create.mutate(
            { accountId, ...input },
            {
                onSettled: (_data, _error, _request, ctx) => {
                    createInFlightRef.current = false
                    settleFocusReturn(token, ctx)
                },
            }
        )
    }

    // Each hook clears its own earlier failure for the row when its action
    // starts again; the other list action's failure stays until that action
    // starts again or is dismissed.
    function handleSetEnabled(id: string, enabled: boolean) {
        rememberLabel(id, listedAlerts)
        const token = startFocusReturn(itemFocusReturn("list", id))
        update.mutate(
            { id, enabled },
            {
                onSettled: (_data, _error, _variables, ctx) =>
                    settleFocusReturn(token, ctx),
            }
        )
    }

    function handleDelete(id: string) {
        rememberLabel(id, listedAlerts)
        const token = startFocusReturn(itemFocusReturn("list", id))
        remove.mutate(id, {
            onSettled: (_data, _error, _id, ctx) =>
                settleFocusReturn(token, ctx),
        })
    }

    function handleAcknowledge(id: string) {
        rememberLabel(id, notifiedAlerts)
        const token = startFocusReturn(itemFocusReturn("notifications", id))
        acknowledge.mutate(id, {
            onSettled: (_data, _error, _id, ctx) =>
                settleFocusReturn(token, ctx),
        })
    }

    function renderUnplacedErrors() {
        return unplacedErrors.map(({ key, id, message, dismiss }, index) => {
            const textId = `alert-feedback-${key}`
            return (
                <div key={key} className="status-message status-error">
                    <span id={textId} role="alert">
                        {`${labelOf(id)}: ${message}`}
                    </span>
                    <button
                        type="button"
                        className="btn btn-secondary btn-sm"
                        aria-describedby={textId}
                        ref={
                            key === focusAfterDismissKey
                                ? focusAfterDismissRef
                                : undefined
                        }
                        onClick={() => {
                            setDismissed({ index })
                            dismiss()
                        }}
                    >
                        Dismiss
                    </button>
                </div>
            )
        })
    }

    // A 403 renders nothing: the query itself runs the feature shutdown.
    // Loading and error messages are live regions, announced when they
    // appear. A query that never loaded returns to `pending` while it
    // refetches, so a failure stays shown until a fetch settles; otherwise
    // every failing poll would swap it for the loading message and back,
    // announcing both again.
    function renderAlertList() {
        if (isFeatureDisabledError(alertsResult.error)) return null
        if (
            alertsResult.isError ||
            (alertsResult.isPending && alertsResult.errorUpdateCount > 0)
        ) {
            return (
                <div className="status-message status-error" role="alert">
                    Could not load alerts. Please try again later.
                </div>
            )
        }
        if (alertsResult.isPending) {
            return (
                <p className="empty-state alerts-loading" role="status">
                    Loading alerts…
                </p>
            )
        }
        return (
            <AlertList
                alerts={alertsResult.data}
                instruments={instruments}
                onSetEnabled={handleSetEnabled}
                onDelete={handleDelete}
                pendingIds={pendingIds}
                rowErrors={listRowErrors}
            />
        )
    }

    function renderNotifications() {
        if (isFeatureDisabledError(notificationsResult.error)) return null
        if (
            notificationsResult.isError ||
            (notificationsResult.isPending &&
                notificationsResult.errorUpdateCount > 0)
        ) {
            return (
                <div className="status-message status-error" role="alert">
                    Could not load notifications. Please try again later.
                </div>
            )
        }
        if (notificationsResult.isPending) {
            return (
                <p className="empty-state alerts-loading" role="status">
                    Loading notifications…
                </p>
            )
        }
        // The heading and list share one block, so only the heading's own
        // margin separates them; with nothing to show, no block takes a gap.
        if (notificationsResult.data.length === 0) return null
        return (
            <div>
                <AlertNotifications
                    notifications={notificationsResult.data}
                    instruments={instruments}
                    onAcknowledge={handleAcknowledge}
                    pendingIds={pendingIds}
                    errors={acknowledgeErrors}
                />
            </div>
        )
    }

    return (
        <section
            id="alerts-panel"
            className="card"
            aria-labelledby="alerts-panel-heading"
            ref={sectionRef}
        >
            {/* Focusable by script only, as the place focus goes when a
                Dismiss or a settled action leaves no control to take it; it
                stays out of the Tab order. */}
            <h3
                id="alerts-panel-heading"
                className="section-heading"
                tabIndex={-1}
                ref={headingRef}
            >
                Price and P/L alerts
            </h3>
            {/* Regions are direct children of the stack, so a region that
                renders nothing adds no gap. */}
            <div className="form">
                <AlertForm
                    instruments={instruments}
                    onCreate={handleCreate}
                    isPending={create.isPending}
                    serverError={create.errorMessage}
                    created={created}
                />
                {renderUnplacedErrors()}
                {renderAlertList()}
                {/* Outside the list's states, so a refetch that is pending
                    or fails after the 204 keeps the confirmation. */}
                <DeletedAlertOutput deletedId={remove.deletedId} />
                {renderNotifications()}
            </div>
        </section>
    )
}

/**
 * The alerts panel of one account. Keyed by the account, so an in-place
 * account change mounts a fresh panel: no confirmation, error, pending state
 * or form text of the previous account is shown for the next.
 */
export function AlertsPanel({ accountId, instruments }: AlertsPanelProps) {
    return (
        <AlertsPanelContent
            key={accountId}
            accountId={accountId}
            instruments={instruments}
        />
    )
}
