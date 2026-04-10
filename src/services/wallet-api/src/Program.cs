using MassTransit;
using Microsoft.EntityFrameworkCore;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using SuperApp.Security;
using SuperApp.WalletApi.Api;
using SuperApp.WalletApi.Application;
using SuperApp.WalletApi.Consumers;
using SuperApp.WalletApi.Infrastructure;
using SuperApp.Messaging;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDbContext<WalletDbContext>(o =>
    o.UseSqlServer(builder.Configuration.GetConnectionString("WalletDb")!,
        sql => sql.EnableRetryOnFailure(5, TimeSpan.FromSeconds(10), null)));

builder.Services.AddScoped<IWalletService, WalletService>();

builder.Services.AddAuthentication("Bearer")
    .AddJwtBearer("Bearer", o => {
        o.Authority = builder.Configuration["Auth:Authority"];
        o.Audience  = builder.Configuration["Auth:Audience"];
    });
builder.Services.AddAuthorization();

builder.Services.AddMassTransit(x => {
    x.AddConsumer<DebitWalletConsumer>();
    x.AddConsumer<ReverseWalletDebitConsumer>();
    x.UsingKafka((ctx, k) => {
        k.Host(builder.Configuration["Messaging:BootstrapServers"]);
        k.TopicEndpoint<SuperApp.PaymentApi.Application.Sagas.DebitWalletCommand>(
            Topics.PaymentSource, "wallet-debit-group",
            e => e.ConfigureConsumer<DebitWalletConsumer>(ctx));
    });
});

builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService("wallet-api"))
    .WithTracing(t => t.AddAspNetCoreInstrumentation().AddEntityFrameworkCoreInstrumentation()
        .AddOtlpExporter(o => o.Endpoint = new Uri(
            builder.Configuration["Telemetry:OtlpEndpoint"] ?? "http://localhost:4317")));

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

app.UseSecurityHeaders();
app.UseCorrelationId();
app.UseAuthentication();
app.UseAuthorization();

if (!app.Environment.IsProduction()) app.UseSwagger().UseSwaggerUI();

app.MapWalletEndpoints();
app.MapHealthChecks("/health/ready");
app.MapHealthChecks("/health/live", new() { Predicate = _ => false });

await app.RunAsync();
