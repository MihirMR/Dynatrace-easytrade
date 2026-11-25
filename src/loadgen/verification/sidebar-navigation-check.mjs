/* global document, window */
/**
 * Browser check of the sidebar as the Portfolio Insights feature styles it:
 * the keyboard focus ring and the one-line, horizontally scrolling mobile row
 * that the sidebar gets while the Portfolio Insights link is shown, and the
 * legacy sidebar while it is not.
 *
 * Usage, from src/loadgen after `npm ci`:
 *
 *     node verification/sidebar-navigation-check.mjs --base-url URL
 *         --mode flag-off|flag-on --fixture FILE --evidence-dir DIR
 *
 * Every option is required. The `portfolio-insights-enabled` flag must
 * already be in the state the mode names, `false` for flag-off and `true` for
 * flag-on: the check reads the flag and never changes it.
 *
 * Fixture: a JSON file whose `holder.username` and `holder.password` are
 * non-empty strings, the login the check signs in with. Other fields are
 * ignored. The password is never printed or written.
 *
 * Output: one `PASS <check>` or `FAIL <check>: <reason>` line per check, and
 * `sidebar-navigation-check-<mode>.json` plus screenshots in the evidence
 * directory.
 *
 * Exit codes: 0 when every check passed; 1 when a check or the setup failed;
 * 2 on a usage or fixture error.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { parseArgs } from "node:util"

const USAGE =
    "Usage: node verification/sidebar-navigation-check.mjs --base-url URL --mode flag-off|flag-on --fixture FILE --evidence-dir DIR"

const OPTIONS = {
    "base-url": { type: "string" },
    mode: { type: "string" },
    fixture: { type: "string" },
    "evidence-dir": { type: "string" },
}

const MODES = ["flag-off", "flag-on"]

const FLAG_ID = "portfolio-insights-enabled"
const FLAG_PATH = `/feature-flag-service/v1/flags/${FLAG_ID}`

/** The five sidebar links that exist without the feature, in their order. */
const EXISTING_LINK_IDS = [
    "nav-home",
    "nav-instruments",
    "nav-deposit",
    "nav-withdraw",
    "nav-credit-card",
]
const INSIGHTS_LINK_ID = "nav-portfolio-insights"
const FLAG_ON_LINK_IDS = [...EXISTING_LINK_IDS, INSIGHTS_LINK_ID]

/** A phone viewport, below the sidebar's 768 px breakpoint. */
const NARROW_VIEWPORT = { width: 375, height: 800 }
/** A laptop viewport, above the breakpoint. */
const WIDE_VIEWPORT = { width: 1366, height: 900 }

/** Deadline of every page navigation, selector wait and page action. */
const PAGE_TIMEOUT_MS = 30_000
/** Deadline of the check's own flag read. */
const FLAG_READ_TIMEOUT_MS = 10_000
/** Deadline for the page's first flag response. */
const FLAG_RESPONSE_TIMEOUT_MS = 15_000
/** Deadline for scrolling and viewport changes to settle. */
const SETTLE_TIMEOUT_MS = 2_000
const SETTLE_INTERVAL_MS = 50
/** Bound on the Tab presses that look for every sidebar link. */
const MAX_TAB_PRESSES = 60
/** Tolerance for sub-pixel box edges. */
const BOX_TOLERANCE_PX = 0.5
/** Tolerance for list items and line boxes that share one row. */
const ROW_TOLERANCE_PX = 1

/** A bad command line or fixture; the run stops with exit code 2. */
class UsageError extends Error {
    constructor(message) {
        super(message)
        this.name = "UsageError"
    }
}

/** A bounded wait that ran out of time. */
class WaitTimeoutError extends Error {
    constructor(message) {
        super(message)
        this.name = "WaitTimeoutError"
    }
}

/**
 * Polls `predicate` every `intervalMs` until it returns a truthy value, which
 * it resolves with, and throws a `WaitTimeoutError` naming `what` once
 * `timeoutMs` has passed without one.
 */
async function waitFor(predicate, { timeoutMs, intervalMs = 250, what }) {
    const deadline = Date.now() + timeoutMs
    for (;;) {
        const value = await predicate()
        if (value) {
            return value
        }
        const remainingMs = deadline - Date.now()
        if (remainingMs <= 0) {
            throw new WaitTimeoutError(
                `timed out after ${timeoutMs} ms waiting for ${what}`
            )
        }
        await new Promise((resolve) =>
            setTimeout(resolve, Math.min(intervalMs, remainingMs))
        )
    }
}

