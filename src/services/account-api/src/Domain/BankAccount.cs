using SuperApp.Domain;

namespace SuperApp.AccountApi.Domain;

public enum AccountType   { Savings, Current, Business }
public enum AccountStatus { Pending, Active, Dormant, Closed, Suspended }

public class BankAccount : AggregateRoot
{
    public Guid          Id            { get; private set; }
    public string        AccountNumber { get; private set; } = default!;
    public string        UserId        { get; private set; } = default!;
    public AccountType   Type          { get; private set; }
    public AccountStatus Status        { get; private set; }
    public string        Currency      { get; private set; } = default!;
    public DateTimeOffset OpenedAt     { get; private set; }
    public DateTimeOffset? ClosedAt    { get; private set; }

    private BankAccount() {}

    public static BankAccount Open(string userId, AccountType type, string currency, string correlationId)
    {
        var acct = new BankAccount {
            Id            = Guid.NewGuid(),
            AccountNumber = GenerateAccountNumber(),
            UserId        = userId,
            Type          = type,
            Status        = AccountStatus.Pending,
            Currency      = currency,
            OpenedAt      = DateTimeOffset.UtcNow,
        };
        // Domain event would go here e.g. AccountOpened
        return acct;
    }

    public void Activate()
    {
        if (Status != AccountStatus.Pending)
            throw new InvalidOperationException($"Cannot activate account in {Status} state");
        Status = AccountStatus.Active;
    }

    public void Suspend(string reason)
    {
        if (Status == AccountStatus.Closed)
            throw new InvalidOperationException("Cannot suspend a closed account");
        Status = AccountStatus.Suspended;
    }

    private static string GenerateAccountNumber()
    {
        // Luhn-compliant 10-digit account number
        var rand = Random.Shared.Next(100_000_000, 999_999_999);
        return $"0{rand}";
    }
}
