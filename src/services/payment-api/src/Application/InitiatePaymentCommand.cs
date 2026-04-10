using SuperApp.Common;
using SuperApp.PaymentApi.Domain;

namespace SuperApp.PaymentApi.Application;

public record InitiatePaymentRequest(
    string  SourceWalletId,
    string  DestinationAccount,
    decimal Amount,
    string  Currency,      // ISO-4217: GHS, USD
    string  PaymentRail,   // GhIPSS | ExpressPay | InternalTransfer
    string? IdempotencyKey // Client-supplied UUID — prevents duplicate payments
);

public record PaymentResponse(Guid PaymentId, string Status, string? ExternalReference);

public interface IInitiatePaymentHandler
{
    Task<Result<PaymentResponse>> HandleAsync(
        InitiatePaymentRequest request,
        string userId,
        string correlationId,
        CancellationToken ct = default);
}
