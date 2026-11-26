using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using EasyTrade.BrokerService.ExceptionHandling.Exceptions;
using EasyTrade.BrokerService.Helpers.FeatureFlags;
using Grpc.Core;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace EasyTrade.BrokerService.ExceptionHandling;

public class BrokerExceptionFilter(ILogger<BrokerExceptionFilter> logger) : IExceptionFilter
{
    // Public message of a database failure on a Portfolio Insights endpoint. DbException text
    // names the db-adapter call site and carries the gRPC transport error, whose detail is the
    // database driver's own diagnostic: on these endpoints neither the response body nor the
    // handled-exception log line carries it (see DescribeForLog).
    private const string DatabaseUnavailableMessage = "Database is unavailable";

    // The most exceptions one DescribeForLog rendering walks, so a long chain stays bounded.
    private const int MaxDescribedExceptions = 16;
    private const string ChainSeparator = " ---> ";
    private const string WithheldMessage = "message withheld";
    private const string UnavailableMessage = "message unavailable";

    // The fixed prefix GrpcHelper puts before the wrapped error's message. Only an identifier
    // passes as the operation, so text an upstream error carries can never be logged as one.
    // The non-backtracking engine matches in linear time and never times out.
    private static readonly Regex DbAdapterOperation = new(
        "^Db Adapter call error in \"(?<operation>[A-Za-z_][A-Za-z0-9_]*)\" method: ",
        RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture | RegexOptions.NonBacktracking,
        Regex.InfiniteMatchTimeout
    );

    private readonly ILogger _logger = logger;

    public void OnException(ExceptionContext context) =>
        UpdateContext(context, GetStatusCode(context.Exception));

    /// <summary>
    /// Renders <paramref name="exception"/> for one log line, deterministically and without a
    /// stack trace; it never throws. The exception and its inner exceptions, every entry of an
    /// <see cref="AggregateException"/> included, are rendered depth first as
    /// <c>Type: detail</c> segments joined by <c> ---&gt; </c>, with short type names. Each
    /// exception appears once and at most sixteen appear; <c> ---&gt; ...</c> marks the rest.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A chain holding a <see cref="DbException"/> or an <see cref="RpcException"/> is a
    /// db-adapter failure. Their messages carry driver and RPC diagnostics, such as a database
    /// login or endpoint, and an outer message can repeat an inner one, as an
    /// <see cref="AggregateException"/>'s does, so no message in such a chain is rendered. A
    /// chain longer than sixteen exceptions renders no message either, because the exceptions
    /// past the bound are never classified and a rendered message could repeat one of theirs:
    /// </para>
    /// <list type="bullet">
    /// <item><description>
    /// A <see cref="DbException"/> renders as
    /// <c>DbException: db-adapter call [operation] failed with status [code]</c>. The operation
    /// is the identifier named by the fixed message prefix of <c>GrpcHelper</c>, and is left
    /// out when the message does not start with that prefix. The status is that of the first
    /// <see cref="RpcException"/> among its inner exceptions; without one,
    /// <c>with cause [type]</c> names its inner exception's type, and without an inner
    /// exception nothing follows <c>failed</c>. Its inner exceptions are not rendered again.
    /// </description></item>
    /// <item><description>
    /// An <see cref="RpcException"/> renders as <c>RpcException: status [code]</c>.
    /// </description></item>
    /// <item><description>
    /// Any other exception renders as <c>Type: message withheld</c>.
    /// </description></item>
    /// </list>
    /// <para>
    /// Every other chain, one of at most sixteen exceptions with neither, renders each exception
    /// as <c>Type: message</c>. Each run of control characters and line or paragraph separators
    /// becomes one space, so the record stays on one line. A message that cannot be read renders
    /// as <c>message unavailable</c>, and a null exception as an empty string.
    /// </para>
    /// </remarks>
    public static string DescribeForLog(Exception? exception) => Describe(exception, true);

    private static int GetStatusCode(Exception exception) =>
        exception switch
        {
            BalanceNotFoundException
            or InstrumentNotFoundException
            or ProductNotFoundException
            or PriceNotFoundException
            or AlertNotFoundException => StatusCodes.Status404NotFound,
            NotEnoughMoneyException
            or NotEnoughAssetsException
            or NegativeAmountException
            or InvalidAlertException => StatusCodes.Status400BadRequest,
            DbException or PricingUnavailableException => StatusCodes.Status503ServiceUnavailable,
            _ => StatusCodes.Status500InternalServerError,
        };

    private void UpdateContext(ExceptionContext context, int statusCode)
    {
        var typeName = context.Exception.GetType().ToString();
        // A Portfolio Insights endpoint logs the safe rendering, because a db-adapter failure's
        // message carries driver and RPC diagnostics. The type stays in its own field, so the
        // rendering drops its outermost label. Every other endpoint logs the raw message.
        string message = IsPortfolioInsightsEndpoint(context)
            ? Describe(context.Exception, false)
            : context.Exception.Message;

        if (statusCode == StatusCodes.Status500InternalServerError)
        {
            _logger.LogError("Exception not handled: ({type}: {message})", typeName, message);
            return;
        }

        ErrorResponse response = new(statusCode, GetPublicMessage(context));
        context.Result = new ObjectResult(response) { StatusCode = statusCode };
        context.ExceptionHandled = true;

        _logger.LogInformation(
            "Exception handled with status [{status}]: ({type}: {message})",
            statusCode,
            typeName.Split('.').Last(),
            message
        );
    }

