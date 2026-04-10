using FluentAssertions;
using SuperApp.Messaging.Events;
using SuperApp.PaymentApi.Domain;
using Xunit;
namespace SuperApp.Payment.Tests.Domain;
public class PaymentTests
{
    [Fact]
    public void Create_RaisesPaymentInitiatedEvent()
    {
        var p = Payment.Create("wallet-1","acc-1",100m,"GHS",PaymentRail.GhIPSS,"user-1","corr-1");
        p.Status.Should().Be(PaymentStatus.Pending);
        p.DomainEvents.Should().ContainSingle().Which.Should().BeOfType<PaymentInitiated>();
    }

    [Fact]
    public void MarkFailed_SetsStatusAndRaisesEvent()
    {
        var p = Payment.Create("w1","a1",200m,"GHS",PaymentRail.GhIPSS,"u1","c1");
        p.MarkFailed("GH-404","Not found");
        p.Status.Should().Be(PaymentStatus.Failed);
        p.DomainEvents.OfType<PaymentFailed>().Should().ContainSingle();
    }
}
