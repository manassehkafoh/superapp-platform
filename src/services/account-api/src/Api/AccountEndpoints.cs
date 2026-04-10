using Microsoft.AspNetCore.Mvc;
using SuperApp.AccountApi.Application;
using SuperApp.Common;

namespace SuperApp.AccountApi.Api;

public static class AccountEndpoints
{
    public static IEndpointRouteBuilder MapAccountEndpoints(this IEndpointRouteBuilder app)
    {
        var g = app.MapGroup("/api/v1/accounts").RequireAuthorization().WithTags("Accounts").WithOpenApi();

        g.MapPost("/", async ([FromBody] OpenAccountRequest req, IAccountService svc, HttpContext ctx, CancellationToken ct) => {
            var userId = ctx.User.FindFirst("sub")?.Value ?? string.Empty;
            var corrId = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();
            var r = await svc.OpenAccountAsync(userId, req, corrId, ct);
            return r.Match(a => Results.Created($"/api/v1/accounts/{a.Id}", a),
                e => e is ValidationError ? Results.UnprocessableEntity(new { e.Code, e.Message }) : Results.Problem());
        }).WithName("OpenAccount").Produces<AccountDto>(201);

        g.MapGet("/{id:guid}", async (Guid id, IAccountService svc, CancellationToken ct) => {
            var r = await svc.GetAccountAsync(id, ct);
            return r.Match(Results.Ok, e => e is NotFoundError ? Results.NotFound() : Results.Problem());
        }).WithName("GetAccount").Produces<AccountDto>();

        g.MapGet("/", async (IAccountService svc, HttpContext ctx, CancellationToken ct) => {
            var userId = ctx.User.FindFirst("sub")?.Value ?? string.Empty;
            var r = await svc.GetUserAccountsAsync(userId, ct);
            return r.Match(Results.Ok, _ => Results.Problem());
        }).WithName("ListAccounts").Produces<IReadOnlyList<AccountDto>>();

        return app;
    }
}
