using Microsoft.EntityFrameworkCore;
using SuperApp.AccountApi.Domain;
using SuperApp.Infrastructure;

namespace SuperApp.AccountApi.Infrastructure;

public class AccountDbContext(DbContextOptions<AccountDbContext> opts) : DbContext(opts)
{
    public DbSet<BankAccount>  Accounts       => Set<BankAccount>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<BankAccount>(e => {
            e.ToTable("BankAccounts");
            e.HasKey(a => a.Id);
            e.Property(a => a.AccountNumber).HasMaxLength(20).IsRequired();
            e.Property(a => a.UserId).HasMaxLength(100).IsRequired();
            e.Property(a => a.Type).HasConversion<string>().HasMaxLength(20);
            e.Property(a => a.Status).HasConversion<string>().HasMaxLength(20);
            e.Property(a => a.Currency).HasMaxLength(3).IsRequired();
            e.HasIndex(a => a.AccountNumber).IsUnique();
            e.HasIndex(a => a.UserId);
        });
        b.Entity<OutboxMessage>(e => { e.ToTable("OutboxMessages"); e.HasKey(o => o.Id); });
    }
}
