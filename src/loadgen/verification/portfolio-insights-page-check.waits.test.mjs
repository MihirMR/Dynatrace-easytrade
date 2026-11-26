// Unit tests of the bounded waits of portfolio-insights-page-check.mjs, and
// of the live-shutdown window they serve.
//
// Time is controlled, never slept: `performance.now()` reads a test clock and
// `setTimeout` runs on node:test's mock timers, which `advance` moves
// together one millisecond at a time. `lag` moves only the clock, as a busy
// event loop does when it runs a timer late. The live-shutdown cases move the
// clock from a loopback flag-service stub and a page stand-in instead, and
// no outcome waits on a real timer.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
//
// `npm test` runs only the compiled `build/` suites.
import assert from "node:assert/strict"
import { createServer } from "node:http"
import { test } from "node:test"

import {
    checkAcknowledge,
    checkLiveShutdown,
    clickWhenClear,
    observeAbsence,
    probePage,
    waitFor,
    waitForToggle,
    WaitTimeoutError,
} from "./portfolio-insights-page-check.mjs"

const TIMEOUT_MS = 50
const WINDOW_MS = 100
const INTERVAL_MS = 20
const WHAT = "the condition"
const TIMEOUT_MESSAGE = `timed out after ${TIMEOUT_MS} ms waiting for ${WHAT}`
const UNANSWERED_MESSAGE = `${TIMEOUT_MESSAGE}; its last probe did not answer in time`
const ABSENCE_MESSAGE = `timed out after ${WINDOW_MS + INTERVAL_MS} ms waiting for the absence probe to answer; the ${WINDOW_MS} ms window was not fully observed`
const VIOLATION = "a notification request was sent"
/** Longest delay one `setTimeout` keeps; Node runs a longer one after 1 ms. */
const MAX_TIMER_MS = 2 ** 31 - 1
/** The re-arm window, 2 × interval + 30 s, of the longest interval allowed. */
const LONG_BUDGET_MS = (2 * 4_294_967 + 30) * 1000

/** Both waits, with the time at which a probe left unanswered ends each. */
const WAITS = [
    {
        name: "waitFor",
        run: (probe) =>
            waitFor(probe, {
                timeoutMs: TIMEOUT_MS,
                intervalMs: INTERVAL_MS,
                what: WHAT,
            }),
        endsAt: TIMEOUT_MS,
    },
    {
        name: "observeAbsence",
        run: (probe) =>
            observeAbsence(probe, {
                windowMs: WINDOW_MS,
                intervalMs: INTERVAL_MS,
            }),
        endsAt: WINDOW_MS + INTERVAL_MS,
    },
]

/** Lets every promise continuation that is already due run. */
function settle() {
    return new Promise((resolve) => setImmediate(resolve))
}

/** Puts `performance.now()` and `setTimeout` under the test's control. */
function controlClock(t) {
    let now = 0
    t.mock.method(performance, "now", () => now)
    t.mock.timers.enable({ apis: ["setTimeout"] })
    return {
        async advance(ms) {
            await settle()
            for (let step = 0; step < ms; step += 1) {
                now += 1
                t.mock.timers.tick(1)
                await settle()
            }
        },
        lag(ms) {
            now += ms
        },
        /**
         * Moves the clock and the timers on together by `ms`, in steps of at
         * most `stepMs`, one timer's longest delay unless given, rather than
         * one millisecond each.
         */
        async leap(ms, stepMs = MAX_TIMER_MS) {
            await settle()
            for (let left = ms; left > 0; left -= stepMs) {
                const step = Math.min(left, stepMs)
                now += step
                t.mock.timers.tick(step)
                await settle()
            }
        },
    }
}

/** Records how `promise` settles, and when by the test clock. */
function track(promise) {
    const outcome = { state: "pending", value: undefined, error: undefined }
    promise.then(
        (value) =>
            Object.assign(outcome, {
                state: "fulfilled",
                value,
                at: performance.now(),
            }),
        (error) =>
            Object.assign(outcome, {
                state: "rejected",
                error,
                at: performance.now(),
            })
    )
    return outcome
}

/** A probe whose answer the test gives through `answer`. */
function heldProbe() {
    const held = {}
    held.probe = (signal) =>
        new Promise((resolve, reject) => {
            held.signal = signal
            held.resolve = resolve
            held.reject = reject
        })
    return held
}

function resolveAfter(ms, value) {
    return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

function rejectAfter(ms, error) {
    return new Promise((_, reject) => setTimeout(() => reject(error), ms))
}

test("waitFor_probeUnansweredAtDeadline_rejectsWithWaitTimeoutErrorAtDeadline", async (t) => {
    const cases = [
        { name: "probe never settles", probe: () => new Promise(() => {}) },
        {
            name: "probe answers truthy after the deadline",
            probe: () => resolveAfter(TIMEOUT_MS + 10, true),
        },
    ]
    for (const { name, probe } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const outcome = track(
                waitFor(probe, {
                    timeoutMs: TIMEOUT_MS,
                    intervalMs: INTERVAL_MS,
                    what: WHAT,
                })
            )
            await clock.advance(TIMEOUT_MS - 1)
            const before = outcome.state
            await clock.advance(1)
            assert.deepEqual(
                {
                    before,
                    state: outcome.state,
                    at: outcome.at,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                },
                {
                    before: "pending",
                    state: "rejected",
                    at: TIMEOUT_MS,
                    timeout: true,
                    message: UNANSWERED_MESSAGE,
                }
            )
        })
    }
})

