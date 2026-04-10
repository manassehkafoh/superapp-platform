using SuperApp.PaymentApi.Extensions;
using SuperApp.PaymentApi.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

// ── Configuration ─────────────────────────────────────────────────────────
builder.Configuration
    .AddJsonFile("appsettings.json", optional: false)
    .AddJsonFile($"appsettings.{builder.Environment.EnvironmentName}.json", optional: true)
    .AddEnvironmentVariables(prefix: "SUPERAPP_");

// ── Services ──────────────────────────────────────────────────────────────
builder.Services
    .AddPaymentApiServices(builder.Configuration)
    .AddPaymentApiAuth(builder.Configuration)
    .AddPaymentApiMessaging(builder.Configuration)
    .AddPaymentApiObservability(builder.Configuration)
    .AddPaymentApiResilience()
    .AddHealthChecks()
        .AddSqlServer(builder.Configuration["ConnectionStrings:PaymentDb"]!, name: "sql")
        .AddRedis(builder.Configuration["ConnectionStrings:Redis"]!, name: "redis")
        .AddKafka(builder.Configuration["Messaging:BootstrapServers"]!, name: "kafka");

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(o => {
    o.SwaggerDoc("v1", new() { Title = "SuperApp Payment API", Version = "v1" });
    o.AddSecurityDefinition("Bearer", new() { Type = Microsoft.OpenApi.Models.SecuritySchemeType.Http, Scheme = "bearer" });
});

var app = builder.Build();

// ── Middleware pipeline ────────────────────────────────────────────────────
app.UseSecurityHeaders();           // Custom middleware — adds HSTS, CSP, X-Frame-Options
app.UseCorrelationId();             // Custom middleware — propagates X-Correlation-ID
app.UseRequestLogging();            // Structured request/response logging (no PII)

if (!app.Environment.IsProduction())
    app.UseSwagger().UseSwaggerUI();

app.UseAuthentication();
app.UseAuthorization();

// ── Endpoints ─────────────────────────────────────────────────────────────
app.MapPaymentEndpoints();
app.MapHealthChecks("/health/ready", new() { Predicate = r => r.Tags.Contains("ready") });
app.MapHealthChecks("/health/live",  new() { Predicate = _ => false });

await app.RunAsync();