function parseBaseUrl(text) {
    let url
    try {
        url = new URL(text)
    } catch (error) {
        throw new UsageError(`--base-url is not a URL: ${error.message}`)
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
        throw new UsageError(
            `--base-url must be an http or https URL, not ${url.protocol}`
        )
    }
    if (url.username !== "" || url.password !== "") {
        throw new UsageError("--base-url must not carry credentials")
    }
    if (url.search !== "" || url.hash !== "") {
        throw new UsageError("--base-url must not carry a query or fragment")
    }
    return `${url.origin}${url.pathname}`.replace(/\/+$/, "")
}

function parseOptions(args) {
    let parsed
    try {
        parsed = parseArgs({ args, options: OPTIONS, strict: true })
    } catch (error) {
        throw new UsageError(error.message)
    }
    const { values } = parsed
    for (const name of Object.keys(OPTIONS)) {
        if (values[name] === undefined || values[name] === "") {
            throw new UsageError(`--${name} is required`)
        }
    }
    if (!MODES.includes(values.mode)) {
        throw new UsageError(
            `--mode must be ${MODES.join(" or ")}, not "${values.mode}"`
        )
    }
    return {
        baseUrl: parseBaseUrl(values["base-url"]),
        mode: values.mode,
        fixturePath: path.resolve(values.fixture),
        evidenceDir: path.resolve(values["evidence-dir"]),
    }
}

/** The login of the fixture's holder. */
async function readFixture(fixturePath) {
    let text
    try {
        text = await readFile(fixturePath, "utf8")
    } catch (error) {
        throw new UsageError(`cannot read --fixture: ${error.message}`)
    }
    let fixture
    try {
        fixture = JSON.parse(text.replace(/^\uFEFF/, ""))
    } catch {
        // The parser's message quotes the text around the error, which can
        // hold the password, so it is not repeated.
        throw new UsageError(`--fixture ${fixturePath} is not valid JSON`)
    }
    const holder =
        fixture !== null && typeof fixture === "object" ? fixture.holder : null
    for (const field of ["username", "password"]) {
        if (
            holder === null ||
            typeof holder !== "object" ||
            typeof holder[field] !== "string" ||
            holder[field] === ""
        ) {
            throw new UsageError(
                `--fixture ${fixturePath} needs a non-empty string holder.${field}`
            )
        }
    }
    return { username: holder.username, password: holder.password }
}

/** The flag in a flag-service response body, or `null` when it holds none. */
function parseFlagBody(body) {
    let flag
    try {
        flag = JSON.parse(body)
    } catch {
        // Not JSON, so not a flag; the caller reports the body.
        return null
    }
    return flag !== null &&
        typeof flag === "object" &&
        flag.id === FLAG_ID &&
        typeof flag.enabled === "boolean"
        ? { enabled: flag.enabled }
        : null
}

/** Reads the flag from the flag service, as the frontend does. */
async function readFlagEnabled(baseUrl) {
    const url = `${baseUrl}${FLAG_PATH}`
    const response = await fetch(url, {
        signal: AbortSignal.timeout(FLAG_READ_TIMEOUT_MS),
    })
    const body = await response.text()
    if (!response.ok) {
        throw new Error(`GET ${url} answered HTTP ${response.status}: ${body}`)
    }
    const flag = parseFlagBody(body)
    if (flag === null) {
        throw new Error(
            `GET ${url} answered HTTP ${response.status} without "${FLAG_ID}" and a boolean "enabled": ${body}`
        )
    }
    return flag.enabled
}

/**
 * Runs one check, prints its `PASS` or `FAIL` line and records it. A check
 * returns the problems it found and the details it measured; an error it
 * throws is a failure of that check.
 */
async function runCheck(report, name, check) {
    let outcome
    try {
        outcome = await check()
    } catch (error) {
        console.error(error)
        outcome = { problems: [error.message], details: {} }
    }
    const passed = outcome.problems.length === 0
    const reason = outcome.problems.join("; ")
    report.checks.push({
        name,
        passed,
        ...(passed ? {} : { reason }),
        details: outcome.details,
    })
    console.log(passed ? `PASS ${name}` : `FAIL ${name}: ${reason}`)
    return passed
}

