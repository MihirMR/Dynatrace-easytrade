namespace EasyTrade.BrokerService.Entities.Portfolio.DTO
{
    public class PortfolioInsightsDTO(
        decimal totalValue,
        decimal totalInvested,
        decimal unrealizedPnl,
        decimal unrealizedPnlPercent,
        IEnumerable<AllocationDTO> allocations,
        AllocationDTO? largestPosition,
        string? riskLevel
    )
    {
        public decimal TotalValue { get; set; } = totalValue;
        public decimal TotalInvested { get; set; } = totalInvested;
        public decimal UnrealizedPnl { get; set; } = unrealizedPnl;
        public decimal UnrealizedPnlPercent { get; set; } = unrealizedPnlPercent;
        public IEnumerable<AllocationDTO> Allocations { get; set; } = allocations;
        public AllocationDTO? LargestPosition { get; set; } = largestPosition;
        public string? RiskLevel { get; set; } = riskLevel;
    }
}
