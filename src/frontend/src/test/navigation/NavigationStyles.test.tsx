import { act, cleanup, render } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router"
import Navigation from "../../components/Navigation"
import { PortfolioInsightsFlagId } from "../../api/featureFlags"
import { featureFlagKeys } from "../../utils/queryKeys"
import layoutCss from "../../styles/layout.css?raw"
import componentsCss from "../../styles/components.css?raw"

type ScrollIntoView = (
    this: Element,
    arg?: boolean | ScrollIntoViewOptions
) => void

/** The stylesheets that style the sidebar, in the order main.tsx loads them. */
const SIDEBAR_STYLESHEETS = [
    { name: "layout.css", text: layoutCss },
    { name: "components.css", text: componentsCss },
]

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

/** A phone width, below the 768 px breakpoint. */
const NARROW_VIEWPORT = 375
/** The breakpoint itself, where `(max-width: 768px)` still applies. */
const BREAKPOINT_VIEWPORT = 768
/** One pixel above the breakpoint, where the desktop column applies. */
const ABOVE_BREAKPOINT_VIEWPORT = 769
/** A laptop width. */
const WIDE_VIEWPORT = 1366

/** The ring the feature gives every sidebar link under keyboard focus. */
const FEATURE_FOCUS_RING = {
    outline: "2px solid var(--border-focus)",
    outlineOffset: "0",
}

/**
 * jsdom's own `:focus` rule, which a focused sidebar link keeps while the
 * feature is off.
 */
const DEFAULT_FOCUS_RING = {
    outline: "auto 5px -webkit-focus-ring-color",
    outlineOffset: "",
}

/**
 * `(max-width: Npx)`, the only media condition the stylesheets use. Any
 * other condition makes `emulateViewport` throw, so a new kind of breakpoint
 * cannot be silently ignored.
 */
const MAX_WIDTH_CONDITION = /^\(max-width: (\d+)px\)$/

/** jsdom has no `scrollIntoView`, so each test installs one and removes it. */
const scrollIntoViewDescriptor = Object.getOwnPropertyDescriptor(
    Element.prototype,
    "scrollIntoView"
)

afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    for (const style of document.head.querySelectorAll(
        "style[data-sidebar-stylesheet]"
    )) {
        style.remove()
    }
    if (scrollIntoViewDescriptor === undefined) {
        Reflect.deleteProperty(Element.prototype, "scrollIntoView")
    } else {
        Object.defineProperty(
            Element.prototype,
            "scrollIntoView",
            scrollIntoViewDescriptor
        )
    }
})

/**
 * Keeps the sheet's `(max-width: Npx)` rules active exactly when
 * `viewportWidth` is at most N.
 *
 * jsdom has no layout and no viewport. Its `getComputedStyle` applies the
 * rules of an `@media` block only when the block's medium list contains
 * `screen`, and ignores every other block. Appending `screen` to a block
 * whose condition holds at `viewportWidth` therefore applies that block, and
 * leaving the others untouched keeps them ignored.
 */
function emulateViewport(sheet: CSSStyleSheet, viewportWidth: number): void {
    for (const rule of Array.from(sheet.cssRules)) {
        if (!(rule instanceof CSSMediaRule)) {
            continue
        }
        const condition = MAX_WIDTH_CONDITION.exec(rule.media.mediaText)
        if (condition === null) {
            throw new Error(
                `No viewport emulation for @media ${rule.media.mediaText}`
            )
        }
        if (viewportWidth <= Number(condition[1])) {
            rule.media.appendMedium("screen")
        }
    }
}

/**
 * Adds the shipped sidebar stylesheets to the document as they apply at
 * `viewportWidth`. The test removes them afterwards.
 */
function installSidebarStylesheets(viewportWidth: number): void {
    for (const { name, text } of SIDEBAR_STYLESHEETS) {
        if (text === "") {
            throw new Error(
                `${name} was imported empty; vitest.config.ts must let it through`
            )
        }
        const style = document.createElement("style")
        style.dataset.sidebarStylesheet = name
        style.textContent = text
        document.head.append(style)
        if (style.sheet === null) {
            throw new Error(`${name} was not parsed into a stylesheet`)
        }
        emulateViewport(style.sheet, viewportWidth)
    }
}