/** Adds a problem to `problems` unless `actual` equals `expected`. */
function expectEqual(problems, label, actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        problems.push(
            `${label} is ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
        )
    }
}

async function checkFlagState(baseUrl, mode) {
    const expected = mode === "flag-on"
    const enabled = await readFlagEnabled(baseUrl)
    const problems = []
    expectEqual(
        problems,
        `${FLAG_ID} enabled (the check does not change it)`,
        enabled,
        expected
    )
    return { problems, details: { flagId: FLAG_ID, enabled, expected } }
}

/**
 * Records every flag response the page receives, with whether it held the
 * flag, so a check can wait for the page's own read.
 */
function recordFlagResponses(page) {
    const responses = []
    page.on("response", (response) => {
        if (
            response.request().method() !== "GET" ||
            !new URL(response.url()).pathname.endsWith(FLAG_PATH)
        ) {
            return
        }
        response.text().then(
            (body) => {
                const flag = response.ok() ? parseFlagBody(body) : null
                responses.push({
                    status: response.status(),
                    parsed: flag !== null,
                    enabled: flag === null ? null : flag.enabled,
                    receivedAt: new Date().toISOString(),
                })
            },
            (error) => {
                console.error(error)
            }
        )
    })
    return responses
}

async function screenshot(report, page, evidenceDir, fileName) {
    const file = path.join(evidenceDir, fileName)
    await page.screenshot({ path: file })
    report.screenshots.push(file)
}

/** Signs the fixture's holder in at the narrow viewport, landing on /home. */
async function openSignedInPage(browser, baseUrl, holder) {
    const context = await browser.createBrowserContext()
    const page = await context.newPage()
    page.setDefaultTimeout(PAGE_TIMEOUT_MS)
    await page.setViewport(NARROW_VIEWPORT)
    const flagResponses = recordFlagResponses(page)
    await page.goto(baseUrl, { waitUntil: "domcontentloaded" })
    await page.waitForSelector("#login")
    await page.type("#login", holder.username)
    await page.type("#password", holder.password)
    await page.click("#submitButton")
    await page.waitForSelector("#nav-home")
    return { page, flagResponses }
}

/**
 * In the page: the computed sizing of the sidebar row and of each of its
 * links, or `null` without a sidebar. A link's `labelLines` counts the line
 * boxes of its label text.
 */
function measureSidebar(rowTolerancePx) {
    const sidebar = document.querySelector(".sidebar")
    const list = document.querySelector(".sidebar-nav ul")
    if (sidebar === null || list === null) {
        return null
    }
    return {
        viewportWidth: window.innerWidth,
        sidebar: {
            overflowX: window.getComputedStyle(sidebar).overflowX,
            scrollWidth: sidebar.scrollWidth,
            clientWidth: sidebar.clientWidth,
        },
        listDirection: window.getComputedStyle(list).flexDirection,
        links: Array.from(list.querySelectorAll(".nav-link"), (link) => {
            const style = window.getComputedStyle(link)
            const item = link.closest("li")
            const lineTops = []
            for (const node of link.childNodes) {
                if (
                    node.nodeType !== node.TEXT_NODE ||
                    node.textContent.trim() === ""
                ) {
                    continue
                }
                const range = document.createRange()
                range.selectNodeContents(node)
                for (const rect of range.getClientRects()) {
                    if (
                        rect.width > 0 &&
                        !lineTops.some(
                            (top) => Math.abs(top - rect.top) <= rowTolerancePx
                        )
                    ) {
                        lineTops.push(rect.top)
                    }
                }
            }
            return {
                id: link.id,
                label: link.textContent.trim(),
                whiteSpace: style.whiteSpace,
                scrollMarginLeft: style.scrollMarginLeft,
                scrollMarginRight: style.scrollMarginRight,
                labelLines: lineTops.length,
                scrollWidth: link.scrollWidth,
                clientWidth: link.clientWidth,
                itemFlexShrink:
                    item === null
                        ? null
                        : window.getComputedStyle(item).flexShrink,
                itemTop:
                    item === null ? null : item.getBoundingClientRect().top,
            }
        }),
    }
}

async function sidebarLayout(page) {
    const layout = await page.evaluate(measureSidebar, ROW_TOLERANCE_PX)
    if (layout === null) {
        throw new Error("the page has no .sidebar with a .sidebar-nav list")
    }
    return layout
}

/**
 * In the page: the value `value` computes to for `property`, read from a
 * temporary element that is removed again.
 */
function resolveToken(property, value) {
    const probe = document.createElement("span")
    probe.style.setProperty(property, value)
    document.body.append(probe)
    const resolved = window.getComputedStyle(probe).getPropertyValue(property)
    probe.remove()
    return resolved
}

/**
 * In the page: the focus state, outline and box of link `id`, and the box of
 * the sidebar area that shows content, or `null` when either is missing.
 */
function inspectFocusedLink(id) {
    const link = document.getElementById(id)
    const sidebar = document.querySelector(".sidebar")
    if (link === null || sidebar === null) {
        return null
    }
    const style = window.getComputedStyle(link)
    const linkRect = link.getBoundingClientRect()
    const sidebarRect = sidebar.getBoundingClientRect()
    const left = sidebarRect.left + sidebar.clientLeft
    const top = sidebarRect.top + sidebar.clientTop
    return {
        id,
        focused: document.activeElement === link,
        focusVisible: link.matches(":focus-visible"),
        outlineStyle: style.outlineStyle,
        outlineWidth: style.outlineWidth,
        outlineOffset: style.outlineOffset,
        outlineColor: style.outlineColor,
        linkBox: {
            left: linkRect.left,
            right: linkRect.right,
            top: linkRect.top,
            bottom: linkRect.bottom,
        },
        sidebarVisibleBox: {
            left,
            right: left + sidebar.clientWidth,
            top,
            bottom: top + sidebar.clientHeight,
        },
        sidebarScrollLeft: sidebar.scrollLeft,
    }
}

function liesInsideSidebar(state) {
    if (state === null) {
        return false
    }
    const { linkBox, sidebarVisibleBox } = state
    return (
        linkBox.left >= sidebarVisibleBox.left - BOX_TOLERANCE_PX &&
        linkBox.right <= sidebarVisibleBox.right + BOX_TOLERANCE_PX &&
        linkBox.top >= sidebarVisibleBox.top - BOX_TOLERANCE_PX &&
        linkBox.bottom <= sidebarVisibleBox.bottom + BOX_TOLERANCE_PX
    )
}

/**
 * Presses Tab from the top of the page until each of `linkIds` has had
 * keyboard focus, at most `MAX_TAB_PRESSES` times, and records what
 * `inspect` returns for each link while it holds focus.
 */
async function tabThroughLinks(page, linkIds, inspect) {
    await page.evaluate(() => {
        const active = document.activeElement
        if (active !== null && active !== document.body) {
            active.blur()
        }
    })
    const focused = new Map()
    let presses = 0
    while (focused.size < linkIds.length && presses < MAX_TAB_PRESSES) {
        await page.keyboard.press("Tab")
        presses += 1
        const id = await page.evaluate(() =>
            document.activeElement === null ? "" : document.activeElement.id
        )
        if (linkIds.includes(id) && !focused.has(id)) {
            focused.set(id, await inspect(id))
        }
    }
    const problems = linkIds
        .filter((id) => !focused.has(id))
        .map(
            (id) => `#${id} never took keyboard focus in ${presses} Tab presses`
        )
    for (const [id, state] of focused) {
        if (state === null) {
            problems.push(`#${id} or .sidebar vanished while #${id} had focus`)
        }
    }
    return { presses, focused, problems }
}

