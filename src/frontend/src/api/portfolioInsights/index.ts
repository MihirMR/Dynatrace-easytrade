import { getJson, services } from "../http"
import { PortfolioInsights } from "./types"
export * from "./types"

export async function getPortfolioInsights(
    accountId: string
): Promise<PortfolioInsights> {
    return await getJson<PortfolioInsights>(
        `${services.broker()}/portfolio/insights/${accountId}`
    )
}
