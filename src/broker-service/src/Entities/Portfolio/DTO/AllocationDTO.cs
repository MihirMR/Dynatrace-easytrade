namespace EasyTrade.BrokerService.Entities.Portfolio.DTO
{
    public class AllocationDTO(
        Guid instrumentId,
        string name,
        decimal quantity,
        decimal value,
        decimal percent
    )
    {
        public Guid InstrumentId { get; set; } = instrumentId;
        public string Name { get; set; } = name;
        public decimal Quantity { get; set; } = quantity;
        public decimal Value { get; set; } = value;
        public decimal Percent { get; set; } = percent;
    }
}
