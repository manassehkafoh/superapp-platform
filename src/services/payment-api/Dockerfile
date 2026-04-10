# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /repo

# Copy solution and shared project files first (layer caching)
COPY global.json Directory.Build.props Directory.Build.targets ./
COPY src/shared/ src/shared/
COPY src/services/payment-api/ src/services/payment-api/

# Restore — cached unless .csproj files change
RUN dotnet restore src/services/payment-api/src/SuperApp.PaymentApi.csproj

# Build and publish
RUN dotnet publish src/services/payment-api/src/SuperApp.PaymentApi.csproj \
    -c Release \
    -o /app/publish \
    --no-restore \
    /p:UseAppHost=false

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

# Security: non-root user (matches K8s securityContext.runAsUser: 1000)
RUN groupadd --gid 1000 appgroup && \
    useradd  --uid 1000 --gid 1000 --no-create-home appuser

# Copy only published output — no SDK, no source
COPY --from=build --chown=appuser:appgroup /app/publish .

USER appuser

# Health check (Kubernetes also has liveness/readiness probes)
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:8080/health/live || exit 1

EXPOSE 8080
ENTRYPOINT ["dotnet", "SuperApp.PaymentApi.dll"]
