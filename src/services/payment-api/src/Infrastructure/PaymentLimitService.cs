using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using SuperApp.Common;
using SuperApp.PaymentApi.Application;
using SuperApp.PaymentApi.Domain;

namespace SuperApp.PaymentApi.Infrastructure;

/// <summary>
/// Enforces per-user daily transaction limits based on KYC tier.
/// Limits are configurable per environment via appsettings.
/// </summary>
public class PaymentLimitService(PaymentDbContext db, IConfiguration cfg) : IPaymentLimitService
{
    public async Task<Result<bool>> CheckDailyLimitAsync(
        string userId, decimal amount, string currency, CancellationToken ct = default)
    {
        // Sum today's successful + pending payments for this user
        var todayStart = DateTimeOffset.UtcNow.Date;
        var dailyTotal = await db.Payments
            .Where(p => p.InitiatedByUserId == userId
                     && p.Currency == currency
                     && p.CreatedAt >= todayStart
                     && p.Status != PaymentStatus.Failed
                     && p.Status != PaymentStatus.Reversed)
            .SumAsync(p => p.Amount, ct);

        // TODO: get tier from identity-api (call or read from JWT claim)
        // For now default to Basic
        var dailyLimit = cfg.GetValue<decimal>("Limits:BasicTierDailyLimitGHS", 500m);

        if (dailyTotal + amount > dailyLimit)
            return Result.Fail<bool>(new BusinessRuleError(
                "PAY-004",
                $"Daily limit of {currency} {dailyLimit:F2} would be exceeded. Used: {dailyTotal:F2}, Requested: {amount:F2}"));

        return Result.Ok(true);
    }
}
