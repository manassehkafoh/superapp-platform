using SuperApp.Domain;
namespace SuperApp.Messaging.Events;

public record WalletCredited(string AggregateId, string CorrelationId,
    string WalletId, string UserId, decimal Amount, string Currency, string Reference
) : DomainEventBase(AggregateId, CorrelationId);

public record WalletDebited(string AggregateId, string CorrelationId,
    string WalletId, string UserId, decimal Amount, string Currency, string Reference
) : DomainEventBase(AggregateId, CorrelationId);
