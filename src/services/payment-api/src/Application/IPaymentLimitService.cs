using SuperApp.Common;
namespace SuperApp.PaymentApi.Application;

public interface IPaymentLimitService
{
    Task<Result<bool>> CheckDailyLimitAsync(string userId, decimal amount, string currency, CancellationToken ct = default);
}
