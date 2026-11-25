import { type FocusEvent, useEffect, useRef, useState } from "react"
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
const INSIGHTS_UNAVAILABLE_MESSAGE =
    "Portfolio Insights is no longer available."

/**
 * How long the status region stays in the document once the removal message
 * is written. It matches the 4 s lifetime of the app's other polite
 * announcements, the Toasts that `ToastProvider` dismisses after 4 s, which
 * gives assistive technology time to read the message before the region
 * leaves.
 */
const STATUS_HOLD_MS = 4000

/**
 * Text for a polite status region that tells screen-reader users when a flag
 * poll adds or removes the Portfolio Insights link without any navigation,
 * or `null` while the region is not rendered.
 *
 * The first settled flag value of the mount, whether read now or already
 * cached, is the baseline and is not announced. Only a later change of the
 * link's visibility is, so a poll that returns the same value announces
 * nothing.
 *
 * Assistive technology announces text inserted into a live region that is
 * already in the document. The browser hands it one accessibility update per
 * rendered frame, so text that reaches the document in the frame that
 * inserts the region, or that equals the text already there, is often not
 * announced. The region therefore follows this lifecycle:
 *
 * - It is rendered only while the link is shown or its removal is being
 *   announced. A sidebar whose feature is off, whether it was never on or
 *   has settled off, renders exactly what it rendered without the feature.
 * - It first appears empty, in the same commit as the link.
 * - Each change of the link's visibility clears the text at once and writes
 *   its message two animation frames later, after a frame has rendered the
 *   empty region. Every message is then a fresh insertion, and a superseded
 *   message never stays in the region.
 * - Once the removal message is written, the region stays for
 *   `STATUS_HOLD_MS`, then leaves the document and its text resets to empty.
 *   A return of the link during that time keeps the region, which announces
 *   the return; a return after it inserts the region empty again, as on its
 *   first appearance.
 * - A newer change cancels a write or a hold still waiting, and an unmount
 *   cancels both, so a stale message is never written and nothing runs after
 *   the sidebar has gone.
 */
function useInsightsAvailabilityStatus(linkShown: boolean): string | null {
    const client = useQueryClient()
    // A pending first read and a settled `false` both hide the link; only the
    // settled one sets the baseline.
    const settled =
        client.getQueryData(featureFlagKeys.portfolioInsights) !== undefined
    // The link visibility last accounted for: the baseline, then each change
    // whose message is written or waiting. `null` until the first read
    // settles.
    const knownShown = useRef<boolean | null>(null)
    const [regionMounted, setRegionMounted] = useState(false)
    const [message, setMessage] = useState("")

    useEffect(() => {
        if (linkShown) {
            setRegionMounted(true)
        }
        if (knownShown.current === null && settled) {
            knownShown.current = linkShown
        }
    }, [linkShown, settled])

    // Keyed on the link alone, so this effect, and the cleanup that cancels
    // its pending write or hold, runs only when the link's visibility changes
    // or the sidebar unmounts.
    useEffect(() => {
        const previous = knownShown.current
        if (previous === null || previous === linkShown) {
            return
        }
        knownShown.current = linkShown
        const next = linkShown
            ? INSIGHTS_AVAILABLE_MESSAGE
            : INSIGHTS_UNAVAILABLE_MESSAGE
        setMessage("")
        let hold: ReturnType<typeof setTimeout> | undefined
        // The outer callback runs before the next frame renders the region as
        // it stands; the inner one runs a frame later and writes the message.
        let frame = requestAnimationFrame(() => {
            frame = requestAnimationFrame(() => {
                setMessage(next)
                if (!linkShown) {
                    hold = setTimeout(() => {
                        setRegionMounted(false)
                        setMessage("")
                    }, STATUS_HOLD_MS)
                }
            })
        })
        return () => {
            cancelAnimationFrame(frame)
            clearTimeout(hold)
        }
    }, [linkShown])

    return regionMounted || linkShown ? message : null
}

/**
 * Scrolls a sidebar link that takes keyboard focus fully into view.
 *
 * The browser leaves a partly visible element where it is when it takes
 * keyboard focus, so the horizontally scrolling mobile row would show only a
 * sliver of the focused link. Pointer focus is left alone, so a click never
 * scrolls the link out from under the pointer. It is attached only while the
 * Portfolio Insights link is shown, so with the feature off the sidebar keeps
 * its original focus behaviour.
 */
function revealKeyboardFocusedLink(event: FocusEvent<HTMLUListElement>) {
    const link = event.target
    if (link instanceof HTMLElement && link.matches(":focus-visible")) {
        link.scrollIntoView({ block: "nearest", inline: "nearest" })
    }
}

export default function Navigation() {
    // Observed on every protected route, so the flag keeps revalidating and a
    // disable shuts the feature down wherever the user is.
    const portfolioInsightsEnabled = usePortfolioInsightsFlag()
    const availabilityStatus = useInsightsAvailabilityStatus(
        portfolioInsightsEnabled
    )

    return (
        <nav className="sidebar">
            <div className="sidebar-nav">
                <ul
                    onFocus={
                        portfolioInsightsEnabled
                            ? revealKeyboardFocusedLink
                            : undefined
                    }
                >
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
                        <li>
                            <NavLink
                                id="nav-portfolio-insights"
                                to="/insights"
                                className={({ isActive }) =>
                                    "nav-link" + (isActive ? " active" : "")
                                }
                            >
                                <InsightsIcon />
                                Portfolio Insights
                            </NavLink>
                        </li>
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
