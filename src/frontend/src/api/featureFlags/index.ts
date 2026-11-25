import {
    ApiError,
    getJson,
    getJsonWithTimeoutExactStatus,
    put,
    services,
} from "../http"
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

const PORTFOLIO_INSIGHTS_FLAG_STATUS = 200

type FlagReadFailureReason =
    "status" | "aborted" | "timeout" | "network" | "unreadable_json" | "error"

type FlagResponseCheck = "not_object" | "id_mismatch" | "enabled_not_boolean"

type FlagReadFailure = {
    reason: FlagReadFailureReason
    status?: number
    errorName?: string
    error: unknown
}

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

function isAbortError(error: unknown): boolean {
    return (
        typeof error === "object" &&
        error !== null &&
        "name" in error &&
        error.name === "AbortError"
    )
}

/** A content-free error logged in place of one that may quote the response. */
class FlagResponseError extends Error {
    constructor(message: string) {
        super(message)
        this.name = "FlagResponseError"
    }
}

// Every outcome is logged with a whole error object. Errors that carry no
// upstream content are logged as thrown. A JSON parse error's message is built
// from the response bytes, and the body is untrusted, so that error and any
// unrecognised thrown value are replaced by a content-free FlagResponseError
// without a cause.
function describeFlagReadFailure(
    error: unknown,
    signal?: AbortSignal
): FlagReadFailure {
    if (error instanceof ApiError) {
        return { reason: "status", status: error.status, error }
    }
    if (isAbortError(error)) {
        return { reason: signal?.aborted ? "aborted" : "timeout", error }
    }
    if (error instanceof TypeError) {
        return { reason: "network", error }
    }
    if (error instanceof SyntaxError) {
        return {
            reason: "unreadable_json",
            status: PORTFOLIO_INSIGHTS_FLAG_STATUS,
            errorName: "SyntaxError",
            error: new FlagResponseError(
                "Flag response body is not valid JSON"
            ),
        }
    }
    return {
        reason: "error",
        errorName: error instanceof Error ? error.name : typeof error,
        error: new FlagResponseError(
            "Flag read failed with an unrecognised error"
        ),
    }
}

// The body is untrusted, so only the failed check is logged, never the body.
function rejectFlagResponse(check: FlagResponseCheck): false {
    console.error("[getPortfolioInsightsFlag] invalid flag response", {
        reason: "invalid_response",
        status: PORTFOLIO_INSIGHTS_FLAG_STATUS,
        check,
    })
    return false
}

// Fails closed, not propagating: an unreachable flag service means disabled.
export async function getPortfolioInsightsFlag(
    signal?: AbortSignal
): Promise<boolean> {
    let body: unknown
    try {
        body = await getJsonWithTimeoutExactStatus<unknown>(
            `${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`,
            PORTFOLIO_INSIGHTS_FLAG_TIMEOUT_MS,
            PORTFOLIO_INSIGHTS_FLAG_STATUS,
            signal
        )
    } catch (error) {
        console.error(
            "[getPortfolioInsightsFlag] flag read failed",
            describeFlagReadFailure(error, signal)
        )
        return false
    }
    if (!isRecord(body)) {
        return rejectFlagResponse("not_object")
    }
    if (body.id !== PortfolioInsightsFlagId) {
        return rejectFlagResponse("id_mismatch")
    }
    if (typeof body.enabled !== "boolean") {
        return rejectFlagResponse("enabled_not_boolean")
    }
    if (!body.enabled) {
        console.info("[getPortfolioInsightsFlag] flag disabled")
        return false
    }
    return true
}
