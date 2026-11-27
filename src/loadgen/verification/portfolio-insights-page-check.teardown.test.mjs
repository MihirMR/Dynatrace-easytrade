// Unit tests of the bounded browser teardown of
// portfolio-insights-page-check.mjs: `teardownBrowser`, which closes the
// browser the run launched and escalates for that browser's own process
// only, and `killBrowserProcess`, which kills that process as Puppeteer does.
//
// Time is controlled, never slept: `performance.now()` reads a test clock and
// `setTimeout` runs on node:test's mock timers, which `advance` moves
// together one millisecond at a time. The browser, its process and the kill
// are stand-ins the test settles, so no Chrome runs and no process is
// signalled.
//
// Run from src/loadgen, with the other verification suites, as
//
//     node --test "verification/**/*.test.mjs"
import assert from "node:assert/strict"
import { EventEmitter } from "node:events"
import { test } from "node:test"

import {
    killBrowserProcess,
    teardownBrowser,
} from "./portfolio-insights-page-check.mjs"

const CLOSE_TIMEOUT_MS = 50
const KILL_TIMEOUT_MS = 30
const PID = 4242
const LATE_CLOSE = "the browser did not close within 50 ms"
const FAILED_CLOSE = "the browser close failed before its 50 ms deadline"
const KILLED = "its process was killed and exited within 30 ms"
const NOT_EXITED = "its process was not seen to exit within 30 ms of the kill"

/** Lets every promise continuation that is already due run. */
function settle() {
    return new Promise((resolve) => setImmediate(resolve))
}

/**
 * Puts `performance.now()` and `setTimeout` under the test's control.
 *
 * The first `t.mock.timers.enable` of a process can queue Node's one-time
 * ExperimentalWarning for the MockTimers API: Node 22 does, Node 24 does not.
 * Node emits a warning from a `process.nextTick` callback and prints it
 * through `console.error`, so the clock is handed over only after a tick
 * queued behind it. The warning has then reached the real stderr, and a
 * console captured afterwards holds only what the code under test prints.
 */
async function controlClock(t) {
    let now = 0
    t.mock.method(performance, "now", () => now)
    t.mock.timers.enable({ apis: ["setTimeout"] })
    await new Promise((resolve) => process.nextTick(resolve))
    return {
        async advance(ms) {
            await settle()
            for (let step = 0; step < ms; step += 1) {
                now += 1
                t.mock.timers.tick(1)
                await settle()
            }
        },
    }
}

/** Records how `promise` settles, and when by the test clock. */
function track(promise) {
    const outcome = { state: "pending", value: undefined, at: undefined }
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
                value: error,
                at: performance.now(),
            })
    )
    return outcome
}

/** Captures what the code under test prints, one entry per call. */
function captureConsole(t) {
    const log = t.mock.method(console, "log", () => undefined)
    const error = t.mock.method(console, "error", () => undefined)
    const lines = (mocked) =>
        mocked.mock.calls.map((call) => call.arguments.join(" "))
    return { stdout: () => lines(log), stderr: () => lines(error) }
}

/** A pipe of the browser process that records being destroyed. */
function fakeStream() {
    return {
        destroyed: false,
        destroy() {
            this.destroyed = true
        },
    }
}

/** A stand-in for the ChildProcess Puppeteer starts Chrome as. */
class FakeProcess extends EventEmitter {
    constructor({ exited = false, killResult = true } = {}) {
        super()
        this.pid = PID
        this.exitCode = exited ? 0 : null
        this.signalCode = null
        this.killResult = killResult
        this.kills = []
        this.unrefs = 0
        // A real `stdio` holds `null` for a stream that is not a pipe.
        this.stdio = [fakeStream(), fakeStream(), fakeStream(), null]
    }

    kill(signal) {
        this.kills.push(signal)
        return this.killResult
    }

    unref() {
        this.unrefs += 1
    }

