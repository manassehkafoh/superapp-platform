FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /repo
COPY global.json Directory.Build.props Directory.Build.targets ./
COPY src/shared/ src/shared/
COPY src/services/account-api/ src/services/account-api/
RUN dotnet publish src/services/account-api/src/SuperApp.AccountApi.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
RUN groupadd --gid 1000 appgroup && useradd --uid 1000 --gid 1000 --no-create-home appuser
COPY --from=build --chown=appuser:appgroup /app/publish .
USER appuser
EXPOSE 8080
ENTRYPOINT ["dotnet", "SuperApp.AccountApi.dll"]
