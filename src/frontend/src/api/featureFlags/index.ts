import { getJson, getJsonWithTimeout, put, services } from "../http"
import { Config, FeatureFlag, HandlerResponse } from "./types"
export * from "./types"

type FlagDto = {
    id: string
    enabled: boolean
    name: string
    description: string
    isModifiable: boolean
    tag: string
    enabledAt?: string
}

type FlagsDto = {
    results: FlagDto[]
}

export const ConfigFlagIds = {
    FEATURE_FLAG_MANAGEMENT: "frontend_feature_flag_management",
}

export const ConfigDefaults: Config = { featureFlagManagement: true }

export const PortfolioInsightsFlagId = "portfolio-insights-enabled"

const PORTFOLIO_INSIGHTS_FLAG_TIMEOUT_MS = 2000

export async function getFeatureFlags(): Promise<FeatureFlag[]> {
    const { results } = await getJson<FlagsDto>(
        `${services.featureFlag()}/flags?tag=problem_pattern`
    )
    return results.map(({ id, enabled, name, description, isModifiable, enabledAt }) => ({
        id,
        enabled,
        name,
        description,
        isModifiable,
        enabledAt,
    }))
}

export async function getConfig(): Promise<Config> {
    const { results } = await getJson<FlagsDto>(
        `${services.featureFlag()}/flags?tag=config`
    )
    const flag = results.find(
        ({ id }) => id === ConfigFlagIds.FEATURE_FLAG_MANAGEMENT
    )
    return {
        featureFlagManagement:
            flag?.enabled ?? ConfigDefaults.featureFlagManagement,
    }
}

export async function handleFlagToggle(
    flagId: string,
    enabled: boolean
): Promise<HandlerResponse> {
    try {
        await put(`${services.featureFlag()}/flags/${flagId}`, { enabled })
        return {}
    } catch (error) {
        console.error("[handleFlagToggle] failed", error)
        return { error: "There was an error when setting flag state" }
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value)
}

// Fails closed, not propagating: an unreachable flag service means disabled.
export async function getPortfolioInsightsFlag(
    signal?: AbortSignal
): Promise<boolean> {
    let body: unknown
    try {
        body = await getJsonWithTimeout<unknown>(
            `${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`,
            PORTFOLIO_INSIGHTS_FLAG_TIMEOUT_MS,
            signal
        )
    } catch (error) {
        console.error("[getPortfolioInsightsFlag] flag read failed", error)
        return false
    }
    if (
        !isRecord(body) ||
        body.id !== PortfolioInsightsFlagId ||
        typeof body.enabled !== "boolean"
    ) {
        console.error("[getPortfolioInsightsFlag] invalid flag response", body)
        return false
    }
    if (!body.enabled) {
        console.info("[getPortfolioInsightsFlag] flag disabled")
        return false
    }
    return true
}
