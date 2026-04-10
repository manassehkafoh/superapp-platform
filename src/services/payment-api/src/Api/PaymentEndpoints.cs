using Microsoft.AspNetCore.Mvc;
using SuperApp.Common;
using SuperApp.PaymentApi.Application;

namespace SuperApp.PaymentApi.Api;

public static class PaymentEndpoints
{
    public static IEndpointRouteBuilder MapPaymentEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app
            .MapGroup("/api/v1/payments")
            .RequireAuthorization()
            .WithTags("Payments")
            .WithOpenApi();

        /// <summary>Initiate a new payment. Returns 202 immediately; result delivered via webhook/polling.</summary>
        group.MapPost("/", async (
            [FromBody] InitiatePaymentRequest request,
            [FromServices] IInitiatePaymentHandler handler,
            HttpContext ctx,
            CancellationToken ct) =>
        {
            var userId        = ctx.User.FindFirst("sub")?.Value ?? string.Empty;
            var correlationId = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();

            var result = await handler.HandleAsync(request, userId, correlationId, ct);

            return result.Match(
                onSuccess: p => Results.Accepted($"/api/v1/payments/{p.PaymentId}", p),
                onFailure: e => e switch {
                    ValidationError v     => Results.UnprocessableEntity(new { v.Code, v.Message }),
                    BusinessRuleError b   => Results.Conflict(new { b.Code, b.Message }),
                    InfrastructureError i => Results.Problem(i.Message, statusCode: 503),
                    _                     => Results.Problem("Unexpected error", statusCode: 500)
                });
        })
        .WithName("InitiatePayment")
        .Produces<PaymentResponse>(StatusCodes.Status202Accepted)
        .ProducesValidationProblem()
        .ProducesProblem(StatusCodes.Status503ServiceUnavailable);

        /// <summary>Get payment status by ID.</summary>
        group.MapGet("/{id:guid}", async (
            Guid id,
            [FromServices] IPaymentQueryService query,
            CancellationToken ct) =>
        {
            var result = await query.GetByIdAsync(id, ct);
            return result.Match(
                onSuccess: p  => Results.Ok(p),
                onFailure: e  => e is NotFoundError ? Results.NotFound() : Results.Problem());
        })
        .WithName("GetPayment")
        .Produces<PaymentResponse>(StatusCodes.Status200OK)
        .ProducesProblem(StatusCodes.Status404NotFound);

        return app;
    }
}

// Extension method to add the history endpoint (called from MapPaymentEndpoints)
// In the main file we just need to add one more route to the existing group
