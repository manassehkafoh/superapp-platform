using Microsoft.AspNetCore.Mvc;
using SuperApp.WalletApi.Application;

namespace SuperApp.WalletApi.Api;

public static class WalletEndpoints
{
    public static IEndpointRouteBuilder MapWalletEndpoints(this IEndpointRouteBuilder app)
    {
        var g = app.MapGroup("/api/v1/wallets").RequireAuthorization().WithTags("Wallets").WithOpenApi();

        g.MapGet("/{id:guid}", async (Guid id, IWalletService svc, CancellationToken ct) => {
            var r = await svc.GetWalletAsync(id, ct);
            return r.Match(Results.Ok, e => e is NotFoundError ? Results.NotFound() : Results.Problem());
        }).WithName("GetWallet").Produces<WalletDto>();

        g.MapPost("/", async ([FromBody] OpenWalletRequest req, IWalletService svc, HttpContext ctx, CancellationToken ct) => {
            var userId = ctx.User.FindFirst("sub")?.Value ?? string.Empty;
            var r = await svc.OpenWalletAsync(userId, req.Currency, ct);
            return r.Match(
                w  => Results.Created($"/api/v1/wallets/{w.Id}", w),
                e  => e is BusinessRuleError ? Results.Conflict(new { e.Code, e.Message }) : Results.Problem());
        }).WithName("OpenWallet").Produces<WalletDto>(201);

        g.MapGet("/{id:guid}/transactions", async (
            Guid id, int page, int pageSize, IWalletService svc, CancellationToken ct) => {
            var r = await svc.GetTransactionsAsync(id, page < 1 ? 1 : page, pageSize < 1 ? 20 : pageSize, ct);
            return r.Match(Results.Ok, _ => Results.Problem());
        }).WithName("GetWalletTransactions");

        return app;
    }
}

public record OpenWalletRequest(string Currency);
