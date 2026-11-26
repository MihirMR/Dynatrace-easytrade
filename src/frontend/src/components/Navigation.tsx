import {
    type FocusEvent,
    type RefObject,
    useEffect,
    useLayoutEffect,
    useRef,
    useState,
} from "react"
import { NavLink } from "react-router"
import { useQueryClient } from "@tanstack/react-query"
import {
    HomeIcon,
    InstrumentsIcon,
    DepositIcon,
    WithdrawIcon,
    AddCardIcon,
    InsightsIcon,
} from "./icons"
import { usePortfolioInsightsFlag } from "../hooks/useFeatureFlags"
import { featureFlagKeys } from "../utils/queryKeys"

const INSIGHTS_AVAILABLE_MESSAGE =
    "Portfolio Insights is now available in the navigation."

/**
 * Text for a polite status region that tells screen-reader users when a flag
 * poll adds the Portfolio Insights link without any navigation, or `null`
 * while the region is not rendered.
 *
 * The first settled flag value of the mount, whether read now or already
 * cached, is the baseline and is not announced. Only a later appearance of
 * the link is, so a poll that returns the same value announces nothing.
 *
 * Assistive technology announces text inserted into a live region that is
 * already in the document. The browser hands it one accessibility update per
 * rendered frame, so text that reaches the document in the frame that
 * inserts the region, or that equals the text already there, is often not
 * announced. The region therefore follows this lifecycle:
 *
 * - It is rendered only while the link is shown. It enters empty in the same
 *   commit as the link and leaves in the same commit as the link, so with
 *   the feature off, whether it was never on or has just been disabled, the
 *   sidebar renders exactly what it rendered without the feature.
 * - When a later read shows the link, the text is cleared at once and the
 *   availability message is written two animation frames later, after a
 *   frame has rendered the empty region. A read that keeps the link shown
 *   keeps the text.
 * - When a read hides the link, the region leaves with it, a write still
 *   waiting is cancelled and the text resets to empty, so a later return of
 *   the link inserts the region empty again, as on its first appearance.
 * - A newer change or an unmount cancels a write still waiting, so a stale
 *   message is never written and nothing runs after the sidebar has gone.
 */
function useInsightsAvailabilityStatus(linkShown: boolean): string | null {
    const client = useQueryClient()
    // A pending first read and a settled `false` both hide the link; only the
    // settled one sets the baseline.
    const settled =
        client.getQueryData(featureFlagKeys.portfolioInsights) !== undefined
    // The link visibility last accounted for: the baseline, then each change.
    // `null` until the first read settles.
    const knownShown = useRef<boolean | null>(null)
    const [message, setMessage] = useState("")

    useEffect(() => {
        if (knownShown.current === null && settled) {
            knownShown.current = linkShown
        }
    }, [linkShown, settled])

    // Keyed on the link alone, so this effect, and the cleanup that cancels
    // its pending write, runs only when the link's visibility changes or the
    // sidebar unmounts.
    useEffect(() => {
        const previous = knownShown.current
        if (previous === null || previous === linkShown) {
            return
        }
        knownShown.current = linkShown
        setMessage("")
        if (!linkShown) {
            return
        }
        // The outer callback runs before the next frame renders the region as
        // it stands; the inner one runs a frame later and writes the message.
        let frame = requestAnimationFrame(() => {
            frame = requestAnimationFrame(() => {
                setMessage(INSIGHTS_AVAILABLE_MESSAGE)
            })
        })
        return () => {
            cancelAnimationFrame(frame)
        }
    }, [linkShown])

    return linkShown ? message : null
}

/**
 * Scrolls the Portfolio Insights link fully into view when it takes keyboard
 * focus.
 *
 * The browser leaves a partly visible element where it is when it takes
 * keyboard focus, so the horizontally scrolling mobile row would show only a
 * sliver of the focused link. Pointer focus is left alone, so a click never
 * scrolls the link out from under the pointer. It is attached only to the
 * Portfolio Insights link, so the five existing links keep their original
 * focus behaviour with the feature on and off.
 */
