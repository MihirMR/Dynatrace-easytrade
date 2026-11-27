/**
 * Unit tests of how the page check holds the five sidebar links that predate
 * Portfolio Insights to their layout without it: each link must be present
 * and rendered at every width with the feature on and off, so a link lost or
 * hidden in both modes is reported instead of comparing equal, and every
 * other value read with the feature on must equal the one read with it off.
 * The in-page read runs in Chrome through the locked Puppeteer against
 * markup the test sets itself, so no stack is needed.
 *
 * Run from src/loadgen, with the other verification suites, as:
 *
 *     node --test "verification/*.test.mjs"
 *
 * `npm test` runs only the compiled TypeScript tests under build/, so it does
 * not pick this file up. No test sleeps.
 */
import assert from "node:assert/strict"
import { test } from "node:test"
import puppeteer from "puppeteer"

import {
    compareLegacySidebarLayouts,
    projectLegacySidebar,
    readLegacySidebar,
} from "./portfolio-insights-page-check.mjs"

/**
 * The ids of the five links, as Navigation.tsx renders them, in order, each
 * with the route its `NavLink` renders as its href.
 */
const LEGACY_NAV_ROUTES = {
    "nav-home": "/home",
    "nav-instruments": "/instruments",
    "nav-deposit": "/deposit",
    "nav-withdraw": "/withdraw",
    "nav-credit-card": "/credit-card",
}
const LEGACY_NAV_IDS = Object.keys(LEGACY_NAV_ROUTES)
/** The widths the continuity check reads the sidebar at. */
const WIDTHS = [375, 668, 1366]

/** A link as `readLegacySidebar` reads one the page renders. */
function renderedLink(id, index) {
    return {
        id,
        present: true,
        inSidebar: true,
        anchor: true,
        sameOrigin: true,
        route: LEGACY_NAV_ROUTES[id],
        boxes: 1,
        display: "flex",
        visibility: "visible",
        visible: true,
        left: 8,
        top: 12 + 38 * index,
        width: 244,
        height: 36,
        lines: 1,
        whiteSpace: "normal",
        itemFlexShrink: "1",
        scrollMarginInlineStart: "0px",
        scrollMarginInlineEnd: "0px",
    }
}

/**
 * A `readLegacySidebar` result of five rendered links, with the values in
 * `changes` replaced per link id, and a link whose change is `null` missing.
 */
function sidebarRead(changes = {}) {
    return {
        sidebarHeight: 900,
        links: LEGACY_NAV_IDS.map((id, index) =>
            changes[id] === null
                ? { id, present: false }
                : { ...renderedLink(id, index), ...changes[id] }
        ),
    }
}

/** `read`, projected as the check projects it, at every width. */
function layoutsOf(read) {
    return Object.fromEntries(
        WIDTHS.map((width) => [width, projectLegacySidebar(read)])
    )
}

/** The problems `problem(width)` names, for each width in order. */
function atEveryWidth(problem) {
    return WIDTHS.flatMap((width) => problem(width))
}

/** `problem(width, mode)` for each width, with the feature on, then off. */
function inBothModes(problem) {
    return WIDTHS.flatMap((width) =>
        ["on", "off"].map((mode) => problem(width, mode))
    )
}

/** The problem naming a present link that is not rendered for `gaps`. */
function notRendered(id, gaps) {
    return (width, mode) =>
        `with the feature ${mode} at ${width} px, #${id} is not rendered in the .sidebar: ${gaps}`
}

/** The problem naming a missing link. */
function missing(id) {
    return (width, mode) =>
        `with the feature ${mode} at ${width} px, #${id} is missing`
}

/** The problem naming a width and mode without a sidebar. */
function noSidebar(width, mode) {
    return `at ${width} px the page shows no .sidebar with the feature ${mode}`
}

