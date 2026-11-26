import "@testing-library/jest-dom/vitest"
import { getPortfolioInsightsFlag } from "../../api/featureFlags"
import { getPortfolioInsights } from "../../api/portfolioInsights"
import type { PortfolioInsights } from "../../api/portfolioInsights/types"
import {
    createAlert,
    deleteAlert,
    listAlertNotifications,
    listAlerts,
} from "../../api/alerts"
import type { Alert, CreateAlertRequest } from "../../api/alerts/types"
import {
    ApiError,
    InvalidResponseError,
    patchJson,
    services,
} from "../../api/http"

// Contract cases of the Portfolio Insights fetch modules: what each sends and
// how each maps the reply. The flag read's exact log diagnostics are covered
// in portfolioInsightsFlag.test.ts and the shared transport in http.test.ts.

type Respond = (init: RequestInit | undefined) => Promise<Response>

type Route = {
    method: string
    url: string
    respond: Respond
}

const accountId = "a0000000-0000-4000-8000-000000000000"
const instrumentId = "c0000000-0000-4000-8000-000000000001"
const alertId = "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f"

const flagUrl = `${services.featureFlag()}/flags/portfolio-insights-enabled`

const enabledFlag = {
    id: "portfolio-insights-enabled",
    enabled: true,
    name: "Portfolio insights",
    description: "Demo feature, not financial advice.",
    isModifiable: true,
    tag: "feature",
}

const alert: Alert = {
    id: alertId,
    accountId,
    instrumentId,
    type: "TARGET_PRICE",
    direction: "ABOVE",
    threshold: 150.25,
    enabled: true,
    armingRevision: 1,
    triggeredAt: null,
    triggerValue: null,
    acknowledged: false,
    createdAt: "2026-01-15T10:30:00.000Z",
}

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

function respondWith(body: unknown, status = 200): Respond {
    return () => Promise.resolve(jsonResponse(body, status))
}

/** Never settles on its own; rejects with AbortError once its signal aborts. */
function hangUntilAborted(init: RequestInit | undefined): Promise<Response> {
    return new Promise<Response>((_, reject) => {
        const signal = init?.signal
        const abort = (): void =>
            reject(new DOMException("Aborted", "AbortError"))
        if (signal?.aborted) {
            abort()
            return
        }
        signal?.addEventListener("abort", abort, { once: true })
    })
}

function requestUrl(input: RequestInfo | URL): string {
    if (typeof input === "string") {
        return input
    }
    return input instanceof URL ? input.href : input.url
}

/**
 * Answers each request from the route matching its URL and method. Anything
 * else gets a 404, so a wrong path or method fails the case instead of
 * passing silently.
 */
function stubFetch(...routes: Route[]) {
    return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = requestUrl(input)
        const method = init?.method ?? "GET"
        const route = routes.find(
            (candidate) => candidate.url === url && candidate.method === method
        )
        return route
            ? route.respond(init)
            : Promise.resolve(
                  jsonResponse({ error: `no stub for ${method} ${url}` }, 404)
              )
    })
}

function spyConsole() {
    return [
        vi.spyOn(console, "error").mockImplementation(() => undefined),
        vi.spyOn(console, "warn").mockImplementation(() => undefined),
        vi.spyOn(console, "info").mockImplementation(() => undefined),
        vi.spyOn(console, "debug").mockImplementation(() => undefined),
    ]
}

/** Resolves with the rejection reason, or `undefined` when the call resolved. */
function rejectionOf(pending: Promise<unknown>): Promise<unknown> {
    return pending.then(
        () => undefined,
        (error: unknown) => error
    )
}

function apiErrorShape(error: unknown) {
    return {
        isApiError: error instanceof ApiError,
        status: error instanceof ApiError ? error.status : undefined,
    }
}

afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
})

