using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using SuperApp.NotificationApi.Application;
using System.Net.Http.Json;

namespace SuperApp.NotificationApi.Infrastructure;

/// <summary>
/// Sends SMS via Hubtel SMS API.
/// Retries handled by Polly pipeline on the named HttpClient.
/// </summary>
public class HubtelSmsSender(IHttpClientFactory http, IConfiguration cfg, ILogger<HubtelSmsSender> logger)
    : INotificationSender
{
    public async Task SendAsync(NotificationRequest request, CancellationToken ct = default)
    {
        if (request.Channel != NotificationChannel.SMS) return;

        using var client = http.CreateClient("hubtel");
        var payload = new {
            From        = cfg["Hubtel:SenderId"],
            To          = request.PhoneNumber,
            Content     = request.Body,
            RegisteredDelivery = true,
        };

        var resp = await client.PostAsJsonAsync("v1/messages/send", payload, ct);
        if (!resp.IsSuccessStatusCode)
        {
            logger.LogWarning("Hubtel SMS failed for {Recipient}: {Status}", request.RecipientId, resp.StatusCode);
            return;
        }

        logger.LogInformation("SMS sent to {Phone} for {RecipientId}", request.PhoneNumber, request.RecipientId);
    }
}
