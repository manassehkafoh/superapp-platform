namespace SuperApp.Messaging;

/// <summary>
/// Canonical Kafka topic names — single source of truth for all services.
/// All producers AND consumers reference these constants; never hardcode topic names.
/// </summary>
public static class Topics
{
    public const string UserEvents         = "superapp-user-events";
    public const string IdentityReset      = "superapp-identity-reset";
    public const string PaymentSource      = "superapp-payment-source";
    public const string TransactionLogs    = "superapp-transaction-logs";
    public const string AuditLogs          = "superapp-audit-logs";
    public const string NotificationEvents = "superapp-notification-events";
    public const string WalletEvents       = "superapp-wallet-events";
    public const string DeadLetterQueue    = "superapp-dlq";
}
