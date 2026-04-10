namespace SuperApp.IdentityApi.Domain;

public class RefreshToken
{
    public Guid   Id        { get; set; } = Guid.NewGuid();
    public Guid   UserId    { get; set; }
    public string Token     { get; set; } = default!;  // SHA256 hash of the raw token
    public DateTimeOffset ExpiresAt  { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public bool IsActive => RevokedAt is null && ExpiresAt > DateTimeOffset.UtcNow;

    // Navigation property
    public User? User { get; set; }
}
