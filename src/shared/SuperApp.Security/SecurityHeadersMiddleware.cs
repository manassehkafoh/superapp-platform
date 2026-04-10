namespace SuperApp.Security;

/// <summary>
/// Adds security response headers to every response.
/// Protects against XSS, clickjacking, MIME sniffing.
/// </summary>
public class SecurityHeadersMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        ctx.Response.Headers["X-Content-Type-Options"]    = "nosniff";
        ctx.Response.Headers["X-Frame-Options"]           = "DENY";
        ctx.Response.Headers["X-XSS-Protection"]          = "1; mode=block";
        ctx.Response.Headers["Referrer-Policy"]           = "strict-origin-when-cross-origin";
        ctx.Response.Headers["Permissions-Policy"]        = "geolocation=(), camera=(), microphone=()";
        ctx.Response.Headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains; preload";
        ctx.Response.Headers["Content-Security-Policy"]   =
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'";
        await next(ctx);
    }
}

public static class SecurityHeadersExtensions
{
    public static IApplicationBuilder UseSecurityHeaders(this IApplicationBuilder app)
        => app.UseMiddleware<SecurityHeadersMiddleware>();
}
