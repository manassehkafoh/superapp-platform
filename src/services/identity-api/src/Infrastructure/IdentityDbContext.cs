using Microsoft.EntityFrameworkCore;
using SuperApp.Infrastructure;
using SuperApp.IdentityApi.Domain;

namespace SuperApp.IdentityApi.Infrastructure;

public class IdentityDbContext(DbContextOptions<IdentityDbContext> opts) : DbContext(opts)
{
    public DbSet<User>         Users          => Set<User>();
    public DbSet<RefreshToken> RefreshTokens  => Set<RefreshToken>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<User>(e => {
            e.ToTable("Users");
            e.HasKey(u => u.Id);
            e.Property(u => u.Email).HasMaxLength(256).IsRequired();
            e.Property(u => u.PhoneNumber).HasMaxLength(20).IsRequired();
            e.Property(u => u.PasswordHash).HasMaxLength(512).IsRequired();
            e.Property(u => u.Tier).HasConversion<string>().HasMaxLength(20);
            e.Property(u => u.Status).HasConversion<string>().HasMaxLength(30);
            e.Property(u => u.KycLevel).HasConversion<string>().HasMaxLength(10);
            e.HasIndex(u => u.Email).IsUnique();
            e.HasIndex(u => u.PhoneNumber).IsUnique();
        });

        b.Entity<RefreshToken>(e => {
            e.ToTable("RefreshTokens");
            e.HasKey(r => r.Id);
            e.Property(r => r.Token).HasMaxLength(512).IsRequired();
            e.HasIndex(r => r.Token).IsUnique();
            e.HasIndex(r => r.UserId);
        });

        b.Entity<OutboxMessage>(e => {
            e.ToTable("OutboxMessages");
            e.HasKey(o => o.Id);
            e.HasIndex(o => o.ProcessedAt);
        });
    }
}