test("waitFor_answerArrivesAfterDeadline_rejectsWithWaitTimeoutError", async (t) => {
    const lateError = new Error("the probe failed late")
    const cases = [
        {
            name: "truthy value",
            answer: (held) => held.resolve("ready"),
            cause: undefined,
        },
        {
            name: "rejection",
            answer: (held) => held.reject(lateError),
            cause: lateError,
        },
    ]
    for (const { name, answer, cause } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const held = heldProbe()
            const outcome = track(
                waitFor(held.probe, {
                    timeoutMs: TIMEOUT_MS,
                    intervalMs: INTERVAL_MS,
                    what: WHAT,
                })
            )
            // The answer comes after the deadline, before the expiry timer
            // had its turn.
            clock.lag(TIMEOUT_MS + 10)
            answer(held)
            await settle()
            assert.deepEqual(
                {
                    state: outcome.state,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                    cause: outcome.error?.cause,
                },
                {
                    state: "rejected",
                    timeout: true,
                    message: UNANSWERED_MESSAGE,
                    cause,
                }
            )
        })
    }
})

test("waitFor_truthyAnswerByDeadline_resolvesWithIt", async (t) => {
    const cases = [
        {
            name: "synchronous first answer",
            probe: () => () => "ready",
            value: "ready",
            at: 0,
        },
        {
            name: "asynchronous answer",
            probe: () => () => resolveAfter(10, { id: 7 }),
            value: { id: 7 },
            at: 10,
        },
        {
            name: "truthy on the third poll",
            probe: () => {
                let polls = 0
                return () => {
                    polls += 1
                    return polls < 3 ? false : 3
                }
            },
            value: 3,
            at: 2 * INTERVAL_MS,
        },
    ]
    for (const { name, probe, value, at } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const outcome = track(
                waitFor(probe(), {
                    timeoutMs: TIMEOUT_MS,
                    intervalMs: INTERVAL_MS,
                    what: WHAT,
                })
            )
            await clock.advance(TIMEOUT_MS)
            assert.deepEqual(
                { state: outcome.state, value: outcome.value, at: outcome.at },
                { state: "fulfilled", value, at }
            )
        })
    }
})

test("waitFor_falsyUntilDeadline_rejectsAtDeadlineWithoutProbingAfterIt", async (t) => {
    const clock = controlClock(t)
    const probedAt = []
    const outcome = track(
        waitFor(
            () => {
                probedAt.push(performance.now())
                return false
            },
            { timeoutMs: TIMEOUT_MS, intervalMs: INTERVAL_MS, what: WHAT }
        )
    )
    await clock.advance(TIMEOUT_MS + INTERVAL_MS)
    assert.deepEqual(
        {
            probedAt,
            state: outcome.state,
            at: outcome.at,
            timeout: outcome.error instanceof WaitTimeoutError,
            message: outcome.error?.message,
        },
        {
            probedAt: [0, INTERVAL_MS, 2 * INTERVAL_MS],
            state: "rejected",
            at: TIMEOUT_MS,
            timeout: true,
            message: TIMEOUT_MESSAGE,
        }
    )
})

test("boundedWait_predicateThrowsInTime_rejectsWithThatError", async (t) => {
    const thrown = new Error("the page went away")
    const failures = [
        {
            name: "synchronous throw",
            probe: () => {
                throw thrown
            },
            at: 0,
        },
        {
            name: "asynchronous rejection",
            probe: () => rejectAfter(10, thrown),
            at: 10,
        },
    ]
    for (const wait of WAITS) {
        for (const failure of failures) {
            await t.test(`${wait.name}, ${failure.name}`, async (t) => {
                const clock = controlClock(t)
                const outcome = track(wait.run(failure.probe))
                await clock.advance(INTERVAL_MS)
                assert.deepEqual(
                    {
                        state: outcome.state,
                        same: outcome.error === thrown,
                        at: outcome.at,
                    },
                    { state: "rejected", same: true, at: failure.at }
                )
            })
        }
    }
})

test("boundedWait_probeUnanswered_abortsSignalWithTheTimeout", async (t) => {
    for (const wait of WAITS) {
        await t.test(wait.name, async (t) => {
            const clock = controlClock(t)
            const held = heldProbe()
            const outcome = track(wait.run(held.probe))
            await clock.advance(wait.endsAt - 1)
            const abortedBefore = held.signal.aborted
            await clock.advance(1)
            assert.deepEqual(
                {
                    abortedBefore,
                    aborted: held.signal.aborted,
                    reasonIsTheTimeout:
                        outcome.error instanceof WaitTimeoutError &&
                        held.signal.reason === outcome.error,
                },
                {
                    abortedBefore: false,
                    aborted: true,
                    reasonIsTheTimeout: true,
                }
            )
        })
    }
})

test("boundedWait_abandonedProbeRejectsLater_raisesNoUnhandledRejection", async (t) => {
    for (const wait of WAITS) {
        await t.test(wait.name, async (t) => {
            const unhandled = []
            const listener = (reason) => unhandled.push(reason)
            process.on("unhandledRejection", listener)
            t.after(() => process.off("unhandledRejection", listener))
            const clock = controlClock(t)
            const held = heldProbe()
            const outcome = track(wait.run(held.probe))
            await clock.advance(wait.endsAt)
            held.reject(new Error("the browser closed"))
            await settle()
            await settle()
            assert.deepEqual(
                { state: outcome.state, unhandled },
                { state: "rejected", unhandled: [] }
            )
        })
    }
})

