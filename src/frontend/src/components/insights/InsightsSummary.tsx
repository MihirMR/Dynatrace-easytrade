import type { PortfolioInsights } from "../../api/portfolioInsights/types"
import { useFormatter } from "../../contexts/FormatterContext/context"
import type { IFormatterContext } from "../../contexts/FormatterContext/types"
import { AllocationTable, AllocationTableHead } from "./AllocationTable"
import { RiskBadge } from "./RiskBadge"

/** Shown where the broker reports no value (no holdings). */
const noValue = "—"

/**
 * The labels of the six figure cards, in the order `InsightsSummary` shows
 * them. `InsightsSummaryPlaceholder` repeats them, so both name the same cards.
 */
const figureLabels = {
    totalValue: "Total value",
    totalInvested: "Total invested",
    unrealizedPnl: "Unrealized P/L",
    unrealizedPnlPercent: "Unrealized P/L %",
    largestPosition: "Largest position",
    risk: "Risk",
} as const

/**
 * Colour of a signed P/L figure, the amount or its percent, each by its own
 * sign; exactly 0 keeps the default text colour.
 */
function pnlClassName(signedValue: number): string | undefined {
    if (signedValue > 0) {
        return "text-success"
    }
    if (signedValue < 0) {
        return "text-danger"
    }
    return undefined
}

/**
 * Signed money through `formatCurrency`, which gives every value below 0.01,
 * and so every loss, its significant-digits format. Formatting the magnitude
 * and writing the sign in front shows a loss with two places as a gain is
 * shown. A magnitude below one cent is first rounded to whole cents, so from
 * half a cent it shows as `$0.01`, after a minus for a loss, and below that
 * as the formatter's zero, `$0`, unsigned, as a P/L of exactly 0 shows.
 */
function formatSignedCurrency(
    formatCurrency: IFormatterContext["formatCurrency"],
    n: number
): string {
    const absolute = Math.abs(n)
    const magnitude =
        absolute < 0.01 ? Math.round(absolute * 100) / 100 : absolute
    const text = formatCurrency(magnitude)
    return n < 0 && magnitude > 0 ? `-${text}` : text
}

/**
 * Figures, risk and allocations of `GET /v1/portfolio/insights/{accountId}`.
 * Every number is the broker's, formatted through `FormatterContext` and never
 * recomputed; percents arrive in percent and are passed to `formatPercent` as
 * ratios, and the signed P/L is formatted by `formatSignedCurrency`. Each
 * id-bearing element holds only its formatted value, because the browser
 * check compares that text with the response.
 */
