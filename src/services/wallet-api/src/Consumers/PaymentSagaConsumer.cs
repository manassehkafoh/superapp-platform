using MassTransit;
using Microsoft.Extensions.Logging;
using SuperApp.PaymentApi.Application.Sagas;
using SuperApp.WalletApi.Application;

namespace SuperApp.WalletApi.Consumers;

public class DebitWalletConsumer(IWalletService walletService, ILogger<DebitWalletConsumer> logger)
    : IConsumer<DebitWalletCommand>
{
    public async Task Consume(ConsumeContext<DebitWalletCommand> ctx)
    {
        var cmd = ctx.Message;
        logger.LogInformation("Debiting {WalletId} {Amount} {Currency} ref {Ref}",
            cmd.SourceWalletId, cmd.Amount, cmd.Currency, cmd.Reference);
        var result = await walletService.DebitAsync(
            Guid.Parse(cmd.SourceWalletId), cmd.Amount,
            cmd.Reference, ctx.CorrelationId?.ToString() ?? string.Empty);
        if (!result.IsSuccess)
            await ctx.Publish(new SuperApp.Messaging.Events.PaymentFailed(
                cmd.PaymentId.ToString(), ctx.CorrelationId?.ToString() ?? string.Empty,
                cmd.PaymentId, "WAL-DEBIT-FAILED", result.Error?.Message ?? "Debit failed"));
    }
}

public class ReverseWalletDebitConsumer(IWalletService walletService, ILogger<ReverseWalletDebitConsumer> logger)
    : IConsumer<ReverseWalletDebitCommand>
{
    public async Task Consume(ConsumeContext<ReverseWalletDebitCommand> ctx)
    {
        var cmd = ctx.Message;
        logger.LogInformation("Reversing debit {WalletId} {Amount} ref {Ref}", cmd.SourceWalletId, cmd.Amount, cmd.Reference);
        await walletService.CreditAsync(Guid.Parse(cmd.SourceWalletId), cmd.Amount,
            cmd.Reference, ctx.CorrelationId?.ToString() ?? string.Empty);
    }
}
