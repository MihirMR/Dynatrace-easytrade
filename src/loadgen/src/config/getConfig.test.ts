import assert from "node:assert/strict"
import { afterEach, beforeEach, test } from "node:test"
import { WeightedProvider } from "@demoability/loadgen-core/lib/providers/weightedProvider"
import { getConfig } from "./getConfig"

const EXISTING_WEIGHT_VARIABLES = [
    "DEPOSIT_AND_BUY_SUCCESS_WEIGHT",
    "DEPOSIT_AND_LONG_BUY_ERROR_WEIGHT",
    "DEPOSIT_AND_LONG_BUY_SUCCESS_WEIGHT",
    "DEPOSIT_AND_LONG_BUY_TIMEOUT_WEIGHT",
    "LONG_SELL_ERROR_WEIGHT",
    "LONG_SELL_SUCCESS_WEIGHT",
    "LONG_SELL_TIMEOUT_WEIGHT",
    "SELL_AND_WITHDRAW_SUCCESS_WEIGHT",
]
const PORTFOLIO_WEIGHT_VARIABLE = "PORTFOLIO_INSIGHTS_ALERT_WEIGHT"

let savedEnv: NodeJS.ProcessEnv = {}

beforeEach(() => {
    savedEnv = { ...process.env }
    for (const name of [
        ...EXISTING_WEIGHT_VARIABLES,
        PORTFOLIO_WEIGHT_VARIABLE,
    ]) {
        delete process.env[name]
    }
    process.env.EASYTRADE_URL = "http://easytrade.test"
})

afterEach(() => {
    for (const name of Object.keys(process.env)) {
        if (!(name in savedEnv)) {
            delete process.env[name]
        }
    }
    Object.assign(process.env, savedEnv)
})

test("getConfig_portfolioWeightUnset_defaultsZero", () => {
    assert.equal(getConfig().regularVisitsWeights.portfolio_insights_alert, 0)
})

test("getConfig_portfolioWeightSet_usesValue", () => {
    process.env[PORTFOLIO_WEIGHT_VARIABLE] = "3"

    assert.equal(getConfig().regularVisitsWeights.portfolio_insights_alert, 3)
})

test("getConfig_portfolioWeightZero_keepsExistingWeights", () => {
    const weights = getConfig().regularVisitsWeights
    const provider = new WeightedProvider(weights, (name) => name)
    const drawn = new Set<string>()
    for (let draw = 0; draw < 1000; draw++) {
        const item = provider.getItem()
        drawn.add(item.type === "item" ? String(item.value) : item.type)
    }

    assert.deepEqual(
        { weights, drawn: [...drawn].sort() },
        {
            weights: {
                deposit_and_buy_success: 1,
                deposit_and_long_buy_error: 1,
                deposit_and_long_buy_success: 1,
                deposit_and_long_buy_timeout: 1,
                long_sell_error: 1,
                long_sell_success: 1,
                long_sell_timeout: 1,
                sell_and_withdraw_success: 1,
                portfolio_insights_alert: 0,
            },
            drawn: [
                "deposit_and_buy_success",
                "deposit_and_long_buy_error",
                "deposit_and_long_buy_success",
                "deposit_and_long_buy_timeout",
                "long_sell_error",
                "long_sell_success",
                "long_sell_timeout",
                "sell_and_withdraw_success",
            ],
        }
    )
})
