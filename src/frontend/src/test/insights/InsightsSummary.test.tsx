import "@testing-library/jest-dom/vitest"
import { render, renderHook, screen, within } from "@testing-library/react"
import {
    InsightsSummary,
    InsightsSummaryPlaceholder,
} from "../../components/insights/InsightsSummary"
import { useFormatter } from "../../contexts/FormatterContext/context"
import { FormatterWrapper } from "../providers"
import type {
    Allocation,
    PortfolioInsights,
} from "../../api/portfolioInsights/types"

type Formatter = ReturnType<typeof useFormatter>

const easyTravel: Allocation = {
    instrumentId: "c0000000-0000-4000-8000-000000000001",
    name: "EasyTravel",
    quantity: 15,
    value: 1100,
    percent: 66.6666666667,
}

const easyPlanes: Allocation = {
    instrumentId: "c0000000-0000-4000-8000-000000000002",
    name: "EasyPlanes",
    quantity: 5,
    value: 550,
    percent: 33.3333333333,
}

const noHoldings: PortfolioInsights = {
    totalValue: 0,
    totalInvested: 0,
    unrealizedPnl: 0,
    unrealizedPnlPercent: 0,
    allocations: [],
    largestPosition: null,
    riskLevel: null,
}

const twoHoldings: PortfolioInsights = {
    totalValue: 1650,
    totalInvested: 1600,
    unrealizedPnl: 50,
    unrealizedPnlPercent: 3.125,
    allocations: [easyTravel, easyPlanes],
    largestPosition: easyTravel,
    riskLevel: "HIGH",
}

// Not an order the broker sends: it proves the table keeps the received order.
const lowerValueFirst: PortfolioInsights = {
    ...twoHoldings,
    allocations: [easyPlanes, easyTravel],
}

const responses: ReadonlyArray<{ label: string; insights: PortfolioInsights }> =
    [
        { label: "broker order", insights: twoHoldings },
        { label: "lower value first", insights: lowerValueFirst },
    ]

type PnlFigures = Pick<
    PortfolioInsights,
    "unrealizedPnl" | "unrealizedPnlPercent"
>

/** Class of the P/L amount and of its percent; `null` is no class. */
type PnlClasses = { amount: string | null; percent: string | null }

const pnlColours: ReadonlyArray<{
    sign: string
    figures: PnlFigures
    expected: PnlClasses
}> = [
    {
        sign: "gain",
        figures: { unrealizedPnl: 8.04, unrealizedPnlPercent: 6.65 },
        expected: { amount: "text-success", percent: "text-success" },
    },
    {
        sign: "loss",
        figures: { unrealizedPnl: -1.56839895, unrealizedPnlPercent: -6.65 },
        expected: { amount: "text-danger", percent: "text-danger" },
    },
    {
        sign: "zero",
        figures: { unrealizedPnl: 0, unrealizedPnlPercent: 0 },
        expected: { amount: null, percent: null },
    },
    // A negative cost basis gives the two figures opposite signs.
    {
        sign: "loss with a positive percent",
        figures: { unrealizedPnl: -20, unrealizedPnlPercent: 12.5 },
        expected: { amount: "text-danger", percent: "text-success" },
    },
]

// A loss shows the format of the gain of the same size, signed.
const pnlAmounts: ReadonlyArray<{ sign: string; pnl: number; text: string }> = [
    { sign: "gain", pnl: 8.04, text: "$8.04" },
    { sign: "loss", pnl: -1.56839895, text: "-$1.57" },
    { sign: "zero", pnl: 0, text: "$0" },
]

// Below one cent the amount is rounded to whole cents: from half a cent it
// shows one cent, signed for a loss; below that the unsigned zero. Its
// colour still follows the received sign.
const subCentPnls: ReadonlyArray<{
    pnl: number
    expected: { text: string; className: string }
}> = [
    { pnl: 0.006, expected: { text: "$0.01", className: "text-success" } },
    { pnl: -0.006, expected: { text: "-$0.01", className: "text-danger" } },
    { pnl: 0.005, expected: { text: "$0.01", className: "text-success" } },
    { pnl: -0.005, expected: { text: "-$0.01", className: "text-danger" } },
    { pnl: 0.004, expected: { text: "$0", className: "text-success" } },
    { pnl: -0.004, expected: { text: "$0", className: "text-danger" } },
]

