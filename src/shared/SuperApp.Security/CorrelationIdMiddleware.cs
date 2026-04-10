using SuperApp.Common;
namespace SuperApp.Security;

/// <summary>
/// Reads X-Correlation-ID from inbound requests (or generates one if absent).
/// Writes it back to the response header and stores it in HttpContext.Items
/// for downstream logging and event publishing.
/// </summary>
public class CorrelationIdMiddleware(RequestDelegate next)
{
    private const string HeaderName = "X-Correlation-ID";

    public async Task InvokeAsync(HttpContext ctx, ICorrelationIdAccessor accessor)
    {
        var correlationId = ctx.Request.Headers[HeaderName].FirstOrDefault()
                            ?? Guid.NewGuid().ToString();

        ctx.Items[HeaderName] = correlationId;
        ctx.Response.Headers[HeaderName] = correlationId;

        await next(ctx);
    }
}

public static class CorrelationIdExtensions
{
    public static IApplicationBuilder UseCorrelationId(this IApplicationBuilder app)
        => app.UseMiddleware<CorrelationIdMiddleware>();
}
