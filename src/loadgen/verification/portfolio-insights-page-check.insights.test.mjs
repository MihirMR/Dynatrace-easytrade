// Unit tests of how the page check compares the insights page with an
// insights response: the exact formatted text of each figure, allocation row
// and the largest position, its placeholder when there is none, and the
// rereads and deadline of the comparison with the page's last response.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { test } from "node:test"

import {
    compareInsights,
    compareWithLastInsights,
} from "./portfolio-insights-page-check.mjs"

const ACCOUNT_ID = "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f"
/** The page check's poll interval between two reads. */
const POLL_STEP_MS = 250

/** An insights response of an account holding two instruments. */
const HOLDER = {
    totalValue: 300,
    totalInvested: 250,
    unrealizedPnl: 50,
    unrealizedPnlPercent: 20,
    allocations: [
        {
            instrumentId: "1b2c3d4e-0000-4000-8000-000000000001",
            name: "EasyTravel",
            quantity: 100,
            value: 200,
            percent: 66.6667,
        },
        {
            instrumentId: "1b2c3d4e-0000-4000-8000-000000000002",
            name: "EasyCloud",
            quantity: 2,
            value: 100,
            percent: 33.3333,
        },
    ],
    largestPosition: {
        instrumentId: "1b2c3d4e-0000-4000-8000-000000000001",
        name: "EasyTravel",
        quantity: 100,
        value: 200,
        percent: 66.6667,
    },
    riskLevel: "HIGH",
}

/** What the page shows for `HOLDER`, as `readInsightsDom` reads it. */
const HOLDER_DOM = {
    totalValue: "$300.00",
    totalInvested: "$250.00",
    unrealizedPnl: "$50.00",
    unrealizedPnlPercent: "+20.00%",
    largestPosition: "EasyTravel (+66.67%)",
    riskBadge: "High",
    emptyState: false,
    rows: [
        ["EasyTravel", "100", "$200.00", "+66.67%"],
        ["EasyCloud", "2", "$100.00", "+33.33%"],
    ],
}

/** A later response of the same account, after EasyTravel rose. */
const HOLDER_LATER = {
    ...HOLDER,
    totalValue: 450,
    unrealizedPnl: 200,
    unrealizedPnlPercent: 80,
    allocations: [
        { ...HOLDER.allocations[0], value: 350, percent: 77.7778 },
        { ...HOLDER.allocations[1], percent: 22.2222 },
    ],
    largestPosition: {
        ...HOLDER.largestPosition,
        value: 350,
        percent: 77.7778,
    },
}

const HOLDER_LATER_DOM = {
    ...HOLDER_DOM,
    totalValue: "$450.00",
    unrealizedPnl: "$200.00",
    unrealizedPnlPercent: "+80.00%",
    largestPosition: "EasyTravel (+77.78%)",
    rows: [
        ["EasyTravel", "100", "$350.00", "+77.78%"],
        ["EasyCloud", "2", "$100.00", "+22.22%"],
    ],
}

/** An insights response of an account without holdings. */
const EMPTY = {
    totalValue: 0,
    totalInvested: 0,
    unrealizedPnl: 0,
    unrealizedPnlPercent: 0,
    allocations: [],
    largestPosition: null,
    riskLevel: null,
}

const EMPTY_DOM = {
    totalValue: "$0",
    totalInvested: "$0",
    unrealizedPnl: "$0",
    unrealizedPnlPercent: "0.00%",
    largestPosition: "\u2014",
    riskBadge: null,
    emptyState: true,
    rows: null,
}

/**
 * A page whose `evaluate` runs `formatInPage` in Node and answers
 * `readInsightsDom` with the DOM `view.dom` held when the call began. While
 * either call is in flight it runs `view.during` with the function's name.
 */
function fakePage(view) {
    return {
        evaluate: async (fn, arg) => {
            const dom = view.dom
            view.during?.(fn.name)
            if (fn.name === "readInsightsDom") {
                return dom
            }
            if (fn.name === "formatInPage") {
                return fn(arg)
            }
            throw new Error(`unexpected page function ${fn.name}`)
        },
    }
}

function insightsEntry(body) {
    return {
        kind: "insights",
        accountId: ACCOUNT_ID,
        status: 200,
        accepted: true,
        rejection: null,
        parsed: true,
        body,
    }
}

function sessionShowing(view, body) {
    return {
        account: { accountId: ACCOUNT_ID },
        page: fakePage(view),
        responses: [insightsEntry(body)],
    }
}

/**
 * Settles what `start` returns while mocked time advances one poll step
 * whenever the code under test waits, so its waits take no real time. The
 * check's own deadline bounds the loop.
 */