const flagResponses: { label: string; respond: Respond; expected: boolean }[] =
    [
        {
            label: "enabled true",
            respond: respondWith(enabledFlag),
            expected: true,
        },
        {
            label: "enabled false",
            respond: respondWith({ ...enabledFlag, enabled: false }),
            expected: false,
        },
        {
            label: "404",
            respond: respondWith({ error: "flag not found" }, 404),
            expected: false,
        },
        {
            label: "network error",
            respond: () => Promise.reject(new TypeError("Failed to fetch")),
            expected: false,
        },
        {
            label: "non-boolean enabled",
            respond: respondWith({ ...enabledFlag, enabled: "true" }),
            expected: false,
        },
        {
            label: "other id",
            respond: respondWith({
                ...enabledFlag,
                id: "frontend_feature_flag_management",
            }),
            expected: false,
        },
    ]

// Every row runs the same clock: only the true row may resolve true, and each
// false row must fail closed and leave a log entry.
it.each(flagResponses)(
    "getPortfolioInsightsFlag_response_mapsToBoolean ($label)",
    async ({ respond, expected }) => {
        vi.useFakeTimers({ shouldAdvanceTime: true })
        const consoleSpies = spyConsole()
        stubFetch({ method: "GET", url: flagUrl, respond })

        const pending = getPortfolioInsightsFlag()
        await vi.advanceTimersByTimeAsync(2000)
        const enabled = await pending

        expect({
            enabled,
            logged: consoleSpies.some((spy) => spy.mock.calls.length > 0),
        }).toEqual({ enabled: expected, logged: !expected })
    }
)

// The hung row of the matrix above, on a clock that moves only when advanced,
// so the deadline is pinned on both sides of 2,000 ms: the request is still
// live 1 ms before it, and is aborted and answered `false` at it.
it("getPortfolioInsightsFlag_response_mapsToBoolean (hung read aborted at 2 s)", async () => {
    vi.useFakeTimers()
    const [consoleError] = spyConsole()
    let requestSignal: AbortSignal | null | undefined
    stubFetch({
        method: "GET",
        url: flagUrl,
        respond: (init) => {
            requestSignal = init?.signal
            return hangUntilAborted(init)
        },
    })
    // Read without awaiting, so a read still open at the deadline fails the
    // assertion below instead of stalling the case.
    let enabled: boolean | undefined

    void getPortfolioInsightsFlag().then((value) => {
        enabled = value
    })
    await vi.advanceTimersByTimeAsync(1999)
    const beforeDeadline = { aborted: requestSignal?.aborted, enabled }
    await vi.advanceTimersByTimeAsync(1)

    expect({
        beforeDeadline,
        atDeadline: { aborted: requestSignal?.aborted, enabled },
        logged: consoleError.mock.calls,
    }).toEqual({
        beforeDeadline: { aborted: false, enabled: undefined },
        atDeadline: { aborted: true, enabled: false },
        logged: [
            [
                "[getPortfolioInsightsFlag] flag read failed",
                expect.objectContaining({ reason: "timeout" }),
            ],
        ],
    })
})

it("getPortfolioInsightsFlag_request_usesHyphenatedPath", async () => {
    spyConsole()
    const fetchSpy = stubFetch({
        method: "GET",
        url: flagUrl,
        respond: respondWith(enabledFlag),
    })

    await getPortfolioInsightsFlag()

    expect(fetchSpy.mock.calls.map(([input]) => requestUrl(input))).toEqual([
        expect.stringMatching(
            /\/feature-flag-service\/v1\/flags\/portfolio-insights-enabled$/
        ),
    ])
})

it("getPortfolioInsights_forbidden_throwsApiError403", async () => {
    stubFetch({
        method: "GET",
        url: `${services.broker()}/portfolio/insights/${accountId}`,
        respond: respondWith({ error: "feature_disabled" }, 403),
    })

    const error = await rejectionOf(getPortfolioInsights(accountId))

    expect(apiErrorShape(error)).toEqual({ isApiError: true, status: 403 })
})

const insightsUrl = `${services.broker()}/portfolio/insights/${accountId}`

/** A 200 whose body is `text` exactly, for tokens JSON.stringify cannot write. */
function respondWithText(text: string): Respond {
    return () =>
        Promise.resolve(
            new Response(text, {
                status: 200,
                headers: { "Content-Type": "application/json" },
            })
        )
}

