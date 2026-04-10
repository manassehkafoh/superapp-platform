using SuperApp.Domain;
namespace SuperApp.Messaging.Events;

public record UserRegistered(string AggregateId, string CorrelationId,
    string UserId, string Email, string PhoneNumber, string Tier
) : DomainEventBase(AggregateId, CorrelationId);

public record UserKycCompleted(string AggregateId, string CorrelationId,
    string UserId, string KycLevel, string VerifiedBy
) : DomainEventBase(AggregateId, CorrelationId);