test("compareLegacySidebarLayouts_onAndOffLayouts_reportsEveryLostOrChangedLink", async (t) => {
    const rows = [
        {
            name: "identicalRenderedLayouts_noProblem",
            on: sidebarRead(),
            off: sidebarRead(),
            problems: [],
        },
        {
            name: "linkMissingInBothModes_problemPerWidthAndMode",
            on: sidebarRead({ "nav-deposit": null }),
            off: sidebarRead({ "nav-deposit": null }),
            problems: inBothModes(missing("nav-deposit")),
        },
        {
            name: "linkZeroSizedInBothModes_problemNamesSize",
            on: sidebarRead({ "nav-withdraw": { width: 0, height: 0 } }),
            off: sidebarRead({ "nav-withdraw": { width: 0, height: 0 } }),
            problems: inBothModes(
                notRendered("nav-withdraw", "width is 0, height is 0")
            ),
        },
        {
            name: "linkWithoutBoxInBothModes_problemNamesEveryGap",
            on: sidebarRead({
                "nav-withdraw": {
                    boxes: 0,
                    display: "none",
                    visible: false,
                    width: 0,
                    height: 0,
                },
            }),
            off: sidebarRead({
                "nav-withdraw": {
                    boxes: 0,
                    display: "none",
                    visible: false,
                    width: 0,
                    height: 0,
                },
            }),
            problems: inBothModes(
                notRendered(
                    "nav-withdraw",
                    'boxes is 0, width is 0, height is 0, display is "none", visible is false'
                )
            ),
        },
        {
            name: "linkHiddenInBothModes_problemNamesVisibility",
            on: sidebarRead({
                "nav-instruments": { visibility: "hidden", visible: false },
            }),
            off: sidebarRead({
                "nav-instruments": { visibility: "hidden", visible: false },
            }),
            problems: inBothModes(
                notRendered(
                    "nav-instruments",
                    'visibility is "hidden", visible is false'
                )
            ),
        },
        {
            name: "linkCollapsedInBothModes_problemNamesVisibility",
            on: sidebarRead({
                "nav-instruments": { visibility: "collapse", visible: false },
            }),
            off: sidebarRead({
                "nav-instruments": { visibility: "collapse", visible: false },
            }),
            problems: inBothModes(
                notRendered(
                    "nav-instruments",
                    'visibility is "collapse", visible is false'
                )
            ),
        },
        {
            name: "linkTransparentInBothModes_problemNamesVisible",
            on: sidebarRead({ "nav-home": { visible: false } }),
            off: sidebarRead({ "nav-home": { visible: false } }),
            problems: inBothModes(notRendered("nav-home", "visible is false")),
        },
        {
            name: "linkOutsideSidebarInBothModes_problemNamesInSidebar",
            on: sidebarRead({ "nav-home": { inSidebar: false } }),
            off: sidebarRead({ "nav-home": { inSidebar: false } }),
            problems: inBothModes(
                notRendered("nav-home", "inSidebar is false")
            ),
        },
        {
            name: "displayOutsideDefinedForm_problemQuotesNoPageText",
            on: sidebarRead({ "nav-home": { display: "flex; secret" } }),
            off: sidebarRead({ "nav-home": { display: "flex; secret" } }),
            problems: inBothModes(
                notRendered("nav-home", "display is a string of 12 characters")
            ),
        },
        {
            name: "placeholderNotAnchorInBothModes_problemNamesAnchorAndHref",
            on: sidebarRead({
                "nav-deposit": { anchor: false, sameOrigin: null, route: null },
            }),
            off: sidebarRead({
                "nav-deposit": { anchor: false, sameOrigin: null, route: null },
            }),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    "anchor is false, sameOrigin is null, route is null"
                )
            ),
        },
        {
            name: "anchorWithoutHrefInBothModes_problemNamesHref",
            on: sidebarRead({
                "nav-deposit": { sameOrigin: null, route: null },
            }),
            off: sidebarRead({
                "nav-deposit": { sameOrigin: null, route: null },
            }),
            problems: inBothModes(
                notRendered("nav-deposit", "sameOrigin is null, route is null")
            ),
        },
        {
            name: "anchorToWrongRouteInBothModes_problemQuotesNoPageText",
            on: sidebarRead({ "nav-deposit": { route: "/home" } }),
            off: sidebarRead({ "nav-deposit": { route: "/home" } }),
            problems: inBothModes(
                notRendered("nav-deposit", "route is a string of 5 characters")
            ),
        },
        {
            name: "anchorToOtherLinksRouteInBothModes_problemNamesRoute",
            on: sidebarRead({ "nav-deposit": { route: "/withdraw" } }),
            off: sidebarRead({ "nav-deposit": { route: "/withdraw" } }),
            problems: inBothModes(
                notRendered("nav-deposit", "route is a string of 9 characters")
            ),
        },
        {
            name: "anchorOffOriginInBothModes_problemNamesSameOrigin",
            on: sidebarRead({ "nav-deposit": { sameOrigin: false } }),
            off: sidebarRead({ "nav-deposit": { sameOrigin: false } }),
            problems: inBothModes(
                notRendered("nav-deposit", "sameOrigin is false")
            ),
        },
        {
            name: "anchorToWrongRouteOnlyWithFeatureOn_problemNamesOnMode",
            on: sidebarRead({ "nav-home": { route: "/insights" } }),
            off: sidebarRead(),
            problems: atEveryWidth((width) => [
                notRendered("nav-home", "route is a string of 9 characters")(
                    width,
                    "on"
                ),
            ]),
        },
        {
            name: "linkMissingOnlyWithFeatureOn_problemNamesOnMode",
            on: sidebarRead({ "nav-credit-card": null }),
            off: sidebarRead(),
            problems: atEveryWidth((width) => [
                missing("nav-credit-card")(width, "on"),
            ]),
        },
        {
            name: "linkHiddenOnlyWithFeatureOff_problemNamesOffMode",
            on: sidebarRead(),
            off: sidebarRead({ "nav-home": { visible: false } }),
            problems: atEveryWidth((width) => [
                notRendered("nav-home", "visible is false")(width, "off"),
            ]),
        },
        {
            name: "linkMovedWithFeatureOn_problemNamesField",
            on: sidebarRead({ "nav-home": { width: 230 } }),
            off: sidebarRead(),
            problems: atEveryWidth((width) => [
                `with the feature on at ${width} px, #nav-home width is 230, expected 244`,
            ]),
        },
        {
            name: "linkMissingAndOtherMovedWithFeatureOn_reportsBoth",
            on: sidebarRead({
                "nav-credit-card": null,
                "nav-home": { whiteSpace: "nowrap" },
            }),
            off: sidebarRead(),
            problems: atEveryWidth((width) => [
                missing("nav-credit-card")(width, "on"),
                `with the feature on at ${width} px, #nav-home whiteSpace is "nowrap", expected "normal"`,
            ]),
        },
        {
            name: "sidebarMissingWithFeatureOn_problemNamesOnMode",
            on: null,
            off: sidebarRead(),
            problems: atEveryWidth((width) => [noSidebar(width, "on")]),
        },
        {
            name: "sidebarMissingInBothModes_problemPerWidthAndMode",
            on: null,
            off: null,
            problems: inBothModes(noSidebar),
        },
        {
            name: "sidebarMissingWithFeatureOff_linksWithFeatureOnStillHeld",
            on: sidebarRead({ "nav-deposit": null }),
            off: null,
            problems: atEveryWidth((width) => [
                missing("nav-deposit")(width, "on"),
                noSidebar(width, "off"),
            ]),
        },
    ]
    for (const row of rows) {
        await t.test(row.name, () => {
            const problems = []

            compareLegacySidebarLayouts(
                problems,
                layoutsOf(row.on),
                layoutsOf(row.off)
            )

            assert.deepEqual(problems, row.problems)
        })
    }
})

