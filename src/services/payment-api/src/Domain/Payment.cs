using SuperApp.Domain;
using SuperApp.Messaging.Events;

namespace SuperApp.PaymentApi.Domain;

public enum PaymentStatus { Pending, Debiting, Processing, Completed, Failed, Reversed }
public enum PaymentRail   { GhIPSS, ExpressPay, Hubtel, InternalTransfer }

/// <summary>
/// Payment aggregate root. Encapsulates all state transitions for a payment.
/// Raises domain events consumed by wallet-api (saga) and notification-api.
/// </summary>
public class Payment : AggregateRoot
{
    public Guid          Id                { get; private set; }
    public string        SourceWalletId    { get; private set; } = default!;
    public string        DestinationAccount { get; private set; } = default!;
    public decimal       Amount            { get; private set; }
    public string        Currency          { get; private set; } = default!;
    public PaymentStatus Status            { get; private set; }
    public PaymentRail   Rail              { get; private set; }
    public string        InitiatedByUserId { get; private set; } = default!;
    public string?       ExternalReference { get; private set; }
    public string?       FailureReason     { get; private set; }
    public DateTimeOffset CreatedAt        { get; private set; }
    public DateTimeOffset? CompletedAt     { get; private set; }

    private Payment() { } // EF Core

    public static Payment Create(
        string sourceWalletId, string destinationAccount,
        decimal amount, string currency,
        PaymentRail rail, string initiatedByUserId,
        string correlationId)
    {
        var payment = new Payment
        {
            Id                = Guid.NewGuid(),
            SourceWalletId    = sourceWalletId,
            DestinationAccount = destinationAccount,
            Amount            = amount,
            Currency          = currency,
            Status            = PaymentStatus.Pending,
            Rail              = rail,
            InitiatedByUserId = initiatedByUserId,
            CreatedAt         = DateTimeOffset.UtcNow,
        };

        payment.Raise(new PaymentInitiated(
            payment.Id.ToString(), correlationId,
            payment.Id, sourceWalletId, destinationAccount,
            amount, currency, rail.ToString(), initiatedByUserId));

        return payment;
    }

    public void MarkCompleted(string externalReference)
    {
        if (Status != PaymentStatus.Processing)
            throw new InvalidOperationException($"Cannot complete payment in status {Status}");

        ExternalReference = externalReference;
        Status            = PaymentStatus.Completed;
        CompletedAt       = DateTimeOffset.UtcNow;

        Raise(new PaymentCompleted(Id.ToString(), string.Empty, Id, externalReference, Amount, Currency));
    }

    public void MarkFailed(string failureCode, string reason)
    {
        FailureReason = reason;
        Status        = PaymentStatus.Failed;
        Raise(new PaymentFailed(Id.ToString(), string.Empty, Id, failureCode, reason));
    }
}
