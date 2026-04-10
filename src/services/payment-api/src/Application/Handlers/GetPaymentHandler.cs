using Microsoft.EntityFrameworkCore;
using SuperApp.Common;
using SuperApp.PaymentApi.Domain;
using SuperApp.PaymentApi.Infrastructure;

namespace SuperApp.PaymentApi.Application;

public interface IPaymentQueryService
{
    Task<Result<PaymentResponse>> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<Result<PagedResult<PaymentResponse>>> GetByUserAsync(string userId, int page, int pageSize, CancellationToken ct = default);
}

public class PaymentQueryService(PaymentDbContext db) : IPaymentQueryService
{
    public async Task<Result<PaymentResponse>> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        var p = await db.Payments.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id, ct);
        if (p is null) return Result.Fail<PaymentResponse>(new NotFoundError("PAY-404", $"Payment {id} not found"));
        return Result.Ok(new PaymentResponse(p.Id, p.Status.ToString(), p.ExternalReference));
    }

    public async Task<Result<PagedResult<PaymentResponse>>> GetByUserAsync(
        string userId, int page, int pageSize, CancellationToken ct = default)
    {
        var q = db.Payments.AsNoTracking()
            .Where(p => p.InitiatedByUserId == userId)
            .OrderByDescending(p => p.CreatedAt);

        var total = await q.CountAsync(ct);
        var items = await q.Skip((page - 1) * pageSize).Take(pageSize)
            .Select(p => new PaymentResponse(p.Id, p.Status.ToString(), p.ExternalReference))
            .ToListAsync(ct);

        return Result.Ok(new PagedResult<PaymentResponse>(items, page, pageSize, total));
    }
}
