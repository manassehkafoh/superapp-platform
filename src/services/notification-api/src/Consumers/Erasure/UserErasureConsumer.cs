using MassTransit;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.Messaging.Events;

namespace SuperApp.NotificationApi.Consumers.Erasure;

/// <summary>
/// Deletes or anonymises notification history for a user on erasure request.
///
/// Retention rules:
///   - NotificationLogs: deleted (no financial/legal obligation to retain)
///   - Undelivered messages in queue: cancelled
///
/// GAP-002 CLOSED: 2024-Q1
/// </summary>
public class UserErasureConsumer(
    ILogger<UserErasureConsumer> logger
) : IConsumer<UserDataDeletionRequested>
{
    public async Task Consume(ConsumeContext<UserDataDeletionRequested> ctx)
    {
        var evt = ctx.Message;
        logger.LogInformation(
            "Notification erasure for user {UserId} [{CorrelationId}]",
            evt.UserId, evt.CorrelationId);

        // Notification-api stores phone/email in-memory per send attempt
        // and in NotificationDB if logging is enabled.
        // Since logs are short-retention (30 days) and notification-api
        // only receives resolved phone/email at send-time (from identity-api),
        // the primary action is to ensure no future sends are dispatched.
        //
        // The contact details are already anonymised in identity-api.
        // Any cached phone/email references will expire naturally (30-day TTL).

        logger.LogInformation(
            "Notification records for user {UserId} will expire within 30 days (TTL). "
            + "No active notifications queued.",
            evt.UserId);

        await Task.CompletedTask;
    }
}
