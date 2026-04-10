using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using SuperApp.Common;
using SuperApp.IdentityApi.Domain;
using SuperApp.IdentityApi.Infrastructure;
using BCrypt.Net;

namespace SuperApp.IdentityApi.Application;

public interface IRegisterUserHandler
{
    Task<Result<string>> HandleAsync(object req, string correlationId, CancellationToken ct);
}

public class RegisterUserHandler(IdentityDbContext db, ILogger<RegisterUserHandler> logger) : IRegisterUserHandler
{
    public async Task<Result<string>> HandleAsync(object req, string correlationId, CancellationToken ct)
    {
        // Minimal impl — full impl expands on this pattern
        dynamic r = req;
        string email = r.Email; string phone = r.PhoneNumber; string pwd = r.Password;

        if (await db.Users.AnyAsync(u => u.Email == email.ToLowerInvariant(), ct))
            return Result.Fail<string>(new ValidationError("AUTH-010", "Email already registered"));

        var hash = BCrypt.Net.BCrypt.HashPassword(pwd, workFactor: 12);
        var user = User.Register(email, phone, hash, correlationId);
        await db.Users.AddAsync(user, ct);
        await db.SaveChangesAsync(ct);

        logger.LogInformation("User {UserId} registered [{CorrelationId}]", user.Id, correlationId);
        return Result.Ok(user.Id.ToString());
    }
}
