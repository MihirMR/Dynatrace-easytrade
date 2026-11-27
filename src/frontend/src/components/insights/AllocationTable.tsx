import type { Allocation } from "../../api/portfolioInsights/types"
import { useFormatter } from "../../contexts/FormatterContext/context"

type AllocationTableProps = {
    /** Rendered in the order received: the broker already sorts the entries. */
    allocations: Allocation[]
}

/**
 * The column header row, shared with the summary's loading placeholder so its
 * table has the same columns and header row as this one.
 */
export function AllocationTableHead() {
    return (
        <thead>
            <tr>
                <th scope="col">Instrument</th>
                <th scope="col" className="col-number">
                    Quantity
                </th>
                <th scope="col" className="col-number">
                    Value
                </th>
                <th scope="col" className="col-number">
                    Allocation
                </th>
            </tr>
        </thead>
    )
}

export function AllocationTable({ allocations }: AllocationTableProps) {
    const { formatCurrency, formatPercent } = useFormatter()

    return (
        <div>
            <h3 id="insights-allocations-heading" className="section-heading">
                Allocation
            </h3>
            {/* Same horizontal-scroll wrapper as the other data tables. It is a
                named, focusable region so the keyboard can scroll it. */}
            <div
                className="insights-allocations-scroll"
                style={{ overflowX: "auto" }}
                role="region"
                aria-labelledby="insights-allocations-heading"
                tabIndex={0}
            >
                <table id="insights-allocations" className="data-table">
                    <AllocationTableHead />
                    <tbody>
                        {allocations.map((allocation) => (
                            <tr key={allocation.instrumentId}>
                                <td>{allocation.name}</td>
                                <td className="col-number">
                                    {allocation.quantity}
                                </td>
                                <td className="col-number">
                                    {formatCurrency(allocation.value)}
                                </td>
                                <td className="col-number">
                                    {formatPercent(allocation.percent / 100)}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    )
}
