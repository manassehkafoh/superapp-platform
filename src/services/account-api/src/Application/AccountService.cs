using Microsoft.EntityFrameworkCore;
using SuperApp.AccountApi.Domain;
using SuperApp.AccountApi.Infrastructure;
using SuperApp.Common;

namespace SuperApp.AccountApi.Application;

public record AccountDto(Guid Id, string AccountNumber, string Type, string Status, string Currency, DateTimeOffset OpenedAt);
public record OpenAccountRequest(string AccountType, string Currency);

public interface IAccountService
{
    Task<Result<AccountDto>> OpenAccountAsync(string userId, OpenAccountRequest req, string correlationId, CancellationToken ct = default);
    Task<Result<AccountDto>> GetAccountAsync(Guid id, CancellationToken ct = default);
    Task<Result<IReadOnlyList<AccountDto>>> GetUserAccountsAsync(string userId, CancellationToken ct = default);
}

public class AccountService(AccountDbContext db) : IAccountService
{
    public async Task<Result<AccountDto>> OpenAccountAsync(string userId, OpenAccountRequest req, string correlationId, CancellationToken ct = default)
    {
        if (!Enum.TryParse<AccountType>(req.AccountType, true, out var type))
            return Result.Fail<AccountDto>(new ValidationError("ACC-001", $"Unknown account type: {req.AccountType}"));
        var account = BankAccount.Open(userId, type, req.Currency, correlationId);
        await db.Accounts.AddAsync(account, ct);
        await db.SaveChangesAsync(ct);
        return Result.Ok(ToDto(account));
    }

    public async Task<Result<AccountDto>> GetAccountAsync(Guid id, CancellationToken ct = default)
    {
        var a = await db.Accounts.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id, ct);
        return a is null
            ? Result.Fail<AccountDto>(new NotFoundError("ACC-404", $"Account {id} not found"))
            : Result.Ok(ToDto(a));
    }

    public async Task<Result<IReadOnlyList<AccountDto>>> GetUserAccountsAsync(string userId, CancellationToken ct = default)
    {
        var accounts = await db.Accounts.AsNoTracking()
            .Where(a => a.UserId == userId && a.Status != AccountStatus.Closed)
            .Select(a => ToDto(a))
            .ToListAsync(ct);
        return Result.Ok<IReadOnlyList<AccountDto>>(accounts);
    }

    private static AccountDto ToDto(BankAccount a) =>
        new(a.Id, a.AccountNumber, a.Type.ToString(), a.Status.ToString(), a.Currency, a.OpenedAt);
}
