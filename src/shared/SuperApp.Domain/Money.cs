namespace SuperApp.Domain;

/// <summary>
/// Value object representing a monetary amount with currency.
/// Immutable. Enforces positive amounts and valid ISO-4217 currency codes.
/// All financial calculations MUST use decimal to avoid floating-point errors.
/// </summary>
public record Money
{
    public decimal Amount { get; }
    public string  Currency { get; }

    private static readonly HashSet<string> ValidCurrencies = ["GHS", "USD", "EUR", "GBP"];

    public Money(decimal amount, string currency)
    {
        if (amount < 0)
            throw new ArgumentException("Amount cannot be negative", nameof(amount));
        if (!ValidCurrencies.Contains(currency.ToUpperInvariant()))
            throw new ArgumentException($"Unsupported currency: {currency}", nameof(currency));

        Amount   = amount;
        Currency = currency.ToUpperInvariant();
    }

    public static Money Zero(string currency) => new(0m, currency);

    public Money Add(Money other)
    {
        EnsureSameCurrency(other);
        return new(Amount + other.Amount, Currency);
    }

    public Money Subtract(Money other)
    {
        EnsureSameCurrency(other);
        if (Amount < other.Amount)
            throw new InvalidOperationException("Insufficient funds");
        return new(Amount - other.Amount, Currency);
    }

    private void EnsureSameCurrency(Money other)
    {
        if (Currency != other.Currency)
            throw new InvalidOperationException($"Currency mismatch: {Currency} vs {other.Currency}");
    }

    public override string ToString() => $"{Currency} {Amount:F2}";
}
