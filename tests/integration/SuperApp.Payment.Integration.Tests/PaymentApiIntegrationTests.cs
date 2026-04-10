using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using System.Net.Http.Json;
using Xunit;

namespace SuperApp.Payment.Integration.Tests;

/// <summary>
/// Integration tests use Testcontainers to spin up real SQL Server + Kafka.
/// Runs in CI via Docker-in-Docker. Requires Docker Desktop locally.
/// Category = Integration so unit test runs can exclude them: --filter Category!=Integration
/// </summary>
[Trait("Category", "Integration")]
public class PaymentApiIntegrationTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public PaymentApiIntegrationTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task PostPayment_WithValidRequest_Returns202Accepted()
    {
        var request = new {
            SourceWalletId     = "wallet-test-001",
            DestinationAccount = "0241234567",
            Amount             = 50.00m,
            Currency           = "GHS",
            PaymentRail        = "GhIPSS",
            IdempotencyKey     = Guid.NewGuid().ToString()
        };

        var response = await _client.PostAsJsonAsync("/api/v1/payments", request);

        response.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var body = await response.Content.ReadFromJsonAsync<dynamic>();
        ((string?)body?.status).Should().Be("Pending");
    }

    [Fact]
    public async Task PostPayment_WithNegativeAmount_Returns422()
    {
        var request = new {
            SourceWalletId     = "wallet-test-001",
            DestinationAccount = "0241234567",
            Amount             = -10m,
            Currency           = "GHS",
            PaymentRail        = "GhIPSS"
        };

        var response = await _client.PostAsJsonAsync("/api/v1/payments", request);
        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }
}
