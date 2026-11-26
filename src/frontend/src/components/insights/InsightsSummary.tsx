import type { PortfolioInsights } from "../../api/portfolioInsights/types"
import { useFormatter } from "../../contexts/FormatterContext/context"
import { AllocationTable } from "./AllocationTable"
import { RiskBadge } from "./RiskBadge"

/** Shown where the broker reports no value (no holdings). */
const noValue = "—"

/** Colour of the signed P/L figure; exactly 0 keeps the default text colour. */
function pnlClassName(unrealizedPnl: number): string | undefined {
    if (unrealizedPnl > 0) {
        return "text-success"
    }
    if (unrealizedPnl < 0) {
        return "text-danger"
    }
    return undefined
}

/**
 * Figures, risk and allocations of `GET /v1/portfolio/insights/{accountId}`.
 * Every number is the broker's, formatted through `FormatterContext` and never
 * recomputed; percents arrive in percent and are passed to `formatPercent` as
 * ratios. Each id-bearing element holds only its formatted value, because the
 * browser check compares that text with the response.
 */
export function InsightsSummary({ insights }: { insights: PortfolioInsights }) {
    const { formatCurrency, formatPercent } = useFormatter()
    const {
        totalValue,
        totalInvested,
        unrealizedPnl,
        unrealizedPnlPercent,
        allocations,
        largestPosition,
        riskLevel,
    } = insights

    return (
        <div className="form">
            <div className="insights-summary">
                <div className="insights-figure">
                    <span className="form-label">Total value</span>
                    <span id="insights-total-value">
                        {formatCurrency(totalValue)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">Total invested</span>
                    <span id="insights-total-invested">
                        {formatCurrency(totalInvested)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">Unrealized P/L</span>
                    <span
                        id="insights-unrealized-pnl"
                        className={pnlClassName(unrealizedPnl)}
                    >
                        {formatCurrency(unrealizedPnl)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">Unrealized P/L %</span>
                    <span id="insights-unrealized-pnl-percent">
                        {formatPercent(unrealizedPnlPercent / 100)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">Largest position</span>
                    <span id="insights-largest-position">
                        {largestPosition === null
                            ? noValue
                            : `${largestPosition.name} (${formatPercent(largestPosition.percent / 100)})`}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">Risk</span>
                    {/* The span keeps the badge content-sized inside the flex column card. */}
                    <span>
                        {riskLevel === null ? (
                            noValue
                        ) : (
                            <RiskBadge riskLevel={riskLevel} />
                        )}
                    </span>
                </div>
            </div>
            {allocations.length > 0 ? (
                <AllocationTable allocations={allocations} />
            ) : (
                <p id="insights-empty-state" className="empty-state">
                    You have no holdings yet. Buy instruments to see portfolio
                    insights.
                </p>
            )}
        </div>
    )
}
