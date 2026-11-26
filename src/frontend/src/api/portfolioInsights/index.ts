import { getJsonWithSignal, InvalidResponseError, services } from "../http"
import type { Allocation, PortfolioInsights, RiskLevel } from "./types"
export * from "./types"

type JsonObject = Record<string, unknown>

function isJsonObject(value: unknown): value is JsonObject {
    return typeof value === "object" && value !== null && !Array.isArray(value)
}

/** Exact and case-sensitive, as the broker writes it; `null` is no holdings. */
function toRiskLevel(value: unknown): RiskLevel | null {
    if (
        value === null ||
        value === "LOW" ||
        value === "MEDIUM" ||
        value === "HIGH"
    ) {
        return value
    }
    throw new InvalidResponseError("riskLevel")
}

/** `key` of `source`, an object found at `parent`, as a finite number. */
function finiteNumber(source: JsonObject, key: string, parent = ""): number {
    const value = source[key]
    if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new InvalidResponseError(parent === "" ? key : `${parent}.${key}`)
    }
    return value
}

function toAllocation(value: unknown, path: string): Allocation {
    if (!isJsonObject(value)) throw new InvalidResponseError(path)
    const { instrumentId, name } = value
    if (typeof instrumentId !== "string" || instrumentId === "") {
        throw new InvalidResponseError(`${path}.instrumentId`)
    }
    if (typeof name !== "string") {
        throw new InvalidResponseError(`${path}.name`)
    }
    return {
        instrumentId,
        name,
        quantity: finiteNumber(value, "quantity", path),
        value: finiteNumber(value, "value", path),
        percent: finiteNumber(value, "percent", path),
    }
}

function toAllocations(value: unknown): Allocation[] {
    if (!Array.isArray(value)) throw new InvalidResponseError("allocations")
    const entries: readonly unknown[] = value
    return entries.map((entry, index) =>
        toAllocation(entry, `allocations[${index}]`)
    )
}

/**
 * Checks a 200 body against the insights contract and returns its values
 * unchanged, in source field order, so the first field that fails names the
 * error. Figures may be 0 or negative, but must be finite.
 */
function toPortfolioInsights(body: unknown): PortfolioInsights {
    if (!isJsonObject(body)) throw new InvalidResponseError("body")
    const { largestPosition } = body
    return {
        totalValue: finiteNumber(body, "totalValue"),
        totalInvested: finiteNumber(body, "totalInvested"),
        unrealizedPnl: finiteNumber(body, "unrealizedPnl"),
        unrealizedPnlPercent: finiteNumber(body, "unrealizedPnlPercent"),
        allocations: toAllocations(body.allocations),
        largestPosition:
            largestPosition === null
                ? null
                : toAllocation(largestPosition, "largestPosition"),
        riskLevel: toRiskLevel(body.riskLevel),
    }
}

/**
 * The account's insights; aborting `signal` cancels the HTTP read. A 200
 * whose body breaks the contract (a missing or non-finite figure, a malformed
 * allocation, an unknown risk level) rejects with `InvalidResponseError`, so
 * it reaches the query's error state instead of failing a render.
 */
export async function getPortfolioInsights(
    accountId: string,
    signal?: AbortSignal
): Promise<PortfolioInsights> {
    const body = await getJsonWithSignal<unknown>(
        `${services.broker()}/portfolio/insights/${accountId}`,
        signal
    )
    return toPortfolioInsights(body)
}
