namespace SuperApp.Infrastructure;

/// <summary>
/// Outbox pattern: domain events are saved to this table in the same DB transaction
/// as the aggregate. A background worker reads and publishes them to Kafka,
/// guaranteeing at-least-once delivery even if Kafka is temporarily unavailable.
/// </summary>
public class OutboxMessage
{
    public Guid      Id           { get; set; } = Guid.NewGuid();
    public string    EventType    { get; set; } = default!;
    public string    EventPayload { get; set; } = default!;  // JSON
    public string    AggregateId  { get; set; } = default!;
    public string    CorrelationId { get; set; } = default!;
    public DateTimeOffset OccurredAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ProcessedAt { get; set; }
    public int       RetryCount   { get; set; }
    public string?   Error        { get; set; }
}