test("boundedWait_invalidDurationOrDeadline_rejectsWithRangeErrorBeforeProbing", async (t) => {
    const cases = [
        ["waitFor", "timeoutMs NaN", { timeoutMs: Number.NaN }],
        ["waitFor", "timeoutMs undefined", {}],
        ["waitFor", "timeoutMs 0", { timeoutMs: 0 }],
        ["waitFor", "timeoutMs Infinity", { timeoutMs: Infinity }],
        ["waitFor", "intervalMs 0", { timeoutMs: TIMEOUT_MS, intervalMs: 0 }],
        [
            "waitFor",
            "deadline NaN",
            { timeoutMs: TIMEOUT_MS, deadline: Number.NaN },
        ],
        [
            "waitFor",
            "deadline Infinity",
            { timeoutMs: TIMEOUT_MS, deadline: Infinity },
        ],
        ["waitFor", "deadline null", { timeoutMs: TIMEOUT_MS, deadline: null }],
        ["observeAbsence", "windowMs NaN", { windowMs: Number.NaN }],
        ["observeAbsence", "windowMs -1", { windowMs: -1 }],
        [
            "observeAbsence",
            "intervalMs NaN",
            { windowMs: WINDOW_MS, intervalMs: Number.NaN },
        ],
    ]
    const waits = { waitFor, observeAbsence }
    for (const [name, label, options] of cases) {
        await t.test(`${name}, ${label}`, async () => {
            let probes = 0
            const error = await waits[name](
                () => {
                    probes += 1
                    return true
                },
                { what: WHAT, ...options }
            ).then(
                () => null,
                (rejection) => rejection
            )
            assert.deepEqual(
                { name: error?.name, probes },
                { name: "RangeError", probes: 0 }
            )
        })
    }
})

test("observeAbsence_violationAnswered_rejectsWithIt", async (t) => {
    const cases = [
        { name: "first probe", probe: () => VIOLATION, at: 0 },
        {
            name: "a later probe",
            probe: () => (performance.now() >= 30 ? VIOLATION : null),
            at: 2 * INTERVAL_MS,
        },
        {
            name: "the closing probe",
            probe: () => (performance.now() >= WINDOW_MS ? VIOLATION : null),
            at: WINDOW_MS,
        },
        {
            name: "an asynchronous answer",
            probe: () => resolveAfter(10, VIOLATION),
            at: 10,
        },
    ]
    for (const { name, probe, at } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const outcome = track(
                observeAbsence(probe, {
                    windowMs: WINDOW_MS,
                    intervalMs: INTERVAL_MS,
                })
            )
            await clock.advance(WINDOW_MS + INTERVAL_MS)
            assert.deepEqual(
                {
                    state: outcome.state,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                    at: outcome.at,
                },
                { state: "rejected", timeout: false, message: VIOLATION, at }
            )
        })
    }
})

test("observeAbsence_probeStalls_rejectsWithWaitTimeoutError", async (t) => {
    const never = () => new Promise(() => {})
    const cases = [
        { name: "first probe", probe: never },
        {
            name: "a mid-window probe",
            probe: () => (performance.now() >= 40 ? never() : null),
        },
        {
            name: "the closing probe",
            probe: () => (performance.now() >= WINDOW_MS ? never() : null),
        },
    ]
    for (const { name, probe } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const outcome = track(
                observeAbsence(probe, {
                    windowMs: WINDOW_MS,
                    intervalMs: INTERVAL_MS,
                })
            )
            await clock.advance(WINDOW_MS + 2 * INTERVAL_MS)
            assert.deepEqual(
                {
                    state: outcome.state,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                    at: outcome.at,
                },
                {
                    state: "rejected",
                    timeout: true,
                    message: ABSENCE_MESSAGE,
                    at: WINDOW_MS + INTERVAL_MS,
                }
            )
        })
    }
})

test("observeAbsence_answerAfterDeadline_reportsViolationElseTimesOut", async (t) => {
    const lateError = new Error("the probe failed late")
    const cases = [
        {
            name: "clean answer",
            answer: (held) => held.resolve(null),
            expected: {
                timeout: true,
                message: ABSENCE_MESSAGE,
                cause: undefined,
            },
        },
        {
            name: "violation",
            answer: (held) => held.resolve(VIOLATION),
            expected: { timeout: false, message: VIOLATION, cause: undefined },
        },
        {
            name: "rejection",
            answer: (held) => held.reject(lateError),
            expected: {
                timeout: true,
                message: ABSENCE_MESSAGE,
                cause: lateError,
            },
        },
    ]
    for (const { name, answer, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const held = heldProbe()
            const outcome = track(
                observeAbsence(held.probe, {
                    windowMs: WINDOW_MS,
                    intervalMs: INTERVAL_MS,
                })
            )
            clock.lag(WINDOW_MS + 2 * INTERVAL_MS)
            answer(held)
            await settle()
            assert.deepEqual(
                {
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                    cause: outcome.error?.cause,
                },
                expected
            )
        })
    }
})