/** The production formatter, so expectations follow the FormatterContext contract. */
function productionFormatter(): Formatter {
    const { result } = renderHook(() => useFormatter(), {
        wrapper: FormatterWrapper,
    })
    return result.current
}

function renderSummary(insights: PortfolioInsights): void {
    render(
        <FormatterWrapper>
            <InsightsSummary insights={insights} />
        </FormatterWrapper>
    )
}

function getById(id: string): HTMLElement {
    const element = document.getElementById(id)
    if (element === null) {
        throw new Error(`No element with id [${id}] was rendered`)
    }
    return element
}

function textOf(id: string): string | null {
    return getById(id).textContent
}

function classOf(id: string): string | null {
    return getById(id).getAttribute("class")
}

type FigureId =
    | "insights-total-value"
    | "insights-total-invested"
    | "insights-unrealized-pnl"
    | "insights-unrealized-pnl-percent"

/** Exact text of each figure and of every allocation body cell, row by row. */
type RenderedSummary = {
    figures: Record<FigureId, string | null>
    allocationRows: Array<Array<string | null>>
}

function readRenderedSummary(): RenderedSummary {
    const [, ...bodyRows] = within(
        getById("insights-allocations")
    ).getAllByRole("row")
    return {
        figures: {
            "insights-total-value": textOf("insights-total-value"),
            "insights-total-invested": textOf("insights-total-invested"),
            "insights-unrealized-pnl": textOf("insights-unrealized-pnl"),
            "insights-unrealized-pnl-percent": textOf(
                "insights-unrealized-pnl-percent"
            ),
        },
        allocationRows: bodyRows.map((row) =>
            within(row)
                .getAllByRole("cell")
                .map((cell) => cell.textContent)
        ),
    }
}

/**
 * Signed money as `InsightsSummary` writes it: the sign, then the magnitude,
 * rounded to whole cents below one cent; a magnitude rounded to 0 is unsigned.
 */
function signedCurrency(n: number, { formatCurrency }: Formatter): string {
    const absolute = Math.abs(n)
    const magnitude =
        absolute < 0.01 ? Math.round(absolute * 100) / 100 : absolute
    const text = formatCurrency(magnitude)
    return n < 0 && magnitude > 0 ? `-${text}` : text
}

function expectedSummary(
    insights: PortfolioInsights,
    formatter: Formatter
): RenderedSummary {
    const { formatCurrency, formatPercent } = formatter
    return {
        figures: {
            "insights-total-value": formatCurrency(insights.totalValue),
            "insights-total-invested": formatCurrency(insights.totalInvested),
            "insights-unrealized-pnl": signedCurrency(
                insights.unrealizedPnl,
                formatter
            ),
            "insights-unrealized-pnl-percent": formatPercent(
                insights.unrealizedPnlPercent / 100
            ),
        },
        allocationRows: insights.allocations.map((allocation) => [
            allocation.name,
            String(allocation.quantity),
            formatCurrency(allocation.value),
            formatPercent(allocation.percent / 100),
        ]),
    }
}

