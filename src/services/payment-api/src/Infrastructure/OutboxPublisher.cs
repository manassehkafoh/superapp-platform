using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using SuperApp.Domain;
using SuperApp.Infrastructure;
using MassTransit;

namespace SuperApp.PaymentApi.Infrastructure;

/// <summary>
/// Hosted background service implementing the Transactional Outbox pattern.
/// Polls OutboxMessages every 2 seconds, publishes unprocessed events to Kafka via MassTransit,
/// marks them processed. Guarantees at-least-once delivery — consumers must be idempotent.
/// </summary>
public sealed class OutboxPublisher(IServiceScopeFactory scopeFactory, ILogger<OutboxPublisher> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("OutboxPublisher started");

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ProcessBatchAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "OutboxPublisher error — will retry in 5s");
            }
            await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
        }
    }

    private async Task ProcessBatchAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db  = scope.ServiceProvider.GetRequiredService<PaymentDbContext>();
        var bus = scope.ServiceProvider.GetRequiredService<IPublishEndpoint>();

        var messages = await db.OutboxMessages
            .Where(m => m.ProcessedAt == null && m.RetryCount < 5)
            .OrderBy(m => m.OccurredAt)
            .Take(50)
            .ToListAsync(ct);

        if (messages.Count == 0) return;

        foreach (var msg in messages)
        {
            try
            {
                // Deserialise payload back to the concrete event type
                var eventType = Type.GetType(msg.EventType);
                if (eventType is null)
                {
                    logger.LogWarning("Unknown event type {Type} — skipping", msg.EventType);
                    msg.ProcessedAt = DateTimeOffset.UtcNow;
                    continue;
                }

                var @event = JsonSerializer.Deserialize(msg.EventPayload, eventType) as IDomainEvent;
                if (@event is not null)
                    await bus.Publish(@event, eventType, ct);

                msg.ProcessedAt = DateTimeOffset.UtcNow;
                logger.LogDebug("Published outbox event {Type} {Id}", msg.EventType, msg.Id);
            }
            catch (Exception ex)
            {
                msg.RetryCount++;
                msg.Error = ex.Message;
                logger.LogWarning(ex, "Failed to publish outbox event {Id} (retry {Count})", msg.Id, msg.RetryCount);
            }
        }

        await db.SaveChangesAsync(ct);
    }
}
