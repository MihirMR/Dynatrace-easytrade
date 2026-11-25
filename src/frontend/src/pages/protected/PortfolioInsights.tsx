import { useEffect, useRef, useState } from "react"
import { useNavigate } from "react-router"
import { useQueryClient } from "@tanstack/react-query"
import { BizEvents } from "../../api/bizEvents"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import { InsightsSummary } from "../../components/insights/InsightsSummary"
import { useAuthUser } from "../../contexts/UserContext/context"
import { useAlertsQuery } from "../../hooks/useAlerts"
import { usePortfolioInsightsFlag } from "../../hooks/useFeatureFlags"
import { useInstrumentsQuery } from "../../hooks/useInstruments"
import { usePortfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    captureFeatureContext,
    isCurrentFeatureContext,
    isFeatureDisabledError,
    onPortfolioInsightsDisabled,
} from "../../utils/portfolioInsightsFeature"

/**
 * The `/insights` page: the broker's portfolio figures and the alerts panel,
 * shown only while the Portfolio Insights flag is on. The page holds no
 * shutdown logic of its own: it hands every 403 to the shared shutdown and
 * leaves for `/home` once the flag reads `false`.
 */
export function PortfolioInsights() {
    const { userId } = useAuthUser()
    const flag = usePortfolioInsightsFlag()
    const navigate = useNavigate()
    const queryClient = useQueryClient()
    const insights = usePortfolioInsightsQuery(userId, flag)
    const { data: instruments } = useInstrumentsQuery(userId)
    // Observed only for its 403: `AlertsPanel` renders this cache entry.
    const alerts = useAlertsQuery(userId, flag)
    const [mountContext] = useState(() => captureFeatureContext())
    const viewSent = useRef(false)

    useEffect(() => {
        if (!flag) {
            void navigate("/home", { replace: true })
        }
    }, [flag, navigate])

    useEffect(() => {
        if (
            isFeatureDisabledError(insights.error) ||
            isFeatureDisabledError(alerts.error)
        ) {
            onPortfolioInsightsDisabled(queryClient)
        }
    }, [insights.error, alerts.error, queryClient])

    useEffect(() => {
        if (insights.error && !isFeatureDisabledError(insights.error)) {
            console.error("Could not load portfolio insights", insights.error)
        }
    }, [insights.error])

    // Sent once per mount, on the first result that is still current: a
    // refetch never sends it again, and neither does a result that arrives
    // after a logout, an account switch or a shutdown since the mount.
    const data = insights.data
    useEffect(() => {
        if (
            viewSent.current ||
            !flag ||
            data === undefined ||
            !isCurrentFeatureContext(mountContext)
        ) {
            return
        }
        viewSent.current = true
        BizEvents.portfolioInsightsView({
            accountId: userId,
            holdingCount: data.allocations.length,
            riskLevel: data.riskLevel,
        })
    }, [data, flag, mountContext, userId])

    if (!flag) {
        return null
    }

    function renderSummary() {
        // The shared shutdown handles a 403 and no message is shown.
        if (isFeatureDisabledError(insights.error)) {
            return null
        }
        if (insights.isError) {
            return (
                <div
                    id="insights-error"
                    className="status-message status-error"
                >
                    Could not load portfolio insights. Please try again later.
                </div>
            )
        }
        if (insights.isPending) {
            return <p id="insights-loading">Loading portfolio insights…</p>
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