    /** Ends the process, as a kill does. */
    end() {
        this.signalCode = "SIGKILL"
        this.emit("exit", null, "SIGKILL")
    }
}

/** A stand-in for Puppeteer's Browser whose close the test supplies. */
function fakeBrowser({ close, child, disconnect = () => Promise.resolve() }) {
    const browser = {
        closes: 0,
        disconnects: 0,
        close() {
            browser.closes += 1
            return close()
        },
        process: () => child,
        disconnect() {
            browser.disconnects += 1
            return disconnect()
        },
    }
    return browser
}

/** A kill seam that records each call and then behaves as `act` says. */
function fakeKill(act) {
    const calls = []
    return {
        calls,
        run: (child, signal) => {
            calls.push({ child, signal })
            return act(child)
        },
    }
}

/** A close that answers only when the test settles it through `held`. */
function heldClose() {
    const held = {}
    held.close = () =>
        new Promise((resolve, reject) => {
            held.resolve = resolve
            held.reject = reject
        })
    return held
}

/**
 * Runs `teardownBrowser` on a stand-in browser for longer than both
 * deadlines, then rejects a close still pending, as Puppeteer does once its
 * connection is dropped, and summarises what the teardown did.
 */
async function runTeardown(t, { close, child, kill, disconnect }) {
    const unhandled = []
    const listener = (reason) => unhandled.push(reason)
    process.on("unhandledRejection", listener)
    t.after(() => process.off("unhandledRejection", listener))
    const clock = await controlClock(t)
    const output = captureConsole(t)
    const held = heldClose()
    const browser = fakeBrowser({
        close: close ?? held.close,
        child,
        disconnect,
    })
    const report = { checks: [] }
    const outcome = track(
        teardownBrowser(report, browser, {
            kill: kill.run,
            closeTimeoutMs: CLOSE_TIMEOUT_MS,
            killTimeoutMs: KILL_TIMEOUT_MS,
        })
    )
    await clock.advance(CLOSE_TIMEOUT_MS + KILL_TIMEOUT_MS + 10)
    held.reject?.(new Error("Connection closed."))
    await settle()
    await settle()
    return {
        state: outcome.state,
        answer: outcome.value,
        at: outcome.at,
        checks: report.checks.map(({ name, status, reason, details }) => ({
            name,
            status,
            reason,
            details,
        })),
        stdout: output.stdout(),
        stderr: output.stderr(),
        kills: kill.calls.map((call) => ({
            owned: call.child === child,
            aborted: call.signal.aborted,
        })),
        disconnects: browser.disconnects,
        unrefs: child?.unrefs ?? 0,
        destroyedPipes:
            child?.stdio.filter((stream) => stream?.destroyed).length ?? 0,
        unhandled,
    }
}

/** The summary of a teardown that recorded `reason` as its FAIL. */
function failedTeardown({ at, reason, process, kills, released, stderr }) {
    return {
        state: "fulfilled",
        answer: false,
        at,
        checks: [
            {
                name: "teardown",
                status: "FAIL",
                reason,
                details: {
                    closeTimeoutMs: CLOSE_TIMEOUT_MS,
                    killTimeoutMs: KILL_TIMEOUT_MS,
                    process,
                },
            },
        ],
        stdout: [`FAIL teardown: ${reason}`],
        stderr,
        kills,
        disconnects: released ? 1 : 0,
        unrefs: released && process !== "none" ? 1 : 0,
        destroyedPipes: released && process !== "none" ? 3 : 0,
        unhandled: [],
    }
}

test("teardownBrowser_noBrowserLaunched_recordsNothing", async (t) => {
    const output = captureConsole(t)
    const neverKill = fakeKill(() => {
        throw new Error("no kill was expected")
    })
    const report = { checks: [] }
    const answer = await teardownBrowser(report, null, { kill: neverKill.run })
    assert.deepEqual(
        {
            answer,
            checks: report.checks,
            stdout: output.stdout(),
            kills: neverKill.calls.length,
        },
        { answer: true, checks: [], stdout: [], kills: 0 }
    )
})

