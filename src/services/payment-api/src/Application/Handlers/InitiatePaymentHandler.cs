using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Logging;
using SuperApp.Common;
using SuperApp.Infrastructure;
using SuperApp.PaymentApi.Domain;
using System.Text.Json;

namespace SuperApp.PaymentApi.Application;

public class InitiatePaymentHandler(
    IRepository<Payment>     repository,
    IDistributedCache        cache,
    IPaymentLimitService     limitService,
    ILogger<InitiatePaymentHandler> logger
) : IInitiatePaymentHandler
{
    public async Task<Result<PaymentResponse>> HandleAsync(
        InitiatePaymentRequest request,
        string userId,
        string correlationId,
        CancellationToken ct = default)
    {
        // ── 1. Validate request ───────────────────────────────────────────
        if (request.Amount <= 0)
            return Result.Fail<PaymentResponse>(new ValidationError("PAY-001", "Amount must be positive"));
        if (request.Amount > 100_000m)
            return Result.Fail<PaymentResponse>(new ValidationError("PAY-001", "Amount exceeds maximum single transaction limit"));
        if (!Enum.TryParse<PaymentRail>(request.PaymentRail, true, out var rail))
            return Result.Fail<PaymentResponse>(new ValidationError("PAY-006", $"Unknown payment rail: {request.PaymentRail}"));

        // ── 2. Idempotency check (Redis — 24-hour window) ─────────────────
        if (!string.IsNullOrWhiteSpace(request.IdempotencyKey))
        {
            var cacheKey = $"idempotency:payment:{request.IdempotencyKey}";
            var cached   = await cache.GetStringAsync(cacheKey, ct);
            if (cached is not null)
            {
                logger.LogInformation("Idempotent duplicate for key {Key} user {UserId}", request.IdempotencyKey, userId);
                var existing = JsonSerializer.Deserialize<PaymentResponse>(cached)!;
                return Result.Ok(existing);
            }
        }

        // ── 3. Check daily limit ──────────────────────────────────────────
        var limitResult = await limitService.CheckDailyLimitAsync(userId, request.Amount, request.Currency, ct);
        if (!limitResult.IsSuccess)
            return Result.Fail<PaymentResponse>(limitResult.Error!);

        // ── 4. Create payment aggregate ───────────────────────────────────
        var payment = Payment.Create(
            request.SourceWalletId,
            request.DestinationAccount,
            request.Amount,
            request.Currency,
            rail,
            userId,
            correlationId);

        await repository.AddAsync(payment, ct);
        await repository.SaveChangesAsync(ct);   // Persists Payment + OutboxMessage atomically

        logger.LogInformation(
            "Payment {PaymentId} created by {UserId} for {Amount} {Currency} via {Rail} [{CorrelationId}]",
            payment.Id, userId, request.Amount, request.Currency, rail, correlationId);

        var response = new PaymentResponse(payment.Id, payment.Status.ToString(), null);

        // ── 5. Store idempotency response ─────────────────────────────────
        if (!string.IsNullOrWhiteSpace(request.IdempotencyKey))
        {
            var cacheKey = $"idempotency:payment:{request.IdempotencyKey}";
            await cache.SetStringAsync(cacheKey,
                JsonSerializer.Serialize(response),
                new DistributedCacheEntryOptions { AbsoluteExpirationRelativeToNow = TimeSpan.FromHours(24) },
                ct);
        }

        return Result.Ok(response);
    }
}
