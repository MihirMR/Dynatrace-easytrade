namespace EasyTrade.BrokerService.ExceptionHandling.Exceptions
{
    public class InvalidAlertException : Exception
    {
        public InvalidAlertException(string message)
            : base(message) { }

        public InvalidAlertException()
            : base() { }

        public InvalidAlertException(string? message, System.Exception? innerException)
            : base(message, innerException) { }
    }
}
