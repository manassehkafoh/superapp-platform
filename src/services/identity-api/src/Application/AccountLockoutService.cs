using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Logging;
using SuperApp.Common;

namespace SuperApp.IdentityApi.Application;

/// <summary>
/// SOC 2 CC6.2 — Brute-force account protection.
/// Tracks failed login attempts per normalised email in Redis.
/// Progressive lockout: 5 attempts = 15 min, 10 attempts = 1 hour.
/// Counter resets on successful authentication.
///
/// GAP-001 CLOSED: 2024-Q1
/// </summary>
public interface IAccountLockoutService
{
    Task<Result<bool>> CheckLockoutAsync(string email, CancellationToken ct = default);
    Task RecordFailedAttemptAsync(string email, CancellationToken ct = default);
    Task ClearAttemptsAsync(string email, CancellationToken ct = default);
    Task<int>  GetAttemptCountAsync(string email, CancellationToken ct = default);
}

public class AccountLockoutService(
    IDistributedCache cache,
    ILogger<AccountLockoutService> logger
) : IAccountLockoutService
{
    private const int SoftLockThreshold = 5;
    private const int HardLockThreshold = 10;
    private static readonly TimeSpan SoftLockDuration = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan HardLockDuration = TimeSpan.FromHours(1);

    private static string AttemptKey(string email) => $"auth:attempts:{email.ToLowerInvariant()}";
    private static string LockKey(string email)    => $"auth:lockout:{email.ToLowerInvariant()}";

    public async Task<Result<bool>> CheckLockoutAsync(string email, CancellationToken ct = default)
    {
        var locked = await cache.GetStringAsync(LockKey(email), ct);
        if (locked is null) return Result.Ok(false);

        var unlockAt = DateTimeOffset.Parse(locked);
        var remaining = (int)(unlockAt - DateTimeOffset.UtcNow).TotalMinutes + 1;

        logger.LogWarning("Lockout check for {Email}: locked until {UnlockAt}", email, unlockAt);
        return Result.Fail<bool>(new BusinessRuleError(
            "AUTH-009",
            $"Account temporarily locked due to too many failed login attempts. Try again in {remaining} minute(s)."));
    }

    public async Task RecordFailedAttemptAsync(string email, CancellationToken ct = default)
    {
        var key = AttemptKey(email);
        var raw = await cache.GetStringAsync(key, ct);
        var count = raw is null ? 0 : int.Parse(raw);
        count++;

        // Store attempt counter with rolling 1-hour window
        await cache.SetStringAsync(key, count.ToString(),
            new DistributedCacheEntryOptions
                { AbsoluteExpirationRelativeToNow = HardLockDuration }, ct);

        if (count >= HardLockThreshold)
        {
            var unlockAt = DateTimeOffset.UtcNow.Add(HardLockDuration);
            await cache.SetStringAsync(LockKey(email), unlockAt.ToString("O"),
                new DistributedCacheEntryOptions
                    { AbsoluteExpirationRelativeToNow = HardLockDuration }, ct);
            logger.LogWarning("HARD LOCKOUT for {Email} after {Count} attempts. Locked until {Until}",
                email, count, unlockAt);
        }
        else if (count >= SoftLockThreshold)
        {
            var unlockAt = DateTimeOffset.UtcNow.Add(SoftLockDuration);
            await cache.SetStringAsync(LockKey(email), unlockAt.ToString("O"),
                new DistributedCacheEntryOptions
                    { AbsoluteExpirationRelativeToNow = SoftLockDuration }, ct);
            logger.LogWarning("SOFT LOCKOUT for {Email} after {Count} attempts. Locked until {Until}",
                email, count, unlockAt);
        }
        else
        {
            logger.LogInformation("Failed attempt {Count}/{Soft} for {Email}",
                count, SoftLockThreshold, email);
        }
    }

    public async Task ClearAttemptsAsync(string email, CancellationToken ct = default)
    {
        await cache.RemoveAsync(AttemptKey(email), ct);
        await cache.RemoveAsync(LockKey(email), ct);
        logger.LogDebug("Cleared lockout state for {Email}", email);
    }

    public async Task<int> GetAttemptCountAsync(string email, CancellationToken ct = default)
    {
        var raw = await cache.GetStringAsync(AttemptKey(email), ct);
        return raw is null ? 0 : int.Parse(raw);
    }
}
