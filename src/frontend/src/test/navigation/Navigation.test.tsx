import { act, cleanup, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router"
import Navigation from "../../components/Navigation"
import { PortfolioInsightsFlagId } from "../../api/featureFlags"
import { featureFlagKeys } from "../../utils/queryKeys"

type ScrollIntoView = (
    this: Element,
    arg?: boolean | ScrollIntoViewOptions
) => void

/** The five sidebar links that exist without the feature, in their order. */
const EXISTING_LINKS = [
    { id: "nav-home", href: "/home", text: "Home", navLink: true },
    {
        id: "nav-instruments",
        href: "/instruments",
        text: "Instruments",
        navLink: true,
    },
    { id: "nav-deposit", href: "/deposit", text: "Deposit", navLink: true },
    { id: "nav-withdraw", href: "/withdraw", text: "Withdraw", navLink: true },
    {
        id: "nav-credit-card",
        href: "/credit-card",
        text: "Credit Card",
        navLink: true,
    },
]

const INSIGHTS_LINK_ID = "nav-portfolio-insights"

/** jsdom has no `scrollIntoView`, so each test installs one and removes it. */
const scrollIntoViewDescriptor = Object.getOwnPropertyDescriptor(
    Element.prototype,
    "scrollIntoView"
)

afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
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

/** Records every `scrollIntoView` call with the element it was called on. */
function installScrollIntoView() {
    const scrollIntoView = vi.fn<ScrollIntoView>()
    Object.defineProperty(Element.prototype, "scrollIntoView", {
        configurable: true,
        writable: true,
        value: scrollIntoView,
    })
    return scrollIntoView
}

/**
 * Makes `:focus-visible` match `link`, as it does under keyboard focus, or
 * not, as under pointer focus. Every other selector is matched as usual.
 */
function stubFocusVisible(link: Element, focusVisible: boolean): void {
    vi.spyOn(link, "matches").mockImplementation((selectors) =>
        selectors === ":focus-visible"
            ? focusVisible
            : Element.prototype.matches.call(link, selectors)
    )
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
 * Renders the sidebar on `/home` with the Portfolio Insights flag seeded as
 * `enabled` and the flag service answering the same value.
 */
async function renderNavigation(enabled: boolean): Promise<void> {
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

function sidebarLink(id: string): HTMLElement {
    const link = document.getElementById(id)
    if (link === null) {
        throw new Error(`The sidebar has no link #${id}`)
    }
    return link
}

/** The Portfolio Insights link as rendered, or `null` when it is absent. */
function insightsLinkState() {
    const link = document.getElementById(INSIGHTS_LINK_ID)
    if (link === null) {
        return null
    }
    const links = screen.getAllByRole("link")
    return {
        href: link.getAttribute("href"),
        className: link.className,
        text: link.textContent,
        isLastLink: links[links.length - 1] === link,
    }
}

it.each([
    {
        name: "flagDisabled_hidesInsightsLink",
        enabled: false,
        expected: null,
    },
    {
        name: "flagEnabled_showsInsightsLink",
        enabled: true,
        expected: {
            href: "/insights",
            className: "nav-link",
            text: "Portfolio Insights",
            isLastLink: true,
        },
    },
])("navigation_$name", async ({ enabled, expected }) => {
    await renderNavigation(enabled)

    expect(insightsLinkState()).toEqual(expected)
})

it("navigation_flagDisabled_keepsExistingLinks", async () => {
    await renderNavigation(false)

    expect({
        links: screen.getAllByRole("link").map((link) => ({
            id: link.id,
            href: link.getAttribute("href"),
            text: link.textContent,
            navLink: link.classList.contains("nav-link"),
        })),
        insightsLink: document.getElementById(INSIGHTS_LINK_ID),
    }).toEqual({ links: EXISTING_LINKS, insightsLink: null })
})

it.each([
    {
        name: "flagOnKeyboardFocusOnExistingLink_scrollsLinkIntoView",
        enabled: true,
        linkId: "nav-withdraw",
        focusVisible: true,
        scrolls: true,
    },
    {
        name: "flagOnPointerFocusOnExistingLink_doesNotScroll",
        enabled: true,
        linkId: "nav-withdraw",
        focusVisible: false,
        scrolls: false,
    },
    {
        name: "flagOnKeyboardFocusOnInsightsLink_scrollsLinkIntoView",
        enabled: true,
        linkId: INSIGHTS_LINK_ID,
        focusVisible: true,
        scrolls: true,
    },
    {
        name: "flagOnPointerFocusOnInsightsLink_doesNotScroll",
        enabled: true,
        linkId: INSIGHTS_LINK_ID,
        focusVisible: false,
        scrolls: false,
    },
    {
        name: "flagOffKeyboardFocusOnExistingLink_doesNotScroll",
        enabled: false,
        linkId: "nav-withdraw",
        focusVisible: true,
        scrolls: false,
    },
])(
    "revealKeyboardFocusedLink_$name",
    async ({ enabled, linkId, focusVisible, scrolls }) => {
        const scrollIntoView = installScrollIntoView()
        await renderNavigation(enabled)
        const link = sidebarLink(linkId)
        stubFocusVisible(link, focusVisible)

        act(() => {
            link.focus()
        })

        expect({
            focused: document.activeElement?.id,
            scrolled: scrollIntoView.mock.contexts.map((element) => element.id),
            options: scrollIntoView.mock.calls,
        }).toEqual({
            focused: linkId,
            scrolled: scrolls ? [linkId] : [],
            options: scrolls ? [[{ block: "nearest", inline: "nearest" }]] : [],
        })
    }
)
