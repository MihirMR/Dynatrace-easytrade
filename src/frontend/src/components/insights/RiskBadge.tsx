import type { RiskLevel } from "../../api/portfolioInsights/types"

// The label stays mixed case in the DOM; `.badge` uppercases it visually only.
const riskBadges: Record<RiskLevel, { className: string; label: string }> = {
    LOW: { className: "badge badge-success", label: "Low" },
    MEDIUM: { className: "badge badge-warning", label: "Medium" },
    HIGH: { className: "badge badge-danger", label: "High" },
}

/** Risk level as computed by broker-service; `null` (no holdings) renders nothing. */
export function RiskBadge({ riskLevel }: { riskLevel: RiskLevel | null }) {
    if (!riskLevel) {
        return null
    }
    const { className, label } = riskBadges[riskLevel]
    return (
        <span id="insights-risk-badge" className={className}>
            {label}
        </span>
    )
}