async function settleWithMockedTime(t, start) {
    t.mock.timers.enable({ apis: ["setTimeout", "Date"] })
    let settled = false
    const outcome = start().then(
        (value) => {
            settled = true
            return { value }
        },
        (error) => {
            settled = true
            return { error }
        }
    )
    while (!settled) {
        await new Promise((resolve) => setImmediate(resolve))
        t.mock.timers.tick(POLL_STEP_MS)
    }
    const result = await outcome
    if ("error" in result) {
        throw result.error
    }
    return result.value
}

test("compareInsights_pageShowsFormattedResponse_reportsNoProblem", async () => {
    const result = await compareInsights(fakePage({}), HOLDER_DOM, HOLDER)

    assert.deepEqual(result.problems, [])
})

test("compareInsights_namesWithSurroundingSpaces_comparesTrimmedText", async () => {
    const padded = { ...HOLDER.allocations[0], name: " EasyTravel " }
    const body = {
        ...HOLDER,
        allocations: [padded, HOLDER.allocations[1]],
        largestPosition: padded,
    }
    // The page renders " EasyTravel  (+66.67%)"; the read trims its ends.
    const dom = { ...HOLDER_DOM, largestPosition: "EasyTravel  (+66.67%)" }

    const result = await compareInsights(fakePage({}), dom, body)

    assert.deepEqual(result.problems, [])
})

/**
 * How many problems a comparison reports and which elements it found
 * mismatched. How a problem prints page text is the redaction suite's.
 */
function mismatchesOf(result) {
    return {
        problems: result.problems.length,
        mismatched: result.pairs
            .filter((pair) => !pair.ok)
            .map((pair) => pair.element),
    }
}

for (const [scenario, label] of [
    ["longer name", "NotEasyTravel (+66.67%)"],
    ["trailing text", "EasyTravel (+66.67%) x"],
    ["repeated percent", "EasyTravel (+66.67%) (+66.67%)"],
    ["other name first", "EasyCloud EasyTravel (+66.67%)"],
]) {
    test(`compareInsights_largestPositionLabelOnlyContainsNameAndPercent_reportsMismatch (${scenario})`, async () => {
        const dom = { ...HOLDER_DOM, largestPosition: label }

        const result = await compareInsights(fakePage({}), dom, HOLDER)

        assert.deepEqual(mismatchesOf(result), {
            problems: 1,
            mismatched: ["#insights-largest-position"],
        })
    })
}

test("compareInsights_noLargestPositionAndPlaceholder_reportsNoProblem", async () => {
    const result = await compareInsights(fakePage({}), EMPTY_DOM, EMPTY)

    assert.deepEqual(result.problems, [])
})

for (const [scenario, text] of [
    ["element absent", null],
    ["empty text", ""],
    ["hyphen", "-"],
    ["en dash", "\u2013"],
    ["stale label", "EasyTravel (+66.67%)"],
]) {
    test(`compareInsights_noLargestPositionAndOtherText_reportsMismatch (${scenario})`, async () => {
        const dom = { ...EMPTY_DOM, largestPosition: text }

        const result = await compareInsights(fakePage({}), dom, EMPTY)

        assert.deepEqual(mismatchesOf(result), {
            problems: 1,
            mismatched: ["#insights-largest-position"],
        })
    })
}

for (const quantityText of ["1,0", "1,00", "100.0", "1e2", "0100"]) {
    test(`compareInsights_quantityTextNotStringOfQuantity_reportsMismatch (${quantityText})`, async () => {
        const dom = {
            ...HOLDER_DOM,
            rows: [
                ["EasyTravel", quantityText, "$200.00", "+66.67%"],
                HOLDER_DOM.rows[1],
            ],
        }

        const result = await compareInsights(fakePage({}), dom, HOLDER)

        assert.deepEqual(mismatchesOf(result), {
            problems: 1,
            mismatched: ["#insights-allocations row 1 quantity"],
        })
    })
}

for (const phase of ["readInsightsDom", "formatInPage"]) {
    test(`compareWithLastInsights_newerResponseDuringRead_repeatsReadAgainstNewerResponse (${phase})`, async (t) => {
        // The first read sees the page showing HOLDER, which it matches; the
        // newer response and its render arrive while `phase` is in flight.
        const view = { dom: HOLDER_DOM }
        const session = sessionShowing(view, HOLDER)
        view.during = (name) => {
            if (name === phase && session.responses.length === 1) {
                session.responses.push(insightsEntry(HOLDER_LATER))
                view.dom = HOLDER_LATER_DOM
            }
        }

        const result = await settleWithMockedTime(t, () =>
            compareWithLastInsights(session)
        )

        assert.deepEqual(
            {
                problems: result.problems,
                response: result.response,
                unstableReads: result.unstableReads,
            },
            { problems: [], response: HOLDER_LATER, unstableReads: 1 }
        )
    })
}