test("observeAbsence_cleanWindow_resolvesAfterAProbeFromTheWindowEnd", async (t) => {
    const cases = [
        { name: "synchronous probe", answerMs: 0, at: WINDOW_MS },
        { name: "asynchronous probe", answerMs: 5, at: WINDOW_MS + 5 },
        // The probe started at 90 answers at the window end, so one more
        // probe has to close the window.
        { name: "probe straddling the end", answerMs: 10, at: WINDOW_MS + 10 },
    ]
    for (const { name, answerMs, at } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const probedAt = []
            const outcome = track(
                observeAbsence(
                    () => {
                        probedAt.push(performance.now())
                        return answerMs === 0
                            ? null
                            : resolveAfter(answerMs, null)
                    },
                    { windowMs: WINDOW_MS, intervalMs: INTERVAL_MS }
                )
            )
            await clock.advance(at - 1)
            const before = outcome.state
            await clock.advance(1)
            assert.deepEqual(
                {
                    before,
                    state: outcome.state,
                    at: outcome.at,
                    lastProbeAt: probedAt.at(-1),
                },
                {
                    before: "pending",
                    state: "fulfilled",
                    at,
                    lastProbeAt: WINDOW_MS,
                }
            )
        })
    }
})

test("boundedWait_budgetBeyondTimerLimit_endsOnlyAtItsEnd", async (t) => {
    const cases = [
        {
            name: "waitFor, probe never answers",
            run: () =>
                waitFor(() => new Promise(() => {}), {
                    timeoutMs: LONG_BUDGET_MS,
                    intervalMs: INTERVAL_MS,
                    what: WHAT,
                }),
            expected: {
                state: "rejected",
                message: `timed out after ${LONG_BUDGET_MS} ms waiting for ${WHAT}; its last probe did not answer in time`,
                probedAt: [],
            },
        },
        {
            name: "waitFor, falsy probe polled once per budget",
            run: (probedAt) =>
                waitFor(
                    () => {
                        probedAt.push(performance.now())
                        return false
                    },
                    {
                        timeoutMs: LONG_BUDGET_MS,
                        intervalMs: LONG_BUDGET_MS,
                        what: WHAT,
                    }
                ),
            expected: {
                state: "rejected",
                message: `timed out after ${LONG_BUDGET_MS} ms waiting for ${WHAT}`,
                probedAt: [0],
            },
        },
        {
            name: "observeAbsence, clean probe polled once per window",
            run: (probedAt) =>
                observeAbsence(
                    () => {
                        probedAt.push(performance.now())
                        return null
                    },
                    { windowMs: LONG_BUDGET_MS, intervalMs: LONG_BUDGET_MS }
                ),
            expected: {
                state: "fulfilled",
                message: undefined,
                probedAt: [0, LONG_BUDGET_MS],
            },
        },
    ]
    for (const { name, run, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const probedAt = []
            const outcome = track(run(probedAt))
            await clock.leap(LONG_BUDGET_MS - 1)
            const before = outcome.state
            await clock.leap(1)
            assert.deepEqual(
                {
                    before,
                    state: outcome.state,
                    at: outcome.at,
                    message: outcome.error?.message,
                    probedAt,
                },
                { before: "pending", at: LONG_BUDGET_MS, ...expected }
            )
        })
    }
})

test("boundedWait_budgetBeyondTimerLimit_emitsNoTimeoutOverflowWarning", async (t) => {
    const cases = [
        {
            name: "waitFor",
            run: (probe) =>
                waitFor(probe, {
                    timeoutMs: LONG_BUDGET_MS,
                    intervalMs: INTERVAL_MS,
                    what: WHAT,
                }),
            answer: "ready",
            expected: {
                state: "fulfilled",
                value: "ready",
                message: undefined,
            },
        },
        {
            name: "observeAbsence",
            run: (probe) =>
                observeAbsence(probe, {
                    windowMs: LONG_BUDGET_MS,
                    intervalMs: INTERVAL_MS,
                }),
            answer: VIOLATION,
            expected: {
                state: "rejected",
                value: undefined,
                message: VIOLATION,
            },
        },
    ]
    for (const { name, run, answer, expected } of cases) {
        await t.test(name, async (t) => {
            // Real timers, which warn on an overflowing delay; the clock only
            // moves when the test moves it.
            let now = 0
            t.mock.method(performance, "now", () => now)
            const overflows = []
            const listener = (warning) => {
                if (warning.name === "TimeoutOverflowWarning") {
                    overflows.push(warning.message)
                }
            }
            process.on("warning", listener)
            t.after(() => process.off("warning", listener))
            const held = heldProbe()
            const outcome = track(run(held.probe))
            await settle()
            now = LONG_BUDGET_MS - 1
            held.resolve(answer)
            await settle()
            assert.deepEqual(
                {
                    overflows,
                    state: outcome.state,
                    value: outcome.value,
                    message: outcome.error?.message,
                },
                { overflows: [], ...expected }
            )
        })
    }
})

/** A page stand-in that counts its closes; `close` is the case's own. */
function closablePage(close) {
    const page = { closes: 0 }
    page.close = () => {
        page.closes += 1
        return close()
    }
    return page
}

/** Collects the unhandled rejections raised while `t` runs. */
function watchUnhandled(t) {
    const unhandled = []
    const listener = (reason) => unhandled.push(reason)
    process.on("unhandledRejection", listener)
    t.after(() => process.off("unhandledRejection", listener))
    return unhandled
}

