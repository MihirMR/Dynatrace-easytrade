namespace EasyTrade.BrokerService.ExceptionHandling.Exceptions
{
    public class PricingUnavailableException : Exception
    {
        public PricingUnavailableException(string message)
            : base(message) { }

        public PricingUnavailableException()
            : base() { }

        public PricingUnavailableException(string? message, System.Exception? innerException)
            : base(message, innerException) { }
    }
}