describe("InsightsSummary", () => {
    it("insightsSummary_noHoldings_showsEmptyStateWithoutBadge", () => {
        renderSummary(noHoldings)

        expect(getById("insights-empty-state")).toHaveTextContent(
            "You have no holdings yet. Buy instruments to see portfolio insights."
        )
        expect(
            document.getElementById("insights-allocations")
        ).not.toBeInTheDocument()
        expect(
            document.getElementById("insights-risk-badge")
        ).not.toBeInTheDocument()
    })

    it.each(responses)(
        "insightsSummary_response_showsFormattedEndpointFigures ($label)",
        ({ insights }) => {
            const formatter = productionFormatter()

            renderSummary(insights)

            expect(readRenderedSummary()).toEqual(
                expectedSummary(insights, formatter)
            )
        }
    )

    it.each(pnlAmounts)(
        "insightsSummary_pnlSign_showsSignedAmountInGainFormat ($sign)",
        ({ pnl, text }) => {
            renderSummary({ ...twoHoldings, unrealizedPnl: pnl })

            expect(textOf("insights-unrealized-pnl")).toBe(text)
        }
    )

    it.each(subCentPnls)(
        "insightsSummary_pnlBelowOneCent_showsWholeCentsColouredBySign ($pnl)",
        ({ pnl, expected }) => {
            renderSummary({ ...twoHoldings, unrealizedPnl: pnl })

            expect({
                text: textOf("insights-unrealized-pnl"),
                className: classOf("insights-unrealized-pnl"),
            }).toEqual(expected)
        }
    )

    it.each(pnlColours)(
        "insightsSummary_pnlSign_coloursAmountAndPercent ($sign)",
        ({ figures, expected }) => {
            renderSummary({ ...twoHoldings, ...figures })

            expect({
                amount: classOf("insights-unrealized-pnl"),
                percent: classOf("insights-unrealized-pnl-percent"),
            }).toEqual(expected)
        }
    )

    it("insightsSummary_allocations_exposeColumnHeadersInNamedScrollRegion", () => {
        renderSummary(twoHoldings)

        const table = getById("insights-allocations")
        const region = screen.getByRole("region", { name: "Allocation" })
        // The table scrolls inside a named region the keyboard can focus.
        expect({
            columnHeaders: within(table)
                .getAllByRole("columnheader")
                .map((header) => ({
                    text: header.textContent,
                    scope: header.getAttribute("scope"),
                })),
            regionTabIndex: region.getAttribute("tabindex"),
            regionContainsTable: region.contains(table),
        }).toEqual({
            columnHeaders: [
                "Instrument",
                "Quantity",
                "Value",
                "Allocation",
            ].map((text) => ({ text, scope: "col" })),
            regionTabIndex: "0",
            regionContainsTable: true,
        })
    })

    it("insightsSummary_largestPosition_showsNameAndPercent", () => {
        const { formatPercent } = productionFormatter()

        renderSummary(twoHoldings)

        const largestPosition = getById("insights-largest-position")
        expect(largestPosition).toHaveTextContent(easyTravel.name)
        expect(largestPosition).toHaveTextContent(
            formatPercent(easyTravel.percent / 100)
        )
    })
})

/** The markup that sets a summary's size, which the placeholder must repeat. */
type SummaryOutline = {
    rootClassName: string | undefined
    figureLabels: Array<string | null>
    heading: string | null | undefined
    columnHeaders: Array<string | null>
    bodyRowCellClasses: string[][]
    emptyStateClasses: string[]
}

function readOutline(container: HTMLElement): SummaryOutline {
    return {
        rootClassName: container.firstElementChild?.className,
        figureLabels: Array.from(
            container.querySelectorAll(
                ".insights-summary > .insights-figure > .form-label"
            ),
            (label) => label.textContent
        ),
        heading: container.querySelector("h3.section-heading")?.textContent,
        columnHeaders: Array.from(
            container.querySelectorAll("table.data-table thead th"),
            (header) => header.textContent
        ),
        bodyRowCellClasses: Array.from(
            container.querySelectorAll("table.data-table tbody tr"),
            (row) => Array.from(row.children, (cell) => cell.className)
        ),
        emptyStateClasses: Array.from(
            container.querySelectorAll(".insights-content > p"),
            (paragraph) => paragraph.className
        ),
    }
}

/**
 * A placeholder body cell: `"bar"` when a skeleton bar is all it holds, else
 * its text.
 */