/** Styles close to the frontend's sidebar, so links lay out as there. */
const SIDEBAR_STYLE = `
    body { margin: 0; font: 14px sans-serif }
    .sidebar { width: 260px; display: flex; flex-direction: column }
    .sidebar-nav ul { display: flex; flex-direction: column; margin: 0; padding: 0 }
    .sidebar-nav li { list-style: none }
    .nav-link { display: flex; padding: 8px 12px }
`

/** A sidebar link item, linking to its route, as Navigation.tsx renders one. */
function navItem(id, label, linkStyle = "", itemStyle = "") {
    return `<li style="${itemStyle}"><a id="${id}" class="nav-link" href="${LEGACY_NAV_ROUTES[id]}" style="${linkStyle}">${label}</a></li>`
}

/** A #nav-deposit item whose element is `<tag attributes>Deposit</tag>`. */
function depositItem(tag, attributes) {
    return `<li><${tag} id="nav-deposit" class="nav-link" ${attributes}>Deposit</${tag}></li>`
}

/**
 * The page the in-page rows run on, served by request interception, so the
 * links resolve on an origin of their own as on the app.
 */
const PAGE_URL = "http://easytrade.test/home"

/**
 * A page whose sidebar holds the four links other than #nav-deposit and, in
 * their place, `depositItem`, followed by `afterSidebar` outside it.
 */
