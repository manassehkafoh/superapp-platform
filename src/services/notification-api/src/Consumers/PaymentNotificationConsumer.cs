using MassTransit;
using Microsoft.Extensions.Logging;
using SuperApp.Messaging.Events;
using SuperApp.NotificationApi.Application;
using SuperApp.PaymentApi.Application.Sagas;

namespace SuperApp.NotificationApi.Consumers;

/// <summary>Sends SMS confirmation when a payment completes successfully.</summary>
public class PaymentSuccessNotificationConsumer(
    INotificationSender sender,
    ILogger<PaymentSuccessNotificationConsumer> logger)
    : IConsumer<NotifyPaymentSuccessCommand>
{
    public async Task Consume(ConsumeContext<NotifyPaymentSuccessCommand> ctx)
    {
        var cmd = ctx.Message;
        logger.LogInformation("Sending payment success notification for {PaymentId}", cmd.PaymentId);

        await sender.SendAsync(new NotificationRequest(
            RecipientId:   cmd.UserId,
            PhoneNumber:   "lookup-from-user-service",   // TODO: resolve from identity-api
            EmailAddress:  string.Empty,
            Subject:       "Payment Successful",
            Body:          $"Your payment of {cmd.Currency} {cmd.Amount:F2} was successful. Ref: {cmd.ExternalReference}",
            Channel:       NotificationChannel.SMS
        ), ctx.CancellationToken);
    }
}

/// <summary>Sends SMS alert when a payment fails.</summary>
public class PaymentFailedNotificationConsumer(
    INotificationSender sender,
    ILogger<PaymentFailedNotificationConsumer> logger)
    : IConsumer<PaymentFailed>
{
    public async Task Consume(ConsumeContext<PaymentFailed> ctx)
    {
        var evt = ctx.Message;
        logger.LogInformation("Sending payment failure notification for {PaymentId}", evt.PaymentId);

        await sender.SendAsync(new NotificationRequest(
            RecipientId:   evt.AggregateId,
            PhoneNumber:   "lookup-from-user-service",
            EmailAddress:  string.Empty,
            Subject:       "Payment Failed",
            Body:          $"Your payment could not be processed. Reason: {evt.FailureReason}. Please try again.",
            Channel:       NotificationChannel.SMS
        ), ctx.CancellationToken);
    }
}

/// <summary>Sends welcome SMS after successful user registration.</summary>
public class UserRegisteredNotificationConsumer(
    INotificationSender sender,
    ILogger<UserRegisteredNotificationConsumer> logger)
    : IConsumer<UserRegistered>
{
    public async Task Consume(ConsumeContext<UserRegistered> ctx)
    {
        var evt = ctx.Message;
        await sender.SendAsync(new NotificationRequest(
            RecipientId:   evt.UserId,
            PhoneNumber:   evt.PhoneNumber,
            EmailAddress:  evt.Email,
            Subject:       "Welcome to SuperApp",
            Body:          "Welcome to SuperApp! Your account has been created. Complete your KYC to unlock full features.",
            Channel:       NotificationChannel.SMS
        ), ctx.CancellationToken);
    }
}