test("probePage_probePendingAtTimeout_closesPageOnce", async (t) => {
    const cases = [
        { name: "close resolves", close: async () => {}, logged: 0 },
        {
            name: "close rejects",
            close: () => Promise.reject(new Error("Target closed")),
            logged: 1,
        },
        {
            name: "close throws",
            close: () => {
                throw new Error("Session closed")
            },
            logged: 1,
        },
    ]
    for (const { name, close, logged } of cases) {
        await t.test(name, async (t) => {
            const unhandled = watchUnhandled(t)
            const log = t.mock.method(console, "error", () => {})
            const clock = controlClock(t)
            const page = closablePage(close)
            const held = heldProbe()
            const outcome = track(
                waitFor(
                    (signal) => probePage(page, signal, () => held.probe()),
                    {
                        timeoutMs: TIMEOUT_MS,
                        intervalMs: INTERVAL_MS,
                        what: WHAT,
                    }
                )
            )
            await clock.advance(TIMEOUT_MS - 1)
            const closesBefore = page.closes
            await clock.advance(1)
            // Closing the page ends the pending call, as Puppeteer does.
            held.reject(new Error("Target closed"))
            await settle()
            await settle()
            assert.deepEqual(
                {
                    closesBefore,
                    closes: page.closes,
                    state: outcome.state,
                    at: outcome.at,
                    message: outcome.error?.message,
                    logged: log.mock.callCount(),
                    unhandled,
                },
                {
                    closesBefore: 0,
                    closes: 1,
                    state: "rejected",
                    at: TIMEOUT_MS,
                    message: UNANSWERED_MESSAGE,
                    logged,
                    unhandled: [],
                }
            )
        })
    }
})

test("probePage_noProbePendingAtAbort_leavesPageOpen", async (t) => {
    const failure = new Error("the selector is invalid")
    const cases = [
        {
            name: "probe answered, then the signal aborts",
            run: async (page) => {
                const controller = new AbortController()
                const value = await probePage(
                    page,
                    controller.signal,
                    async () => "ready"
                )
                controller.abort(new Error("later timeout"))
                return value
            },
            expected: { state: "fulfilled", value: "ready", error: undefined },
        },
        {
            name: "probe rejected, then the signal aborts",
            run: async (page) => {
                const controller = new AbortController()
                try {
                    return await probePage(page, controller.signal, () =>
                        Promise.reject(failure)
                    )
                } finally {
                    controller.abort(new Error("later timeout"))
                }
            },
            expected: { state: "rejected", value: undefined, error: failure },
        },
        {
            name: "wait times out after falsy answers",
            run: async (page, clock) => {
                const wait = waitFor(
                    (signal) => probePage(page, signal, async () => false),
                    {
                        timeoutMs: TIMEOUT_MS,
                        intervalMs: INTERVAL_MS,
                        what: WHAT,
                    }
                )
                // Its rejection is awaited below, once the clock ran it out.
                wait.catch(() => {})
                await clock.advance(TIMEOUT_MS)
                return wait
            },
            expected: {
                state: "rejected",
                value: undefined,
                error: { message: TIMEOUT_MESSAGE },
            },
        },
        {
            name: "wait times out on an answer after the deadline",
            run: (page, clock) => {
                const held = heldProbe()
                const wait = waitFor(
                    (signal) => probePage(page, signal, () => held.probe()),
                    {
                        timeoutMs: TIMEOUT_MS,
                        intervalMs: INTERVAL_MS,
                        what: WHAT,
                    }
                )
                clock.lag(TIMEOUT_MS + 10)
                held.resolve(true)
                return wait
            },
            expected: {
                state: "rejected",
                value: undefined,
                error: { message: UNANSWERED_MESSAGE },
            },
        },
    ]
    for (const { name, run, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const page = closablePage(async () => {})
            const outcome = await run(page, clock).then(
                (value) => ({ state: "fulfilled", value, error: undefined }),
                (error) => ({ state: "rejected", value: undefined, error })
            )
            await settle()
            assert.deepEqual(
                {
                    closes: page.closes,
                    state: outcome.state,
                    value: outcome.value,
                    error:
                        outcome.error === failure || outcome.error === undefined
                            ? outcome.error
                            : { message: outcome.error.message },
                },
                { closes: 0, ...expected }
            )
        })
    }
})

test("probePage_signalAlreadyAborted_throwsReasonBeforeAnyCall", async () => {
    const reason = new Error("timed out")
    const controller = new AbortController()
    controller.abort(reason)
    const page = closablePage(async () => {})
    let probes = 0

    const error = await probePage(page, controller.signal, async () => {
        probes += 1
        return true
    }).then(
        () => null,
        (rejection) => rejection
    )

    assert.deepEqual(
        { same: error === reason, probes, closes: page.closes },
        { same: true, probes: 0, closes: 0 }
    )
})

const ALERT_ID = "0b5c9f2e-6a1d-4c3b-9e8f-7a6b5c4d3e2f"
/** The page check's deadline for an alert row and a notification item. */
const ROW_TIMEOUT_MS = 20_000

/**
 * The page on /insights, whose `stalledRead` never answers until the page
 * is closed, as with a hung renderer; closing rejects it as Puppeteer does.
 * Every other read is the check's presence test of #portfolio-insights.
 */
