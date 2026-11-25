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

function setWeightEnvironment(variables: Record<string, string>) {
    for (const name of [
        ...EXISTING_WEIGHT_VARIABLES,
        PORTFOLIO_WEIGHT_VARIABLE,
    ]) {
        delete process.env[name]
    }
    process.env.EASYTRADE_URL = "http://easytrade.test"
    Object.assign(process.env, variables)
}

function isPortfolioWeightError(reason: string) {
    return (error: unknown) =>
        error instanceof Error &&
        error.constructor.name === "ConfigError" &&
        error.message.includes(`[${PORTFOLIO_WEIGHT_VARIABLE}]`) &&
        error.message.includes(reason)
}

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

test("getConfig_portfolioWeightNonFinite_throwsConfigError", async (t) => {
    for (const weight of ["Infinity", "-Infinity", "1e400"]) {
        await t.test(weight, () => {
            setWeightEnvironment({ [PORTFOLIO_WEIGHT_VARIABLE]: weight })

            assert.throws(
                () => getConfig(),
                isPortfolioWeightError("is not a finite number")
            )
        })
    }
})

test("getConfig_portfolioWeightUnsafeCount_throwsConfigError", async (t) => {
    for (const weight of ["1e16", "1e300", "1e-16", "1e-320"]) {
        await t.test(weight, () => {
            setWeightEnvironment({ [PORTFOLIO_WEIGHT_VARIABLE]: weight })

            assert.throws(
                () => getConfig(),
                isPortfolioWeightError("above Number.MAX_SAFE_INTEGER")
            )
        })
    }
})

test("getConfig_portfolioWeightNonPositive_returnsValue", async (t) => {
    for (const weight of ["0", "-1", "-1e300"]) {
        await t.test(weight, () => {
            setWeightEnvironment({ [PORTFOLIO_WEIGHT_VARIABLE]: weight })

            assert.equal(
                getConfig().regularVisitsWeights.portfolio_insights_alert,
                Number(weight)
            )
        })
    }
})

test("getConfig_portfolioWeightSafeBoundary_returnsValue", async (t) => {
    for (const weight of ["9007199254740991", "1e-15"]) {
        await t.test(weight, () => {
            setWeightEnvironment({ [PORTFOLIO_WEIGHT_VARIABLE]: weight })

            assert.equal(
                getConfig().regularVisitsWeights.portfolio_insights_alert,
                Number(weight)
            )
        })
    }
})

test("getConfig_portfolioWeightRescalesExistingCounts_throwsConfigError", async (t) => {
    const rows: { name: string; variables: Record<string, string> }[] = [
        {
            name: "existing weight 2^53, portfolio weight 1e-320",
            variables: {
                DEPOSIT_AND_BUY_SUCCESS_WEIGHT: "9007199254740992",
                [PORTFOLIO_WEIGHT_VARIABLE]: "1e-320",
            },
        },
        {
            name: "existing weight 2^53, portfolio weight 0.5",
            variables: {
                DEPOSIT_AND_BUY_SUCCESS_WEIGHT: "9007199254740992",
                [PORTFOLIO_WEIGHT_VARIABLE]: "0.5",
            },
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            setWeightEnvironment(row.variables)

            assert.throws(
                () => getConfig(),
                isPortfolioWeightError("above Number.MAX_SAFE_INTEGER")
            )
        })
    }
})

test("getConfig_existingCountsUnchanged_acceptsPortfolioWeight", async (t) => {
    const rows: {
        name: string
        variables: Record<string, string>
        expected: number
    }[] = [
        {
            name: "existing weight 1e300, portfolio weight 1",
            variables: {
                DEPOSIT_AND_BUY_SUCCESS_WEIGHT: "1e300",
                [PORTFOLIO_WEIGHT_VARIABLE]: "1",
            },
            expected: 1,
        },
        {
            name: "every existing weight 0, portfolio weight 1e300",
            variables: {
                ...Object.fromEntries(
                    EXISTING_WEIGHT_VARIABLES.map((name) => [name, "0"])
                ),
                [PORTFOLIO_WEIGHT_VARIABLE]: "1e300",
            },
            expected: 1e300,
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            setWeightEnvironment(row.variables)

            assert.equal(
                getConfig().regularVisitsWeights.portfolio_insights_alert,
                row.expected
            )
        })
    }
})