/** What a rejection tells its logger, and whether it names the request. */
function invalidResponseShape(error: unknown) {
    const message = error instanceof Error ? error.message : ""
    return {
        isInvalidResponse: error instanceof InvalidResponseError,
        name: error instanceof Error ? error.name : undefined,
        field: error instanceof InvalidResponseError ? error.field : undefined,
        message,
        mentionsRequest:
            message.includes(accountId) || message.includes("/broker-service"),
    }
}

const easyTravel = {
    instrumentId,
    name: "EasyTravel",
    quantity: 5,
    value: 60,
    percent: 120,
}

// A negative close values its holding below zero; figures are signed.
const easyHealth = {
    instrumentId: "c0000000-0000-4000-8000-000000000002",
    name: "EasyHealth",
    quantity: 2,
    value: -10,
    percent: -20,
}

const heldInsights: PortfolioInsights = {
    totalValue: 50,
    totalInvested: 80,
    unrealizedPnl: -30,
    unrealizedPnlPercent: -37.5,
    allocations: [easyTravel, easyHealth],
    largestPosition: easyTravel,
    riskLevel: "HIGH",
}

it.each<{ holdings: string; body: PortfolioInsights }>([
    { holdings: "held, signed figures", body: heldInsights },
    {
        holdings: "none",
        body: {
            totalValue: 0,
            totalInvested: 0,
            unrealizedPnl: 0,
            unrealizedPnlPercent: 0,
            allocations: [],
            largestPosition: null,
            riskLevel: null,
        },
    },
])(
    "getPortfolioInsights_validBody_returnsFiguresUnchanged ($holdings)",
    async ({ body }) => {
        stubFetch({
            method: "GET",
            url: insightsUrl,
            respond: respondWith(body),
        })

        const insights = await getPortfolioInsights(accountId)

        expect(insights).toEqual(body)
    }
)

const malformedInsights: {
    variant: string
    bodyText: string
    field: string
}[] = [
    { variant: "array body", bodyText: "[]", field: "body" },
    { variant: "null body", bodyText: "null", field: "body" },
    {
        variant: "missing figure",
        bodyText: JSON.stringify({ ...heldInsights, totalValue: undefined }),
        field: "totalValue",
    },
    {
        variant: "figure as text",
        bodyText: JSON.stringify({ ...heldInsights, totalInvested: "80" }),
        field: "totalInvested",
    },
    {
        variant: "figure overflowing to Infinity",
        bodyText: JSON.stringify(heldInsights).replace(
            '"unrealizedPnl":-30',
            '"unrealizedPnl":1e400'
        ),
        field: "unrealizedPnl",
    },
    {
        variant: "null figure",
        bodyText: JSON.stringify({
            ...heldInsights,
            unrealizedPnlPercent: null,
        }),
        field: "unrealizedPnlPercent",
    },
    {
        variant: "missing allocations",
        bodyText: JSON.stringify({ ...heldInsights, allocations: undefined }),
        field: "allocations",
    },
    {
        variant: "allocations as an object",
        bodyText: JSON.stringify({ ...heldInsights, allocations: {} }),
        field: "allocations",
    },
    {
        variant: "null allocation",
        bodyText: JSON.stringify({
            ...heldInsights,
            allocations: [easyTravel, null],
        }),
        field: "allocations[1]",
    },
    {
        variant: "allocation without instrument id",
        bodyText: JSON.stringify({
            ...heldInsights,
            allocations: [{ ...easyTravel, instrumentId: "" }],
        }),
        field: "allocations[0].instrumentId",
    },
    {
        variant: "allocation name not text",
        bodyText: JSON.stringify({
            ...heldInsights,
            allocations: [{ ...easyTravel, name: 7 }],
        }),
        field: "allocations[0].name",
    },
    {
        variant: "allocation value overflowing to -Infinity",
        bodyText: JSON.stringify(heldInsights).replace(
            '"value":-10',
            '"value":-1e400'
        ),
        field: "allocations[1].value",
    },
    {
        variant: "allocation percent as text",
        bodyText: JSON.stringify({
            ...heldInsights,
            allocations: [easyTravel, { ...easyHealth, percent: "-20" }],
        }),
        field: "allocations[1].percent",
    },
    {
        variant: "missing largest position",
        bodyText: JSON.stringify({
            ...heldInsights,
            largestPosition: undefined,
        }),
        field: "largestPosition",
    },
    {
        variant: "largest position without quantity",
        bodyText: JSON.stringify({
            ...heldInsights,
            largestPosition: { ...easyTravel, quantity: undefined },
        }),
        field: "largestPosition.quantity",
    },
    {
        variant: "lowercase risk level",
        bodyText: JSON.stringify({ ...heldInsights, riskLevel: "high" }),
        field: "riskLevel",
    },
    {
        variant: "unknown risk level",
        bodyText: JSON.stringify({ ...heldInsights, riskLevel: "EXTREME" }),
        field: "riskLevel",
    },
    {
        variant: "missing risk level",
        bodyText: JSON.stringify({ ...heldInsights, riskLevel: undefined }),
        field: "riskLevel",
    },
]