function stallingPage(stalledRead) {
    const page = { closes: 0, clicks: 0, pending: [] }
    page.bringToFront = async () => {}
    page.url = () => "http://127.0.0.1/insights"
    page.click = async () => {
        page.clicks += 1
    }
    page.evaluate = (fn, arg) =>
        fn.name === stalledRead
            ? new Promise((_, reject) => page.pending.push(reject))
            : Promise.resolve(arg === "#portfolio-insights")
    page.close = async () => {
        page.closes += 1
        for (const reject of page.pending.splice(0)) {
            reject(new Error("Target closed"))
        }
    }
    return page
}

test("pageWait_readStallsPastDeadline_closesPageOnceAndTimesOut", async (t) => {
    const cases = [
        {
            name: "clickWhenClear",
            stalledRead: "isClickable",
            budgetMs: TIMEOUT_MS,
            run: (page) => clickWhenClear(page, "#alert-toggle", TIMEOUT_MS),
            expected: {
                state: "rejected",
                value: undefined,
                message: `timed out after ${TIMEOUT_MS} ms waiting for #alert-toggle to be enabled and uncovered; its last probe did not answer in time`,
            },
        },
        {
            name: "waitForToggle",
            stalledRead: "readRowToggle",
            budgetMs: ROW_TIMEOUT_MS,
            run: (page) => waitForToggle(page, ALERT_ID, "Enable"),
            expected: {
                state: "rejected",
                value: undefined,
                message: `timed out after ${ROW_TIMEOUT_MS} ms waiting for the Enable toggle of alert ${ALERT_ID}; its last probe did not answer in time`,
            },
        },
        {
            name: "checkAcknowledge",
            stalledRead: "readNotificationIds",
            budgetMs: ROW_TIMEOUT_MS,
            run: async (page) => {
                const problems = []
                await checkAcknowledge(problems, {}, {}, { page }, [
                    { id: ALERT_ID },
                ])
                return problems
            },
            expected: {
                state: "fulfilled",
                value: [
                    `timed out after ${ROW_TIMEOUT_MS} ms waiting for a fixture alert in #alert-notifications; its last probe did not answer in time`,
                    "#alert-notifications lists no notification",
                ],
                message: undefined,
            },
        },
    ]
    for (const { name, stalledRead, budgetMs, run, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const page = stallingPage(stalledRead)
            const outcome = track(run(page))
            await clock.leap(budgetMs - 1)
            const closesBefore = page.closes
            await clock.leap(1)
            await settle()
            assert.deepEqual(
                {
                    closesBefore,
                    closes: page.closes,
                    clicks: page.clicks,
                    at: outcome.at,
                    state: outcome.state,
                    value: outcome.value,
                    message: outcome.error?.message,
                },
                {
                    closesBefore: 0,
                    closes: 1,
                    clicks: 0,
                    at: budgetMs,
                    ...expected,
                }
            )
        })
    }
})

test("checkAcknowledge_itemRemovalReadStalls_closesPageAndReportsTimeout", async (t) => {
    // The page check's poll interval and its deadline for the first
    // notification poll after the acknowledge click.
    const pollMs = 250
    const nextPollTimeoutMs = 25_000
    const clock = controlClock(t)
    const removal = `li.alert-notification[data-notification-id="${ALERT_ID}" i]`
    const holder = {
        label: "holder",
        account: { accountId: "6f1d3c2a-8b4e-4d5f-9a7c-1e2b3c4d5e6f" },
        responses: [],
        toasts: [],
        pendingBodies: new Set(),
    }
    const page = stallingPage("readNotificationIds")
    // The fixture alert is listed and clickable; the acknowledge answers
    // 204, but the read of whether the item left never answers.
    page.evaluate = (fn, arg) => {
        if (fn.name === "readNotificationIds") {
            return Promise.resolve([ALERT_ID])
        }
        if (fn.name === "isClickable") {
            return Promise.resolve(true)
        }
        return arg === removal
            ? new Promise((_, reject) => page.pending.push(reject))
            : Promise.resolve(arg === "#portfolio-insights")
    }
    page.click = async () => {
        page.clicks += 1
        holder.responses.push({
            kind: "acknowledge",
            alertId: ALERT_ID,
            seq: Number.MAX_SAFE_INTEGER,
            status: 204,
        })
    }
    holder.page = page
    const problems = []
    const details = {}

    const outcome = track(
        checkAcknowledge(problems, details, {}, holder, [
            { id: ALERT_ID, armingRevision: 1 },
        ])
    )
    await clock.leap(ROW_TIMEOUT_MS - 1, pollMs)
    const closesBefore = page.closes
    await clock.leap(1)
    await clock.leap(nextPollTimeoutMs, pollMs)

    assert.deepEqual(
        {
            closesBefore,
            closes: page.closes,
            clicks: page.clicks,
            state: outcome.state,
            acknowledgeStatus: details.acknowledgeStatus,
            problems,
        },
        {
            closesBefore: 0,
            closes: 1,
            clicks: 1,
            state: "fulfilled",
            acknowledgeStatus: 204,
            problems: [
                `timed out after ${ROW_TIMEOUT_MS} ms waiting for alert ${ALERT_ID} to leave #alert-notifications; its last probe did not answer in time`,
                `timed out after ${nextPollTimeoutMs} ms waiting for the next notification response after the acknowledge`,
            ],
        }
    )
})

/** A notification read the test answers itself, through `page.answer`. */
const HELD_LISTING = Symbol("held listing")

