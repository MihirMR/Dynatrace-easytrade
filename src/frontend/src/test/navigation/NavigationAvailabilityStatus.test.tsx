import "@testing-library/jest-dom/vitest"
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

const AVAILABLE = "Portfolio Insights is now available in the navigation."
const UNAVAILABLE = "Portfolio Insights is no longer available."
/** How long the region stays once the removal message is written. */
const HOLD_MS = 4000

const LEGACY_LINKS = [
    { id: "nav-home", href: "/home", className: "nav-link active" },
    { id: "nav-instruments", href: "/instruments", className: "nav-link" },
    { id: "nav-deposit", href: "/deposit", className: "nav-link" },
    { id: "nav-withdraw", href: "/withdraw", className: "nav-link" },
    { id: "nav-credit-card", href: "/credit-card", className: "nav-link" },
]

const INSIGHTS_LINK = {
    id: "nav-portfolio-insights",
    href: "/insights",
    className: "nav-link",
}

type FlagService = {
    /**
     * Serves `enabled` to the flag read in flight, as the mount read is, or
     * to a new one, as a poll is, and renders the outcome inside `act`.
     */
    answer: (enabled: boolean, client: QueryClient) => Promise<void>
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

function renderNavigation(cached: boolean | undefined): QueryClient {
    // No garbage-collection timer, so the fake clock holds only the timers
    // that Navigation and a flag read in flight schedule.
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
                      followsLinkList: status.matches(".sidebar-nav > ul + p"),
                  },
    }
}

