/** Computed by broker-service; the client never derives it. */
export type RiskLevel = "LOW" | "MEDIUM" | "HIGH"

export type Allocation = {
    instrumentId: string
    name: string
    quantity: number
    value: number
    /** Share of `totalValue` in percent (50 means 50 %), not a ratio. */
    percent: number
}

/** `GET /v1/portfolio/insights/{accountId}`; figures may be 0 or negative. */
export type PortfolioInsights = {
    totalValue: number
    totalInvested: number
    unrealizedPnl: number
    /** `unrealizedPnl` relative to `totalInvested`, in percent, not a ratio. */
    unrealizedPnlPercent: number
    /** Ordered by `value` descending, then `instrumentId` ascending. */
    allocations: Allocation[]
    /** `null` when the account has no holdings. */
    largestPosition: Allocation | null
    /** `null` when the account has no holdings. */
    riskLevel: RiskLevel | null
}
