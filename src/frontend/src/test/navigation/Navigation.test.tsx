import { act, cleanup, render, screen } from "@testing-library/react"
import {
    QueryClient,
    QueryClientProvider,
    defaultScheduler,
    notifyManager,
} from "@tanstack/react-query"
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

// Query notifications run synchronously, so a flag change renders, and its
// effects run, inside the `act` that made it.
beforeAll(() => {
    notifyManager.setScheduler((callback) => callback())
})

afterAll(() => {
    notifyManager.setScheduler(defaultScheduler)
})

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
 * Renders the sidebar on `/home` with the Portfolio Insights flag cached as
 * `cached`, or with no cached value when it is `undefined`.
 */
function mountNavigation(cached: boolean | undefined): QueryClient {
    // No garbage-collection timer, so a fake clock holds only the timers that
    // Navigation and a flag read in flight schedule, and the next flag poll
    // while Navigation is mounted.
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false, gcTime: Infinity } },
    })
    if (cached !== undefined) {
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, cached)
    }
    render(
        <QueryClientProvider client={client}>
            <MemoryRouter initialEntries={["/home"]}>
                <Navigation />
            </MemoryRouter>
        </QueryClientProvider>
    )
    return client
}

/**
 * Renders the sidebar on `/home` with the Portfolio Insights flag seeded as
 * `enabled` and the flag service answering the same value.
 */
