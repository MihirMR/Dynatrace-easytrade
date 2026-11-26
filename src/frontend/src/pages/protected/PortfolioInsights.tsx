import { useEffect, useRef, useState, type ReactNode } from "react"
import { useNavigate } from "react-router"
import { BizEvents } from "../../api/bizEvents"
import { loggableError } from "../../api/http"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import { InsightsSummary } from "../../components/insights/InsightsSummary"
import { useAuthUser } from "../../contexts/UserContext/context"
import { useAlertsQuery } from "../../hooks/useAlerts"
import { usePortfolioInsightsFlag } from "../../hooks/useFeatureFlags"
import { useInstrumentsQuery } from "../../hooks/useInstruments"
import { usePortfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    featureResultContext,
    isCurrentFeatureContext,
    isFeatureDisabledError,
} from "../../utils/portfolioInsightsFeature"

/**
 * Renders its content one commit after it mounts, so text placed in a live
 * region through it is added to a region that is already present: a region
 * inserted already holding its text may stay silent. The state is local, so
 * the page and its queries do not render again when it flips.
 */
function AfterMount({ children }: { children: ReactNode }) {
    const [mounted, setMounted] = useState(false)

    useEffect(() => {
        setMounted(true)
    }, [])

    return mounted ? children : null
}

/**
 * The `/insights` page: the broker's portfolio figures and the alerts panel,
 * shown only while the Portfolio Insights flag is on. The page holds no
 * shutdown logic: its feature queries run the shared shutdown on a 403
 * themselves, and the page leaves for `/home` once the flag reads `false`.
 */
export function PortfolioInsights() {
    const { userId } = useAuthUser()
    const flag = usePortfolioInsightsFlag()
    const navigate = useNavigate()
    const insights = usePortfolioInsightsQuery(userId, flag)
    const { data: instruments } = useInstrumentsQuery(userId)
    // Started with the page's other queries; `AlertsPanel` renders this
    // cache entry.
    useAlertsQuery(userId, flag)
    const viewSent = useRef(false)

    useEffect(() => {
        if (!flag) {
            void navigate("/home", { replace: true })
        }
    }, [flag, navigate])

    useEffect(() => {
        if (insights.error && !isFeatureDisabledError(insights.error)) {
            console.error(
                "Could not load portfolio insights",
                loggableError(insights.error, userId)
            )
        }
    }, [insights.error])

    // Sent once per mount, on the first result whose own request is still
    // current for the account shown: the account, session and activation it
    // was requested under all still hold. A refetch never sends it again.
    // Data cached under an earlier session or activation, or for another
    // account, is skipped, and a result loaded afresh after an in-place
    // account change or a shutdown and resume while the page stays mounted
    // still sends it. `dataUpdatedAt` re-runs the check when a refetch
    // returns equal data, which keeps its reference but carries the context
    // of the request that just returned it.
    const { data, dataUpdatedAt } = insights
    useEffect(() => {
        if (viewSent.current || !flag || data === undefined) {
            return
        }
        const produced = featureResultContext(data)
        if (
            produced === undefined ||
            produced.userId !== userId ||
            !isCurrentFeatureContext(produced)
        ) {
            return
        }
        viewSent.current = true
        BizEvents.portfolioInsightsView({
            accountId: userId,
            holdingCount: data.allocations.length,
            riskLevel: data.riskLevel,
        })
    }, [data, dataUpdatedAt, flag, userId])

    if (!flag) {
        return null
    }

    function renderSummary() {
        // The shared shutdown handles a 403 and no message is shown.
        if (isFeatureDisabledError(insights.error)) {
            return null
        }
        // One plain block keeps the page stack's spacing in every state. The
        // status region in it stays mounted, empty unless the query is pending.
        return (
            <div>
                <div id="insights-status" role="status">
                    {insights.isPending && (
                        <AfterMount>
                            <p id="insights-loading">
                                Loading portfolio insights…
                            </p>
                        </AfterMount>
                    )}
                </div>
                {renderSummaryResult()}
            </div>
        )
    }

    function renderSummaryResult() {
        if (insights.isError) {
            return (
                <div
                    id="insights-error"
                    className="status-message status-error"
                    role="alert"
                >
                    Could not load portfolio insights. Please try again later.
                </div>
            )
        }
        if (insights.isPending) {
            return null
        }
        return <InsightsSummary insights={insights.data} />
    }

    return (
        // The inline `gap` follows the page stack of `Home.tsx`.
        <div
            id="portfolio-insights"
            className="form"
            style={{ gap: "var(--space-8)" }}
        >
            <h2>Portfolio Insights</h2>
            <p
                id="insights-disclaimer"
                className="status-message status-info"
                role="note"
            >
                Simulated demo data. Portfolio Insights is not financial advice.
            </p>
            {renderSummary()}
            <AlertsPanel accountId={userId} instruments={instruments ?? []} />
        </div>
    )
}
