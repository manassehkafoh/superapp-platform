namespace SuperApp.Domain;

/// <summary>
/// Marker interface for all domain events.
/// Domain events are raised within aggregates and published to Kafka after
/// the aggregate is persisted (transactional outbox pattern).
/// </summary>
public interface IDomainEvent
{
    Guid   EventId        { get; }
    string EventType      { get; }
    string AggregateId    { get; }
    DateTimeOffset OccurredAt { get; }
    string CorrelationId  { get; }
}

/// <summary>Base record for all domain events with default property implementations.</summary>
public abstract record DomainEventBase(string AggregateId, string CorrelationId) : IDomainEvent
{
    public Guid   EventId     { get; } = Guid.NewGuid();
    public string EventType   => GetType().Name;
    public DateTimeOffset OccurredAt { get; } = DateTimeOffset.UtcNow;
}
