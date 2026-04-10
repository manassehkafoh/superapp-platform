using Microsoft.AspNetCore.Mvc;
using SuperApp.Common;
using SuperApp.IdentityApi.Application;

namespace SuperApp.IdentityApi.Api;

public record RegisterRequest(string Email, string PhoneNumber, string Password);
public record LoginRequest(string Email, string Password, string? MfaCode);
public record TokenResponse(string AccessToken, string RefreshToken, int ExpiresIn);
public record DeleteAccountRequest(string Reason);

public static class AuthEndpoints
{
    public static IEndpointRouteBuilder MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        // ── Public auth endpoints ──────────────────────────────────────────
        var pub = app.MapGroup("/api/v1/auth").WithTags("Authentication").WithOpenApi();

        pub.MapPost("/register", async (
            [FromBody] RegisterRequest req,
            [FromServices] IRegisterUserHandler handler,
            HttpContext ctx, CancellationToken ct) =>
        {
            var corr = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();
            var r = await handler.HandleAsync(req, corr, ct);
            return r.Match(
                onSuccess: id  => Results.Created($"/api/v1/users/{id}", new { UserId = id }),
                onFailure: e   => e is ValidationError v
                    ? Results.UnprocessableEntity(new { v.Code, v.Message })
                    : Results.Problem(e.Message, statusCode: 500));
        })
        .WithName("RegisterUser")
        .AllowAnonymous();

        pub.MapPost("/login", async (
            [FromBody] LoginRequest req,
            [FromServices] ILoginHandler handler,
            CancellationToken ct) =>
        {
            var r = await handler.HandleAsync(req, ct);
            return r.Match(
                onSuccess: t  => Results.Ok(t),
                onFailure: e  => e is BusinessRuleError b
                    ? Results.Problem(b.Message, statusCode: 423)   // 423 Locked
                    : Results.Unauthorized());
        })
        .WithName("Login")
        .AllowAnonymous()
        .Produces<TokenResponse>()
        .ProducesProblem(423);

        pub.MapPost("/refresh", async (
            [FromHeader(Name = "X-Refresh-Token")] string refreshToken,
            [FromServices] IRefreshTokenHandler handler,
            CancellationToken ct) =>
        {
            var r = await handler.HandleAsync(refreshToken, ct);
            return r.Match(Results.Ok, _ => Results.Unauthorized());
        })
        .WithName("RefreshToken")
        .AllowAnonymous();

        pub.MapGet("/health", () => Results.Ok(new { status = "Healthy" }))
            .AllowAnonymous()
            .WithName("AuthHealth");

        // ── Authenticated user endpoints ───────────────────────────────────
        var user = app.MapGroup("/api/v1/users").RequireAuthorization().WithTags("Users").WithOpenApi();

        /// <summary>
        /// GDPR / BoG right-to-erasure endpoint.
        /// Anonymises PII immediately; publishes deletion event to all services.
        /// Financial records retained for 7 years (legal obligation).
        /// GAP-002 CLOSED.
        /// </summary>
        user.MapDelete("/{id}", async (
            string id,
            [FromBody] DeleteAccountRequest req,
            [FromServices] IUserDeletionHandler deletionHandler,
            HttpContext ctx,
            CancellationToken ct) =>
        {
            var requesterId = ctx.User.FindFirst("sub")?.Value ?? string.Empty;
            var corr        = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();

            var r = await deletionHandler.HandleAsync(id, requesterId, req.Reason, corr, ct);
            return r.Match(
                onSuccess: _ => Results.Accepted("/api/v1/users/erasure-status",
                    new { message = "Account deletion initiated. PII will be removed within 24 hours." }),
                onFailure: e => e switch {
                    NotFoundError  => Results.NotFound(),
                    ForbiddenError => Results.Forbid(),
                    _              => Results.Problem(e.Message, statusCode: 500)
                });
        })
        .WithName("DeleteUserAccount")
        .Produces(202)
        .ProducesProblem(403)
        .ProducesProblem(404);

        return app;
    }
}
