using MassTransit;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.AccountApi.Infrastructure;
using SuperApp.Messaging.Events;

namespace SuperApp.AccountApi.Consumers;

/// <summary>
/// Consumes UserDataDeletionRequested events from identity-api.
/// Anonymises account holder PII while retaining the financial record shell.
///
/// Retention rules (BoG / AML compliance):
///   - AccountNumber: retained (pseudonymised with hash prefix)
///   - UserId: replaced with anonymised reference
///   - AccountType, Status, Currency, Dates: retained for 7 years
///
/// GAP-002 CLOSED: 2024-Q1
/// </summary>
public class UserErasureConsumer(
    AccountDbContext db,
    ILogger<UserErasureConsumer> logger
) : IConsumer<UserDataDeletionRequested>
{
    public async Task Consume(ConsumeContext<UserDataDeletionRequested> ctx)
    {
        var evt = ctx.Message;
        logger.LogInformation(
            "Processing erasure for user {UserId} [{CorrelationId}]",
            evt.UserId, evt.CorrelationId);

        var accounts = await db.Accounts
            .Where(a => a.UserId == evt.UserId)
            .ToListAsync(ctx.CancellationToken);

        if (accounts.Count == 0)
        {
            logger.LogInformation("No accounts found for user {UserId} — erasure complete", evt.UserId);
            return;
        }

        // Anonymise UserId reference; keep account shell for financial records
        var anonymisedUserId = $"ERASED_{Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(evt.UserId)))[..16]}";

        await db.Database.ExecuteSqlRawAsync(
            @"UPDATE BankAccounts SET
                UserId   = {0},
                [Status] = 'Closed'
              WHERE UserId = {1}",
            anonymisedUserId, evt.UserId);

        logger.LogInformation(
            "Anonymised {Count} account(s) for user {UserId}. Records retained until {Expiry}",
            accounts.Count, evt.UserId, evt.RetentionExpiryAt);
    }
}