/** Records every `scrollIntoView` call, which keyboard focus triggers. */
function installScrollIntoView(): void {
    Object.defineProperty(Element.prototype, "scrollIntoView", {
        configurable: true,
        writable: true,
        value: vi.fn<ScrollIntoView>(),
    })
}

function flagResponse(enabled: boolean): Response {
    return new Response(
        JSON.stringify({ id: PortfolioInsightsFlagId, enabled }),
        {
            status: 200,
            headers: { "Content-Type": "application/json" },
        }
    )
}

/**
 * Renders the sidebar on `/home`, styled for `viewportWidth`, with the
 * Portfolio Insights flag seeded as `enabled` and the flag service answering
 * the same value.
 */
async function renderStyledNavigation(
    enabled: boolean,
    viewportWidth: number
): Promise<void> {
    installSidebarStylesheets(viewportWidth)
    installScrollIntoView()
    vi.spyOn(window, "fetch").mockImplementation(() =>
        Promise.resolve(flagResponse(enabled))
    )
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false, gcTime: Infinity } },
    })
    client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, enabled)
    render(
        <QueryClientProvider client={client}>
            <MemoryRouter initialEntries={["/home"]}>
                <Navigation />
            </MemoryRouter>
        </QueryClientProvider>
    )
    // The mount read is answered at once; awaiting it leaves no read in
    // flight when the test ends.
    await act(async () => {
        await client.refetchQueries(
            { queryKey: featureFlagKeys.portfolioInsights },
            { cancelRefetch: false }
        )
    })
}

function requiredElement(selector: string): HTMLElement {
    const element = document.querySelector<HTMLElement>(selector)
    if (element === null) {
        throw new Error(`The sidebar has no ${selector}`)
    }
    return element
}

function sidebarLinks(): HTMLElement[] {
    return Array.from(
        document.querySelectorAll<HTMLElement>(".sidebar-nav .nav-link")
    )
}

/**
 * Focuses each sidebar link in turn, as keyboard focus does, and records the
 * outline it then computes to.
 *
 * jsdom caches computed styles until the DOM changes, and focus changes no
 * DOM, so each link is read only after it has taken focus.
 */
function focusRingOfEachLink() {
    return sidebarLinks().map((link) => {
        act(() => {
            link.focus()
        })
        const style = window.getComputedStyle(link)
        return {
            id: link.id,
            focused: document.activeElement === link,
            focusVisible: link.matches(":focus-visible"),
            outline: style.getPropertyValue("outline"),
            outlineOffset: style.getPropertyValue("outline-offset"),
        }
    })
}

/** The computed sizing of the sidebar row and of each of its links. */
function sidebarRowLayout() {
    return {
        sidebarOverflowX: window
            .getComputedStyle(requiredElement(".sidebar"))
            .getPropertyValue("overflow-x"),
        listDirection: window
            .getComputedStyle(requiredElement(".sidebar-nav ul"))
            .getPropertyValue("flex-direction"),
        links: sidebarLinks().map((link) => {
            const item = link.closest("li")
            if (item === null) {
                throw new Error(`#${link.id} is not inside a list item`)
            }
            const linkStyle = window.getComputedStyle(link)
            return {
                id: link.id,
                itemFlexShrink: window
                    .getComputedStyle(item)
                    .getPropertyValue("flex-shrink"),
                whiteSpace: linkStyle.getPropertyValue("white-space"),
                scrollMarginInline: linkStyle.getPropertyValue(
                    "scroll-margin-inline"
                ),
            }
        }),
    }
}

function expectedFocusRings(
    linkIds: string[],
    ring: { outline: string; outlineOffset: string }
) {
    return linkIds.map((id) => ({
        id,
        focused: true,
        focusVisible: true,
        ...ring,
    }))
}

