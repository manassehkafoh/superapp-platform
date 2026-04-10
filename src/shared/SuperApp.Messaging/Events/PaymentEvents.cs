using SuperApp.Domain;
namespace SuperApp.Messaging.Events;

public record PaymentInitiated(string AggregateId, string CorrelationId,
    Guid PaymentId, string SourceWalletId, string DestinationAccount,
    decimal Amount, string Currency, string PaymentRail, string InitiatedByUserId
) : DomainEventBase(AggregateId, CorrelationId);

public record PaymentCompleted(string AggregateId, string CorrelationId,
    Guid PaymentId, string ExternalReference, decimal Amount, string Currency
) : DomainEventBase(AggregateId, CorrelationId);

public record PaymentFailed(string AggregateId, string CorrelationId,
    Guid PaymentId, string FailureCode, string FailureReason
) : DomainEventBase(AggregateId, CorrelationId);
