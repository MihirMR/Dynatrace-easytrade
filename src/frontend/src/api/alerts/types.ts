/** Exact, case-sensitive; the broker rejects any other spelling. */
export type AlertType = "TARGET_PRICE" | "PROFIT_LOSS"

/** Exact, case-sensitive; the broker rejects any other spelling. */
export type AlertDirection = "ABOVE" | "BELOW"

/** One alert; also the shape of every notification entry. */
export type Alert = {
    /** GUID string, as are `accountId` and `instrumentId` (broker `AlertDTO`). */
    id: string
    accountId: string
    instrumentId: string
    type: AlertType
    direction: AlertDirection
    /**
     * A price for `TARGET_PRICE`, a percentage for `PROFIT_LOSS`. Parsed from a
     * JSON number, so it is for display only; the server's value is the record.
     */
    threshold: number
    enabled: boolean
    /**
     * Starts at 1 and grows by 1 on each enable. Notifications are deduplicated
     * on `${accountId}:${id}:${armingRevision}`.
     */
    armingRevision: number
    /** ISO-8601; `null` until the current arming triggers. */
    triggeredAt: string | null
    /** Observed price or P/L percent, display only; `null` until triggered. */
    triggerValue: number | null
    acknowledged: boolean
    /** ISO-8601. */
    createdAt: string
}

/** Raw text from the alert form, before validation. */
export type AlertFormInput = {
    type: string
    instrumentId: string
    direction: string
    threshold: string
}

/**
 * Create request; threshold is validated text, never a number. Server-owned
 * fields (enabled, revision, trigger data, acknowledgement, creation time) are
 * absent because a caller may not set them.
 */
export type CreateAlertRequest = {
    accountId: string
    type: AlertType
    instrumentId: string
    direction: AlertDirection
    /**
     * Text validated and normalised by `utils/alertValidation.ts` and sent as
     * an unquoted JSON number token, so it never passes through a `Number`.
     */
    threshold: string
}

/**
 * A 201 create: the alert the broker returned and the exact threshold token
 * its request body carried, kept as text so it never passes through a
 * `Number`.
 */
export type CreatedAlert = { alert: Alert; threshold: string }

/**
 * Form input that passed `utils/alertValidation.ts`: exact enum names, a
 * listed instrument id and the normalised threshold token. The alerts panel
 * adds `accountId` to make the create request.
 */
export type ValidatedAlertInput = Omit<CreateAlertRequest, "accountId">
