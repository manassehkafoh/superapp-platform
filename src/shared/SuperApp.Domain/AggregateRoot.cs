namespace SuperApp.Domain;

/// <summary>
/// Base class for DDD aggregate roots.
/// Aggregates collect domain events internally; the repository publishes them
/// after committing the transaction (transactional outbox).
/// </summary>
public abstract class AggregateRoot
{
    private readonly List<IDomainEvent> _domainEvents = [];

    public IReadOnlyList<IDomainEvent> DomainEvents => _domainEvents.AsReadOnly();

    protected void Raise(IDomainEvent domainEvent) => _domainEvents.Add(domainEvent);

    public void ClearDomainEvents() => _domainEvents.Clear();
}
