using Microsoft.EntityFrameworkCore;
using SuperApp.Infrastructure;
using SuperApp.WalletApi.Domain;

namespace SuperApp.WalletApi.Infrastructure;

public class WalletDbContext(DbContextOptions<WalletDbContext> opts) : DbContext(opts)
{
    public DbSet<Wallet>       Wallets        => Set<Wallet>();
    public DbSet<LedgerEntry>  LedgerEntries  => Set<LedgerEntry>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Wallet>(e => {
            e.ToTable("Wallets");
            e.HasKey(w => w.Id);
            e.Property(w => w.UserId).HasMaxLength(100).IsRequired();
            e.Property(w => w.Currency).HasMaxLength(3).IsRequired();
            e.Property(w => w.Status).HasConversion<string>().HasMaxLength(20);
            e.HasIndex(w => w.UserId);
            // Balance is computed, NOT stored — prevents drift
            e.Ignore(w => w.Balance);
        });

        b.Entity<LedgerEntry>(e => {
            e.ToTable("LedgerEntries");
            e.HasKey(le => le.Id);
            e.Property(le => le.Amount).HasPrecision(18, 4).IsRequired();
            e.Property(le => le.Reference).HasMaxLength(200).IsRequired();
            e.HasIndex(le => le.Reference);
        });

        b.Entity<OutboxMessage>(e => {
            e.ToTable("OutboxMessages");
            e.HasKey(o => o.Id);
            e.HasIndex(o => o.ProcessedAt);
        });
    }
}
