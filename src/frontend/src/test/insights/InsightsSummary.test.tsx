import "@testing-library/jest-dom/vitest"
import { render, renderHook, within } from "@testing-library/react"
import { InsightsSummary } from "../../components/insights/InsightsSummary"
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

function expectedSummary(
    insights: PortfolioInsights,
    { formatCurrency, formatPercent }: Formatter
): RenderedSummary {
    return {
        figures: {
            "insights-total-value": formatCurrency(insights.totalValue),
            "insights-total-invested": formatCurrency(insights.totalInvested),
            "insights-unrealized-pnl": formatCurrency(insights.unrealizedPnl),
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
