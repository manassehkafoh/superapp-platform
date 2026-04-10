using FluentAssertions;
using SuperApp.IdentityApi.Domain;
using SuperApp.Messaging.Events;
using Xunit;

namespace SuperApp.Identity.Tests.Domain;

public class UserTests
{
    [Fact]
    public void Register_CreatesUser_WithPendingStatus_AndRaisesEvent()
    {
        var user = User.Register("test@superapp.com.gh", "0241234567",
            "$2a$12$hashedpassword", "corr-001");

        user.Status.Should().Be(UserStatus.PendingVerification);
        user.Tier.Should().Be(UserTier.Basic);
        user.KycLevel.Should().Be(KycLevel.None);
        user.MfaEnabled.Should().BeFalse();
        user.DomainEvents.Should().ContainSingle()
            .Which.Should().BeOfType<UserRegistered>();
    }

    [Fact]
    public void Register_NormalisesEmailToLowercase()
    {
        var user = User.Register("TEST@SUPERAPP.COM.GH", "0241234567", "hash", "corr");
        user.Email.Should().Be("test@superapp.com.gh");
    }

    [Fact]
    public void CompleteKyc_SetsLevel_AndActivatesUser()
    {
        var user = User.Register("kyc@superapp.com.gh", "0241234567", "hash", "corr");
        user.CompleteKyc(KycLevel.Tier2, "ops-agent-001", "corr-002");

        user.KycLevel.Should().Be(KycLevel.Tier2);
        user.Status.Should().Be(UserStatus.Active);
        user.DomainEvents.OfType<UserKycCompleted>().Should().ContainSingle();
    }
}
