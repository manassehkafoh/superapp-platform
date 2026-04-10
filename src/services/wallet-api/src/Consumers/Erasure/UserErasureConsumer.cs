using MassTransit;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.Messaging.Events;
using SuperApp.WalletApi.Infrastructure;

namespace SuperApp.WalletApi.Consumers.Erasure;

/// <summary>
/// Anonymises wallet ownership PII on user erasure request.
///
/// Retention rules:
///   - LedgerEntries: fully retained (financial audit trail, 7-year legal hold)
///   - Wallet.UserId: pseudonymised
///   - Wallet.Status: set to Closed
///   - Balance is computed from ledger — retained for reconciliation
///
/// GAP-002 CLOSED: 2024-Q1
/// </summary>
public class UserErasureConsumer(
    WalletDbContext db,
    ILogger<UserErasureConsumer> logger
) : IConsumer<UserDataDeletionRequested>
{
    public async Task Consume(ConsumeContext<UserDataDeletionRequested> ctx)
    {
        var evt = ctx.Message;
        logger.LogInformation(
            "Wallet erasure for user {UserId} [{CorrelationId}]",
            evt.UserId, evt.CorrelationId);

        var wallets = await db.Wallets
            .Where(w => w.UserId == evt.UserId)
            .ToListAsync(ctx.CancellationToken);

        if (wallets.Count == 0)
        {
            logger.LogInformation("No wallets found for user {UserId}", evt.UserId);
            return;
        }

        var anonymisedUserId = $"ERASED_{Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(evt.UserId)))[..16]}";

        // Pseudonymise wallet owner; retain ledger entries untouched (legal obligation)
        await db.Database.ExecuteSqlRawAsync(
            @"UPDATE Wallets SET
                UserId   = {0},
                [Status] = 'Closed'
              WHERE UserId = {1}",
            anonymisedUserId, evt.UserId);

        // Note: LedgerEntries are NOT modified — they contain no direct PII
        // (only WalletId references and monetary amounts with references)

        logger.LogInformation(
            "Anonymised {Count} wallet(s) for user {UserId}. "
            + "Ledger entries retained until {Expiry} (financial legal hold)",
            wallets.Count, evt.UserId, evt.RetentionExpiryAt);
    }
}
