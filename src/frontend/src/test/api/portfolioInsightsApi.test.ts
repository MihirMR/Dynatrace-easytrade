import "@testing-library/jest-dom/vitest"
import { getPortfolioInsightsFlag } from "../../api/featureFlags"
import { getPortfolioInsights } from "../../api/portfolioInsights"
import {
    createAlert,
    listAlerts,
    type Alert,
    type CreateAlertRequest,
} from "../../api/alerts"
import { ApiError, patchJson, services } from "../../api/http"

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
            label: "hung read aborted at 2 s",
            respond: hangUntilAborted,
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

it("listAlerts_response_unwrapsResults", async () => {
    stubFetch({
        method: "GET",
        url: `${services.broker()}/alerts?accountId=${accountId}`,
        respond: respondWith({ results: [alert] }),
    })

    const alerts = await listAlerts(accountId)

    expect(alerts).toEqual([alert])
})

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