function readPlaceholderCell(cell: Element): string | null {
    const [only, ...others] = Array.from(cell.childNodes)
    const isBar =
        others.length === 0 &&
        only instanceof HTMLSpanElement &&
        only.className === "insights-value-placeholder" &&
        !only.hasChildNodes()
    return isBar ? "bar" : cell.textContent
}

const barRow = ["bar", "bar", "bar", "bar"]
const emptyLineRow = ["\u00a0", "\u00a0", "\u00a0", "\u00a0"]

/**
 * Markup that puts an element in the Tab order. An overflowing scroll
 * container is a Tab stop in Chrome without any of it, which jsdom does not
 * lay out, so the placeholder's scroll wrapper is checked to be inert instead.
 */
const focusableMarkup =
    "[tabindex], [contenteditable], a, area, button, input, select, textarea, iframe, summary, audio[controls], video[controls]"

/** `count` holdings with distinct ids, as the broker lists them. */
function holdings(count: number): PortfolioInsights {
    if (count === 0) {
        return noHoldings
    }
    return {
        ...twoHoldings,
        allocations: Array.from({ length: count }, (_, index) => ({
            ...easyTravel,
            instrumentId: `c0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
        })),
    }
}

describe("InsightsSummaryPlaceholder", () => {
    // The page reserves the row count it last showed for the account: 0 is
    // the empty state, and 1 is also what it reserves for an unknown account.
    it.each([0, 1, 15])(
        "insightsSummaryPlaceholder_render_mirrorsSummaryWithAsManyHoldingsInertWithoutIds (%i rows)",
        (rows) => {
            const loaded = render(
                <FormatterWrapper>
                    <InsightsSummary insights={holdings(rows)} />
                </FormatterWrapper>
            ).container
            const placeholder = render(
                <InsightsSummaryPlaceholder allocationRows={rows} />
            ).container
            const root = placeholder.firstElementChild

            expect(readOutline(placeholder)).toEqual(readOutline(loaded))
            expect({
                hidden: root?.getAttribute("aria-hidden"),
                inert: root?.hasAttribute("inert"),
                ids: Array.from(
                    placeholder.querySelectorAll("[id]"),
                    (element) => element.id
                ),
                focusable: placeholder.querySelectorAll(focusableMarkup).length,
                scrollWrappersInInertRoot: Array.from(
                    placeholder.querySelectorAll(
                        ".insights-allocations-scroll"
                    ),
                    (wrapper) => wrapper.closest("[inert]") === root
                ),
                valueLines: Array.from(
                    placeholder.querySelectorAll(
                        ".insights-figure > .insights-value-placeholder"
                    ),
                    (value) => value.textContent
                ),
                emptyStateLines: Array.from(
                    placeholder.querySelectorAll(".insights-content > p"),
                    (paragraph) => paragraph.textContent
                ),
            }).toEqual({
                hidden: "true",
                inert: true,
                ids: [],
                focusable: 0,
                scrollWrappersInInertRoot: rows === 0 ? [] : [true],
                valueLines: Array.from({ length: 6 }, () => "\u00a0"),
                emptyStateLines: rows === 0 ? ["\u00a0"] : [],
            })
        }
    )

    // Every row but the last draws a bar in each cell, so the reserved table
    // reads as loading; the last row stays an empty line, because the page's
    // loading message lies over it.
    it.each([
        { rows: 1, barRows: 0 },
        { rows: 2, barRows: 1 },
        { rows: 15, barRows: 14 },
    ])(
        "insightsSummaryPlaceholder_rows_drawBarsInEveryRowButTheLast ($rows rows)",
        ({ rows, barRows }) => {
            const placeholder = render(
                <InsightsSummaryPlaceholder allocationRows={rows} />
            ).container

            expect(
                Array.from(
                    placeholder.querySelectorAll("table.data-table tbody tr"),
                    (row) => Array.from(row.children, readPlaceholderCell)
                )
            ).toEqual([
                ...Array.from({ length: barRows }, () => barRow),
                emptyLineRow,
            ])
        }
    )
})
