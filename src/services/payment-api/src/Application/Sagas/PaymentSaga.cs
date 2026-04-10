using MassTransit;
using SuperApp.Messaging.Events;

namespace SuperApp.PaymentApi.Application.Sagas;

/// <summary>
/// MassTransit StateMachine Saga for the distributed payment flow.
///
/// State transitions:
///   Initial → Pending  (PaymentInitiated received)
///   Pending → Debiting (WalletDebitRequested sent)
///   Debiting → Processing (WalletDebited received — wallet confirmed debit)
///   Processing → Completed (PaymentCompleted received from rails)
///   Processing → Failed (PaymentFailed or timeout)
///   Failed → (compensate) WalletCreditReversal sent → Reversed
///
/// All state stored in OutboxSagaStateRepository (SQL-backed) for durability.
/// If the process restarts mid-saga, MassTransit replays from the last persisted state.
/// </summary>
public class PaymentSagaState : SagaStateMachineInstance
{
    public Guid   CorrelationId      { get; set; }
    public string CurrentState       { get; set; } = default!;
    public Guid   PaymentId          { get; set; }
    public string SourceWalletId     { get; set; } = default!;
    public decimal Amount            { get; set; }
    public string Currency           { get; set; } = default!;
    public string UserId             { get; set; } = default!;
    public string? ExternalReference { get; set; }
    public string? FailureReason     { get; set; }
    public DateTimeOffset CreatedAt  { get; set; }
}

public class PaymentSaga : MassTransitStateMachine<PaymentSagaState>
{
    // ── States ──────────────────────────────────────────────────────────────
    public State Pending    { get; private set; } = default!;
    public State Debiting   { get; private set; } = default!;
    public State Processing { get; private set; } = default!;
    public State Completed  { get; private set; } = default!;
    public State Failed     { get; private set; } = default!;
    public State Reversed   { get; private set; } = default!;

    // ── Events ───────────────────────────────────────────────────────────────
    public Event<PaymentInitiated>  PaymentInitiatedEvent  { get; private set; } = default!;
    public Event<WalletDebited>     WalletDebitedEvent     { get; private set; } = default!;
    public Event<PaymentCompleted>  PaymentCompletedEvent  { get; private set; } = default!;
    public Event<PaymentFailed>     PaymentFailedEvent     { get; private set; } = default!;
    public Event<WalletCredited>    WalletCreditedEvent    { get; private set; } = default!;

    // ── Timeouts ─────────────────────────────────────────────────────────────
    public Schedule<PaymentSagaState, PaymentProcessingTimeout> ProcessingTimeout { get; private set; } = default!;

    public PaymentSaga()
    {
        InstanceState(x => x.CurrentState);

        // Correlation — link events to saga instance by PaymentId
        Event(() => PaymentInitiatedEvent,  e => e.CorrelateBy(s => s.PaymentId, m => m.Message.PaymentId).SelectId(m => m.CorrelationId));
        Event(() => WalletDebitedEvent,     e => e.CorrelateBy(s => s.PaymentId, m => Guid.Parse(m.Message.AggregateId)));
        Event(() => PaymentCompletedEvent,  e => e.CorrelateBy(s => s.PaymentId, m => m.Message.PaymentId));
        Event(() => PaymentFailedEvent,     e => e.CorrelateBy(s => s.PaymentId, m => m.Message.PaymentId));
        Event(() => WalletCreditedEvent,    e => e.CorrelateBy(s => s.PaymentId, m => Guid.Parse(m.Message.AggregateId)));

        Schedule(() => ProcessingTimeout, s => s.CorrelationId,
            s => { s.Delay = TimeSpan.FromSeconds(30); s.Received = e => e.CorrelateBy(x => x.PaymentId, m => m.Message.PaymentId); });

        // ── Transitions ──────────────────────────────────────────────────────
        Initially(
            When(PaymentInitiatedEvent)
                .Then(ctx => {
                    ctx.Saga.PaymentId      = ctx.Message.PaymentId;
                    ctx.Saga.SourceWalletId = ctx.Message.SourceWalletId;
                    ctx.Saga.Amount         = ctx.Message.Amount;
                    ctx.Saga.Currency       = ctx.Message.Currency;
                    ctx.Saga.UserId         = ctx.Message.InitiatedByUserId;
                    ctx.Saga.CreatedAt      = DateTimeOffset.UtcNow;
                })
                .PublishAsync(ctx => ctx.Init<DebitWalletCommand>(new {
                    ctx.Saga.PaymentId,
                    ctx.Saga.SourceWalletId,
                    ctx.Saga.Amount,
                    ctx.Saga.Currency,
                    Reference = ctx.Saga.PaymentId.ToString(),
                }))
                .TransitionTo(Debiting));

        During(Debiting,
            When(WalletDebitedEvent)
                .Schedule(ProcessingTimeout, ctx => ctx.Init<PaymentProcessingTimeout>(new { ctx.Saga.PaymentId }))
                .TransitionTo(Processing),

            When(PaymentFailedEvent)
                .Then(ctx => ctx.Saga.FailureReason = ctx.Message.FailureReason)
                .TransitionTo(Failed));

        During(Processing,
            When(PaymentCompletedEvent)
                .Then(ctx => ctx.Saga.ExternalReference = ctx.Message.ExternalReference)
                .Unschedule(ProcessingTimeout)
                .PublishAsync(ctx => ctx.Init<NotifyPaymentSuccessCommand>(new {
                    ctx.Saga.UserId,
                    ctx.Saga.PaymentId,
                    ctx.Saga.Amount,
                    ctx.Saga.Currency,
                    ctx.Saga.ExternalReference,
                }))
                .TransitionTo(Completed)
                .Finalize(),

            When(PaymentFailedEvent)
                .Then(ctx => ctx.Saga.FailureReason = ctx.Message.FailureReason)
                .Unschedule(ProcessingTimeout)
                .PublishAsync(ctx => ctx.Init<ReverseWalletDebitCommand>(new {
                    ctx.Saga.SourceWalletId,
                    ctx.Saga.Amount,
                    ctx.Saga.Currency,
                    Reference = $"REVERSAL:{ctx.Saga.PaymentId}",
                }))
                .TransitionTo(Failed),

            When(ProcessingTimeout.Received)
                .PublishAsync(ctx => ctx.Init<ReverseWalletDebitCommand>(new {
                    ctx.Saga.SourceWalletId,
                    ctx.Saga.Amount,
                    ctx.Saga.Currency,
                    Reference = $"TIMEOUT-REVERSAL:{ctx.Saga.PaymentId}",
                }))
                .TransitionTo(Failed));

        During(Failed,
            When(WalletCreditedEvent)
                .TransitionTo(Reversed)
                .Finalize());

        SetCompletedWhenFinalized();
    }
}

// Commands published by the saga to other services
public record DebitWalletCommand(Guid PaymentId, string SourceWalletId, decimal Amount, string Currency, string Reference);
public record ReverseWalletDebitCommand(string SourceWalletId, decimal Amount, string Currency, string Reference);
public record NotifyPaymentSuccessCommand(string UserId, Guid PaymentId, decimal Amount, string Currency, string? ExternalReference);
public record PaymentProcessingTimeout(Guid PaymentId);
