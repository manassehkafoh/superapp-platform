using MassTransit;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Metrics;
using OpenTelemetry.Logs;
using Polly;
using SuperApp.Infrastructure;
using SuperApp.PaymentApi.Application;
using SuperApp.PaymentApi.Application.Sagas;
using SuperApp.PaymentApi.Infrastructure;
using SuperApp.Messaging;

namespace SuperApp.PaymentApi.Extensions;

public static class ServiceExtensions
{
    public static IServiceCollection AddPaymentApiServices(
        this IServiceCollection svc, IConfiguration cfg)
    {
        svc.AddDbContext<PaymentDbContext>(o =>
            o.UseSqlServer(cfg.GetConnectionString("PaymentDb"),
                sql => sql.EnableRetryOnFailure(5, TimeSpan.FromSeconds(10), null)));

        svc.AddScoped<IRepository<Domain.Payment>, PaymentRepository>();
        svc.AddScoped<IInitiatePaymentHandler, InitiatePaymentHandler>();
        svc.AddScoped<IPaymentQueryService,    PaymentQueryService>();
        svc.AddScoped<IPaymentLimitService,    PaymentLimitService>();

        svc.AddStackExchangeRedisCache(o =>
            o.Configuration = cfg.GetConnectionString("Redis"));

        svc.AddHostedService<OutboxPublisher>();
        return svc;
    }

    public static IServiceCollection AddPaymentApiAuth(
        this IServiceCollection svc, IConfiguration cfg)
    {
        svc.AddAuthentication("Bearer")
           .AddJwtBearer("Bearer", o => {
               o.Authority             = cfg["Auth:Authority"];
               o.Audience             = cfg["Auth:Audience"];
               o.RequireHttpsMetadata = true;
               o.TokenValidationParameters.ValidateLifetime         = true;
               o.TokenValidationParameters.ClockSkew                = TimeSpan.FromSeconds(30);
           });
        svc.AddAuthorization();
        return svc;
    }

    public static IServiceCollection AddPaymentApiMessaging(
        this IServiceCollection svc, IConfiguration cfg)
    {
        svc.AddMassTransit(x => {
            x.AddSagaStateMachine<PaymentSaga, PaymentSagaState>()
             .EntityFrameworkRepository(r => {
                 r.ExistingDbContext<PaymentDbContext>();
                 r.UseSqlServer();
             });

            x.UsingKafka((ctx, k) => {
                k.Host(cfg["Messaging:BootstrapServers"]);
                k.TopicEndpoint<SuperApp.Messaging.Events.PaymentInitiated>(
                    Topics.PaymentSource, "payment-saga-group", e => {
                        e.ConfigureSaga<PaymentSagaState>(ctx);
                    });
            });
        });
        return svc;
    }

    public static IServiceCollection AddPaymentApiObservability(
        this IServiceCollection svc, IConfiguration cfg)
    {
        var svcName    = cfg["Telemetry:ServiceName"] ?? "payment-api";
        var svcVersion = cfg["Telemetry:ServiceVersion"] ?? "1.0.0";
        var endpoint   = cfg["Telemetry:OtlpEndpoint"] ?? "http://localhost:4317";

        svc.AddOpenTelemetry()
            .ConfigureResource(r => r.AddService(svcName, serviceVersion: svcVersion))
            .WithTracing(t => t
                .AddAspNetCoreInstrumentation()
                .AddEntityFrameworkCoreInstrumentation()
                .AddRedisInstrumentation()
                .AddOtlpExporter(o => o.Endpoint = new Uri(endpoint)))
            .WithMetrics(m => m
                .AddAspNetCoreInstrumentation()
                .AddRuntimeInstrumentation()
                .AddOtlpExporter(o => o.Endpoint = new Uri(endpoint)));
        return svc;
    }

    public static IServiceCollection AddPaymentApiResilience(this IServiceCollection svc)
    {
        // Polly resilience pipeline for external payment rail HTTP clients
        svc.AddHttpClient("ghipss")
           .AddResilienceHandler("payment-rails", b => b
               .AddRetry(new() { MaxRetryAttempts = 3, Delay = TimeSpan.FromSeconds(2) })
               .AddCircuitBreaker(new() { SamplingDuration = TimeSpan.FromSeconds(30), FailureRatio = 0.5 })
               .AddTimeout(TimeSpan.FromSeconds(30)));

        svc.AddHttpClient("expresspay")
           .AddResilienceHandler("payment-rails", b => b
               .AddRetry(new() { MaxRetryAttempts = 3, Delay = TimeSpan.FromSeconds(2) })
               .AddCircuitBreaker(new() { SamplingDuration = TimeSpan.FromSeconds(30), FailureRatio = 0.5 })
               .AddTimeout(TimeSpan.FromSeconds(30)));

        return svc;
    }
}
