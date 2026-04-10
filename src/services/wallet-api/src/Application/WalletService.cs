using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.Common;
using SuperApp.Infrastructure;
using SuperApp.WalletApi.Domain;
using SuperApp.WalletApi.Infrastructure;

namespace SuperApp.WalletApi.Application;

public record WalletDto(Guid Id, string UserId, string Currency, decimal Balance, string Status);
public record TransactionDto(Guid Id, decimal Amount, bool IsCredit, string Reference, DateTimeOffset OccurredAt);

public interface IWalletService
{
    Task<Result<WalletDto>>                    GetWalletAsync(Guid walletId, CancellationToken ct = default);
    Task<Result<WalletDto>>                    OpenWalletAsync(string userId, string currency, CancellationToken ct = default);
    Task<Result<bool>>                         CreditAsync(Guid walletId, decimal amount, string reference, string correlationId, CancellationToken ct = default);
    Task<Result<bool>>                         DebitAsync(Guid walletId, decimal amount, string reference, string correlationId, CancellationToken ct = default);
    Task<Result<PagedResult<TransactionDto>>>  GetTransactionsAsync(Guid walletId, int page, int pageSize, CancellationToken ct = default);
}

public class WalletService(WalletDbContext db, ILogger<WalletService> logger) : IWalletService
{
    public async Task<Result<WalletDto>> GetWalletAsync(Guid walletId, CancellationToken ct = default)
    {
        var w = await db.Wallets
            .Include(x => x.Entries)
            .FirstOrDefaultAsync(x => x.Id == walletId, ct);
        if (w is null) return Result.Fail<WalletDto>(new NotFoundError("WAL-404", $"Wallet {walletId} not found"));
        return Result.Ok(ToDto(w));
    }

    public async Task<Result<WalletDto>> OpenWalletAsync(string userId, string currency, CancellationToken ct = default)
    {
        if (await db.Wallets.AnyAsync(w => w.UserId == userId && w.Currency == currency, ct))
            return Result.Fail<WalletDto>(new BusinessRuleError("WAL-009", $"Wallet for {currency} already exists"));
        var wallet = Wallet.Open(userId, currency);
        await db.Wallets.AddAsync(wallet, ct);
        await db.SaveChangesAsync(ct);
        logger.LogInformation("Wallet {Id} opened for user {UserId} {Currency}", wallet.Id, userId, currency);
        return Result.Ok(ToDto(wallet));
    }

    public async Task<Result<bool>> CreditAsync(Guid walletId, decimal amount, string reference, string correlationId, CancellationToken ct = default)
    {
        var w = await db.Wallets.Include(x => x.Entries).FirstOrDefaultAsync(x => x.Id == walletId, ct);
        if (w is null) return Result.Fail<bool>(new NotFoundError("WAL-404", $"Wallet {walletId} not found"));
        try { w.Credit(amount, reference, correlationId); }
        catch (InvalidOperationException ex) { return Result.Fail<bool>(new BusinessRuleError("WAL-001", ex.Message)); }
        await db.SaveChangesAsync(ct);
        return Result.Ok(true);
    }

    public async Task<Result<bool>> DebitAsync(Guid walletId, decimal amount, string reference, string correlationId, CancellationToken ct = default)
    {
        var w = await db.Wallets.Include(x => x.Entries).FirstOrDefaultAsync(x => x.Id == walletId, ct);
        if (w is null) return Result.Fail<bool>(new NotFoundError("WAL-404", $"Wallet {walletId} not found"));
        try { w.Debit(amount, reference, correlationId); }
        catch (InvalidOperationException ex) { return Result.Fail<bool>(new BusinessRuleError("WAL-002", ex.Message)); }
        await db.SaveChangesAsync(ct);
        return Result.Ok(true);
    }

    public async Task<Result<PagedResult<TransactionDto>>> GetTransactionsAsync(
        Guid walletId, int page, int pageSize, CancellationToken ct = default)
    {
        var q = db.LedgerEntries.AsNoTracking()
            .Where(le => db.Wallets.Any(w => w.Id == walletId && w.Entries.Contains(le)))
            .OrderByDescending(le => le.OccurredAt);
        var total = await q.CountAsync(ct);
        var items = await q.Skip((page - 1) * pageSize).Take(pageSize)
            .Select(le => new TransactionDto(le.Id, le.Amount, le.IsCredit, le.Reference, le.OccurredAt))
            .ToListAsync(ct);
        return Result.Ok(new PagedResult<TransactionDto>(items, page, pageSize, total));
    }

    private static WalletDto ToDto(Wallet w) =>
        new(w.Id, w.UserId, w.Currency, w.Balance, w.Status.ToString());
}