export function InsightsSummary({ insights }: { insights: PortfolioInsights }) {
    const { formatCurrency, formatPercent } = useFormatter()
    const {
        totalValue,
        totalInvested,
        unrealizedPnl,
        unrealizedPnlPercent,
        allocations,
        largestPosition,
        riskLevel,
    } = insights

    return (
        <div className="insights-content">
            <div className="insights-summary">
                <div className="insights-figure">
                    <span className="form-label">
                        {figureLabels.totalValue}
                    </span>
                    <span id="insights-total-value">
                        {formatCurrency(totalValue)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">
                        {figureLabels.totalInvested}
                    </span>
                    <span id="insights-total-invested">
                        {formatCurrency(totalInvested)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">
                        {figureLabels.unrealizedPnl}
                    </span>
                    <span
                        id="insights-unrealized-pnl"
                        className={pnlClassName(unrealizedPnl)}
                    >
                        {formatSignedCurrency(formatCurrency, unrealizedPnl)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">
                        {figureLabels.unrealizedPnlPercent}
                    </span>
                    <span
                        id="insights-unrealized-pnl-percent"
                        className={pnlClassName(unrealizedPnlPercent)}
                    >
                        {formatPercent(unrealizedPnlPercent / 100)}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">
                        {figureLabels.largestPosition}
                    </span>
                    <span id="insights-largest-position">
                        {largestPosition === null
                            ? noValue
                            : `${largestPosition.name} (${formatPercent(largestPosition.percent / 100)})`}
                    </span>
                </div>
                <div className="insights-figure">
                    <span className="form-label">{figureLabels.risk}</span>
                    {/* The span keeps the badge content-sized inside the flex column card. */}
                    <span>
                        {riskLevel === null ? (
                            noValue
                        ) : (
                            <RiskBadge riskLevel={riskLevel} />
                        )}
                    </span>
                </div>
            </div>
            {allocations.length > 0 ? (
                <AllocationTable allocations={allocations} />
            ) : (
                <p id="insights-empty-state" className="empty-state">
                    You have no holdings yet. Buy instruments to see portfolio
                    insights.
                </p>
            )}
        </div>
    )
}

/** An empty line of text, as tall as one line of a figure or a table cell. */
const emptyLine = "\u00a0"

/**
 * Callback ref that makes its element `inert`, so nothing in it takes focus or
 * pointer input. `aria-hidden` alone leaves focus alone, and Chrome makes a
 * scroll container whose content overflows a Tab stop even without a
 * `tabindex`. React 18 and its types have no `inert` prop, so the attribute
 * is set on the element; a module-level function is a stable ref, which React
 * calls with the element when it mounts and with `null` when it unmounts.
 */
function makeInert(element: HTMLDivElement | null): void {
    element?.setAttribute("inert", "")
}

/**
 * Holds the place of `InsightsSummary` while the insights request is pending:
 * the same wrapper, card grid and cards, then the Allocation section with
 * `allocationRows` one-line table rows, or the empty state's block when it is
 * 0, so a table of that many holdings fills the height reserved for it: each
 * placeholder row is one line tall, as is each loaded row, whose cells never
 * wrap. Each card value, and each cell of every row but the last, is a
 * skeleton bar, so the reserved table reads as loading rather than as empty
 * rows; the last row stays an empty line, because the page's loading message
 * lies over it. It has no ids, so each id the browser check and loadgen read
 * exists only once the figures are shown. It is hidden from assistive
 * technology, because the page's status region announces the loading state,
 * and its whole subtree is inert, so no part of it, its scroll wrapper
 * included, is a Tab stop or takes focus.
 */
export function InsightsSummaryPlaceholder({
    allocationRows,
}: {
    /** A whole number of rows; the page caps what it remembers. */
    allocationRows: number
}) {
    return (
        <div className="insights-content" aria-hidden="true" ref={makeInert}>
            <div className="insights-summary">
                {Object.values(figureLabels).map((label) => (
                    <div key={label} className="insights-figure">
                        <span className="form-label">{label}</span>
                        <span className="insights-value-placeholder">
                            {emptyLine}
                        </span>
                    </div>
                ))}
            </div>
            {allocationRows > 0 ? (
                <div>
                    <h3 className="section-heading">Allocation</h3>
                    {/* The scroll wrapper of `AllocationTable`, without its
                        focus stop: the subtree is inert, so even the browser's
                        Tab stop on an overflowing scroller never lands here. */}
                    <div
                        className="insights-allocations-scroll"
                        style={{ overflowX: "auto" }}
                    >
                        <table className="data-table">
                            <AllocationTableHead />
                            <tbody>
                                {Array.from(
                                    { length: allocationRows },
                                    (_, row) => {
                                        // The last row stays an empty line:
                                        // the loading message lies over it.
                                        const cell =
                                            row < allocationRows - 1 ? (
                                                <span className="insights-value-placeholder" />
                                            ) : (
                                                emptyLine
                                            )
                                        return (
                                            <tr key={row}>
                                                <td>{cell}</td>
                                                <td className="col-number">
                                                    {cell}
                                                </td>
                                                <td className="col-number">
                                                    {cell}
                                                </td>
                                                <td className="col-number">
                                                    {cell}
                                                </td>
                                            </tr>
                                        )
                                    }
                                )}
                            </tbody>
                        </table>
                    </div>
                </div>
            ) : (
                <p className="empty-state">{emptyLine}</p>
            )}
        </div>
    )
}