function expectLinkIds(problems, layout, linkIds) {
    expectEqual(
        problems,
        "the sidebar links",
        layout.links.map((link) => link.id),
        linkIds
    )
}

async function runFlagOffChecks(report, page, flagResponses, evidenceDir) {
    await runCheck(report, "flag-off:nav-link-absent", async () => {
        await waitFor(() => flagResponses.some((response) => response.parsed), {
            timeoutMs: FLAG_RESPONSE_TIMEOUT_MS,
            what: "the page's first flag response",
        })
        const shown = await page.evaluate(
            (id) => document.getElementById(id) !== null,
            INSIGHTS_LINK_ID
        )
        const problems = []
        expectEqual(problems, `#${INSIGHTS_LINK_ID} shown`, shown, false)
        return {
            problems,
            details: { shown, flagResponses: [...flagResponses] },
        }
    })
    await screenshot(report, page, evidenceDir, "sidebar-flag-off-narrow.png")

    await runCheck(report, "flag-off:sidebar-legacy-layout", async () => {
        const layout = await sidebarLayout(page)
        const problems = []
        expectLinkIds(problems, layout, EXISTING_LINK_IDS)
        expectEqual(
            problems,
            ".sidebar overflow-x",
            layout.sidebar.overflowX,
            "auto"
        )
        expectEqual(
            problems,
            "list flex-direction",
            layout.listDirection,
            "row"
        )
        for (const link of layout.links) {
            expectEqual(
                problems,
                `#${link.id} white-space`,
                link.whiteSpace,
                "normal"
            )
            expectEqual(
                problems,
                `#${link.id} scroll-margin-left/right`,
                [link.scrollMarginLeft, link.scrollMarginRight],
                ["0px", "0px"]
            )
            expectEqual(
                problems,
                `#${link.id} list item flex-shrink`,
                link.itemFlexShrink,
                "1"
            )
        }
        return { problems, details: layout }
    })

    await runCheck(report, "flag-off:sidebar-legacy-focus", async () => {
        const { presses, focused, problems } = await tabThroughLinks(
            page,
            EXISTING_LINK_IDS,
            (id) => page.evaluate(inspectFocusedLink, id)
        )
        for (const state of focused.values()) {
            if (state === null) {
                continue
            }
            expectEqual(
                problems,
                `#${state.id} :focus-visible`,
                state.focusVisible,
                true
            )
            // Chrome's own focus ring, not the feature's solid ring.
            expectEqual(
                problems,
                `#${state.id} outline-style`,
                state.outlineStyle,
                "auto"
            )
        }
        return { problems, details: { presses, links: [...focused.values()] } }
    })
}

