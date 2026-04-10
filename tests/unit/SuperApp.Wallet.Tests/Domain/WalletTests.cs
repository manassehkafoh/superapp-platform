using FluentAssertions;
using SuperApp.WalletApi.Domain;
using Xunit;

namespace SuperApp.Wallet.Tests.Domain;

public class WalletTests
{
    [Fact]
    public void Open_CreatesActiveWallet_WithZeroBalance()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Status.Should().Be(WalletStatus.Active);
        wallet.Balance.Should().Be(0m);
        wallet.Currency.Should().Be("GHS");
    }

    [Fact]
    public void Credit_AddsToBalance_AndRaisesEvent()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Credit(200m, "TOP-UP-001", "corr-1");

        wallet.Balance.Should().Be(200m);
        wallet.DomainEvents.Should().ContainSingle()
            .Which.EventType.Should().Be("WalletCredited");
    }

    [Fact]
    public void Debit_ReducesBalance_WhenSufficientFunds()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Credit(500m, "TOP-UP", "corr-1");
        wallet.Debit(150m, "PAY-REF-001", "corr-2");

        wallet.Balance.Should().Be(350m);
        wallet.DomainEvents.Count.Should().Be(2);
    }

    [Fact]
    public void Debit_Throws_WhenInsufficientFunds()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Credit(100m, "TOP-UP", "corr-1");

        var act = () => wallet.Debit(200m, "PAY-001", "corr-2");

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*Insufficient balance*");
    }

    [Fact]
    public void Debit_Throws_WhenWalletFrozen()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Credit(500m, "TOP-UP", "corr-1");
        typeof(Wallet).GetProperty("Status")!.SetValue(wallet, WalletStatus.Frozen);

        var act = () => wallet.Debit(100m, "PAY-001", "corr-2");

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*Frozen*");
    }

    [Fact]
    public void MultipleCreditsAndDebits_ProducesCorrectBalance()
    {
        var wallet = Wallet.Open("user-001", "GHS");
        wallet.Credit(1000m, "REF-1", "c1");
        wallet.Debit(200m,   "REF-2", "c2");
        wallet.Credit(50m,   "REF-3", "c3");
        wallet.Debit(100m,   "REF-4", "c4");

        wallet.Balance.Should().Be(750m);
        wallet.Entries.Count.Should().Be(4);
    }
}