test("checkAcknowledge_listingAnswersAfterDeadline_reportsOnlyListingsReadInTime", async (t) => {
    // The page check's poll interval between two reads.
    const pollMs = 250
    const otherId = "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f"
    const lateId = "9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b"
    const timeout = `timed out after ${ROW_TIMEOUT_MS} ms waiting for a fixture alert in #alert-notifications; its last probe did not answer in time`
    const cases = [
        {
            name: "fixture alert listed after the deadline",
            reads: [HELD_LISTING],
            run: async (clock, page) => {
                clock.lag(ROW_TIMEOUT_MS + 1)
                page.answer([ALERT_ID])
            },
            expected: {
                problems: [
                    timeout,
                    "#alert-notifications lists no notification",
                ],
                details: { listed: [], listedWithoutUuid: 0 },
            },
        },
        {
            name: "other alert listed in time, another after the deadline",
            reads: [[otherId], HELD_LISTING],
            run: async (clock, page) => {
                await clock.advance(pollMs)
                clock.lag(ROW_TIMEOUT_MS)
                page.answer([lateId])
            },
            expected: {
                problems: [
                    timeout,
                    `#alert-notifications lists only non-fixture alerts: ${otherId}`,
                ],
                details: { listed: [otherId], listedWithoutUuid: 0 },
            },
        },
    ]
    for (const { name, reads, run, expected } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const page = stallingPage("readNotificationIds")
            const script = [...reads]
            page.evaluate = (fn, arg) => {
                if (fn.name !== "readNotificationIds") {
                    return Promise.resolve(arg === "#portfolio-insights")
                }
                const read = script.shift()
                return read === HELD_LISTING
                    ? new Promise((resolve) => {
                          page.answer = resolve
                      })
                    : Promise.resolve(read)
            }
            const problems = []
            const details = {}

            const outcome = track(
                checkAcknowledge(problems, details, {}, { page }, [
                    { id: ALERT_ID, armingRevision: 1 },
                ])
            )
            await settle()
            await run(clock, page)
            await settle()

            assert.deepEqual(
                {
                    state: outcome.state,
                    clicks: page.clicks,
                    problems,
                    details,
                },
                { state: "fulfilled", clicks: 0, ...expected }
            )
        })
    }
})

test("waitFor_deadlineGiven_endsAtItInsteadOfTimeoutMsFromNow", async (t) => {
    const cases = [
        // The window of WINDOW_MS opened 40 ms before the call.
        { name: "window opened earlier", deadline: 60, probedAt: [0, 20, 40] },
        { name: "deadline at the call", deadline: 0, probedAt: [] },
        { name: "deadline already past", deadline: -5, probedAt: [] },
    ]
    for (const { name, deadline, probedAt } of cases) {
        await t.test(name, async (t) => {
            const clock = controlClock(t)
            const probes = []
            const outcome = track(
                waitFor(
                    () => {
                        probes.push(performance.now())
                        return false
                    },
                    {
                        timeoutMs: WINDOW_MS,
                        deadline,
                        intervalMs: INTERVAL_MS,
                        what: WHAT,
                    }
                )
            )
            await clock.advance(WINDOW_MS + INTERVAL_MS)
            assert.deepEqual(
                {
                    probes,
                    state: outcome.state,
                    at: outcome.at,
                    timeout: outcome.error instanceof WaitTimeoutError,
                    message: outcome.error?.message,
                },
                {
                    probes: probedAt,
                    state: "rejected",
                    at: Math.max(deadline, 0),
                    timeout: true,
                    message: `timed out after ${WINDOW_MS} ms waiting for ${WHAT}`,
                }
            )
        })
    }
})

const FLAG_ID = "portfolio-insights-enabled"
const FLAG_PATH = `/feature-flag-service/v1/flags/${FLAG_ID}`
const SHUTDOWN_STATE = {
    path: "/home",
    insightsLink: false,
    alertsPanel: false,
}
/** The test clock's time when checkLiveShutdown starts the flag PUT. */
const PUT_STARTS_AT = 1000
const SHUTDOWN_TIMEOUT = `timed out after 30000 ms waiting for /home without #nav-portfolio-insights and #alerts-panel within 30000 ms of the flag PUT`

/**
 * A flag service on a free loopback port whose PUT moves `clock` on by
 * `putMs` before it answers `enabled: false`, and from then on makes each
 * clock read move it on by `perReadMs`; closed after `t`.
 */
async function slowFlagService(t, clock, putMs, perReadMs) {
    const requests = []
    const server = createServer((request, response) => {
        let body = ""
        request.setEncoding("utf8")
        request.on("data", (chunk) => {
            body += chunk
        })
        request.on("end", () => {
            requests.push(`${request.method} ${request.url} ${body}`)
            clock.now += putMs
            clock.perReadMs = perReadMs
            response.writeHead(200, { "Content-Type": "application/json" })
            response.end(JSON.stringify({ id: FLAG_ID, enabled: false }))
        })
    })
    await new Promise((resolve, reject) => {
        server.once("error", reject)
        server.listen(0, "127.0.0.1", resolve)
    })
    t.after(
        () =>
            new Promise((resolve) => {
                server.closeAllConnections()
                server.close(() => resolve())
            })
    )
    return { baseUrl: `http://127.0.0.1:${server.address().port}`, requests }
}