async function runFlagOnChecks(report, page, evidenceDir) {
    await page.waitForSelector(`#${INSIGHTS_LINK_ID}`)
    await screenshot(report, page, evidenceDir, "sidebar-flag-on-narrow.png")

    await runCheck(report, "flag-on:sidebar-mobile-row", async () => {
        const spacing = await page.evaluate(
            resolveToken,
            "margin-left",
            "var(--space-2)"
        )
        const layout = await sidebarLayout(page)
        const problems = []
        expectLinkIds(problems, layout, FLAG_ON_LINK_IDS)
        expectEqual(
            problems,
            ".sidebar overflow-x",
            layout.sidebar.overflowX,
            "auto"
        )
        if (layout.sidebar.scrollWidth <= layout.sidebar.clientWidth) {
            problems.push(
                `.sidebar does not scroll: scrollWidth ${layout.sidebar.scrollWidth} <= clientWidth ${layout.sidebar.clientWidth}`
            )
        }
        for (const link of layout.links) {
            expectEqual(
                problems,
                `#${link.id} white-space`,
                link.whiteSpace,
                "nowrap"
            )
            expectEqual(
                problems,
                `#${link.id} label line boxes`,
                link.labelLines,
                1
            )
            if (link.scrollWidth > link.clientWidth) {
                problems.push(
                    `#${link.id} is clipped: scrollWidth ${link.scrollWidth} > clientWidth ${link.clientWidth}`
                )
            }
            expectEqual(
                problems,
                `#${link.id} scroll-margin-left/right`,
                [link.scrollMarginLeft, link.scrollMarginRight],
                [spacing, spacing]
            )
            expectEqual(
                problems,
                `#${link.id} list item flex-shrink`,
                link.itemFlexShrink,
                "0"
            )
        }
        const tops = layout.links.map((link) => link.itemTop)
        if (Math.max(...tops) - Math.min(...tops) > ROW_TOLERANCE_PX) {
            problems.push(
                `the list items do not share one row: tops ${tops.join(", ")}`
            )
        }
        return { problems, details: { spacing, ...layout } }
    })

    await runCheck(report, "flag-on:sidebar-focus-ring", async () => {
        const ringColor = await page.evaluate(
            resolveToken,
            "color",
            "var(--border-focus)"
        )
        const { presses, focused, problems } = await tabThroughLinks(
            page,
            FLAG_ON_LINK_IDS,
            async (id) => {
                let state = null
                try {
                    await waitFor(
                        async () => {
                            state = await page.evaluate(inspectFocusedLink, id)
                            return liesInsideSidebar(state)
                        },
                        {
                            timeoutMs: SETTLE_TIMEOUT_MS,
                            intervalMs: SETTLE_INTERVAL_MS,
                            what: `#${id} to lie inside the sidebar`,
                        }
                    )
                } catch (error) {
                    // A link left outside the sidebar is reported below from
                    // its last state; any other error fails the check.
                    if (!(error instanceof WaitTimeoutError)) {
                        throw error
                    }
                }
                if (id === INSIGHTS_LINK_ID) {
                    await screenshot(
                        report,
                        page,
                        evidenceDir,
                        "sidebar-flag-on-focus.png"
                    )
                }
                return state
            }
        )
        for (const state of focused.values()) {
            if (state === null) {
                continue
            }
            expectEqual(
                problems,
                `#${state.id} focus ring`,
                {
                    focusVisible: state.focusVisible,
                    outlineStyle: state.outlineStyle,
                    outlineWidth: state.outlineWidth,
                    outlineOffset: state.outlineOffset,
                    outlineColor: state.outlineColor,
                },
                {
                    focusVisible: true,
                    outlineStyle: "solid",
                    outlineWidth: "2px",
                    outlineOffset: "0px",
                    outlineColor: ringColor,
                }
            )
            if (!liesInsideSidebar(state)) {
                problems.push(
                    `#${state.id} is not fully inside the sidebar: link ${JSON.stringify(state.linkBox)}, sidebar ${JSON.stringify(state.sidebarVisibleBox)}`
                )
            }
        }
        return {
            problems,
            details: { ringColor, presses, links: [...focused.values()] },
        }
    })

    await runCheck(report, "flag-on:sidebar-desktop-column", async () => {
        await page.setViewport(WIDE_VIEWPORT)
        await waitFor(
            () =>
                page.evaluate(
                    (width) => window.innerWidth === width,
                    WIDE_VIEWPORT.width
                ),
            {
                timeoutMs: SETTLE_TIMEOUT_MS,
                intervalMs: SETTLE_INTERVAL_MS,
                what: `a ${WIDE_VIEWPORT.width} px viewport`,
            }
        )
        const layout = await sidebarLayout(page)
        const problems = []
        expectLinkIds(problems, layout, FLAG_ON_LINK_IDS)
        expectEqual(
            problems,
            "list flex-direction",
            layout.listDirection,
            "column"
        )
        for (const link of layout.links) {
            expectEqual(
                problems,
                `#${link.id} white-space`,
                link.whiteSpace,
                "normal"
            )
            expectEqual(
                problems,
                `#${link.id} list item flex-shrink`,
                link.itemFlexShrink,
                "1"
            )
        }
        return { problems, details: layout }
    })
}