test("compareWithLastInsights_newerResponseDuringEveryRead_throwsUnstable", async (t) => {
    const view = { dom: HOLDER_DOM }
    const session = sessionShowing(view, HOLDER)
    view.during = (name) => {
        if (name === "formatInPage") {
            session.responses.push(insightsEntry({ ...HOLDER }))
        }
    }

    await assert.rejects(
        settleWithMockedTime(t, () => compareWithLastInsights(session)),
        {
            message:
                "unstable: a newer insights response arrived during each of 3 reads",
        }
    )
})

/** The page check's deadline for the page to show its last response. */
const RENDER_TIMEOUT_MS = 10_000
const RENDER_TIMEOUT = `timed out after ${RENDER_TIMEOUT_MS} ms waiting for the page to show its last insights response`
/** A DOM read the test answers itself, through `page.held`. */
const HELD = Symbol("held read")

/**
 * A page whose DOM reads answer `reads` in turn, each a DOM or `HELD`, and
 * whose formatting runs `formatInPage` in Node. Closing it rejects a held
 * read, as Puppeteer ends a pending call on a closed page.
 */
function scriptedPage(reads) {
    const page = { closes: 0, held: null }
    page.evaluate = async (fn, arg) => {
        if (fn.name === "formatInPage") {
            return fn(arg)
        }
        if (fn.name !== "readInsightsDom") {
            throw new Error(`unexpected page function ${fn.name}`)
        }
        const read = reads.shift()
        if (read !== HELD) {
            return read
        }
        return new Promise((resolve, reject) => {
            page.held = { resolve, reject }
        })
    }
    page.close = async () => {
        page.closes += 1
        page.held?.reject(new Error("Target closed"))
    }
    return page
}

/**
 * Puts `performance.now()` and `setTimeout` under the test's control;
 * `advance` moves both on one poll step at a time, and `lag` moves only the
 * clock, as a busy event loop that runs timers late does.
 */
function controlClock(t) {
    let now = 0
    t.mock.method(performance, "now", () => now)
    t.mock.timers.enable({ apis: ["setTimeout"] })
    const settle = () => new Promise((resolve) => setImmediate(resolve))
    return {
        settle,
        async advance(ms) {
            await settle()
            for (let left = ms; left > 0; left -= POLL_STEP_MS) {
                const step = Math.min(left, POLL_STEP_MS)
                now += step
                t.mock.timers.tick(step)
                await settle()
            }
        },
        lag(ms) {
            now += ms
        },
    }
}

test("compareWithLastInsights_noMatchByDeadline_returnsOnlyReadsAnsweredInTime", async (t) => {
    // What compareInsights finds for the one read that answered in time.
    const onTimeMismatch = await compareInsights(
        fakePage({}),
        HOLDER_LATER_DOM,
        HOLDER
    )
    const cases = [
        {
            name: "matching read answers after the deadline",
            responses: [insightsEntry(HOLDER)],
            reads: [HELD],
            run: async (clock, page) => {
                clock.lag(RENDER_TIMEOUT_MS + 1)
                page.held.resolve(HOLDER_DOM)
            },
            expected: {
                problems: [
                    `${RENDER_TIMEOUT}; its last probe did not answer in time`,
                ],
                pairs: [],
                response: null,
                unstableReads: 0,
                closes: 0,
            },
        },
        {
            name: "mismatch in time, then a matching read after the deadline",
            responses: [insightsEntry(HOLDER)],
            reads: [HOLDER_LATER_DOM, HELD],
            run: async (clock, page) => {
                await clock.advance(POLL_STEP_MS)
                clock.lag(RENDER_TIMEOUT_MS)
                page.held.resolve(HOLDER_DOM)
            },
            expected: { ...onTimeMismatch, unstableReads: 0, closes: 0 },
        },
        {
            name: "read stalls past the deadline",
            responses: [insightsEntry(HOLDER)],
            reads: [HELD],
            run: (clock) => clock.advance(RENDER_TIMEOUT_MS),
            expected: {
                problems: [
                    `${RENDER_TIMEOUT}; its last probe did not answer in time`,
                ],
                pairs: [],
                response: null,
                unstableReads: 0,
                closes: 1,
            },
        },
        {
            name: "no insights response",
            responses: [],
            reads: [],
            run: (clock) => clock.advance(RENDER_TIMEOUT_MS),
            expected: {
                problems: ["the page received no insights response"],
                pairs: [],
                response: null,
                unstableReads: 0,
                closes: 0,
            },
        },
    ]
    for (const { name, responses, reads, run, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const page = scriptedPage([...reads])
            const session = {
                account: { accountId: ACCOUNT_ID },
                page,
                responses,
            }
            const result = compareWithLastInsights(session)
            await clock.settle()
            await run(clock, page)
            await clock.settle()

            assert.deepEqual(
                { ...(await result), closes: page.closes },
                expected
            )
        })
    }
})
