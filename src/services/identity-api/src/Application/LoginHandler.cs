using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.IdentityModel.Tokens;
using SuperApp.Common;
using SuperApp.IdentityApi.Domain;
using SuperApp.IdentityApi.Infrastructure;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;

namespace SuperApp.IdentityApi.Application;

public interface ILoginHandler
{
    Task<Result<object>> HandleAsync(object req, CancellationToken ct);
}

public interface IRefreshTokenHandler
{
    Task<Result<object>> HandleAsync(string refreshToken, CancellationToken ct);
}

public class LoginHandler(IdentityDbContext db, IConfiguration cfg) : ILoginHandler
{
    public async Task<Result<object>> HandleAsync(object req, CancellationToken ct)
    {
        dynamic r = req;
        string email = r.Email; string pwd = r.Password;

        var user = await db.Users
            .FirstOrDefaultAsync(u => u.Email == email.ToLowerInvariant(), ct);

        if (user is null || !BCrypt.Net.BCrypt.Verify(pwd, user.PasswordHash))
            return Result.Fail<object>(new ValidationError("AUTH-002", "Invalid credentials"));

        if (user.Status != UserStatus.Active)
            return Result.Fail<object>(new BusinessRuleError("AUTH-003", $"Account is {user.Status}"));

        var (access, refresh) = await IssueTokensAsync(user, ct);
        return Result.Ok<object>(new { AccessToken = access, RefreshToken = refresh, ExpiresIn = 3600 });
    }

    private async Task<(string access, string refresh)> IssueTokensAsync(User user, CancellationToken ct)
    {
        // Access token
        var key     = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(cfg["Auth:SigningKey"]!));
        var creds   = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);
        var claims  = new[] {
            new Claim(JwtRegisteredClaimNames.Sub,   user.Id.ToString()),
            new Claim(JwtRegisteredClaimNames.Email, user.Email),
            new Claim("tier",  user.Tier.ToString()),
            new Claim("kyc",   user.KycLevel.ToString()),
        };
        var jwt = new JwtSecurityToken(
            issuer:   cfg["Auth:Issuer"],
            audience: cfg["Auth:Audience"],
            claims:   claims,
            expires:  DateTime.UtcNow.AddHours(1),
            signingCredentials: creds);
        var accessToken = new JwtSecurityTokenHandler().WriteToken(jwt);

        // Refresh token
        var refreshBytes = RandomNumberGenerator.GetBytes(64);
        var refreshToken = Convert.ToBase64String(refreshBytes);
        await db.RefreshTokens.AddAsync(new RefreshToken {
            UserId    = user.Id,
            Token     = refreshToken,
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        }, ct);
        await db.SaveChangesAsync(ct);

        return (accessToken, refreshToken);
    }
}
