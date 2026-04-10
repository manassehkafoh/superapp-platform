using FluentAssertions;
using SuperApp.Domain;
using Xunit;
namespace SuperApp.Payment.Tests.Domain;
public class MoneyTests
{
    [Theory, InlineData(100,"GHS"), InlineData(0,"USD")]
    public void Constructor_ValidArgs_CreatesInstance(decimal amt, string cur)
    { new Money(amt, cur).Amount.Should().Be(amt); }

    [Fact]
    public void Constructor_NegativeAmount_Throws()
    { ((Action)(() => new Money(-1m, "GHS"))).Should().Throw<ArgumentException>(); }

    [Fact]
    public void Add_SameCurrency_ReturnsSum()
    { new Money(100m,"GHS").Add(new Money(50m,"GHS")).Amount.Should().Be(150m); }

    [Fact]
    public void Subtract_InsufficientFunds_Throws()
    { ((Action)(() => new Money(50m,"GHS").Subtract(new Money(100m,"GHS")))).Should().Throw<InvalidOperationException>(); }
}