// The message names only the failing field: no URL, account id or value.
it.each(malformedInsights)(
    "getPortfolioInsights_malformedBody_rejectsInvalidResponseError ($variant)",
    async ({ bodyText, field }) => {
        stubFetch({
            method: "GET",
            url: insightsUrl,
            respond: respondWithText(bodyText),
        })

        const error = await rejectionOf(getPortfolioInsights(accountId))

        expect(invalidResponseShape(error)).toEqual({
            isInvalidResponse: true,
            name: "InvalidResponseError",
            field,
            message: `Invalid response body at ${field}`,
            mentionsRequest: false,
        })
    }
)

it("listAlerts_response_unwrapsResults", async () => {
    stubFetch({
        method: "GET",
        url: `${services.broker()}/alerts?accountId=${accountId}`,
        respond: respondWith({ results: [alert] }),
    })

    const alerts = await listAlerts(accountId)

    expect(alerts).toEqual([alert])
})

const triggeredAlert: Alert = {
    ...alert,
    id: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e50",
    armingRevision: 2,
    triggeredAt: "2026-01-15T11:00:00.000Z",
    triggerValue: 151.5,
}

// A disabled alert keeps its trigger data, so it is still a notification, and
// a trigger value of 0 is a reading, not a missing one.
const disabledTriggeredAlert: Alert = {
    ...triggeredAlert,
    id: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e51",
    type: "PROFIT_LOSS",
    direction: "BELOW",
    threshold: 1,
    enabled: false,
    triggeredAt: "2026-01-15T10:45:00.000Z",
    triggerValue: 0,
}

const notificationsUrl = `${services.broker()}/alerts/notifications?accountId=${accountId}&unacknowledged=true`

// Both reads share one envelope decoder, so every case runs against both. The
// list also holds armed alerts; a notification has always triggered.
const alertReads: {
    read: string
    url: string
    call: () => Promise<Alert[]>
    entries: Alert[]
}[] = [
    {
        read: "listAlerts",
        url: `${services.broker()}/alerts?accountId=${accountId}`,
        call: () => listAlerts(accountId),
        entries: [triggeredAlert, alert],
    },
    {
        read: "listAlertNotifications",
        url: notificationsUrl,
        call: () => listAlertNotifications(accountId, true),
        entries: [triggeredAlert, disabledTriggeredAlert],
    },
]

it.each(alertReads)(
    "alertRead_validBody_returnsEntriesUnchanged ($read)",
    async ({ url, call, entries }) => {
        stubFetch({
            method: "GET",
            url,
            respond: respondWith({ results: entries }),
        })

        const alerts = await call()

        expect(alerts).toEqual(entries)
    }
)

