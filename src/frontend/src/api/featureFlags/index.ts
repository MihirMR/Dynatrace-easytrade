import {
    ApiError,
    getJson,
    getJsonWithTimeoutExactStatus,
    isReadDeadlineAbort,
    MalformedJsonError,
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

// The diagnostic logged for an exception caught during the read. Every error
// is kept as thrown. Within this read only parsing builds a message from the
// response bytes, which are untrusted, and the parse boundary of
// `getJsonWithTimeoutExactStatus` in http.ts already makes that error
// content-safe: a `MalformedJsonError`, whose message is fixed and whose
// stack holds frames but no body text. Only that error counts as unreadable
// JSON; a SyntaxError raised anywhere else is unrecognised.
function describeFlagReadFailure(
    error: unknown,
    signal?: AbortSignal
): FlagReadFailure {
    if (error instanceof ApiError) {
        return { reason: "status", status: error.status, error }
    }
    if (isAbortError(error)) {
        const callerAborted = signal?.aborted && !isReadDeadlineAbort(error)
        return { reason: callerAborted ? "aborted" : "timeout", error }
    }
    if (error instanceof TypeError) {
        return { reason: "network", error }
    }
    if (error instanceof MalformedJsonError) {
        return {
            reason: "unreadable_json",
            status: PORTFOLIO_INSIGHTS_FLAG_STATUS,
            errorName: error.name,
            error,
        }
    }
    return {
        reason: "error",
        errorName: error instanceof Error ? error.name : typeof error,
        error,
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
        // `getJsonWithTimeoutExactStatus`, not `getJsonWithTimeout`: the flag
        // counts only for a 200, and an unparsable body must fail as the
        // content-safe `MalformedJsonError`, while `getJsonWithTimeout` keeps
        // its signature and parser error for the version page.
        body = await getJsonWithTimeoutExactStatus<unknown>(
            `${services.featureFlag()}/flags/${PortfolioInsightsFlagId}`,
            PORTFOLIO_INSIGHTS_FLAG_TIMEOUT_MS,
            PORTFOLIO_INSIGHTS_FLAG_STATUS,
            signal
        )
    } catch (error) {
        const diagnostic = describeFlagReadFailure(error, signal)
        // A read its caller cancelled has its result discarded, so it is
        // logged at debug level; every other failure at error level.
        if (diagnostic.reason === "aborted") {
            console.debug(
                "[getPortfolioInsightsFlag] flag read failed",
                diagnostic
            )
        } else {
            console.error(
                "[getPortfolioInsightsFlag] flag read failed",
                diagnostic
            )
        }
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
