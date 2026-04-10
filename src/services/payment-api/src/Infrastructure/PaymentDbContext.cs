using Microsoft.EntityFrameworkCore;
using SuperApp.Infrastructure;
using SuperApp.PaymentApi.Domain;

namespace SuperApp.PaymentApi.Infrastructure;

/// <summary>
/// EF Core DbContext for the payment bounded context.
/// Each bounded context owns its own DbContext — never share across services.
/// Outbox table included for guaranteed-delivery event publishing.
/// </summary>
public class PaymentDbContext(DbContextOptions<PaymentDbContext> options) : DbContext(options)
{
    public DbSet<Payment>      Payments      => Set<Payment>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Payment>(e =>
        {
            e.ToTable("Payments");
            e.HasKey(p => p.Id);
            e.Property(p => p.Id).ValueGeneratedNever();
            e.Property(p => p.SourceWalletId).HasMaxLength(100).IsRequired();
            e.Property(p => p.DestinationAccount).HasMaxLength(50).IsRequired();
            e.Property(p => p.Amount).HasPrecision(18, 4).IsRequired();
            e.Property(p => p.Currency).HasMaxLength(3).IsRequired();
            e.Property(p => p.Status).HasConversion<string>().HasMaxLength(20);
            e.Property(p => p.Rail).HasConversion<string>().HasMaxLength(30);
            e.Property(p => p.InitiatedByUserId).HasMaxLength(100).IsRequired();
            e.Property(p => p.ExternalReference).HasMaxLength(200);
            e.Property(p => p.FailureReason).HasMaxLength(500);
            e.HasIndex(p => p.InitiatedByUserId);
            e.HasIndex(p => p.Status);
            e.HasIndex(p => p.CreatedAt);
        });

        b.Entity<OutboxMessage>(e =>
        {
            e.ToTable("OutboxMessages");
            e.HasKey(o => o.Id);
            e.Property(o => o.EventType).HasMaxLength(200).IsRequired();
            e.Property(o => o.AggregateId).HasMaxLength(100).IsRequired();
            e.Property(o => o.CorrelationId).HasMaxLength(100).IsRequired();
            e.Property(o => o.EventPayload).IsRequired();           // JSON — no length limit
            e.HasIndex(o => o.ProcessedAt);                         // null = unprocessed
            e.HasIndex(o => new { o.AggregateId, o.OccurredAt });
        });
    }
}
