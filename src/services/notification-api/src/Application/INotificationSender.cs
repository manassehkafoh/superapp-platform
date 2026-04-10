namespace SuperApp.NotificationApi.Application;

public enum NotificationChannel { SMS, Email, Push }

public record NotificationRequest(
    string   RecipientId,
    string   PhoneNumber,
    string   EmailAddress,
    string   Subject,
    string   Body,
    NotificationChannel Channel
);

public interface INotificationSender
{
    Task SendAsync(NotificationRequest request, CancellationToken ct = default);
}