function sidebarPage(depositItem, afterSidebar = "") {
    return [
        `<!doctype html><html><head><style>${SIDEBAR_STYLE}</style></head><body>`,
        '<nav class="sidebar"><div class="sidebar-nav"><ul>',
        navItem("nav-home", "Home"),
        navItem("nav-instruments", "Instruments"),
        depositItem,
        navItem("nav-withdraw", "Withdraw"),
        navItem("nav-credit-card", "Credit card"),
        "</ul></div></nav>",
        afterSidebar,
        "</body></html>",
    ].join("")
}

test("readLegacySidebar_linkMarkup_readsWhetherEachLinkIsRendered", async (t) => {
    const rows = [
        {
            name: "renderedLink_noProblem",
            html: sidebarPage(navItem("nav-deposit", "Deposit")),
            problems: [],
        },
        {
            name: "linkDisplayNone_problemNamesNoBox",
            html: sidebarPage(
                navItem("nav-deposit", "Deposit", "display: none")
            ),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    'boxes is 0, width is 0, height is 0, display is "none", visible is false'
                )
            ),
        },
        {
            name: "itemDisplayNone_problemNamesNoBox",
            html: sidebarPage(
                navItem("nav-deposit", "Deposit", "", "display: none")
            ),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    "boxes is 0, width is 0, height is 0, visible is false"
                )
            ),
        },
        {
            name: "linkVisibilityHidden_problemNamesVisibility",
            html: sidebarPage(
                navItem("nav-deposit", "Deposit", "visibility: hidden")
            ),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    'visibility is "hidden", visible is false'
                )
            ),
        },
        {
            name: "linkVisibilityCollapse_problemNamesVisibility",
            html: sidebarPage(
                navItem("nav-deposit", "Deposit", "visibility: collapse")
            ),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    'visibility is "collapse", visible is false'
                )
            ),
        },
        {
            name: "itemTransparent_problemNamesVisible",
            html: sidebarPage(
                navItem("nav-deposit", "Deposit", "", "opacity: 0")
            ),
            problems: inBothModes(
                notRendered("nav-deposit", "visible is false")
            ),
        },
        {
            name: "linkZeroSized_problemNamesSize",
            html: sidebarPage(
                navItem(
                    "nav-deposit",
                    "Deposit",
                    "width: 0; height: 0; padding: 0; overflow: hidden"
                )
            ),
            problems: inBothModes(
                notRendered("nav-deposit", "width is 0, height is 0")
            ),
        },
        {
            name: "linkOutsideSidebar_problemNamesInSidebar",
            html: sidebarPage(
                "",
                '<a id="nav-deposit" class="nav-link" href="/deposit">Deposit</a>'
            ),
            problems: inBothModes(
                notRendered("nav-deposit", "inSidebar is false")
            ),
        },
        {
            name: "linkAbsent_problemNamesMissing",
            html: sidebarPage(""),
            problems: inBothModes(missing("nav-deposit")),
        },
        {
            name: "noSidebar_problemPerWidthAndMode",
            html: `<!doctype html><html><body>${navItem("nav-deposit", "Deposit")}</body></html>`,
            problems: inBothModes(noSidebar),
        },
        ...["span", "div"].map((tag) => ({
            name: `placeholder${tag === "span" ? "Span" : "Div"}WithHref_problemNamesAnchorAndHref`,
            html: sidebarPage(depositItem(tag, 'href="/deposit"')),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    "anchor is false, sameOrigin is null, route is null"
                )
            ),
        })),
        {
            name: "anchorRelativeHrefToRoute_noProblem",
            html: sidebarPage(depositItem("a", 'href="deposit"')),
            problems: [],
        },
        {
            name: "anchorToWrongRoute_problemQuotesNoPageText",
            html: sidebarPage(depositItem("a", 'href="/home"')),
            problems: inBothModes(
                notRendered("nav-deposit", "route is a string of 5 characters")
            ),
        },
        {
            name: "anchorWithQuery_problemNamesRoute",
            html: sidebarPage(depositItem("a", 'href="/deposit?from=sidebar"')),
            problems: inBothModes(
                notRendered("nav-deposit", "route is a string of 21 characters")
            ),
        },
        {
            name: "anchorOffOrigin_problemNamesSameOrigin",
            html: sidebarPage(
                depositItem("a", 'href="https://elsewhere.test/deposit"')
            ),
            problems: inBothModes(
                notRendered("nav-deposit", "sameOrigin is false")
            ),
        },
        {
            name: "anchorScriptHref_problemNamesOriginAndRoute",
            html: sidebarPage(depositItem("a", 'href="javascript:void(0)"')),
            problems: inBothModes(
                notRendered(
                    "nav-deposit",
                    "sameOrigin is false, route is a string of 7 characters"
                )
            ),
        },
        {
            name: "anchorWithoutHref_problemNamesHref",
            html: sidebarPage(depositItem("a", "")),
            problems: inBothModes(
                notRendered("nav-deposit", "sameOrigin is null, route is null")
            ),
        },
        {
            name: "anchorUnparseableHref_problemNamesHref",
            html: sidebarPage(depositItem("a", 'href="http://["')),
            problems: inBothModes(
                notRendered("nav-deposit", "sameOrigin is null, route is null")
            ),
        },
        {
            // Each href resolves to its route on an opaque origin, which is
            // the opaque page's origin by value and same-origin with nothing.
            name: "opaquePageOrigin_problemNamesSameOriginOfEveryLink",
            url: "about:blank",
            html: [
                `<!doctype html><html><head><style>${SIDEBAR_STYLE}</style></head><body>`,
                '<nav class="sidebar"><div class="sidebar-nav"><ul>',
                ...LEGACY_NAV_IDS.map(
                    (id) =>
                        `<li><a id="${id}" class="nav-link" href="app:${LEGACY_NAV_ROUTES[id]}">${id}</a></li>`
                ),
                "</ul></div></nav></body></html>",
            ].join(""),
            problems: WIDTHS.flatMap((width) =>
                ["on", "off"].flatMap((mode) =>
                    LEGACY_NAV_IDS.map((id) =>
                        notRendered(id, "sameOrigin is false")(width, mode)
                    )
                )
            ),
        },
    ]
    // The check's own launch options: Chrome refuses its sandbox as root.
    const browser = await puppeteer.launch({
        headless: true,
        args: ["--no-sandbox"],
    })
    try {
        const page = await browser.newPage()
        // Every request is answered here, so no row reaches a network.
        page.on("request", (request) =>
            request.respond({
                status: 200,
                contentType: "text/html",
                body: "<!doctype html>",
            })
        )
        await page.setRequestInterception(true)
        for (const row of rows) {
            await t.test(row.name, async () => {
                const url = row.url ?? PAGE_URL
                if (page.url() !== url) {
                    await page.goto(url)
                }
                await page.setContent(row.html)
                const layouts = layoutsOf(
                    await page.evaluate(readLegacySidebar, LEGACY_NAV_IDS)
                )
                const problems = []

                compareLegacySidebarLayouts(problems, layouts, layouts)

                assert.deepEqual(problems, row.problems)
            })
        }
    } finally {
        await browser.close()
    }
})
