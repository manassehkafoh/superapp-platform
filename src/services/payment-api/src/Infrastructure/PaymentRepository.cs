using Microsoft.EntityFrameworkCore;
using SuperApp.Infrastructure;
using SuperApp.PaymentApi.Domain;
using System.Text.Json;

namespace SuperApp.PaymentApi.Infrastructure;

public class PaymentRepository(PaymentDbContext db) : IRepository<Payment>
{
    public async Task<Payment?> GetByIdAsync(Guid id, CancellationToken ct = default)
        => await db.Payments.FindAsync([id], ct);

    public async Task AddAsync(Payment payment, CancellationToken ct = default)
    {
        await db.Payments.AddAsync(payment, ct);
        FlushDomainEventsToOutbox(payment);
    }

    public Task UpdateAsync(Payment payment, CancellationToken ct = default)
    {
        db.Payments.Update(payment);
        FlushDomainEventsToOutbox(payment);
        return Task.CompletedTask;
    }

    public async Task<int> SaveChangesAsync(CancellationToken ct = default)
        => await db.SaveChangesAsync(ct);

    /// <summary>
    /// Writes domain events to the outbox table in the same transaction as the aggregate.
    /// The OutboxPublisher background service reads and publishes them to Kafka.
    /// </summary>
    private void FlushDomainEventsToOutbox(Payment payment)
    {
        foreach (var evt in payment.DomainEvents)
        {
            db.OutboxMessages.Add(new OutboxMessage
            {
                EventType    = evt.EventType,
                AggregateId  = evt.AggregateId,
                CorrelationId = evt.CorrelationId,
                EventPayload = JsonSerializer.Serialize(evt, evt.GetType()),
                OccurredAt   = evt.OccurredAt,
            });
        }
        payment.ClearDomainEvents();
    }
}
