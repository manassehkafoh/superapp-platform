using SuperApp.Domain;
namespace SuperApp.Infrastructure;

/// <summary>
/// Generic repository contract. Implementations use EF Core.
/// All write operations must call SaveChangesAsync to persist both the
/// aggregate state AND flush domain events to the outbox in one transaction.
/// </summary>
public interface IRepository<T> where T : AggregateRoot
{
    Task<T?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task AddAsync(T aggregate, CancellationToken ct = default);
    Task UpdateAsync(T aggregate, CancellationToken ct = default);
    Task<int> SaveChangesAsync(CancellationToken ct = default);
}