async function main() {
    let options
    let holder
    try {
        options = parseOptions(process.argv.slice(2))
        holder = await readFixture(options.fixturePath)
    } catch (error) {
        if (!(error instanceof UsageError)) {
            throw error
        }
        console.error(USAGE)
        console.error(error.message)
        process.exitCode = 2
        return
    }

    const { baseUrl, mode, evidenceDir } = options
    const report = {
        mode,
        baseUrl,
        username: holder.username,
        startedAt: new Date().toISOString(),
        finishedAt: null,
        checks: [],
        screenshots: [],
    }
    let failed = false
    let browser = null
    try {
        await mkdir(evidenceDir, { recursive: true })
        const flagCheck =
            mode === "flag-on"
                ? "flag-on:flag-enabled"
                : "flag-off:flag-disabled"
        const flagReady = await runCheck(report, flagCheck, () =>
            checkFlagState(baseUrl, mode)
        )
        if (flagReady) {
            const { default: puppeteer } = await import("puppeteer")
            browser = await puppeteer.launch({ headless: true })
            const { page, flagResponses } = await openSignedInPage(
                browser,
                baseUrl,
                holder
            )
            if (mode === "flag-on") {
                await runFlagOnChecks(report, page, evidenceDir)
            } else {
                await runFlagOffChecks(report, page, flagResponses, evidenceDir)
            }
        }
    } catch (error) {
        failed = true
        console.log(`FAIL setup: ${error.message}`)
        console.error(error)
    } finally {
        if (browser !== null) {
            try {
                await browser.close()
            } catch (error) {
                failed = true
                console.log(`FAIL teardown: ${error.message}`)
                console.error(error)
            }
        }
        report.finishedAt = new Date().toISOString()
        try {
            await mkdir(evidenceDir, { recursive: true })
            await writeFile(
                path.join(evidenceDir, `sidebar-navigation-check-${mode}.json`),
                `${JSON.stringify(report, null, 4)}\n`
            )
        } catch (error) {
            failed = true
            console.log(`FAIL evidence: ${error.message}`)
            console.error(error)
        }
    }
    process.exitCode =
        failed || report.checks.some((check) => !check.passed) ? 1 : 0
}

await main()
