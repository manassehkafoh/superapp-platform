using Microsoft.AspNetCore.Mvc;
using SuperApp.Common;

namespace SuperApp.IdentityApi.Api;

public record RegisterRequest(string Email, string PhoneNumber, string Password);
public record LoginRequest(string Email, string Password, string? MfaCode);
public record TokenResponse(string AccessToken, string RefreshToken, int ExpiresIn);

public static class AuthEndpoints
{
    public static IEndpointRouteBuilder MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/auth").WithTags("Authentication").WithOpenApi();

        group.MapPost("/register", async (
            [FromBody] RegisterRequest req,
            [FromServices] IRegisterUserHandler handler,
            HttpContext ctx, CancellationToken ct) =>
        {
            var correlationId = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();
            var result = await handler.HandleAsync(req, correlationId, ct);
            return result.Match(
                onSuccess: u  => Results.Created($"/api/v1/users/{u}", new { UserId = u }),
                onFailure: e  => e is ValidationError v
                    ? Results.UnprocessableEntity(new { v.Code, v.Message })
                    : Results.Problem(e.Message, statusCode: 500));
        })
        .WithName("RegisterUser")
        .AllowAnonymous();

        group.MapPost("/login", async (
            [FromBody] LoginRequest req,
            [FromServices] ILoginHandler handler,
            HttpContext ctx, CancellationToken ct) =>
        {
            var result = await handler.HandleAsync(req, ct);
            return result.Match(
                onSuccess: t  => Results.Ok(t),
                onFailure: e  => Results.Unauthorized());
        })
        .WithName("Login")
        .AllowAnonymous();

        group.MapPost("/refresh", async (
            [FromHeader(Name = "X-Refresh-Token")] string refreshToken,
            [FromServices] IRefreshTokenHandler handler, CancellationToken ct) =>
        {
            var result = await handler.HandleAsync(refreshToken, ct);
            return result.Match(Results.Ok, _ => Results.Unauthorized());
        })
        .WithName("RefreshToken")
        .AllowAnonymous();

        group.MapGet("/health", () => Results.Ok(new { status = "Healthy" }))
            .AllowAnonymous().WithName("AuthHealth");

        return app;
    }
}
