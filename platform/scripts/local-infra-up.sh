#!/usr/bin/env bash
# SuperApp — Local Infrastructure Setup
# Starts k3d cluster + docker-compose services for local development
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RESET='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log "Starting SuperApp local infrastructure..."

# k3d cluster
if ! k3d cluster list 2>/dev/null | grep -q superapp-local; then
  log "Creating k3d cluster..."
  k3d cluster create superapp-local \
    --port "8080:80@loadbalancer" \
    --port "8443:443@loadbalancer" \
    --agents 2 \
    --k3s-arg "--disable=traefik@server:*"
  ok "k3d cluster created"
else
  log "k3d cluster already exists — skipping"
fi

# Docker compose services
log "Starting SQL, Redis, Kafka, Vault, Grafana..."
docker compose \
  -f "${REPO_ROOT}/build/docker/docker-compose.local.yml" \
  up -d \
  --remove-orphans \
  --wait

ok "Local infrastructure ready!"

echo ""
echo "  SQL Server:    localhost:1433  (sa / YourStrong@Passw0rd)"
echo "  Redis:         localhost:6379"
echo "  Kafka:         localhost:9092"
echo "  Kafka UI:      http://localhost:8090"
echo "  Schema Reg:    http://localhost:8081"
echo "  Vault:         http://localhost:8200  (token: superapp-dev-root-token)"
echo "  Grafana:       http://localhost:3000  (admin/admin)"
echo "  Prometheus:    http://localhost:9090"
echo ""
echo "  Run a service: make run SERVICE=payment-api"
