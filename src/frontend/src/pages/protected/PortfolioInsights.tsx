import { useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { useNavigate } from "react-router"
import { BizEvents } from "../../api/bizEvents"
import { loggableError, withStackFramesOf } from "../../api/http"
import type { Instrument } from "../../api/instrument/types"
import { AlertsPanel } from "../../components/insights/AlertsPanel"
import {
    InsightsSummary,
    InsightsSummaryPlaceholder,
} from "../../components/insights/InsightsSummary"
import { useAuthUser } from "../../contexts/UserContext/context"
import { useAlertsQuery } from "../../hooks/useAlerts"
import { usePortfolioInsightsFlag } from "../../hooks/useFeatureFlags"
import { useInstrumentsQuery } from "../../hooks/useInstruments"
import { usePortfolioInsightsQuery } from "../../hooks/usePortfolioInsights"
import {
    featureResultContext,
    isCurrentFeatureContext,
    isFeatureDisabledError,
} from "../../utils/portfolioInsightsFeature"

/**
 * Renders its content one commit after it mounts, so text placed in a live
 * region through it is added to a region that is already present: a region
 * inserted already holding its text may stay silent. The state is local, so
 * the page and its queries do not render again when it flips.
 */
function AfterMount({ children }: { children: ReactNode }) {
    const [mounted, setMounted] = useState(false)

    useEffect(() => {
        setMounted(true)
    }, [])

    return mounted ? children : null
}

/**
 * `sessionStorage` key of the allocation row count the page last showed for
 * each account in this tab, as a JSON object keyed by account id. While the
 * figures load, the placeholder reserves that many one-line rows, as tall as
 * that many loaded rows, whose cells never wrap, so on a reload of the page
 * the alerts panel stays put when a table of that many rows arrives. The
 * record survives a reload and is discarded with the tab; logout leaves it in
 * place, because every entry names its account.
 */
export const ALLOCATION_ROWS_STORAGE_KEY = "portfolio-insights.allocation-rows"

/**
 * Rows reserved for an account this tab has shown no figures for, when its
 * instruments fail to load before its figures arrive.
 */
const DEFAULT_ALLOCATION_ROWS = 1

/**
 * The most rows the placeholder reserves; a larger remembered count or
 * holdings estimate reserves this many, so a corrupted record or a very large
 * portfolio cannot build a large table.
 */
export const MAX_ALLOCATION_ROWS = 100

// The record only steadies the layout, so its storage errors are logged in
// full and not rethrown (an exception to the propagate-errors convention): a
// failure must never break the page, which then reserves rows as it does
// when nothing is remembered.

/**
 * The entries of a stored record; an absent or corrupt record holds none.
 * With `report` set, a record that is not JSON or not an object is logged.
 * Only the read for use sets it: the write replaces such a record, and
 * reporting it there would log the same record again.
 */
function parseAllocationRows(
    text: string | null,
    report: boolean
): Record<string, unknown> | undefined {
    if (text === null) return undefined
    let parsed: unknown
    try {
        parsed = JSON.parse(text)
    } catch (error) {
        if (!report) return undefined
        // The parser's SyntaxError quotes the record, and so its account ids,
        // in its message and stack header. A SyntaxError with a fixed message
        // stands in for it and is logged whole with the parser error's stack
        // frames, so the log still shows where parsing failed, as
        // .claude/rules/typescript.md requires, without the record. A thrown
        // value that is not an Error could hold the record too and is never
        // logged; the stand-in then keeps the frames of this catch.
        const parseFailure = new SyntaxError(
            "The allocation rows record is not valid JSON"
        )
        console.error(
            "[PortfolioInsights] ignoring an allocation rows record that is not valid JSON",
            error instanceof Error
                ? withStackFramesOf(parseFailure, error)
                : parseFailure
        )
        return undefined
    }
    if (
        typeof parsed !== "object" ||
        parsed === null ||
        Array.isArray(parsed)
    ) {
        if (report) {
            console.error(
                "[PortfolioInsights] ignoring an allocation rows record that is not an object"
            )
        }
        return undefined
    }
    return parsed as Record<string, unknown>
}

/**
 * The allocation row count the page last showed for `accountId` in this tab,
 * at most `MAX_ALLOCATION_ROWS`. With no such count, an unreadable record, or
 * an entry that is not a whole number of at least 0, it is `undefined`: the
 * tab remembers nothing for the account. Never throws.
 */
function rememberedAllocationRows(accountId: string): number | undefined {
    let text: string | null
    try {
        text = sessionStorage.getItem(ALLOCATION_ROWS_STORAGE_KEY)
    } catch (error) {
        console.error(
            "[PortfolioInsights] could not read the remembered allocation rows",
            error
        )
        return undefined
    }
    const record = parseAllocationRows(text, true)
    if (record === undefined || !Object.hasOwn(record, accountId)) {
        return undefined
    }
    const rows = record[accountId]
    if (typeof rows !== "number" || !Number.isInteger(rows) || rows < 0) {
        console.error(
            "[PortfolioInsights] ignoring a remembered allocation row count that is not a whole number of at least 0"
        )
        return undefined
    }
    return Math.min(rows, MAX_ALLOCATION_ROWS)
}

/**
 * The rows the loading placeholder reserves for an account, at most
 * `MAX_ALLOCATION_ROWS`, or `undefined` while nothing gives an estimate yet.
 * `remembered`, the count the tab remembers for the account, comes first,
 * because it is the exact one last shown. Without it, `instruments`, the
 * account's instruments as the page's instruments query holds them, gives an
 * estimate: the figures list one allocation per holding, an instrument with
 * an `amount` above 0, though the instrument listing omits instruments
 * without price or product data. With no listing, `instrumentsFailed`, set
 * once that query has failed, gives `DEFAULT_ALLOCATION_ROWS`; a listing
 * still loading gives no estimate.
 */
function placeholderAllocationRows(
    remembered: number | undefined,
    instruments: Instrument[] | undefined,
    instrumentsFailed: boolean
): number | undefined {
    if (remembered !== undefined) {
        return remembered
    }
    if (instruments === undefined) {
        return instrumentsFailed ? DEFAULT_ALLOCATION_ROWS : undefined
    }
    const holdings = instruments.filter(
        (instrument) => instrument.amount > 0
    ).length
    return Math.min(holdings, MAX_ALLOCATION_ROWS)
}

/** The rows a placeholder footprint was decided with, and for which account. */
type AllocationRowsReservation = { accountId: string; rows: number }

/**
 * Records that the page showed `rows` allocation rows for `accountId`,
 * keeping the entries of other accounts; a corrupt record is replaced and
 * not logged here, as only its read for use reports it. Never throws.
 */
function rememberAllocationRows(accountId: string, rows: number): void {
    try {
        const record = parseAllocationRows(
            sessionStorage.getItem(ALLOCATION_ROWS_STORAGE_KEY),
            false
        )
        sessionStorage.setItem(
            ALLOCATION_ROWS_STORAGE_KEY,
            JSON.stringify({ ...record, [accountId]: rows })
        )
    } catch (error) {
        console.error(
            "[PortfolioInsights] could not remember the allocation rows",
            error
        )
    }
}

/**
 * The `/insights` page: the broker's portfolio figures and the alerts panel,
 * shown only while the Portfolio Insights flag is on. The page holds no
 * shutdown logic: its feature queries run the shared shutdown on a 403
 * themselves, and the page leaves for `/home` once the flag reads `false`.
 */
export function PortfolioInsights() {
    const { userId } = useAuthUser()
    const flag = usePortfolioInsightsFlag()
    const navigate = useNavigate()
    const insights = usePortfolioInsightsQuery(userId, flag)
    const { data: instruments, isError: instrumentsFailed } =
        useInstrumentsQuery(userId)
    // Started with the page's other queries; `AlertsPanel` renders this
    // cache entry.
    useAlertsQuery(userId, flag)
    const viewSent = useRef(false)
    const [reservation, setReservation] = useState<
        AllocationRowsReservation | undefined
    >(undefined)

    useEffect(() => {
        if (!flag) {
            void navigate("/home", { replace: true })
        }
    }, [flag, navigate])

    useEffect(() => {
        if (insights.error && !isFeatureDisabledError(insights.error)) {
            console.error(
                "Could not load portfolio insights",
                loggableError(insights.error, userId)
            )
        }
    }, [insights.error])

    // Sent once per mount, on the first result whose own request is still
    // current for the account shown: the account, session and activation it
    // was requested under all still hold. A refetch never sends it again.
    // Data cached under an earlier session or activation, or for another
    // account, is skipped, and a result loaded afresh after an in-place
    // account change or a shutdown and resume while the page stays mounted
    // still sends it. `dataUpdatedAt` re-runs the check when a refetch
    // returns equal data, which keeps its reference but carries the context
    // of the request that just returned it.
    const { data, dataUpdatedAt } = insights
    useEffect(() => {
        if (viewSent.current || !flag || data === undefined) {
            return
        }
        const produced = featureResultContext(data)
        if (
            produced === undefined ||
            produced.userId !== userId ||
            !isCurrentFeatureContext(produced)
        ) {
            return
        }
        // Marked sent first, so a failed send is not retried on later renders.
        viewSent.current = true
        // The event is best effort, and its `reportError` fallback can throw
        // as well. That throw is logged whole rather than propagated (an
        // exception to the propagate-errors convention): propagating it from
        // this effect would replace the loaded page with the error page.
        try {
            BizEvents.portfolioInsightsView({
                accountId: userId,
                holdingCount: data.allocations.length,
                riskLevel: data.riskLevel,
            })
        } catch (error) {
            console.error(
                "[PortfolioInsights] portfolioInsightsView event failed",
                error
            )
        }
    }, [data, dataUpdatedAt, flag, userId])

    // The remembered count, read once each time the figures start loading
    // for an account, so an unusable record is logged once rather than on
    // every render that waits for an estimate; the write once the figures
    // show replaces such a record without logging it again.
    const awaitingFigures = flag && insights.isPending
    const rememberedRows = useMemo(
        () => (awaitingFigures ? rememberedAllocationRows(userId) : undefined),
        [awaitingFigures, userId]
    )

    // The footprint the summary reserves while its figures load, decided
    // once per loading period of an account, in the first render that has
    // an estimate: at once from the record or the instruments already
    // cached, else when the page's instruments query settles, with its
    // listing or, on failure, the default. Figures that settle first end the
    // period with nothing reserved. Once decided, the count stays while the
    // placeholder or the error state shows it, so neither a later listing
    // nor a refetch resizes it. It is dropped once the figures show, the
    // flag turns off or the account changes, and the next loading period
    // decides afresh. Kept in state and adjusted during render, so the
    // render that first has an estimate already shows its placeholder.
    let reserved =
        flag && !insights.isSuccess && reservation?.accountId === userId
            ? reservation
            : undefined
    if (reserved === undefined && awaitingFigures) {
        const rows = placeholderAllocationRows(
            rememberedRows,
            instruments,
            instrumentsFailed
        )
        if (rows !== undefined) {
            reserved = { accountId: userId, rows }
        }
    }
    if (reserved !== reservation) {
        setReservation(reserved)
    }
    const reservedRows = reserved?.rows
    // While the figures load with no estimate yet, the page shows neither
    // the placeholder nor the alerts panel below it, so each first paints
    // where it stays: nothing follows the page, so the panel's arrival moves
    // nothing.
    const estimating = awaitingFigures && reservedRows === undefined

    // The rows of the summary on screen, remembered for the account it shows
    // once it has rendered; the error state shows none.
    const shownAllocationRows =
        flag && !insights.isError && data !== undefined
            ? data.allocations.length
            : undefined
    useEffect(() => {
        if (shownAllocationRows !== undefined) {
            rememberAllocationRows(userId, shownAllocationRows)
        }
    }, [shownAllocationRows, userId])

    if (!flag) {
        return null
    }

    function renderSummary() {
        // The shared shutdown handles a 403 and no message is shown.
        if (isFeatureDisabledError(insights.error)) {
            return null
        }
        // One block keeps the page stack's spacing in every state. The status
        // region in it stays mounted, empty unless the placeholder shows, and
        // takes no space: then it lies over the placeholder, which holds the
        // loaded summary's place with one-line allocation rows, as tall as
        // the loaded rows, whose cells never wrap. While the estimate is
        // unknown the block holds the empty region alone.
        return (
            <div className="insights-summary-block">
                <div id="insights-status" role="status">
                    {insights.isPending && !estimating && (
                        <AfterMount>
                            <p id="insights-loading">
                                Loading portfolio insights…
                            </p>
                        </AfterMount>
                    )}
                </div>
                {renderSummaryResult()}
            </div>
        )
    }

    function renderSummaryResult() {
        if (insights.isError) {
            const message = (
                <div
                    id="insights-error"
                    className="status-message status-error"
                    role="alert"
                >
                    Could not load portfolio insights. Please try again later.
                </div>
            )
            if (reservedRows === undefined) {
                return message
            }
            // The footprint the placeholder reserved stays: the message
            // shows at its top, over the same placeholder kept hidden, so the
            // block keeps its height and the alerts panel does not move.
            return (
                <div className="insights-error-footprint">
                    {message}
                    <InsightsSummaryPlaceholder allocationRows={reservedRows} />
                </div>
            )
        }
        if (insights.isPending) {
            return reservedRows === undefined ? null : (
                <InsightsSummaryPlaceholder allocationRows={reservedRows} />
            )
        }
        return <InsightsSummary insights={insights.data} />
    }

    return (
        // The inline `gap` follows the page stack of `Home.tsx`.
        <div
            id="portfolio-insights"
            className="form"
            style={{ gap: "var(--space-8)" }}
        >
            <h2>Portfolio Insights</h2>
            <p
                id="insights-disclaimer"
                className="status-message status-info"
                role="note"
            >
                Simulated demo data. Portfolio Insights is not financial advice.
            </p>
            {renderSummary()}
            {estimating ? null : (
                <AlertsPanel
                    accountId={userId}
                    instruments={instruments ?? []}
                />
            )}
        </div>
    )
}
