import "@testing-library/jest-dom/vitest"
import { render, screen } from "@testing-library/react"
import { RiskBadge } from "../../components/insights/RiskBadge"
import type { RiskLevel } from "../../api/portfolioInsights/types"

const badges: ReadonlyArray<{
    level: RiskLevel
    className: string
    label: string
}> = [
    { level: "LOW", className: "badge-success", label: "Low" },
    { level: "MEDIUM", className: "badge-warning", label: "Medium" },
    { level: "HIGH", className: "badge-danger", label: "High" },
]

describe("RiskBadge", () => {
    it.each(badges)(
        "riskBadge_level_rendersBadge ($level)",
        ({ level, className, label }) => {
            render(<RiskBadge riskLevel={level} />)

            const badge = screen.getByText(label)
            expect(badge).toHaveAttribute("id", "insights-risk-badge")
            expect(badge).toHaveClass("badge", className)
        }
    )

    it("riskBadge_null_rendersNothing", () => {
        const { container } = render(<RiskBadge riskLevel={null} />)

        expect(container).toBeEmptyDOMElement()
        expect(
            document.getElementById("insights-risk-badge")
        ).not.toBeInTheDocument()
    })
})
