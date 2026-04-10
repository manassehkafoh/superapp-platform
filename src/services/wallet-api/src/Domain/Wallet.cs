using SuperApp.Domain;
using SuperApp.Messaging.Events;

namespace SuperApp.WalletApi.Domain;

public enum WalletStatus { Active, Frozen, Closed }

/// <summary>
/// Wallet aggregate using a double-entry ledger pattern.
/// Every balance change creates a LedgerEntry (debit or credit).
/// Balance = sum of all credits - sum of all debits.
/// This ensures full audit trail and correct financial reconciliation.
/// </summary>
public class Wallet : AggregateRoot
{
    public Guid         Id       { get; private set; }
    public string       UserId   { get; private set; } = default!;
    public string       Currency { get; private set; } = default!;
    public WalletStatus Status   { get; private set; }
    public DateTimeOffset CreatedAt { get; private set; }

    private readonly List<LedgerEntry> _entries = [];
    public IReadOnlyList<LedgerEntry> Entries => _entries.AsReadOnly();

    // Balance computed from ledger — never stored directly (prevents drift)
    public decimal Balance => _entries.Sum(e => e.IsCredit ? e.Amount : -e.Amount);

    private Wallet() { }

    public static Wallet Open(string userId, string currency)
        => new() { Id = Guid.NewGuid(), UserId = userId, Currency = currency,
                   Status = WalletStatus.Active, CreatedAt = DateTimeOffset.UtcNow };

    public void Credit(decimal amount, string reference, string correlationId)
    {
        EnsureActive();
        _entries.Add(LedgerEntry.Credit(amount, reference));
        Raise(new WalletCredited(Id.ToString(), correlationId,
            Id.ToString(), UserId, amount, Currency, reference));
    }

    public void Debit(decimal amount, string reference, string correlationId)
    {
        EnsureActive();
        if (Balance < amount) throw new InvalidOperationException("Insufficient balance");
        _entries.Add(LedgerEntry.Debit(amount, reference));
        Raise(new WalletDebited(Id.ToString(), correlationId,
            Id.ToString(), UserId, amount, Currency, reference));
    }

    private void EnsureActive()
    {
        if (Status != WalletStatus.Active)
            throw new InvalidOperationException($"Wallet {Id} is {Status}");
    }
}

public record LedgerEntry(Guid Id, decimal Amount, bool IsCredit, string Reference, DateTimeOffset OccurredAt)
{
    public static LedgerEntry Credit(decimal amount, string ref_) =>
        new(Guid.NewGuid(), amount, true,  ref_, DateTimeOffset.UtcNow);
    public static LedgerEntry Debit(decimal amount, string ref_) =>
        new(Guid.NewGuid(), amount, false, ref_, DateTimeOffset.UtcNow);
}
