using SuperApp.Domain;

namespace SuperApp.Messaging.Events;

/// <summary>Published when a new user completes registration.</summary>
public record UserRegistered(
    string AggregateId,
    string CorrelationId,
    string UserId,
    string Email,
    string PhoneNumber,
    string Tier
) : DomainEventBase(AggregateId, CorrelationId);

/// <summary>Published when KYC verification is completed for a user.</summary>
public record UserKycCompleted(
    string AggregateId,
    string CorrelationId,
    string UserId,
    string KycLevel,
    string VerifiedBy
) : DomainEventBase(AggregateId, CorrelationId);

/// <summary>
/// Published when a user requests deletion under GDPR / Bank of Ghana data rights.
/// All services MUST consume this event and anonymise or delete user PII.
///
/// IMPORTANT — Legal retention rules:
///   Financial records (payments, ledger entries) MUST be retained for 7 years (BoG / AML).
///   Only PII fields (name, email, phone, address) should be anonymised or removed.
///   Account numbers must be retained but can be pseudonymised.
///
/// GAP-002 CLOSED: 2024-Q1
/// </summary>
public record UserDataDeletionRequested(
    string AggregateId,
    string CorrelationId,
    string UserId,
    string RequestedByUserId,
    string DeletionReason,        // USER_REQUEST | REGULATORY | FRAUD
    DateTimeOffset RequestedAt,
    DateTimeOffset RetentionExpiryAt   // Financial records retained until this date
) : DomainEventBase(AggregateId, CorrelationId);

/// <summary>Published after all services have confirmed erasure (saga outcome).</summary>
public record UserDataErasureCompleted(
    string AggregateId,
    string CorrelationId,
    string UserId,
    DateTimeOffset CompletedAt
) : DomainEventBase(AggregateId, CorrelationId);