function expectedRowLayout(
    linkIds: string[],
    row: {
        sidebarOverflowX: string
        listDirection: string
        itemFlexShrink: string
        whiteSpace: string
        scrollMarginInline: string
    }
) {
    const { sidebarOverflowX, listDirection, ...linkLayout } = row
    return {
        sidebarOverflowX,
        listDirection,
        links: linkIds.map((id) => ({ id, ...linkLayout })),
    }
}

/** The mobile row of layout.css, which applies with the feature on or off. */
const LEGACY_MOBILE_ROW = { sidebarOverflowX: "auto", listDirection: "row" }

/** No feature sizing: what each link and list item computes to without it. */
const LEGACY_LINK_SIZING = {
    itemFlexShrink: "",
    whiteSpace: "",
    scrollMarginInline: "",
}

/** The feature's one-line, scrolling sizing of each link and list item. */
const FEATURE_LINK_SIZING = {
    itemFlexShrink: "0",
    whiteSpace: "nowrap",
    scrollMarginInline: "var(--space-2)",
}

it.each([
    {
        name: "flagOnAt375ShowsFeatureRing",
        enabled: true,
        viewportWidth: NARROW_VIEWPORT,
        expected: expectedFocusRings(FLAG_ON_LINK_IDS, FEATURE_FOCUS_RING),
    },
    {
        name: "flagOnAt1366ShowsFeatureRing",
        enabled: true,
        viewportWidth: WIDE_VIEWPORT,
        expected: expectedFocusRings(FLAG_ON_LINK_IDS, FEATURE_FOCUS_RING),
    },
    {
        name: "flagOffAt375KeepsDefaultRing",
        enabled: false,
        viewportWidth: NARROW_VIEWPORT,
        expected: expectedFocusRings(EXISTING_LINK_IDS, DEFAULT_FOCUS_RING),
    },
    {
        name: "flagOffAt1366KeepsDefaultRing",
        enabled: false,
        viewportWidth: WIDE_VIEWPORT,
        expected: expectedFocusRings(EXISTING_LINK_IDS, DEFAULT_FOCUS_RING),
    },
])(
    "sidebarFocusRing_keyboardFocus_$name",
    async ({ enabled, viewportWidth, expected }) => {
        await renderStyledNavigation(enabled, viewportWidth)

        expect(focusRingOfEachLink()).toEqual(expected)
    }
)

it.each([
    {
        name: "flagOnAt375AppliesMobileRow",
        enabled: true,
        viewportWidth: NARROW_VIEWPORT,
        expected: expectedRowLayout(FLAG_ON_LINK_IDS, {
            ...LEGACY_MOBILE_ROW,
            ...FEATURE_LINK_SIZING,
        }),
    },
    {
        name: "flagOnAt768AppliesMobileRow",
        enabled: true,
        viewportWidth: BREAKPOINT_VIEWPORT,
        expected: expectedRowLayout(FLAG_ON_LINK_IDS, {
            ...LEGACY_MOBILE_ROW,
            ...FEATURE_LINK_SIZING,
        }),
    },
    {
        name: "flagOnAt769KeepsDesktopColumn",
        enabled: true,
        viewportWidth: ABOVE_BREAKPOINT_VIEWPORT,
        expected: expectedRowLayout(FLAG_ON_LINK_IDS, {
            sidebarOverflowX: "",
            listDirection: "column",
            ...LEGACY_LINK_SIZING,
        }),
    },
    {
        name: "flagOffAt375KeepsLegacyRow",
        enabled: false,
        viewportWidth: NARROW_VIEWPORT,
        expected: expectedRowLayout(EXISTING_LINK_IDS, {
            ...LEGACY_MOBILE_ROW,
            ...LEGACY_LINK_SIZING,
        }),
    },
])(
    "sidebarMobileRow_viewport_$name",
    async ({ enabled, viewportWidth, expected }) => {
        await renderStyledNavigation(enabled, viewportWidth)

        expect(sidebarRowLayout()).toEqual(expected)
    }
)
