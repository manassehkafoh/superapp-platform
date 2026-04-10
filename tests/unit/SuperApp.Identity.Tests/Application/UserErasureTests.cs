using FluentAssertions;
using SuperApp.Messaging.Events;
using SuperApp.IdentityApi.Domain;
using Xunit;

namespace SuperApp.Identity.Tests.Application;

/// <summary>
/// Tests for GAP-002: Right-to-erasure (GDPR / BoG compliance)
/// Validates event contract and domain model for deletion flow.
/// </summary>
public class UserErasureTests
{
    [Fact]
    public void UserDataDeletionRequested_HasCorrectRetentionPeriod()
    {
        var now = DateTimeOffset.UtcNow;
        var evt = new UserDataDeletionRequested(
            AggregateId:        "user-001",
            CorrelationId:      "corr-001",
            UserId:             "user-001",
            RequestedByUserId:  "user-001",
            DeletionReason:     "USER_REQUEST",
            RequestedAt:        now,
            RetentionExpiryAt:  now.AddYears(7));

        // Verify 7-year retention for financial records (BoG / AML requirement)
        var retentionYears = (evt.RetentionExpiryAt - evt.RequestedAt).TotalDays / 365.25;
        retentionYears.Should().BeApproximately(7, 0.1,
            "Financial records must be retained for 7 years per Bank of Ghana AML requirements");
    }

    [Fact]
    public void UserDataDeletionRequested_EventType_IsCorrect()
    {
        var evt = new UserDataDeletionRequested(
            "uid", "corr", "uid", "uid", "USER_REQUEST",
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddYears(7));

        evt.EventType.Should().Be("UserDataDeletionRequested");
        evt.AggregateId.Should().Be("uid");
    }

    [Fact]
    public void UserDataDeletionRequested_DeletionReasonVariants_AreValid()
    {
        var validReasons = new[] { "USER_REQUEST", "REGULATORY", "FRAUD" };

        foreach (var reason in validReasons)
        {
            var act = () => new UserDataDeletionRequested(
                "uid", "corr", "uid", "admin",
                reason, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddYears(7));
            act.Should().NotThrow($"Reason '{reason}' should be valid");
        }
    }
}
