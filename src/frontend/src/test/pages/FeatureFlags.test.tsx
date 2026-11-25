import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen } from "@testing-library/react"
import { ConfigFlagIds, PortfolioInsightsFlagId } from "../../api/featureFlags"
import { services } from "../../api/http"
import { portfolioInsightsFlagQuery } from "../../hooks/useFeatureFlags"
import FeatureFlags from "../../pages/FeatureFlags"
import { featureFlagKeys } from "../../utils/queryKeys"
import { ToastWrapper } from "../providers"

// The /feature-flags page is unchanged by the Portfolio Insights work: its
// Refresh refetches the legacy flag queries and must leave the shared
// Portfolio Insights flag query alone, even once a protected page cached it.

/** The page's minimum spinner time (`MIN_SPINNER_MS` in pages/FeatureFlags). */
const REFRESH_SPINNER_MS = 500

const PROBLEM_FLAGS_URL = `${services.featureFlag()}/flags?tag=problem_pattern`
const CONFIG_FLAGS_URL = `${services.featureFlag()}/flags?tag=config`
const PORTFOLIO_FLAG_URL = `${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`

type FlagServiceState = { portfolioEnabled: boolean }

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    })
}

function requestUrl(input: RequestInfo | URL): string {
    if (typeof input === "string") {
        return input
    }
    return input instanceof URL ? input.href : input.url
}

/** Answers the three flag reads from `state`, and 404 for anything else. */
function stubFlagService(state: FlagServiceState) {
    return vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = requestUrl(input)
        if (url === PROBLEM_FLAGS_URL) {
            return Promise.resolve(
                jsonResponse({
                    results: [
                        {
                            id: "db_not_responding",
                            enabled: false,
                            name: "db_not_responding",
                            description: "Database does not respond",
                            isModifiable: true,
                            tag: "problem_pattern",
                        },
                    ],
                })
            )
        }
        if (url === CONFIG_FLAGS_URL) {
            return Promise.resolve(
                jsonResponse({
                    results: [
                        {
                            id: ConfigFlagIds.FEATURE_FLAG_MANAGEMENT,
                            enabled: true,
                            name: ConfigFlagIds.FEATURE_FLAG_MANAGEMENT,
                            description: "Flag management in the UI",
                            isModifiable: false,
                            tag: "config",
                        },
                    ],
                })
            )
        }
        if (url === PORTFOLIO_FLAG_URL) {
            return Promise.resolve(
                jsonResponse({
                    id: PortfolioInsightsFlagId,
                    enabled: state.portfolioEnabled,
                    name: PortfolioInsightsFlagId,
                    description: "Portfolio Insights and Alerts",
                    isModifiable: true,
                    tag: "feature",
                })
            )
        }
        return Promise.resolve(jsonResponse({ error: "not found" }, 404))
    })
}

afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
})

it("featureFlagsRefresh_portfolioFlagCached_refreshesOnlyLegacyFlags", async () => {
    const state: FlagServiceState = { portfolioEnabled: true }
    const fetchSpy = stubFlagService(state)
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false } },
    })
    await client.query(portfolioInsightsFlagQuery(client))
    // Turned off after the cache was populated: a Refresh that re-read the
    // portfolio flag would now run the feature shutdown and cache `false`.
    state.portfolioEnabled = false
    vi.useFakeTimers()
    render(
        <QueryClientProvider client={client}>
            <ToastWrapper>
                <FeatureFlags />
            </ToastWrapper>
        </QueryClientProvider>
    )
    await act(() => vi.advanceTimersByTimeAsync(0))
    const sentBeforeRefresh = fetchSpy.mock.calls.length

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }))
    await act(() => vi.advanceTimersByTimeAsync(REFRESH_SPINNER_MS))

    expect({
        refreshRequests: fetchSpy.mock.calls
            .slice(sentBeforeRefresh)
            .map(([input]) => requestUrl(input))
            .sort(),
        refreshFinished: !screen
            .getByRole("button", { name: "Refresh" })
            .hasAttribute("disabled"),
        portfolioFlag: client.getQueryData(featureFlagKeys.portfolioInsights),
    }).toEqual({
        refreshRequests: [CONFIG_FLAGS_URL, PROBLEM_FLAGS_URL].sort(),
        refreshFinished: true,
        portfolioFlag: true,
    })
})