// A row the list accepts as armed is malformed as a notification: one without
// its trigger time and value would show a reading the broker never took. The
// message names only the failing field: no URL, account id or value.
const untriggeredNotificationBodies: {
    variant: string
    bodyText: string
    field: string
}[] = [
    {
        variant: "armed alert after a triggered one",
        bodyText: JSON.stringify({ results: [triggeredAlert, alert] }),
        field: "results[1].triggeredAt",
    },
    {
        variant: "null triggered time",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggeredAt: null }],
        }),
        field: "results[0].triggeredAt",
    },
    {
        variant: "missing triggered time",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggeredAt: undefined }],
        }),
        field: "results[0].triggeredAt",
    },
    {
        variant: "null trigger value",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggerValue: null }],
        }),
        field: "results[0].triggerValue",
    },
    {
        variant: "missing trigger value",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggerValue: undefined }],
        }),
        field: "results[0].triggerValue",
    },
    {
        variant: "trigger value overflowing to Infinity",
        bodyText: JSON.stringify({ results: [triggeredAlert] }).replace(
            '"triggerValue":151.5',
            '"triggerValue":1e400'
        ),
        field: "results[0].triggerValue",
    },
]

it.each(untriggeredNotificationBodies)(
    "listAlertNotifications_rowWithoutTrigger_rejectsInvalidResponseError ($variant)",
    async ({ bodyText, field }) => {
        stubFetch({
            method: "GET",
            url: notificationsUrl,
            respond: respondWithText(bodyText),
        })

        const error = await rejectionOf(listAlertNotifications(accountId, true))

        expect(invalidResponseShape(error)).toEqual({
            isInvalidResponse: true,
            name: "InvalidResponseError",
            field,
            message: `Invalid response body at ${field}`,
            mentionsRequest: false,
        })
    }
)

const malformedAlertBodies: {
    variant: string
    bodyText: string
    field: string
}[] = [
    { variant: "array body", bodyText: "[]", field: "body" },
    { variant: "missing results", bodyText: "{}", field: "results" },
    {
        variant: "results as an object",
        bodyText: JSON.stringify({ results: {} }),
        field: "results",
    },
    {
        variant: "null entry",
        bodyText: JSON.stringify({ results: [triggeredAlert, null] }),
        field: "results[1]",
    },
    {
        variant: "empty id",
        bodyText: JSON.stringify({ results: [{ ...alert, id: "" }] }),
        field: "results[0].id",
    },
    {
        variant: "missing account id",
        bodyText: JSON.stringify({
            results: [{ ...alert, accountId: undefined }],
        }),
        field: "results[0].accountId",
    },
    {
        variant: "instrument id as a number",
        bodyText: JSON.stringify({ results: [{ ...alert, instrumentId: 1 }] }),
        field: "results[0].instrumentId",
    },
    {
        variant: "lowercase type",
        bodyText: JSON.stringify({
            results: [{ ...alert, type: "target_price" }],
        }),
        field: "results[0].type",
    },
    {
        variant: "unknown direction",
        bodyText: JSON.stringify({ results: [{ ...alert, direction: "UP" }] }),
        field: "results[0].direction",
    },
    {
        variant: "threshold as text",
        bodyText: JSON.stringify({
            results: [{ ...alert, threshold: "150.25" }],
        }),
        field: "results[0].threshold",
    },
    {
        variant: "threshold overflowing to Infinity",
        bodyText: JSON.stringify({ results: [alert] }).replace(
            '"threshold":150.25',
            '"threshold":1e400'
        ),
        field: "results[0].threshold",
    },
    {
        variant: "enabled as text",
        bodyText: JSON.stringify({ results: [{ ...alert, enabled: "true" }] }),
        field: "results[0].enabled",
    },
    {
        variant: "arming revision 0",
        bodyText: JSON.stringify({
            results: [{ ...alert, armingRevision: 0 }],
        }),
        field: "results[0].armingRevision",
    },
    {
        variant: "fractional arming revision",
        bodyText: JSON.stringify({
            results: [{ ...alert, armingRevision: 1.5 }],
        }),
        field: "results[0].armingRevision",
    },
    {
        variant: "triggered time as a number",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggeredAt: 0 }],
        }),
        field: "results[0].triggeredAt",
    },
    {
        variant: "trigger value as text",
        bodyText: JSON.stringify({
            results: [{ ...triggeredAlert, triggerValue: "151.5" }],
        }),
        field: "results[0].triggerValue",
    },
    {
        variant: "missing acknowledged",
        bodyText: JSON.stringify({
            results: [{ ...alert, acknowledged: undefined }],
        }),
        field: "results[0].acknowledged",
    },
    {
        variant: "null creation time",
        bodyText: JSON.stringify({ results: [{ ...alert, createdAt: null }] }),
        field: "results[0].createdAt",
    },
]

