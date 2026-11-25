import { Allocation } from "../../api/portfolioInsights"
import { useFormatter } from "../../contexts/FormatterContext/context"

type AllocationTableProps = {
    /** Rendered in the order received: the broker already sorts the entries. */
    allocations: Allocation[]
}

export function AllocationTable({ allocations }: AllocationTableProps) {
    const { formatCurrency, formatPercent } = useFormatter()

    return (
        <div>
            <h3 className="section-heading">Allocation</h3>
            {/* Same horizontal-scroll wrapper as the other data tables. */}
            <div style={{ overflowX: "auto" }}>
                <table id="insights-allocations" className="data-table">
                    <thead>
                        <tr>
                            <th>Instrument</th>
                            <th className="col-number">Quantity</th>
                            <th className="col-number">Value</th>
                            <th className="col-number">Allocation</th>
                        </tr>
                    </thead>
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
