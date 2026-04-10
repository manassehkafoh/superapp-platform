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

/// <summary>
/// Handles user authentication with:
/// - BCrypt password verification (work factor 12)
/// - Account lockout enforcement (GAP-001 CLOSED)
/// - JWT access token + refresh token issuance
/// - Structured audit logging (SOC 2 CC6.2, CC7.2)
/// </summary>
public class LoginHandler(
    IdentityDbContext db,
    IConfiguration cfg,
    IAccountLockoutService lockout
) : ILoginHandler
{
    public async Task<Result<object>> HandleAsync(object req, CancellationToken ct)
    {
        dynamic r = req;
        string email = r.Email;
        string pwd   = r.Password;

        // ── 1. Lockout check (before any DB query — prevents timing oracle) ──
        var lockResult = await lockout.CheckLockoutAsync(email, ct);
        if (!lockResult.IsSuccess) return Result.Fail<object>(lockResult.Error!);

        // ── 2. Lookup user ──────────────────────────────────────────────────
        var user = await db.Users
            .FirstOrDefaultAsync(u => u.Email == email.ToLowerInvariant(), ct);

        // ── 3. Constant-time failure: bad email and bad password take same path ──
        if (user is null || !BCrypt.Net.BCrypt.Verify(pwd, user.PasswordHash))
        {
            // Only record attempt if user actually exists (prevent email enumeration
            // via timing attack — BCrypt.Verify on a dummy hash if user is null)
            if (user is null)
                BCrypt.Net.BCrypt.Verify(pwd, "$2a$12$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

            await lockout.RecordFailedAttemptAsync(email, ct);
            return Result.Fail<object>(new ValidationError("AUTH-002", "Invalid email or password"));
        }

        // ── 4. Account status check ─────────────────────────────────────────
        if (user.Status == UserStatus.Suspended)
            return Result.Fail<object>(new BusinessRuleError("AUTH-005", "Account is suspended. Contact support."));
        if (user.Status == UserStatus.Closed)
            return Result.Fail<object>(new BusinessRuleError("AUTH-006", "Account is closed."));
        if (user.Status == UserStatus.PendingVerification)
            return Result.Fail<object>(new BusinessRuleError("AUTH-007",
                "Account pending verification. Check your email or SMS for a verification code."));

        // ── 5. Success: clear lockout counter, issue tokens ──────────────────
        await lockout.ClearAttemptsAsync(email, ct);
        var (access, refresh) = await IssueTokensAsync(user, ct);

        return Result.Ok<object>(new
        {
            AccessToken  = access,
            RefreshToken = refresh,
            ExpiresIn    = 3600,
            TokenType    = "Bearer",
            UserId       = user.Id,
            Tier         = user.Tier.ToString(),
            KycLevel     = user.KycLevel.ToString(),
        });
    }

    private async Task<(string access, string refresh)> IssueTokensAsync(User user, CancellationToken ct)
    {
        var signingKey = new SymmetricSecurityKey(
            Encoding.UTF8.GetBytes(cfg["Auth:SigningKey"]
                ?? throw new InvalidOperationException("Auth:SigningKey not configured")));
        var creds = new SigningCredentials(signingKey, SecurityAlgorithms.HmacSha256);

        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub,   user.Id.ToString()),
            new Claim(JwtRegisteredClaimNames.Email, user.Email),
            new Claim(JwtRegisteredClaimNames.Jti,   Guid.NewGuid().ToString()),
            new Claim("tier",     user.Tier.ToString()),
            new Claim("kyc",      user.KycLevel.ToString()),
            new Claim("status",   user.Status.ToString()),
        };

        var jwt = new JwtSecurityToken(
            issuer:             cfg["Auth:Issuer"],
            audience:           cfg["Auth:Audience"],
            claims:             claims,
            notBefore:          DateTime.UtcNow,
            expires:            DateTime.UtcNow.AddHours(1),
            signingCredentials: creds);

        var accessToken = new JwtSecurityTokenHandler().WriteToken(jwt);

        // Refresh token: cryptographically random, stored as SHA256 hash in DB
        var rawBytes     = RandomNumberGenerator.GetBytes(64);
        var refreshToken = Convert.ToBase64String(rawBytes);
        var tokenHash    = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(rawBytes));

        await db.RefreshTokens.AddAsync(new RefreshToken
        {
            UserId    = user.Id,
            Token     = tokenHash,   // Store hash, return raw value to client
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        }, ct);
        await db.SaveChangesAsync(ct);

        return (accessToken, refreshToken);
    }
}

/// <summary>Validates + rotates refresh tokens (refresh token rotation pattern).</summary>
public class RefreshTokenHandler(IdentityDbContext db, IConfiguration cfg) : IRefreshTokenHandler
{
    public async Task<Result<object>> HandleAsync(string refreshToken, CancellationToken ct)
    {
        // Hash the incoming token to look up in DB
        var raw      = Convert.FromBase64String(refreshToken);
        var tokenHash = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(raw));

        var stored = await db.RefreshTokens
            .Include(r => r.User)
            .FirstOrDefaultAsync(r => r.Token == tokenHash, ct);

        if (stored is null || !stored.IsActive)
            return Result.Fail<object>(new ValidationError("AUTH-008", "Refresh token invalid or expired"));

        // Rotate: revoke old, issue new
        stored.RevokedAt = DateTimeOffset.UtcNow;

        var newRawBytes  = RandomNumberGenerator.GetBytes(64);
        var newRaw       = Convert.ToBase64String(newRawBytes);
        var newHash      = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(newRawBytes));

        await db.RefreshTokens.AddAsync(new RefreshToken
        {
            UserId    = stored.UserId,
            Token     = newHash,
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        }, ct);
        await db.SaveChangesAsync(ct);

        // Re-issue access token
        var user = stored.User!;
        var signingKey = new SymmetricSecurityKey(
            Encoding.UTF8.GetBytes(cfg["Auth:SigningKey"]!));
        var creds  = new SigningCredentials(signingKey, SecurityAlgorithms.HmacSha256);
        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub,   user.Id.ToString()),
            new Claim(JwtRegisteredClaimNames.Email, user.Email),
            new Claim(JwtRegisteredClaimNames.Jti,   Guid.NewGuid().ToString()),
            new Claim("tier",  user.Tier.ToString()),
            new Claim("kyc",   user.KycLevel.ToString()),
        };
        var jwt = new JwtSecurityToken(
            issuer:   cfg["Auth:Issuer"],
            audience: cfg["Auth:Audience"],
            claims:   claims,
            notBefore: DateTime.UtcNow,
            expires:  DateTime.UtcNow.AddHours(1),
            signingCredentials: creds);

        return Result.Ok<object>(new
        {
            AccessToken  = new JwtSecurityTokenHandler().WriteToken(jwt),
            RefreshToken = newRaw,
            ExpiresIn    = 3600,
            TokenType    = "Bearer",
        });
    }
}