// The message names only the failing field: no URL, account id or value.
it.each(
    alertReads.flatMap(({ read, url, call }) =>
        malformedAlertBodies.map((body) => ({ read, url, call, ...body }))
    )
)(
    "alertRead_malformedBody_rejectsInvalidResponseError ($read, $variant)",
    async ({ url, call, bodyText, field }) => {
        stubFetch({ method: "GET", url, respond: respondWithText(bodyText) })

        const error = await rejectionOf(call())

        expect(invalidResponseShape(error)).toEqual({
            isInvalidResponse: true,
            name: "InvalidResponseError",
            field,
            message: `Invalid response body at ${field}`,
            mentionsRequest: false,
        })
    }
)

const featureReads: {
    read: string
    url: string
    call: (signal: AbortSignal) => Promise<unknown>
}[] = [
    {
        read: "getPortfolioInsights",
        url: `${services.broker()}/portfolio/insights/${accountId}`,
        call: (signal) => getPortfolioInsights(accountId, signal),
    },
    {
        read: "listAlerts",
        url: `${services.broker()}/alerts?accountId=${accountId}`,
        call: (signal) => listAlerts(accountId, signal),
    },
    {
        read: "listAlertNotifications",
        url: `${services.broker()}/alerts/notifications?accountId=${accountId}&unacknowledged=true`,
        call: (signal) => listAlertNotifications(accountId, true, signal),
    },
]

it.each(featureReads)(
    "featureRead_signalAborted_rejectsAbortError ($read)",
    async ({ url, call }) => {
        const sent: (AbortSignal | null | undefined)[] = []
        stubFetch({
            method: "GET",
            url,
            respond: (init) => {
                sent.push(init?.signal)
                return hangUntilAborted(init)
            },
        })
        const caller = new AbortController()

        const pending = rejectionOf(call(caller.signal))
        caller.abort()
        const error = await pending

        expect({
            name: (error as Error).name,
            forwarded: sent.length === 1 && sent[0] === caller.signal,
        }).toEqual({ name: "AbortError", forwarded: true })
    }
)

// Asserted on the raw body text: parsing it would turn the token into a
// Number and round 9999999999.99999999 to 10000000000.
it.each([
    {
        input: "9999999999.99999999",
        token: /"threshold":\s*9999999999\.99999999[,}]/,
    },
    { input: "1.500", token: /"threshold":\s*1\.5[,}]/ },
])(
    "createAlert_threshold_sentAsExactToken ($input)",
    async ({ input, token }) => {
        let sentBody: unknown
        stubFetch({
            method: "POST",
            url: `${services.broker()}/alerts`,
            respond: (init) => {
                sentBody = init?.body
                return Promise.resolve(jsonResponse(alert, 201))
            },
        })
        const request: CreateAlertRequest = {
            accountId,
            type: "TARGET_PRICE",
            instrumentId,
            direction: "ABOVE",
            threshold: input,
        }

        await createAlert(request)

        expect(sentBody).toEqual(expect.stringMatching(token))
    }
)

const createRequest: CreateAlertRequest = {
    accountId,
    type: "TARGET_PRICE",
    instrumentId,
    direction: "ABOVE",
    threshold: "150.25",
}

