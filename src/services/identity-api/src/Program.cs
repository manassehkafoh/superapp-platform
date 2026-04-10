using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using SuperApp.Security;
using SuperApp.IdentityApi.Api;
using SuperApp.IdentityApi.Application;
using SuperApp.IdentityApi.Infrastructure;
using System.Text;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration
    .AddJsonFile("appsettings.json", optional: false)
    .AddJsonFile($"appsettings.{builder.Environment.EnvironmentName}.json", optional: true)
    .AddEnvironmentVariables(prefix: "SUPERAPP_");

// ── Database ──────────────────────────────────────────────────────────────────
builder.Services.AddDbContext<IdentityDbContext>(o =>
    o.UseSqlServer(builder.Configuration.GetConnectionString("IdentityDb")!,
        sql => sql.EnableRetryOnFailure(5, TimeSpan.FromSeconds(10), null)));

// ── Redis (required for account lockout — GAP-001) ────────────────────────────
builder.Services.AddStackExchangeRedisCache(o =>
    o.Configuration = builder.Configuration.GetConnectionString("Redis")
        ?? throw new InvalidOperationException("Redis connection string required"));

// ── Application services ──────────────────────────────────────────────────────
builder.Services.AddScoped<IAccountLockoutService, AccountLockoutService>();
builder.Services.AddScoped<ILoginHandler,          LoginHandler>();
builder.Services.AddScoped<IRefreshTokenHandler,   RefreshTokenHandler>();
builder.Services.AddScoped<IRegisterUserHandler,   RegisterUserHandler>();
builder.Services.AddScoped<IUserDeletionHandler,   UserDeletionHandler>();  // GAP-002

// ── Auth ──────────────────────────────────────────────────────────────────────
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.Authority             = builder.Configuration["Auth:Authority"];
        o.Audience             = builder.Configuration["Auth:Audience"];
        o.RequireHttpsMetadata = !builder.Environment.IsDevelopment();
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer           = true,
            ValidateAudience         = true,
            ValidateLifetime         = true,
            ValidateIssuerSigningKey = true,
            ClockSkew                = TimeSpan.FromSeconds(30),
            IssuerSigningKey         = new SymmetricSecurityKey(
                Encoding.UTF8.GetBytes(builder.Configuration["Auth:SigningKey"]
                    ?? throw new InvalidOperationException("Auth:SigningKey required"))),
        };
    });
builder.Services.AddAuthorization();

// ── OpenTelemetry ─────────────────────────────────────────────────────────────
builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService("identity-api", serviceVersion: "1.0.0"))
    .WithTracing(t => t
        .AddAspNetCoreInstrumentation()
        .AddEntityFrameworkCoreInstrumentation()
        .AddRedisInstrumentation()
        .AddOtlpExporter(o => o.Endpoint = new Uri(
            builder.Configuration["Telemetry:OtlpEndpoint"] ?? "http://localhost:4317")));

builder.Services.AddHealthChecks()
    .AddSqlServer(builder.Configuration.GetConnectionString("IdentityDb")!, name: "sql")
    .AddRedis(builder.Configuration.GetConnectionString("Redis")!, name: "redis");

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(o =>
    o.SwaggerDoc("v1", new() { Title = "SuperApp Identity API", Version = "v1" }));

var app = builder.Build();

app.UseSecurityHeaders();
app.UseCorrelationId();
app.UseAuthentication();
app.UseAuthorization();

if (!app.Environment.IsProduction()) app.UseSwagger().UseSwaggerUI();

app.MapAuthEndpoints();
app.MapHealthChecks("/health/ready", new() { Predicate = r => r.Tags.Contains("ready") });
app.MapHealthChecks("/health/live",  new() { Predicate = _ => false });

await app.RunAsync();
