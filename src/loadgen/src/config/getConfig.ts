import { EnvConfig } from "@demoability/loadgen-core"
import { ConfigError } from "@demoability/loadgen-core/lib/types"
import { Config, HEADLESS_MODES, ProviderConfig } from "./types"

function getProviderConfig(): ProviderConfig {
    const providerType = EnvConfig.ensureEnum(
        "LOAD_TYPE",
        ["constant", "NYSE"],
        "NYSE"
    )
    switch (providerType) {
        case "constant":
            return { type: "constant" }
        case "NYSE":
            return {
                type: "NYSE",
                learnTimeFactor: EnvConfig.ensureNumber(
                    "RATE_LIMIT_LEARN_TIME_FACTOR",
                    2
                ),
                offHoursLoadFactor: EnvConfig.ensureNumber(
                    "NYSE_OFFHOURS_LOAD_FACTOR",
                    0.7
                ),
                timeframeMinutes: EnvConfig.ensureNumber(
                    "RATE_LIMIT_TIMEFRAME_MINUTES",
                    5
                ),
            }
    }
}

/**
 * Mirrors `WeightedProvider.normalizeWeights` of `@demoability/loadgen-core`:
 * weights above 0 are kept, and each becomes the number of times its visit is
 * drawn per weighted cycle, `Math.round(weight / smallest kept weight)`.
 */
function normalizeVisitCounts(
    weights: Record<string, number>
): Record<string, number> {
    const kept = Object.entries(weights).filter(([, weight]) => weight > 0)
    const smallest = Math.min(...kept.map(([, weight]) => weight))
    return Object.fromEntries(
        kept.map(([name, weight]) => [name, Math.round(weight / smallest)])
    )
}

/**
 * Rejects a `PORTFOLIO_INSIGHTS_ALERT_WEIGHT` the weighted provider cannot
 * schedule. The provider counts each visit's draws up to its normalised count
 * and starts a new cycle only once every count is spent. Its draw counter
 * stops at 2^53, so a count above that, or an infinite one, is never reached:
 * the cycle never restarts, and every other visit stops once its own count is
 * spent.
 *
 * A weight of 0 or below opts the visit out and is returned unchanged. A
 * positive weight is checked visit by visit: it is rejected when any visit's
 * normalised count with this weight is not a safe integer and differs from
 * that visit's count without it. This visit has no count without its own
 * weight, so an unsafe count of its own always rejects. An unsafe count that
 * the existing weights already produce, and that this weight leaves
 * unchanged, is accepted, because this variable does not cause it.
 */
function ensureSchedulablePortfolioInsightsAlertWeight(
    weights: Config["regularVisitsWeights"]
): Config["regularVisitsWeights"] {
    const { portfolio_insights_alert: weight, ...existingWeights } = weights
    const value =
        process.env.PORTFOLIO_INSIGHTS_ALERT_WEIGHT ?? weight.toString()
    if (!Number.isFinite(weight)) {
        throw new ConfigError(
            `Environment variable [PORTFOLIO_INSIGHTS_ALERT_WEIGHT] value [${value}] is not a finite number.`
        )
    }
    if (weight <= 0) {
        return weights
    }
    const counts = normalizeVisitCounts(weights)
    const existingCounts = normalizeVisitCounts(existingWeights)
    const causesUnsafeCount = Object.entries(counts).some(
        ([name, count]) =>
            !Number.isSafeInteger(count) && count !== existingCounts[name]
    )
    if (causesUnsafeCount) {
        throw new ConfigError(
            `Environment variable [PORTFOLIO_INSIGHTS_ALERT_WEIGHT] value [${value}] gives, relative to the other visit weights, a visit count per weighted cycle above Number.MAX_SAFE_INTEGER.`
        )
    }
    return weights
}

export function getConfig(): Config {
    return {
        concurrent_visits: EnvConfig.ensureNumber("CONCURRENCY", 5),
        concurrent_browsers: EnvConfig.ensureNumber("BROWSERS", 1),
        browserTimeToLiveMinutes: EnvConfig.ensureNumber(
            "BROWSER_TTL_MINUTES",
            60
        ),
        logLevel: EnvConfig.ensureEnum(
            "LOG_LEVEL",
            ["silly", "debug", "verbose", "http", "info", "warn", "error"],
            "info"
        ),
        rareVisitsIntervalMinutes: EnvConfig.ensureNumber(
            "RARE_VISITS_INTERVAL_MINUTES",
            30
        ),
        headlessMode: EnvConfig.ensureEnum(
            "HEADLESS_MODE",
            HEADLESS_MODES,
            "headless"
        ),
        visitsConfig: {
            depositMinValue: EnvConfig.ensureNumber("DEPOSIT_MIN_VALUE", 500),
            depositMaxValue: EnvConfig.ensureNumber("DEPOSIT_MAX_VALUE", 1500),
            assetSellRatio: EnvConfig.ensureNumber("ASSET_SELL_RATIO", 0.1),
            withdrawMinValue: EnvConfig.ensureNumber("WITHDRAW_MIN_VALUE", 500),
            transactionMinDuration: EnvConfig.ensureNumber(
                "TRANSACTION_MIN_DURATION",
                1
            ),
            transactionMaxDuration: EnvConfig.ensureNumber(
                "TRANSACTION_MAX_DURATION",
                24
            ),
            easytradeUrl: EnvConfig.ensureUrl("EASYTRADE_URL"),
        },
        providerConfig: getProviderConfig(),
        regularVisitsWeights: ensureSchedulablePortfolioInsightsAlertWeight({
            deposit_and_buy_success: EnvConfig.ensureNumber(
                "DEPOSIT_AND_BUY_SUCCESS_WEIGHT",
                1
            ),
            deposit_and_long_buy_error: EnvConfig.ensureNumber(
                "DEPOSIT_AND_LONG_BUY_ERROR_WEIGHT",
                1
            ),
            deposit_and_long_buy_success: EnvConfig.ensureNumber(
                "DEPOSIT_AND_LONG_BUY_SUCCESS_WEIGHT",
                1
            ),
            deposit_and_long_buy_timeout: EnvConfig.ensureNumber(
                "DEPOSIT_AND_LONG_BUY_TIMEOUT_WEIGHT",
                1
            ),
            long_sell_error: EnvConfig.ensureNumber(
                "LONG_SELL_ERROR_WEIGHT",
                1
            ),
            long_sell_success: EnvConfig.ensureNumber(
                "LONG_SELL_SUCCESS_WEIGHT",
                1
            ),
            long_sell_timeout: EnvConfig.ensureNumber(
                "LONG_SELL_TIMEOUT_WEIGHT",
                1
            ),
            sell_and_withdraw_success: EnvConfig.ensureNumber(
                "SELL_AND_WITHDRAW_SUCCESS_WEIGHT",
                1
            ),
            portfolio_insights_alert: EnvConfig.ensureNumber(
                "PORTFOLIO_INSIGHTS_ALERT_WEIGHT",
                0
            ),
        }),
    }
}