    // Only the Portfolio Insights endpoints get the stable message; every other endpoint answers
    // with the exception's own message.
    private static string GetPublicMessage(ExceptionContext context)
    {
        if (context.Exception is DbException && IsPortfolioInsightsEndpoint(context))
        {
            return DatabaseUnavailableMessage;
        }

        return context.Exception.Message;
    }

    // An endpoint is a Portfolio Insights endpoint when PortfolioInsightsFeatureGate is attached
    // to it through [ServiceFilter], on the action or on its controller.
    private static bool IsPortfolioInsightsEndpoint(ExceptionContext context)
    {
        return context.ActionDescriptor.FilterDescriptors.Any(descriptor =>
            descriptor.Filter is ServiceFilterAttribute serviceFilter
            && serviceFilter.ServiceType == typeof(PortfolioInsightsFeatureGate)
        );
    }

    // The rendering of DescribeForLog. Without labelOutermost the outermost segment omits its
    // "Type: " label, for a template that logs the exception type in a field of its own.
    private static string Describe(Exception? exception, bool labelOutermost)
    {
        if (exception is null)
        {
            return string.Empty;
        }

        List<Exception> chain = WalkChain(exception, true, out bool truncated);
        // A truncated walk may have stopped before a db-adapter error, and a visited message
        // such as an AggregateException's can repeat it, so an unclassified chain is unsafe.
        bool withholdMessages = truncated || chain.Exists(IsDbAdapterError);
        StringBuilder text = new();
        for (int index = 0; index < chain.Count; index++)
        {
            if (index > 0)
            {
                text.Append(ChainSeparator);
            }
            if ((index > 0) || labelOutermost)
            {
                AppendSingleLine(text, chain[index].GetType().Name);
                text.Append(": ");
            }
            AppendDetail(text, chain[index], withholdMessages);
        }
        if (truncated)
        {
            text.Append(ChainSeparator).Append("...");
        }
        return text.ToString();
    }

    // Depth first, each exception before its inner ones and an aggregate's entries in order;
    // every exception once, compared by reference, and at most MaxDescribedExceptions of them.
    // With stopAtDbException a DbException's inner exceptions are not walked, because its own
    // rendering summarises them.
    private static List<Exception> WalkChain(
        Exception root,
        bool stopAtDbException,
        out bool truncated
    )
    {
        List<Exception> chain = [];
        HashSet<Exception> seen = new(ReferenceEqualityComparer.Instance);
        Stack<Exception> pending = new();
        pending.Push(root);
        while (pending.Count > 0)
        {
            Exception current = pending.Pop();
            if (!seen.Add(current))
            {
                continue;
            }
            if (chain.Count == MaxDescribedExceptions)
            {
                truncated = true;
                return chain;
            }

            chain.Add(current);
            if (stopAtDbException && (current is DbException))
            {
                continue;
            }
            if (current is AggregateException aggregate)
            {
                for (int index = aggregate.InnerExceptions.Count - 1; index >= 0; index--)
                {
                    pending.Push(aggregate.InnerExceptions[index]);
                }
            }
            else if (current.InnerException is Exception inner)
            {
                pending.Push(inner);
            }
        }

        truncated = false;
        return chain;
    }

    private static bool IsDbAdapterError(Exception exception) =>
        exception is DbException or RpcException;

    private static void AppendDetail(StringBuilder text, Exception exception, bool withholdMessages)
    {
        if (exception is DbException dbException)
        {
            AppendDbExceptionDetail(text, dbException);
        }
        else if (exception is RpcException rpcException)
        {
            text.Append("status [").Append(rpcException.StatusCode.ToString()).Append(']');
        }
        else if (withholdMessages)
        {
            text.Append(WithheldMessage);
        }
        else
        {
            AppendSingleLine(text, ReadMessage(exception));
        }
    }

    private static void AppendDbExceptionDetail(StringBuilder text, DbException exception)
    {
        text.Append("db-adapter call");
        Match operation = DbAdapterOperation.Match(ReadMessage(exception));
        if (operation.Success)
        {
            text.Append(" [").Append(operation.Groups["operation"].Value).Append(']');
        }
        text.Append(" failed");

        if (exception.InnerException is not Exception inner)
        {
            return;
        }
        RpcException? rpcException = WalkChain(inner, false, out _)
            .OfType<RpcException>()
            .FirstOrDefault();
        if (rpcException is not null)
        {
            text.Append(" with status [").Append(rpcException.StatusCode.ToString()).Append(']');
        }
        else
        {
            text.Append(" with cause [");
            AppendSingleLine(text, inner.GetType().Name);
            text.Append(']');
        }
    }

    // Message is virtual, so an exception type can throw from it or return null.
    private static string ReadMessage(Exception exception)
    {
        try
        {
            return exception.Message ?? string.Empty;
        }
        catch (Exception)
        {
            return UnavailableMessage;
        }
    }

    // Each run of control characters and line or paragraph separators becomes one space.
    private static void AppendSingleLine(StringBuilder text, string value)
    {
        bool inBreak = false;
        foreach (char character in value)
        {
            bool isBreak =
                char.IsControl(character)
                || (
                    char.GetUnicodeCategory(character)
                    is UnicodeCategory.LineSeparator
                        or UnicodeCategory.ParagraphSeparator
                );
            if (!isBreak)
            {
                text.Append(character);
            }
            else if (!inBreak)
            {
                text.Append(' ');
            }
            inBreak = isBreak;
        }
    }
}
