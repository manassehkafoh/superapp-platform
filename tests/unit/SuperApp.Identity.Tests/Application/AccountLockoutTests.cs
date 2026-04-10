using FluentAssertions;
using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using SuperApp.Common;
using SuperApp.IdentityApi.Application;
using Xunit;

namespace SuperApp.Identity.Tests.Application;

/// <summary>
/// Tests for GAP-001: Account lockout (SOC 2 CC6.2)
/// Uses in-memory distributed cache to avoid Redis dependency in unit tests.
/// </summary>
public class AccountLockoutTests
{
    private static IAccountLockoutService CreateService()
    {
        // Use MemoryDistributedCache as test double for Redis
        var cache = new MemoryDistributedCache(
            Options.Create(new MemoryDistributedCacheOptions()));
        return new AccountLockoutService(cache, NullLogger<AccountLockoutService>.Instance);
    }

    [Fact]
    public async Task CheckLockout_NoAttempts_ReturnsUnlocked()
    {
        var svc = CreateService();
        var result = await svc.CheckLockoutAsync("test@example.com");
        result.IsSuccess.Should().BeTrue();
    }

    [Fact]
    public async Task RecordFailedAttempts_BelowThreshold_NoLockout()
    {
        var svc = CreateService();
        for (int i = 0; i < 4; i++)
            await svc.RecordFailedAttemptAsync("user@test.com");

        var check = await svc.CheckLockoutAsync("user@test.com");
        check.IsSuccess.Should().BeTrue("4 attempts should not trigger lockout");
    }

    [Fact]
    public async Task RecordFailedAttempts_AtSoftThreshold_TriggersLockout()
    {
        var svc = CreateService();

        // 5th attempt triggers soft lockout
        for (int i = 0; i < 5; i++)
            await svc.RecordFailedAttemptAsync("locked@test.com");

        var check = await svc.CheckLockoutAsync("locked@test.com");
        check.IsSuccess.Should().BeFalse("5 attempts should trigger soft lockout");
        check.Error.Should().BeOfType<BusinessRuleError>();
        check.Error!.Code.Should().Be("AUTH-009");
        check.Error.Message.Should().Contain("locked");
    }

    [Fact]
    public async Task ClearAttempts_AfterLockout_UnlocksAccount()
    {
        var svc = CreateService();
        for (int i = 0; i < 5; i++)
            await svc.RecordFailedAttemptAsync("clear@test.com");

        // Verify locked
        var locked = await svc.CheckLockoutAsync("clear@test.com");
        locked.IsSuccess.Should().BeFalse();

        // Clear and verify unlocked
        await svc.ClearAttemptsAsync("clear@test.com");
        var unlocked = await svc.CheckLockoutAsync("clear@test.com");
        unlocked.IsSuccess.Should().BeTrue("After clearing, account should be unlocked");
    }

    [Fact]
    public async Task GetAttemptCount_TracksCorrectly()
    {
        var svc = CreateService();
        await svc.RecordFailedAttemptAsync("count@test.com");
        await svc.RecordFailedAttemptAsync("count@test.com");
        await svc.RecordFailedAttemptAsync("count@test.com");

        var count = await svc.GetAttemptCountAsync("count@test.com");
        count.Should().Be(3);
    }

    [Fact]
    public async Task EmailNormalisation_CaseInsensitive()
    {
        var svc = CreateService();

        // Record 5 failures with mixed case
        for (int i = 0; i < 5; i++)
            await svc.RecordFailedAttemptAsync("User@TEST.COM");

        // Check with different casing — should still be locked
        var check = await svc.CheckLockoutAsync("user@test.com");
        check.IsSuccess.Should().BeFalse("Lockout should be case-insensitive");
    }
}