// An alert-shaped body that is not a 201 must not confirm the create.
it.each([200, 202])(
    "createAlert_unexpectedSuccessStatus_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = jsonResponse(alert, status)
        stubFetch({
            method: "POST",
            url: `${services.broker()}/alerts`,
            respond: () => Promise.resolve(response),
        })

        const error = await rejectionOf(createAlert(createRequest))

        expect({
            ...apiErrorShape(error),
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)

it("deleteAlert_noContent204_resolves", async () => {
    stubFetch({
        method: "DELETE",
        url: `${services.broker()}/alerts/${alertId}`,
        respond: () => Promise.resolve(new Response(null, { status: 204 })),
    })

    const error = await rejectionOf(deleteAlert(alertId))

    expect(error).toBeUndefined()
})

it.each([200, 202])(
    "deleteAlert_unexpectedSuccessStatus_rejectsApiErrorBeforeBodyRead (%i)",
    async (status) => {
        const response = jsonResponse(alert, status)
        stubFetch({
            method: "DELETE",
            url: `${services.broker()}/alerts/${alertId}`,
            respond: () => Promise.resolve(response),
        })

        const error = await rejectionOf(deleteAlert(alertId))

        expect({
            ...apiErrorShape(error),
            bodyRead: response.bodyUsed,
        }).toEqual({ isApiError: true, status, bodyRead: false })
    }
)

// The returned threshold is read back out of the raw body text, so the case
// fails if it ever differs from the token the request carried.
it.each([
    { input: "1.500", sent: "1.5" },
    { input: "2.", sent: "2" },
    { input: "9999999999.99999999", sent: "9999999999.99999999" },
])("createAlert_success_returnsSentToken ($input)", async ({ input, sent }) => {
    let sentBody: unknown
    stubFetch({
        method: "POST",
        url: `${services.broker()}/alerts`,
        respond: (init) => {
            sentBody = init?.body
            return Promise.resolve(jsonResponse(alert, 201))
        },
    })
    const request: CreateAlertRequest = {
        accountId,
        type: "TARGET_PRICE",
        instrumentId,
        direction: "ABOVE",
        threshold: input,
    }

    const created = await createAlert(request)

    const bodyToken =
        typeof sentBody === "string"
            ? /"threshold":([^,}]+)\}$/.exec(sentBody)?.[1]
            : undefined
    expect({
        alert: created.alert,
        threshold: created.threshold,
        bodyToken,
    }).toEqual({ alert, threshold: sent, bodyToken: sent })
})

// A typed-API caller that bypasses the form is held to the same grammar,
// digit domain and target-price rule, and nothing is sent.
it.each<{
    type: CreateAlertRequest["type"]
    input: string
    message: string
}>([
    { type: "TARGET_PRICE", input: "", message: "Enter a threshold." },
    {
        type: "TARGET_PRICE",
        input: "abc",
        message: "Threshold must be a number.",
    },
    {
        type: "TARGET_PRICE",
        input: "12345678901",
        message: "Threshold allows at most 10 integer and 8 decimal digits.",
    },
    {
        type: "TARGET_PRICE",
        input: "0.000000001",
        message: "Threshold allows at most 10 integer and 8 decimal digits.",
    },
    {
        type: "TARGET_PRICE",
        input: "0",
        message: "Target price must be greater than 0.",
    },
    {
        type: "TARGET_PRICE",
        input: "-1",
        message: "Target price must be greater than 0.",
    },
])(
    "createAlert_invalidThreshold_rejectsBeforeRequest ($type $input)",
    async ({ type, input, message }) => {
        const fetchSpy = stubFetch({
            method: "POST",
            url: `${services.broker()}/alerts`,
            respond: respondWith(alert, 201),
        })
        const request: CreateAlertRequest = {
            accountId,
            type,
            instrumentId,
            direction: "ABOVE",
            threshold: input,
        }

        const error = await rejectionOf(createAlert(request))

        expect({
            message: error instanceof Error ? error.message : undefined,
            requests: fetchSpy.mock.calls.length,
        }).toEqual({
            message: `Invalid alert threshold: ${message}`,
            requests: 0,
        })
    }
)

it.each([500, 404])("patchJson_non2xx_throwsApiError (%i)", async (status) => {
    const fetchSpy = stubFetch({
        method: "PATCH",
        url: `${services.broker()}/alerts/${alertId}`,
        respond: respondWith({ statusCode: status, message: "failed" }, status),
    })

    const error = await rejectionOf(
        patchJson(`${services.broker()}/alerts/${alertId}`, { enabled: true })
    )

    expect({
        ...apiErrorShape(error),
        methods: fetchSpy.mock.calls.map(([, init]) => init?.method),
    }).toEqual({ isApiError: true, status, methods: ["PATCH"] })
})