test("teardownBrowser_closesInTime_recordsNothingAndKillsNothing", async (t) => {
    const child = new FakeProcess()
    const kill = fakeKill(() => {
        throw new Error("no kill was expected")
    })
    const summary = await runTeardown(t, {
        close: () => new Promise((resolve) => setTimeout(resolve, 10)),
        child,
        kill,
    })
    assert.deepEqual(summary, {
        state: "fulfilled",
        answer: true,
        at: 10,
        checks: [],
        stdout: [],
        stderr: [],
        kills: [],
        disconnects: 0,
        unrefs: 0,
        destroyedPipes: 0,
        unhandled: [],
    })
})

test("teardownBrowser_closeDoesNotFinish_escalatesForTheOwnedProcessOnly", async (t) => {
    const owned = [{ owned: true, aborted: false }]
    const cases = [
        {
            name: "close never settles, the killed process exits",
            child: () => new FakeProcess(),
            kill: (child) => child.end(),
            expected: {
                at: CLOSE_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; ${KILLED}`,
                process: "killed",
                kills: owned,
                released: false,
                stderr: [],
            },
        },
        {
            name: "close rejects, the killed process exits",
            close: () => Promise.reject(new Error("Protocol error")),
            child: () => new FakeProcess(),
            kill: (child) => child.end(),
            expected: {
                at: 0,
                reason: `${FAILED_CLOSE}; ${KILLED}`,
                process: "killed",
                kills: owned,
                released: false,
                stderr: ["Error: Protocol error"],
            },
        },
        {
            name: "close throws at once, the killed process exits",
            close: () => {
                throw new TypeError("not connected")
            },
            child: () => new FakeProcess(),
            kill: (child) => child.end(),
            expected: {
                at: 0,
                reason: `${FAILED_CLOSE}; ${KILLED}`,
                process: "killed",
                kills: owned,
                released: false,
                stderr: ["TypeError: not connected"],
            },
        },
        {
            name: "the process had already exited",
            child: () => new FakeProcess({ exited: true }),
            kill: () => undefined,
            expected: {
                at: CLOSE_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; its process had already exited`,
                process: "exited",
                kills: [],
                released: false,
                stderr: [],
            },
        },
        {
            name: "the kill is refused",
            child: () => new FakeProcess(),
            kill: () => Promise.reject(new Error("Access is denied.")),
            expected: {
                at: CLOSE_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; killing its process failed`,
                process: "kill-failed",
                kills: owned,
                released: true,
                stderr: ["Error: Access is denied."],
            },
        },
        {
            name: "the kill is refused and the disconnect rejects",
            child: () => new FakeProcess(),
            kill: () => Promise.reject(new Error("Access is denied.")),
            disconnect: () => Promise.reject(new Error("already detached")),
            expected: {
                at: CLOSE_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; killing its process failed`,
                process: "kill-failed",
                kills: owned,
                released: true,
                stderr: ["Error: Access is denied.", "Error: already detached"],
            },
        },
        {
            name: "the killed process never exits",
            child: () => new FakeProcess(),
            kill: () => Promise.resolve(),
            expected: {
                at: CLOSE_TIMEOUT_MS + KILL_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; ${NOT_EXITED}`,
                process: "lingering",
                kills: [{ owned: true, aborted: true }],
                released: true,
                stderr: [],
            },
        },
        {
            name: "the kill never settles",
            child: () => new FakeProcess(),
            kill: () => new Promise(() => undefined),
            expected: {
                at: CLOSE_TIMEOUT_MS + KILL_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; ${NOT_EXITED}`,
                process: "lingering",
                kills: [{ owned: true, aborted: true }],
                released: true,
                stderr: [],
            },
        },
        {
            name: "the browser has no process of its own",
            child: () => null,
            kill: () => undefined,
            expected: {
                at: CLOSE_TIMEOUT_MS,
                reason: `${LATE_CLOSE}; it has no process this run can kill`,
                process: "none",
                kills: [],
                released: true,
                stderr: [],
            },
        },
    ]
    for (const { name, close, child, kill, disconnect, expected } of cases) {
        await t.test(name, async (t) => {
            const summary = await runTeardown(t, {
                close,
                child: child(),
                kill: fakeKill(kill),
                disconnect,
            })
            assert.deepEqual(summary, failedTeardown(expected))
        })
    }
})