/**
 * The holder's page on /insights. Each read of the shutdown state answers
 * `observedAfterMs` after the PUT started, by `clock`, and finds the
 * shutdown done, unless it `stalls`: then it moves the clock there and never
 * answers until the page is closed, which rejects it as Puppeteer does. A
 * notification request planted after any sequence number ends the quiet
 * window at once.
 */
function shutdownHolder(clock, observedAfterMs, stalls) {
    const holder = {
        shutdownProbes: 0,
        notificationRequests: [{ seq: Number.MAX_SAFE_INTEGER, at: 0 }],
        toasts: [],
    }
    let rejectStalled = null
    holder.page = {
        closes: 0,
        bringToFront: async () => {},
        url: () => "http://127.0.0.1/insights",
        close: async () => {
            holder.page.closes += 1
            rejectStalled?.(new Error("Target closed"))
        },
        evaluate: async (_, selector) => {
            if (selector !== undefined) {
                return selector === "#portfolio-insights"
            }
            holder.shutdownProbes += 1
            clock.now = Math.max(clock.now, PUT_STARTS_AT + observedAfterMs)
            if (stalls) {
                return new Promise((_, reject) => {
                    rejectStalled = reject
                })
            }
            return SHUTDOWN_STATE
        },
    }
    return holder
}

test("checkLiveShutdown_slowFlagPut_countsPutTimeAgainstWindow", async (t) => {
    // The wait passes; the planted request then ends the quiet window.
    const quietWindowEnded = {
        name: "Error",
        message:
            /^a notification request was sent -?\d+ ms after the shutdown$/,
    }
    const cases = [
        // The deadline has passed when the PUT answers: no read starts.
        {
            name: "PUT takes the whole window",
            putMs: 30_000,
            observedAfterMs: 30_000,
            error: {
                name: "WaitTimeoutError",
                message: `${SHUTDOWN_TIMEOUT}; the flag PUT took 30000 ms and no read of the page answered`,
            },
            shutdownProbes: 0,
            shutdownAfterMs: undefined,
        },
        {
            name: "shutdown seen 1 ms after the window",
            putMs: 10_000,
            observedAfterMs: 30_001,
            error: {
                name: "WaitTimeoutError",
                message: `${SHUTDOWN_TIMEOUT}; its last probe did not answer in time; the flag PUT took 10000 ms, and the page shows ${JSON.stringify(SHUTDOWN_STATE)}`,
            },
            shutdownProbes: 1,
            shutdownAfterMs: undefined,
        },
        // The read is still pending at the deadline: the page is closed.
        {
            name: "read stalls past the window",
            putMs: 10_000,
            observedAfterMs: 30_001,
            stalls: true,
            error: {
                name: "WaitTimeoutError",
                message: `${SHUTDOWN_TIMEOUT}; its last probe did not answer in time; the flag PUT took 10000 ms and no read of the page answered`,
            },
            shutdownProbes: 1,
            shutdownAfterMs: undefined,
            closes: 1,
        },
        // Time passes between the PUT and the first read, as on a busy host;
        // the deadline still counts from the PUT's start.
        {
            name: "shutdown seen 1 ms after the window, clock moving at each read",
            putMs: 10_000,
            perReadMs: 1,
            observedAfterMs: 30_001,
            error: {
                name: "WaitTimeoutError",
                message:
                    /^timed out after 30000 ms waiting for \/home without #nav-portfolio-insights and #alerts-panel within 30000 ms of the flag PUT; its last probe did not answer in time; the flag PUT took \d+ ms, and the page shows /,
            },
            shutdownProbes: 1,
            shutdownAfterMs: undefined,
        },
        {
            name: "shutdown seen at the window end",
            putMs: 10_000,
            observedAfterMs: 30_000,
            error: quietWindowEnded,
            shutdownProbes: 1,
            shutdownAfterMs: 30_000,
        },
        {
            name: "shutdown seen 1 ms before the window ends",
            putMs: 10_000,
            observedAfterMs: 29_999,
            error: quietWindowEnded,
            shutdownProbes: 1,
            shutdownAfterMs: 29_999,
        },
    ]
    for (const {
        name,
        putMs,
        perReadMs = 0,
        observedAfterMs,
        stalls = false,
        closes = 0,
        error,
        ...expected
    } of cases) {
        await t.test(name, async (t) => {
            const clock = { now: PUT_STARTS_AT, perReadMs: 0 }
            t.mock.method(performance, "now", () => {
                const now = clock.now
                clock.now += clock.perReadMs
                return now
            })
            const { baseUrl, requests } = await slowFlagService(
                t,
                clock,
                putMs,
                perReadMs
            )
            const holder = shutdownHolder(clock, observedAfterMs, stalls)
            const details = {}

            await assert.rejects(
                checkLiveShutdown([], details, {
                    report: {},
                    holder,
                    baseUrl,
                    evidenceDir: "",
                }),
                error
            )
            assert.deepEqual(
                {
                    requests,
                    flagOff: details.flagOff,
                    shutdownProbes: holder.shutdownProbes,
                    shutdownAfterMs: details.shutdownAfterMs,
                    closes: holder.page.closes,
                },
                {
                    requests: [`PUT ${FLAG_PATH} {"enabled":false}`],
                    flagOff: { id: FLAG_ID, enabled: false },
                    ...expected,
                    closes,
                }
            )
        })
    }
})