function revealKeyboardFocusedLink(event: FocusEvent<HTMLAnchorElement>) {
    const link = event.currentTarget
    if (link.matches(":focus-visible")) {
        link.scrollIntoView({ block: "nearest", inline: "nearest" })
    }
}

/**
 * The sixth sidebar entry, rendered only while the Portfolio Insights flag is
 * on.
 *
 * When the feature turns off while the link has keyboard focus, focus moves
 * to the preceding sidebar link instead of dropping to the document body.
 * Focus held anywhere else is left untouched, and so is focus on the link
 * when the whole sidebar unmounts, because no sidebar link survives to take
 * it.
 */
function PortfolioInsightsNavItem({
    sidebarUnmounting,
}: {
    /** `true` once the `Navigation` that renders this item is unmounting. */
    sidebarUnmounting: RefObject<boolean>
}) {
    const linkRef = useRef<HTMLAnchorElement>(null)

    // React runs a removed component's layout-effect cleanup before it takes
    // the component's elements out of the document, so the link is still
    // connected, and still focused, when this cleanup runs.
    useLayoutEffect(() => {
        const link = linkRef.current
        return () => {
            if (sidebarUnmounting.current) {
                return
            }
            if (link === null || document.activeElement !== link) {
                return
            }
            const previousItem = link.closest("li")?.previousElementSibling
            previousItem?.querySelector<HTMLAnchorElement>("a")?.focus()
        }
    }, [sidebarUnmounting])

    return (
        <li>
            <NavLink
                ref={linkRef}
                id="nav-portfolio-insights"
                to="/insights"
                className={({ isActive }) =>
                    "nav-link" + (isActive ? " active" : "")
                }
                onFocus={revealKeyboardFocusedLink}
            >
                <InsightsIcon />
                Portfolio Insights
            </NavLink>
        </li>
    )
}

export default function Navigation() {
    // Observed on every protected route, so the flag keeps revalidating and a
    // disable shuts the feature down wherever the user is.
    const portfolioInsightsEnabled = usePortfolioInsightsFlag()
    const availabilityStatus = useInsightsAvailabilityStatus(
        portfolioInsightsEnabled
    )
    // Tells the Portfolio Insights item whether it leaves with the whole
    // sidebar or alone, as on a disable. React runs a deleted component's
    // layout-effect cleanups before those of its descendants, so when the
    // sidebar unmounts this cleanup sets the flag before the item's cleanup
    // reads it. When only the item leaves, this component stays mounted and
    // the flag stays `false`. Each mount resets it, because a development
    // remount or a revealed Suspense boundary runs this effect again.
    const sidebarUnmounting = useRef(false)
    useLayoutEffect(() => {
        sidebarUnmounting.current = false
        return () => {
            sidebarUnmounting.current = true
        }
    }, [])

    return (
        <nav className="sidebar">
            <div className="sidebar-nav">
                <ul>
                    <li>
                        <NavLink
                            id="nav-home"
                            to="/home"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <HomeIcon />
                            Home
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-instruments"
                            to="/instruments"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <InstrumentsIcon />
                            Instruments
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-deposit"
                            to="/deposit"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <DepositIcon />
                            Deposit
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-withdraw"
                            to="/withdraw"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <WithdrawIcon />
                            Withdraw
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-credit-card"
                            to="/credit-card"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <AddCardIcon />
                            Credit Card
                        </NavLink>
                    </li>
                    {portfolioInsightsEnabled && (
                        <PortfolioInsightsNavItem
                            sidebarUnmounting={sidebarUnmounting}
                        />
                    )}
                </ul>
                {availabilityStatus !== null && (
                    <p className="sr-only" role="status" aria-live="polite">
                        {availabilityStatus}
                    </p>
                )}
            </div>
        </nav>
    )
}
