using SuperApp.Domain;
using SuperApp.Messaging.Events;

namespace SuperApp.IdentityApi.Domain;

public enum UserTier   { Basic, Premium, Business }
public enum UserStatus { PendingVerification, Active, Suspended, Closed }
public enum KycLevel   { None, Tier1, Tier2, Tier3 }

public class User : AggregateRoot
{
    public Guid        Id           { get; private set; }
    public string      Email        { get; private set; } = default!;
    public string      PhoneNumber  { get; private set; } = default!;
    public string      PasswordHash { get; private set; } = default!;
    public UserTier    Tier         { get; private set; }
    public UserStatus  Status       { get; private set; }
    public KycLevel    KycLevel     { get; private set; }
    public bool        MfaEnabled   { get; private set; }
    public DateTimeOffset CreatedAt { get; private set; }

    private User() { }

    public static User Register(string email, string phoneNumber,
        string passwordHash, string correlationId)
    {
        var user = new User {
            Id          = Guid.NewGuid(),
            Email       = email.ToLowerInvariant(),
            PhoneNumber = phoneNumber,
            PasswordHash = passwordHash,
            Tier        = UserTier.Basic,
            Status      = UserStatus.PendingVerification,
            KycLevel    = KycLevel.None,
            MfaEnabled  = false,
            CreatedAt   = DateTimeOffset.UtcNow,
        };

        user.Raise(new UserRegistered(user.Id.ToString(), correlationId,
            user.Id.ToString(), email, phoneNumber, user.Tier.ToString()));
        return user;
    }

    public void CompleteKyc(KycLevel level, string verifiedBy, string correlationId)
    {
        KycLevel = level;
        if (Status == UserStatus.PendingVerification)
            Status = UserStatus.Active;
        Raise(new UserKycCompleted(Id.ToString(), correlationId,
            Id.ToString(), level.ToString(), verifiedBy));
    }
}
