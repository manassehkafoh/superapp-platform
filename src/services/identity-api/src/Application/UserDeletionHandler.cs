using MassTransit;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.Common;
using SuperApp.IdentityApi.Domain;
using SuperApp.IdentityApi.Infrastructure;
using SuperApp.Messaging.Events;

namespace SuperApp.IdentityApi.Application;

public interface IUserDeletionHandler
{
    Task<Result<bool>> HandleAsync(string userId, string requestedByUserId,
        string reason, string correlationId, CancellationToken ct = default);
}

/// <summary>
/// Handles GDPR / BoG right-to-erasure requests.
///
/// Flow:
///  1. Validate user exists and requester is authorised
///  2. Anonymise PII in IdentityDB immediately
///  3. Revoke all active refresh tokens
///  4. Publish UserDataDeletionRequested to Kafka
///     → account-api, wallet-api, notification-api consume and anonymise
///  5. Financial records retained for 7 years (legal obligation)
///
/// GAP-002 CLOSED: 2024-Q1
/// </summary>
public class UserDeletionHandler(
    IdentityDbContext db,
    IPublishEndpoint bus,
    ILogger<UserDeletionHandler> logger
) : IUserDeletionHandler
{
    public async Task<Result<bool>> HandleAsync(
        string userId, string requestedByUserId,
        string reason, string correlationId, CancellationToken ct = default)
    {
        var uid = Guid.Parse(userId);

        var user = await db.Users.FindAsync([uid], ct);
        if (user is null)
            return Result.Fail<bool>(new NotFoundError("USR-404", $"User {userId} not found"));

        // Only the user themselves or an admin can request deletion
        if (requestedByUserId != userId
            && !await IsAdminAsync(requestedByUserId, ct))
            return Result.Fail<bool>(new ForbiddenError("USR-403",
                "You are not authorised to request deletion for this account"));

        // ── Anonymise PII in IdentityDB ───────────────────────────────────
        var anonymisedEmail = $"deleted_{uid:N}@erased.superapp.internal";
        var anonymisedPhone = $"+000{uid.ToString("N")[..8]}";

        // Directly update via EF — shadow properties to avoid domain event recursion
        await db.Database.ExecuteSqlRawAsync(
            @"UPDATE Users SET
                Email        = {0},
                PhoneNumber  = {1},
                PasswordHash = '$2a$12$DELETED_ACCOUNT_NO_LOGIN_POSSIBLE_XXXXXXXXXXXXXXXXXXXXXXXXX',
                [Status]     = 'Closed'
              WHERE Id = {2}",
            anonymisedEmail, anonymisedPhone, uid);

        // Revoke all refresh tokens immediately
        await db.Database.ExecuteSqlRawAsync(
            "UPDATE RefreshTokens SET RevokedAt = SYSUTCDATETIME() WHERE UserId = {0} AND RevokedAt IS NULL",
            uid);

        logger.LogInformation(
            "User {UserId} PII anonymised in IdentityDB by {RequestedBy} [{CorrelationId}]",
            userId, requestedByUserId, correlationId);

        // ── Publish deletion event → all other services consume ───────────
        var retentionExpiry = DateTimeOffset.UtcNow.AddYears(7); // Financial records retained 7yr

        await bus.Publish(new UserDataDeletionRequested(
            AggregateId:        userId,
            CorrelationId:      correlationId,
            UserId:             userId,
            RequestedByUserId:  requestedByUserId,
            DeletionReason:     reason,
            RequestedAt:        DateTimeOffset.UtcNow,
            RetentionExpiryAt:  retentionExpiry));

        logger.LogInformation(
            "UserDataDeletionRequested published for {UserId}. Financial records retained until {Expiry}",
            userId, retentionExpiry);

        return Result.Ok(true);
    }

    private async Task<bool> IsAdminAsync(string userId, CancellationToken ct)
    {
        // TODO: check Azure AD group membership via Graph API
        // For now: admins have a specific claim validated at JWT level
        return await Task.FromResult(false);
    }
}