async function renderNavigation(enabled: boolean): Promise<QueryClient> {
    vi.spyOn(window, "fetch").mockImplementation(() =>
        Promise.resolve(flagResponse(enabled))
    )
    const client = mountNavigation(enabled)
    // The mount read is answered at once; awaiting it leaves no read in
    // flight when the test ends.
    await act(async () => {
        await client.refetchQueries(
            { queryKey: featureFlagKeys.portfolioInsights },
            { cancelRefetch: false }
        )
    })
    return client
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

/**
 * The markup of the sidebar list element and of the five existing entries,
 * exactly as rendered.
 */
function existingLinkMarkup() {
    const list = document.querySelector(".sidebar-nav > ul")
    if (list === null) {
        throw new Error("The sidebar has no link list")
    }
    return {
        listAttributes: list.getAttributeNames(),
        items: Array.from(list.children)
            .slice(0, EXISTING_LINKS.length)
            .map((item) => item.outerHTML),
    }
}

it("navigation_flagEnabled_keepsExistingLinkMarkup", async () => {
    await renderNavigation(false)
    const flagOff = existingLinkMarkup()
    cleanup()

    await renderNavigation(true)

    expect(existingLinkMarkup()).toEqual({
        listAttributes: [],
        items: flagOff.items,
    })
})

it.each([
    {
        name: "flagOnKeyboardFocusOnExistingLink_doesNotScroll",
        enabled: true,
        linkId: "nav-withdraw",
        focusVisible: true,
        scrolls: false,
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

/** The id of the focused element, or `"body"` when nothing has focus. */
function focusedElementName(): string | undefined {
    return document.activeElement === document.body
        ? "body"
        : document.activeElement?.id
}

it.each([
    {
        name: "insightsLinkFocused_movesFocusToPrecedingLink",
        focusedId: INSIGHTS_LINK_ID,
        expectedFocus: "nav-credit-card",
    },
    {
        name: "existingLinkFocused_keepsFocus",
        focusedId: "nav-deposit",
        expectedFocus: "nav-deposit",
    },
    {
        name: "nothingFocused_leavesFocusOnBody",
        focusedId: null,
        expectedFocus: "body",
    },
])("navigation_liveDisable_$name", async ({ focusedId, expectedFocus }) => {
    installScrollIntoView()
    const client = await renderNavigation(true)
    if (focusedId !== null) {
        const link = sidebarLink(focusedId)
        act(() => {
            link.focus()
        })
    }

    // A disable seen by a poll, a focus read or a 403 sets the shared flag
    // query to `false` while the sidebar stays mounted.
    act(() => {
        client.setQueryData<boolean>(featureFlagKeys.portfolioInsights, false)
    })

    expect({
        insightsLink: document.getElementById(INSIGHTS_LINK_ID),
        focused: focusedElementName(),
    }).toEqual({ insightsLink: null, focused: expectedFocus })
})

it("navigation_sidebarUnmountWhileInsightsLinkFocused_doesNotMoveFocus", async () => {
    installScrollIntoView()
    await renderNavigation(true)
    const insightsLink = sidebarLink(INSIGHTS_LINK_ID)
    act(() => {
        insightsLink.focus()
    })
    const creditCardFocus = vi.spyOn(sidebarLink("nav-credit-card"), "focus")

    // Leaving the protected routes unmounts the whole sidebar, the focused
    // link with it, so no sidebar link is left to take focus.
    cleanup()

    expect(creditCardFocus).not.toHaveBeenCalled()
})

describe("navigationAvailabilityStatus", () => {
    const AVAILABLE = "Portfolio Insights is now available in the navigation."
    /**
     * Well past the two frames of any message write, and short of the next
     * poll.
     */
    const LATER_MS = 10_000
    /** The next flag poll, armed 15 s after each read starts while observed. */
    const FLAG_POLL_TIMER = 1

    /** The five existing links as rendered on `/home`, where Home is active. */
    const LEGACY_LINKS = EXISTING_LINKS.map(({ id, href }) => ({
        id,
        href,
        className: id === "nav-home" ? "nav-link active" : "nav-link",
    }))

    const INSIGHTS_LINK = {
        id: INSIGHTS_LINK_ID,
        href: "/insights",
        className: "nav-link",
    }

    type FlagService = {
        /**
         * Serves `enabled` to the flag read in flight, as the mount read is,
         * or to a new one, as a poll is, and renders the outcome inside
         * `act`.
         */
        answer: (enabled: boolean, client: QueryClient) => Promise<void>
    }

    /** A flag service whose reads wait until the test answers them. */
    function stubFlagService(): FlagService {
        let enabled = false
        let open = false
        const waiting: (() => void)[] = []
        vi.spyOn(window, "fetch").mockImplementation(
            () =>
                new Promise<Response>((resolve) => {
                    const respond = (): void => resolve(flagResponse(enabled))
                    if (open) {
                        respond()
                    } else {
                        waiting.push(respond)
                    }
                })
        )
        return {
            answer: async (value, client) => {
                enabled = value
                await act(async () => {
                    open = true
                    waiting.splice(0).forEach((respond) => respond())
                    await client.refetchQueries(
                        { queryKey: featureFlagKeys.portfolioInsights },
                        { cancelRefetch: false }
                    )
                    open = false
                })
            },
        }
    }

    function navigationState() {
        const status = screen.queryByRole("status")
        return {
            links: screen.getAllByRole("link").map((link) => ({
                id: link.id,
                href: link.getAttribute("href"),
                className: link.className,
            })),
            status:
                status === null
                    ? null
                    : {
                          text: status.textContent,
                          ariaLive: status.getAttribute("aria-live"),
                          className: status.className,
                          followsLinkList: status.matches(
                              ".sidebar-nav > ul + p"
                          ),
                      },
        }
    }

    function expectedState(insightsLink: boolean, status: string | null) {
        return {
            links: insightsLink
                ? [...LEGACY_LINKS, INSIGHTS_LINK]
                : LEGACY_LINKS,
            status:
                status === null
                    ? null
                    : {
                          text: status,
                          ariaLive: "polite",
                          className: "sr-only",
                          followsLinkList: true,
                      },
        }
    }

    /** Runs the next `count` animation frames and renders what they write. */
    function runFrames(count: number): void {
        for (let frame = 0; frame < count; frame++) {
            act(() => {
                vi.advanceTimersToNextFrame()
            })
        }
    }

    /** Moves the clock on by `ms` and renders what the timers due by then do. */
    function advanceTime(ms: number): void {
        act(() => {
            vi.advanceTimersByTime(ms)
        })
    }

    /** The status text and the frames and timeouts still waiting to run. */
    function pendingWork(status: HTMLElement) {
        return { text: status.textContent, pendingTimers: vi.getTimerCount() }
    }

    /**
     * The text of the status region in the document, `null` when there is
     * none, and the frames and timeouts still waiting to run.
     */
    function statusWork() {
        return {
            status: screen.queryByRole("status")?.textContent ?? null,
            pendingTimers: vi.getTimerCount(),
        }
    }

    const mutationObservers = new Set<MutationObserver>()

    /** Records the document's mutations from now on, one test step at a time. */
    function recordMutations() {
        const delivered: MutationRecord[] = []
        const observer = new MutationObserver((records) => {
            delivered.push(...records)
        })
        observer.observe(document.body, {
            childList: true,
            subtree: true,
            characterData: true,
        })
        mutationObservers.add(observer)
        return {
            /** Those delivered since the last step, then those still queued. */
            takeStep: (): MutationRecord[] => [
                ...delivered.splice(0),
                ...observer.takeRecords(),
            ],
        }
    }

    /** What the mutations of one step did to the status region. */
    function regionMutations(records: MutationRecord[], status: HTMLElement) {
        return {
            regionInserted: records.some((record) =>
                Array.from(record.addedNodes).includes(status)
            ),
            textWritten: records.some(
                (record) =>
                    (record.target === status &&
                        Array.from(record.addedNodes).some(
                            (node) => node.nodeType === Node.TEXT_NODE
                        )) ||
                    (record.type === "characterData" &&
                        record.target.parentNode === status)
            ),
            text: status.textContent,
        }
    }

    // Animation frames and timeouts are faked: they time the message write
    // and the next flag poll. The flag reads keep their real promises.
    beforeEach(() => {
        vi.useFakeTimers({
            toFake: [
                "requestAnimationFrame",
                "cancelAnimationFrame",
                "setTimeout",
                "clearTimeout",
            ],
        })
    })

    // The sidebar unmounts while the clock is still fake, so its cleanup
    // cancels the frames that clock holds.
    afterEach(() => {
        mutationObservers.forEach((observer) => observer.disconnect())
        mutationObservers.clear()
        cleanup()
        vi.useRealTimers()
    })

    type AvailabilityCase = {
        /** The title's scenario and expected result. */
        name: string
        /** The flag value cached when `Navigation` mounts; `undefined` is none. */
        cached: boolean | undefined
        /** The value of each flag read: the mount read, then each poll. */
        reads: boolean[]
        insightsLink: boolean
        /** The status text right after the last read, before any frame runs. */
        statusBeforeFrames: string | null
        /** The status text once two animation frames have run. */
        status: string | null
        /** The status text once `LATER_MS` has passed after those frames. */
        statusLater: string | null
    }

    const availabilityCases: AvailabilityCase[] = [
        {
            name: "cachedOffReadOff_rendersNoStatus",
            cached: false,
            reads: [false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "uncachedReadOff_rendersNoStatus",
            cached: undefined,
            reads: [false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "uncachedReadOffPollOff_rendersNoStatus",
            cached: undefined,
            reads: [false, false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "cachedOnReadOn_rendersEmptyStatus",
            cached: true,
            reads: [true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: "",
            statusLater: "",
        },
        {
            name: "uncachedReadOn_rendersEmptyStatus",
            cached: undefined,
            reads: [true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: "",
            statusLater: "",
        },
        {
            name: "cachedOnReadOnPollOn_rendersEmptyStatus",
            cached: true,
            reads: [true, true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: "",
            statusLater: "",
        },
        {
            name: "cachedOnReadOff_removesStatusWithLink",
            cached: true,
            reads: [false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "cachedOnPollOff_removesStatusWithLink",
            cached: true,
            reads: [true, false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "cachedOffPollOn_announcesAvailability",
            cached: false,
            reads: [false, true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: AVAILABLE,
            statusLater: AVAILABLE,
        },
        {
            name: "uncachedReadOffPollOn_announcesAvailability",
            cached: undefined,
            reads: [false, true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: AVAILABLE,
            statusLater: AVAILABLE,
        },
        {
            name: "cachedOnPollOffThenOn_reinsertsEmptyStatusThenAnnouncesAvailability",
            cached: true,
            reads: [true, false, true],
            insightsLink: true,
            statusBeforeFrames: "",
            status: AVAILABLE,
            statusLater: AVAILABLE,
        },
        {
            name: "cachedOffPollOnThenOff_removesStatusWithLink",
            cached: false,
            reads: [false, true, false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
        {
            name: "cachedOffPollOnTwice_keepsAvailabilityMessage",
            cached: false,
            reads: [false, true, true],
            insightsLink: true,
            statusBeforeFrames: AVAILABLE,
            status: AVAILABLE,
            statusLater: AVAILABLE,
        },
        {
            name: "cachedOnPollOffTwice_rendersNoStatus",
            cached: true,
            reads: [true, false, false],
            insightsLink: false,
            statusBeforeFrames: null,
            status: null,
            statusLater: null,
        },
    ]

    it.each(availabilityCases)(
        "navigationAvailabilityStatus_$name",
        async ({
            cached,
            reads,
            insightsLink,
            statusBeforeFrames,
            status,
            statusLater,
        }) => {
            const service = stubFlagService()
            const client = mountNavigation(cached)

            for (const [index, enabled] of reads.entries()) {
                // Polls are seconds apart, so the message of an earlier read
                // is written before the next read.
                if (index > 0) {
                    runFrames(2)
                }
                await service.answer(enabled, client)
            }
            const afterRead = navigationState()
            runFrames(1)
            const afterOneFrame = navigationState()
            runFrames(1)
            const afterTwoFrames = navigationState()
            advanceTime(LATER_MS)
            const later = navigationState()

            expect({ afterRead, afterOneFrame, afterTwoFrames, later }).toEqual(
                {
                    afterRead: expectedState(insightsLink, statusBeforeFrames),
                    afterOneFrame: expectedState(
                        insightsLink,
                        statusBeforeFrames
                    ),
                    afterTwoFrames: expectedState(insightsLink, status),
                    later: expectedState(insightsLink, statusLater),
                }
            )
        }
    )

    it("navigationAvailabilityStatus_linkAppears_writesMessageFramesAfterInsertingRegion", async () => {
        const service = stubFlagService()
        const client = mountNavigation(false)
        await service.answer(false, client)
        const mutations = recordMutations()

        await service.answer(true, client)
        const status = screen.getByRole("status")
        const linkAppeared = regionMutations(mutations.takeStep(), status)
        runFrames(1)
        const firstFrame = regionMutations(mutations.takeStep(), status)
        runFrames(1)
        const secondFrame = regionMutations(mutations.takeStep(), status)

        expect({
            linkAppeared,
            firstFrame,
            secondFrame,
            final: navigationState(),
        }).toEqual({
            linkAppeared: {
                regionInserted: true,
                textWritten: false,
                text: "",
            },
            firstFrame: { regionInserted: false, textWritten: false, text: "" },
            secondFrame: {
                regionInserted: false,
                textWritten: true,
                text: AVAILABLE,
            },
            final: expectedState(true, AVAILABLE),
        })
    })

    it("navigationAvailabilityStatus_pollOffThenOn_insertsNewEmptyRegionThenAnnouncesAvailability", async () => {
        const service = stubFlagService()
        const client = mountNavigation(false)
        await service.answer(false, client)
        await service.answer(true, client)
        runFrames(2)
        const publishedRegion = screen.getByRole("status")
        const published = publishedRegion.textContent

        await service.answer(false, client)
        const disabled = {
            ...navigationState(),
            pendingTimers: vi.getTimerCount(),
        }
        const mutations = recordMutations()
        await service.answer(true, client)
        const status = screen.getByRole("status")
        const reEnabled = {
            ...regionMutations(mutations.takeStep(), status),
            sameRegion: status === publishedRegion,
        }
        runFrames(1)
        const firstFrame = regionMutations(mutations.takeStep(), status)
        runFrames(1)
        const secondFrame = regionMutations(mutations.takeStep(), status)

        expect({
            published,
            disabled,
            reEnabled,
            firstFrame,
            secondFrame,
            final: navigationState(),
            pendingTimers: vi.getTimerCount(),
        }).toEqual({
            published: AVAILABLE,
            disabled: {
                ...expectedState(false, null),
                pendingTimers: FLAG_POLL_TIMER,
            },
            reEnabled: {
                regionInserted: true,
                textWritten: false,
                text: "",
                sameRegion: false,
            },
            firstFrame: { regionInserted: false, textWritten: false, text: "" },
            secondFrame: {
                regionInserted: false,
                textWritten: true,
                text: AVAILABLE,
            },
            final: expectedState(true, AVAILABLE),
            pendingTimers: FLAG_POLL_TIMER,
        })
    })

    it.each([
        {
            name: "flipBackBeforeFirstFrame_cancelsPendingWriteAndRemovesStatus",
            framesBeforeFlip: 0,
        },
        {
            name: "flipBackBetweenFrames_cancelsPendingWriteAndRemovesStatus",
            framesBeforeFlip: 1,
        },
    ])("navigationAvailabilityStatus_$name", async ({ framesBeforeFlip }) => {
        const service = stubFlagService()
        const client = mountNavigation(false)
        await service.answer(false, client)
        await service.answer(true, client)
        runFrames(framesBeforeFlip)
        const pending = pendingWork(screen.getByRole("status"))

        await service.answer(false, client)
        const steps = [statusWork()]
        for (let frame = 0; frame < 3; frame++) {
            runFrames(1)
            steps.push(statusWork())
        }

        // The availability write was waiting on a frame; once the link
        // leaves, the one timer left is the next flag poll and nothing is
        // written.
        expect({ pending, steps, final: navigationState() }).toEqual({
            pending: { text: "", pendingTimers: 1 + FLAG_POLL_TIMER },
            steps: [
                { status: null, pendingTimers: FLAG_POLL_TIMER },
                { status: null, pendingTimers: FLAG_POLL_TIMER },
                { status: null, pendingTimers: FLAG_POLL_TIMER },
                { status: null, pendingTimers: FLAG_POLL_TIMER },
            ],
            final: expectedState(false, null),
        })
    })

    it.each([
        {
            name: "liveDisableAfterLinkShownAtMount_matchesColdOffSidebar",
            cached: true,
            reads: [true],
        },
        {
            name: "liveDisableAfterLinkShownByPoll_matchesColdOffSidebar",
            cached: false,
            reads: [false, true],
        },
    ])("navigationAvailabilityStatus_$name", async ({ cached, reads }) => {
        const service = stubFlagService()
        const coldClient = mountNavigation(false)
        await service.answer(false, coldClient)
        const coldOffSidebar = document.body.innerHTML
        cleanup()
        const client = mountNavigation(cached)
        for (const enabled of reads) {
            await service.answer(enabled, client)
            runFrames(2)
        }

        // No frame runs and no time passes after the read that turns it off.
        await service.answer(false, client)

        expect({
            sidebar: document.body.innerHTML,
            pendingTimers: vi.getTimerCount(),
        }).toEqual({
            sidebar: coldOffSidebar,
            pendingTimers: FLAG_POLL_TIMER,
        })
    })

    it.each([
        {
            name: "unmountBeforeFirstFrame_cancelsPendingWrite",
            framesBeforeUnmount: 0,
        },
        {
            name: "unmountBetweenFrames_cancelsPendingWrite",
            framesBeforeUnmount: 1,
        },
    ])(
        "navigationAvailabilityStatus_$name",
        async ({ framesBeforeUnmount }) => {
            const service = stubFlagService()
            const client = mountNavigation(false)
            await service.answer(false, client)
            await service.answer(true, client)
            runFrames(framesBeforeUnmount)
            const mounted = navigationState()
            const status = screen.getByRole("status")
            const beforeUnmount = pendingWork(status)

            cleanup()
            const afterUnmount = pendingWork(status)
            runFrames(2)
            const afterWaiting = pendingWork(status)

            expect({
                mounted,
                beforeUnmount,
                afterUnmount,
                afterWaiting,
            }).toEqual({
                mounted: expectedState(true, ""),
                beforeUnmount: { text: "", pendingTimers: 1 + FLAG_POLL_TIMER },
                afterUnmount: { text: "", pendingTimers: 0 },
                afterWaiting: { text: "", pendingTimers: 0 },
            })
        }
    )
})