function expectedState(insightsLink: boolean, status: string | null) {
    return {
        links: insightsLink ? [...LEGACY_LINKS, INSIGHTS_LINK] : LEGACY_LINKS,
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

// Query notifications run synchronously, so every flag outcome renders, and
// its effects run, inside the `act` that answered the read.
beforeAll(() => {
    notifyManager.setScheduler((callback) => callback())
})

afterAll(() => {
    notifyManager.setScheduler(defaultScheduler)
})

// Animation frames and timeouts are faked: they time the message write and
// the hold of the region. The flag reads keep their real promises.
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

afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.restoreAllMocks()
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
    /** The status text once the hold has elapsed after those frames. */
    statusAfterHold: string | null
}

const availabilityCases: AvailabilityCase[] = [
    {
        name: "cachedOffReadOff_rendersNoStatus",
        cached: false,
        reads: [false],
        insightsLink: false,
        statusBeforeFrames: null,
        status: null,
        statusAfterHold: null,
    },
    {
        name: "uncachedReadOff_rendersNoStatus",
        cached: undefined,
        reads: [false],
        insightsLink: false,
        statusBeforeFrames: null,
        status: null,
        statusAfterHold: null,
    },
    {
        name: "uncachedReadOffPollOff_rendersNoStatus",
        cached: undefined,
        reads: [false, false],
        insightsLink: false,
        statusBeforeFrames: null,
        status: null,
        statusAfterHold: null,
    },
    {
        name: "cachedOnReadOn_rendersEmptyStatus",
        cached: true,
        reads: [true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: "",
        statusAfterHold: "",
    },
    {
        name: "uncachedReadOn_rendersEmptyStatus",
        cached: undefined,
        reads: [true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: "",
        statusAfterHold: "",
    },
    {
        name: "cachedOnReadOnPollOn_rendersEmptyStatus",
        cached: true,
        reads: [true, true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: "",
        statusAfterHold: "",
    },
    {
        name: "cachedOnReadOff_announcesRemovalThenRemovesStatus",
        cached: true,
        reads: [false],
        insightsLink: false,
        statusBeforeFrames: "",
        status: UNAVAILABLE,
        statusAfterHold: null,
    },
    {
        name: "cachedOnPollOff_announcesRemovalThenRemovesStatus",
        cached: true,
        reads: [true, false],
        insightsLink: false,
        statusBeforeFrames: "",
        status: UNAVAILABLE,
        statusAfterHold: null,
    },
    {
        name: "cachedOffPollOn_announcesAvailability",
        cached: false,
        reads: [false, true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: AVAILABLE,
        statusAfterHold: AVAILABLE,
    },
    {
        name: "uncachedReadOffPollOn_announcesAvailability",
        cached: undefined,
        reads: [false, true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: AVAILABLE,
        statusAfterHold: AVAILABLE,
    },
    {
        name: "cachedOnPollOffThenOn_clearsRemovalThenAnnouncesAvailability",
        cached: true,
        reads: [true, false, true],
        insightsLink: true,
        statusBeforeFrames: "",
        status: AVAILABLE,
        statusAfterHold: AVAILABLE,
    },
    {
        name: "cachedOffPollOnThenOff_announcesRemovalThenRemovesStatus",
        cached: false,
        reads: [false, true, false],
        insightsLink: false,
        statusBeforeFrames: "",
        status: UNAVAILABLE,
        statusAfterHold: null,
    },
    {
        name: "cachedOffPollOnTwice_keepsAvailabilityMessage",
        cached: false,
        reads: [false, true, true],
        insightsLink: true,
        statusBeforeFrames: AVAILABLE,
        status: AVAILABLE,
        statusAfterHold: AVAILABLE,
    },
    {
        name: "cachedOnPollOffTwice_keepsRemovalMessageThenRemovesStatus",
        cached: true,
        reads: [true, false, false],
        insightsLink: false,
        statusBeforeFrames: UNAVAILABLE,
        status: UNAVAILABLE,
        statusAfterHold: null,
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
        statusAfterHold,
    }) => {
        const service = stubFlagService()
        const client = renderNavigation(cached)

        for (const [index, enabled] of reads.entries()) {
            // Polls are seconds apart, so the message of an earlier read is
            // written before the next read.
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
        advanceTime(HOLD_MS)
        const afterHold = navigationState()

        expect({ afterRead, afterOneFrame, afterTwoFrames, afterHold }).toEqual(
            {
                afterRead: expectedState(insightsLink, statusBeforeFrames),
                afterOneFrame: expectedState(insightsLink, statusBeforeFrames),
                afterTwoFrames: expectedState(insightsLink, status),
                afterHold: expectedState(insightsLink, statusAfterHold),
            }
        )
    }
)

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

const mutationObservers = new Set<MutationObserver>()

afterEach(() => {
    mutationObservers.forEach((observer) => observer.disconnect())
    mutationObservers.clear()
})

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

it("navigationAvailabilityStatus_linkAppears_writesMessageFramesAfterInsertingRegion", async () => {
    const service = stubFlagService()
    const client = renderNavigation(false)
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
        linkAppeared: { regionInserted: true, textWritten: false, text: "" },
        firstFrame: { regionInserted: false, textWritten: false, text: "" },
        secondFrame: {
            regionInserted: false,
            textWritten: true,
            text: AVAILABLE,
        },
        final: expectedState(true, AVAILABLE),
    })
})

it.each([
    {
        name: "quickFlipBeforeFirstFrame_clearsThenRewritesAvailabilityMessage",
        framesBeforeFlip: 0,
    },
    {
        name: "quickFlipBetweenFrames_clearsThenRewritesAvailabilityMessage",
        framesBeforeFlip: 1,
    },
])("navigationAvailabilityStatus_$name", async ({ framesBeforeFlip }) => {
    const service = stubFlagService()
    const client = renderNavigation(false)
    await service.answer(false, client)
    await service.answer(true, client)
    runFrames(2)
    const status = screen.getByRole("status")
    const published = status.textContent
    const mutations = recordMutations()

    await service.answer(false, client)
    const disabled = regionMutations(mutations.takeStep(), status)
    runFrames(framesBeforeFlip)
    await service.answer(true, client)
    const reEnabled = regionMutations(mutations.takeStep(), status)
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
        sameRegion: screen.getByRole("status") === status,
        final: navigationState(),
        pendingTimers: vi.getTimerCount(),
    }).toEqual({
        published: AVAILABLE,
        disabled: { regionInserted: false, textWritten: false, text: "" },
        reEnabled: { regionInserted: false, textWritten: false, text: "" },
        firstFrame: { regionInserted: false, textWritten: false, text: "" },
        secondFrame: {
            regionInserted: false,
            textWritten: true,
            text: AVAILABLE,
        },
        sameRegion: true,
        final: expectedState(true, AVAILABLE),
        pendingTimers: 0,
    })
})

it.each([
    {
        name: "flipBackBeforeFirstFrame_writesOnlyRemovalMessage",
        framesBeforeFlip: 0,
    },
    {
        name: "flipBackBetweenFrames_writesOnlyRemovalMessage",
        framesBeforeFlip: 1,
    },
])("navigationAvailabilityStatus_$name", async ({ framesBeforeFlip }) => {
    const service = stubFlagService()
    const client = renderNavigation(false)
    await service.answer(false, client)
    await service.answer(true, client)
    runFrames(framesBeforeFlip)
    const status = screen.getByRole("status")

    await service.answer(false, client)
    const steps = [pendingWork(status)]
    for (let frame = 0; frame < 3; frame++) {
        runFrames(1)
        steps.push(pendingWork(status))
    }

    // Once the removal message is written, the one timer left is the hold.
    expect({ steps, final: navigationState() }).toEqual({
        steps: [
            { text: "", pendingTimers: 1 },
            { text: "", pendingTimers: 1 },
            { text: UNAVAILABLE, pendingTimers: 1 },
            { text: UNAVAILABLE, pendingTimers: 1 },
        ],
        final: expectedState(false, UNAVAILABLE),
    })
})

it.each([
    {
        name: "holdElapsedAfterLinkShownAtMount_matchesColdOffSidebar",
        cached: true,
        reads: [true],
    },
    {
        name: "holdElapsedAfterLinkShownByPoll_matchesColdOffSidebar",
        cached: false,
        reads: [false, true],
    },
])("navigationAvailabilityStatus_$name", async ({ cached, reads }) => {
    const service = stubFlagService()
    const coldClient = renderNavigation(false)
    await service.answer(false, coldClient)
    const coldOffSidebar = document.body.innerHTML
    cleanup()
    const client = renderNavigation(cached)
    for (const enabled of reads) {
        await service.answer(enabled, client)
        runFrames(2)
    }

    await service.answer(false, client)
    runFrames(2)
    advanceTime(HOLD_MS - 1)
    const holdEnding = navigationState()
    advanceTime(1)
    const holdElapsed = navigationState()

    expect({
        holdEnding,
        holdElapsed,
        sidebar: document.body.innerHTML,
        pendingTimers: vi.getTimerCount(),
    }).toEqual({
        holdEnding: expectedState(false, UNAVAILABLE),
        holdElapsed: expectedState(false, null),
        sidebar: coldOffSidebar,
        pendingTimers: 0,
    })
})

it.each([
    {
        name: "reEnableAtHoldStart_keepsRegionAndAnnouncesAvailability",
        msIntoHold: 0,
        keepsRegion: true,
    },
    {
        name: "reEnableDuringHold_keepsRegionAndAnnouncesAvailability",
        msIntoHold: HOLD_MS - 1,
        keepsRegion: true,
    },
    {
        name: "reEnableAfterHold_insertsEmptyRegionThenAnnouncesAvailability",
        msIntoHold: HOLD_MS,
        keepsRegion: false,
    },
])(
    "navigationAvailabilityStatus_$name",
    async ({ msIntoHold, keepsRegion }) => {
        const service = stubFlagService()
        const client = renderNavigation(true)
        await service.answer(true, client)
        await service.answer(false, client)
        runFrames(2)
        const heldRegion = screen.getByRole("status")
        advanceTime(msIntoHold)
        const mutations = recordMutations()

        await service.answer(true, client)
        const status = screen.getByRole("status")
        const reEnabled = {
            ...regionMutations(mutations.takeStep(), status),
            sameRegion: status === heldRegion,
        }
        runFrames(1)
        const firstFrame = regionMutations(mutations.takeStep(), status)
        runFrames(1)
        const secondFrame = regionMutations(mutations.takeStep(), status)
        // Well past the end of any hold that was not cancelled.
        advanceTime(2 * HOLD_MS)
        const later = {
            ...navigationState(),
            sameRegion: screen.getByRole("status") === status,
            pendingTimers: vi.getTimerCount(),
        }

        expect({ reEnabled, firstFrame, secondFrame, later }).toEqual({
            reEnabled: {
                regionInserted: !keepsRegion,
                textWritten: false,
                text: "",
                sameRegion: keepsRegion,
            },
            firstFrame: { regionInserted: false, textWritten: false, text: "" },
            secondFrame: {
                regionInserted: false,
                textWritten: true,
                text: AVAILABLE,
            },
            later: {
                ...expectedState(true, AVAILABLE),
                sameRegion: true,
                pendingTimers: 0,
            },
        })
    }
)

it.each([
    {
        name: "unmountBeforeFirstFrame_cancelsPendingWrite",
        cached: false,
        reads: [false, true],
        framesBeforeUnmount: 0,
        insightsLink: true,
        text: "",
    },
    {
        name: "unmountBetweenFrames_cancelsPendingWrite",
        cached: false,
        reads: [false, true],
        framesBeforeUnmount: 1,
        insightsLink: true,
        text: "",
    },
    {
        name: "unmountDuringHold_cancelsPendingHold",
        cached: true,
        reads: [true, false],
        framesBeforeUnmount: 2,
        insightsLink: false,
        text: UNAVAILABLE,
    },
])(
    "navigationAvailabilityStatus_$name",
    async ({ cached, reads, framesBeforeUnmount, insightsLink, text }) => {
        const service = stubFlagService()
        const client = renderNavigation(cached)
        for (const enabled of reads) {
            await service.answer(enabled, client)
        }
        runFrames(framesBeforeUnmount)
        const mounted = navigationState()
        const status = screen.getByRole("status")
        const beforeUnmount = pendingWork(status)

        cleanup()
        const afterUnmount = pendingWork(status)
        runFrames(2)
        advanceTime(HOLD_MS)
        const afterWaiting = pendingWork(status)

        expect({ mounted, beforeUnmount, afterUnmount, afterWaiting }).toEqual({
            mounted: expectedState(insightsLink, text),
            beforeUnmount: { text, pendingTimers: 1 },
            afterUnmount: { text, pendingTimers: 0 },
            afterWaiting: { text, pendingTimers: 0 },
        })
    }
)
