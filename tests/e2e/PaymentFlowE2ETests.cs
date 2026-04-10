using FluentAssertions;
using System.Net;
using System.Net.Http.Json;
using Xunit;

namespace SuperApp.E2E.Tests;

/// <summary>
/// End-to-end tests for the full payment flow.
/// Requires: API_BASE_URL + AUTH_TOKEN environment variables (set in CI for staging/prod).
/// Run manually: API_BASE_URL=https://api.staging.superapp.com.gh AUTH_TOKEN=... dotnet test --filter Category=E2E
/// </summary>
[Trait("Category", "E2E")]
public class PaymentFlowE2ETests
{
    private readonly HttpClient _client;
    private readonly string _baseUrl;

    public PaymentFlowE2ETests()
    {
        _baseUrl = Environment.GetEnvironmentVariable("API_BASE_URL")
                   ?? "https://api.dev.superapp.com.gh";
        var token = Environment.GetEnvironmentVariable("AUTH_TOKEN") ?? string.Empty;

        _client = new HttpClient { BaseAddress = new Uri(_baseUrl) };
        _client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        _client.DefaultRequestHeaders.Add("X-Correlation-ID", Guid.NewGuid().ToString());
    }

    [Fact]
    public async Task HealthCheck_AllServices_ReturnHealthy()
    {
        var services = new[] { "identity-api", "payment-api", "wallet-api", "account-api" };
        foreach (var svc in services)
        {
            var resp = await _client.GetAsync($"/internal/{svc}/health/ready");
            resp.IsSuccessStatusCode.Should().BeTrue($"{svc} should be healthy");
        }
    }

    [Fact]
    public async Task InitiatePayment_WithValidRequest_Returns202()
    {
        var faker  = new Bogus.Faker();
        var amount = faker.Finance.Amount(10, 200);

        var request = new {
            SourceWalletId     = "wallet-e2e-test-001",
            DestinationAccount = "0241234567",
            Amount             = amount,
            Currency           = "GHS",
            PaymentRail        = "GhIPSS",
            IdempotencyKey     = Guid.NewGuid().ToString()
        };

        var resp = await _client.PostAsJsonAsync("/api/v1/payments", request);

        resp.StatusCode.Should().Be(HttpStatusCode.Accepted,
            $"payment initiation failed: {await resp.Content.ReadAsStringAsync()}");

        var body = await resp.Content.ReadFromJsonAsync<dynamic>();
        ((string?)body?.status).Should().Be("Pending");
    }

    [Fact]
    public async Task InitiatePayment_DuplicateIdempotencyKey_ReturnsSamePaymentId()
    {
        var key = Guid.NewGuid().ToString();
        var request = new {
            SourceWalletId = "wallet-e2e-test-001",
            DestinationAccount = "0241234567",
            Amount = 25.00m, Currency = "GHS", PaymentRail = "GhIPSS",
            IdempotencyKey = key
        };

        var resp1 = await _client.PostAsJsonAsync("/api/v1/payments", request);
        var resp2 = await _client.PostAsJsonAsync("/api/v1/payments", request);

        resp1.StatusCode.Should().Be(HttpStatusCode.Accepted);
        resp2.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var body1 = await resp1.Content.ReadFromJsonAsync<dynamic>();
        var body2 = await resp2.Content.ReadFromJsonAsync<dynamic>();
        ((string?)body1?.paymentId).Should().Be((string?)body2?.paymentId);
    }
}