/** A stand-in `execFile` that records each call and answers with `error`. */
function fakeRun(error) {
    const calls = []
    return {
        calls,
        run: (file, args, options, callback) => {
            calls.push({ file, args, options })
            setImmediate(() => callback(error))
        },
    }
}

test("killBrowserProcess_platformAndOutcome_signalsOnlyTheOwnedPid", async (t) => {
    const taskkill = (signal) => [
        {
            file: "taskkill",
            args: ["/pid", String(PID), "/T", "/F"],
            options: { signal, windowsHide: true },
        },
    ]
    const cases = [
        {
            name: "win32, taskkill stops the tree",
            platform: "win32",
            expected: (signal) => ({
                state: "fulfilled",
                runs: taskkill(signal),
                groupKills: [],
                childKills: [],
            }),
        },
        {
            name: "win32, taskkill refused",
            platform: "win32",
            runError: new Error("Command failed: taskkill"),
            expected: (signal) => ({
                state: "fulfilled",
                runs: taskkill(signal),
                groupKills: [],
                childKills: ["SIGKILL"],
            }),
        },
        {
            name: "win32, taskkill ended by the deadline",
            platform: "win32",
            runError: new Error("The operation was aborted"),
            aborted: true,
            expected: (signal) => ({
                state: "rejected",
                error: signal.reason,
                runs: taskkill(signal),
                groupKills: [],
                childKills: [],
            }),
        },
        {
            name: "linux, the process group is killed",
            platform: "linux",
            expected: () => ({
                state: "fulfilled",
                runs: [],
                groupKills: [[-PID, "SIGKILL"]],
                childKills: [],
            }),
        },
        {
            name: "linux, the process group kill is refused",
            platform: "linux",
            groupError: Object.assign(new Error("kill EPERM"), {
                code: "EPERM",
            }),
            expected: () => ({
                state: "fulfilled",
                runs: [],
                groupKills: [[-PID, "SIGKILL"]],
                childKills: ["SIGKILL"],
            }),
        },
        {
            name: "linux, every kill is refused",
            platform: "linux",
            groupError: Object.assign(new Error("kill ESRCH"), {
                code: "ESRCH",
            }),
            killResult: false,
            expected: () => ({
                state: "rejected",
                error: new Error(
                    `the browser process [${PID}] could not be signalled`
                ),
                runs: [],
                groupKills: [[-PID, "SIGKILL"]],
                childKills: ["SIGKILL"],
            }),
        },
    ]
    for (const {
        name,
        platform,
        runError = null,
        groupError,
        aborted = false,
        killResult = true,
        expected,
    } of cases) {
        await t.test(name, async (t) => {
            captureConsole(t)
            const child = new FakeProcess({ killResult })
            const controller = new AbortController()
            if (aborted) {
                controller.abort(new Error("the kill deadline passed"))
            }
            const run = fakeRun(runError)
            const groupKills = []
            let error
            let state = "fulfilled"
            try {
                await killBrowserProcess(child, controller.signal, {
                    platform,
                    run: run.run,
                    killGroup: (pid, signalName) => {
                        groupKills.push([pid, signalName])
                        if (groupError !== undefined) {
                            throw groupError
                        }
                    },
                })
            } catch (thrown) {
                state = "rejected"
                error = thrown
            }
            assert.deepEqual(
                {
                    state,
                    ...(error === undefined ? {} : { error }),
                    runs: run.calls,
                    groupKills,
                    childKills: child.kills,
                },
                expected(controller.signal)
            )
        })
    }
})
