namespace EasyTrade.BrokerService.ExceptionHandling.Exceptions
{
    public class AlertNotFoundException : Exception
    {
        public AlertNotFoundException(string message)
            : base(message) { }

        public AlertNotFoundException()
            : base() { }

        public AlertNotFoundException(string? message, System.Exception? innerException)
            : base(message, innerException) { }

        public AlertNotFoundException(Guid id)
            : this($"Alert with id {id} doesn't exist") { }
    }
}
