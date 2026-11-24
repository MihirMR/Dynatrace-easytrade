namespace EasyTrade.BrokerService.Entities.Portfolio.Service
{
    /// <summary>
    /// One positive-quantity holding valued at its latest candle. <c>Name</c> is empty when the
    /// instrument name is unknown, and <c>LatestPrice</c> is 0 when <c>HasPrice</c> is false.
    /// <c>Value</c> is signed and unrounded.
    /// </summary>
    public record HoldingPosition(
        Guid InstrumentId,
        string Name,
        decimal Quantity,
        decimal LatestPrice,
        bool HasPrice,
        decimal Value,
        decimal CostBasis,
        decimal PnlPercent
    );
}
