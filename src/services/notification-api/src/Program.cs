using MassTransit;
using SuperApp.Messaging;
using SuperApp.Messaging.Events;
using SuperApp.NotificationApi.Application;
using SuperApp.NotificationApi.Consumers;
using SuperApp.NotificationApi.Consumers.Erasure;
using SuperApp.NotificationApi.Infrastructure;
using SuperApp.PaymentApi.Application.Sagas;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpClient("hubtel", c => {
    c.BaseAddress = new Uri(builder.Configuration["Hubtel:BaseUrl"]!);
    c.DefaultRequestHeaders.Add("Authorization",
        $"Basic {builder.Configuration["Hubtel:ApiKey"]}");
}).AddStandardResilienceHandler();

builder.Services.AddScoped<INotificationSender, HubtelSmsSender>();

builder.Services.AddMassTransit(x => {
    x.AddConsumer<PaymentSuccessNotificationConsumer>();
    x.AddConsumer<PaymentFailedNotificationConsumer>();
    x.AddConsumer<UserRegisteredNotificationConsumer>();
    x.AddConsumer<UserErasureConsumer>();   // GAP-002

    x.UsingKafka((ctx, k) => {
        k.Host(builder.Configuration["Messaging:BootstrapServers"]);

        k.TopicEndpoint<NotifyPaymentSuccessCommand>(
            Topics.NotificationEvents, "notification-payment-success-group",
            e => e.ConfigureConsumer<PaymentSuccessNotificationConsumer>(ctx));

        k.TopicEndpoint<PaymentFailed>(
            Topics.PaymentSource, "notification-payment-failed-group",
            e => e.ConfigureConsumer<PaymentFailedNotificationConsumer>(ctx));

        k.TopicEndpoint<UserRegistered>(
            Topics.UserEvents, "notification-user-registered-group",
            e => e.ConfigureConsumer<UserRegisteredNotificationConsumer>(ctx));

        // GAP-002: erasure consumer
        k.TopicEndpoint<UserDataDeletionRequested>(
            Topics.UserDeletionRequests, "notification-erasure-group",
            e => e.ConfigureConsumer<UserErasureConsumer>(ctx));
    });
});

builder.Services.AddHealthChecks();

var app = builder.Build();
app.MapHealthChecks("/health/ready");
app.MapHealthChecks("/health/live", new() { Predicate = _ => false });
await app.RunAsync();
