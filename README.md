# SuperApp Platform — Monorepo

> Ghana's enterprise digital financial platform. Mono-repo containing all microservices, shared libraries, infrastructure-as-code, Kubernetes manifests, CI/CD pipelines, and documentation in a single repository.

[![CI/CD](https://github.com/superapp-gh/platform/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/superapp-gh/platform/actions/workflows/ci-cd.yml)
[![Coverage](https://img.shields.io/badge/coverage-≥80%25-brightgreen)]()
[![Security](https://img.shields.io/badge/security-SOC2%20%7C%20PCI--DSS%20v4-blue)]()
[![License](https://img.shields.io/badge/license-proprietary-red)]()

---

## 📦 Repository Structure

```
superapp-monorepo/
│
├── src/                            ← All application code
│   ├── shared/                     ← Libraries shared by all services
│   │   ├── SuperApp.Common/        ← Result<T>, AppError types, PagedResult
│   │   ├── SuperApp.Domain/        ← AggregateRoot, DomainEvent, Money value object
│   │   ├── SuperApp.Messaging/     ← Kafka topic constants + all event contracts
│   │   ├── SuperApp.Infrastructure/← Repository pattern, Outbox, EF Core base
│   │   └── SuperApp.Security/      ← Correlation ID, security headers middleware
│   │
│   └── services/                   ← Microservices (one folder = one deployable)
│       ├── identity-api/           ← Auth, registration, MFA, KYC, JWT issuance
│       ├── payment-api/            ← Payment processing (GhIPSS, ExpressPay, Hubtel)
│       ├── wallet-api/             ← Digital wallet with double-entry ledger
│       ├── account-api/            ← Bank account management
│       ├── notification-api/       ← SMS, email, push via Hubtel
│       └── api-gateway/            ← YARP reverse proxy + rate limiting + JWT validation
│
├── tests/
│   ├── unit/                       ← Fast unit tests (no Docker required)
│   └── integration/                ← Integration tests using Testcontainers
│
├── platform/                       ← All infrastructure and deployment code
│   ├── terraform/                  ← Azure IaC (AKS, SQL, Event Hubs, Key Vault...)
│   ├── kubernetes/                 ← Cilium policies + Helm values per service
│   ├── gitops/                     ← ArgoCD ApplicationSet (GitOps deployment)
│   └── scripts/deploy.sh           ← Single end-to-end deployment script
│
├── docs/                           ← Architecture, ADRs, runbooks, onboarding
├── build/docker/                   ← Local development docker-compose
├── .github/workflows/ci-cd.yml     ← GitHub Actions (8-stage, monorepo-aware)
├── Makefile                        ← Common developer tasks (make help)
├── SuperApp.sln                    ← Visual Studio solution file
├── Directory.Build.props           ← Shared MSBuild settings for ALL projects
└── global.json                     ← .NET SDK version pin (8.0.x)
```

---

## 🚀 Quick Start

### Prerequisites
```bash
# Install required tools (macOS — see docs/onboarding/ for Ubuntu)
brew install dotnet-sdk git docker kubectl helm argocd azure-cli \
             hashicorp/tap/terraform vault cosign k3d jq
```

### Local development
```bash
# 1. Clone
git clone https://github.com/superapp-gh/platform.git superapp && cd superapp

# 2. Start local infrastructure (SQL, Redis, Kafka, Vault, Grafana)
make local-up

# 3. Run a service with hot reload
make run SERVICE=payment-api

# 4. Run unit tests
make test-unit

# 5. Open Kafka UI
open http://localhost:8090

# 6. Open local Grafana
open http://localhost:3000
```

### Build & Test
```bash
make restore       # Restore all NuGet packages
make build         # Build full solution
make test          # Unit + integration tests
make coverage      # Generate HTML coverage report
make lint          # Lint with warnings-as-errors
make security-scan # TruffleHog + Trivy scan
```

### Deploy
```bash
make deploy-dev     # Full deploy to dev
make deploy-staging # Full deploy to staging
make deploy-prod    # Production (requires ITSM ticket)

# Or directly:
./platform/scripts/deploy.sh --environment dev
./platform/scripts/deploy.sh --help   # Full option reference
```

---

## 🏗️ Architecture Overview

```
Customer (mobile/web)
      ↓ HTTPS
Cloudflare CDN/WAF → Azure Front Door → Azure Firewall Premium (IDPS Deny)
      ↓
api-gateway  (YARP + Ocelot — routing, rate limiting, JWT validation)
      ↓
┌─────────────┬──────────────┬────────────┬──────────────┬────────────────────┐
│ identity-api│  account-api │ payment-api│  wallet-api  │  notification-api  │
│  IdentityDB │  AccountDB   │  PaymentDB │   WalletDB   │   NotificationDB   │
└─────────────┴──────────────┴────────────┴──────────────┴────────────────────┘
      ↑↓ events via Kafka (Azure Event Hubs Premium — 8 topics)
      ↑↓ secrets via Azure Key Vault → HashiCorp Vault (dynamic creds)
      ↑↓ network isolated by Cilium eBPF Zero Trust policies
      ↑↓ protected by FortiCNAPP (CWPP/CSPM/KSPM/CIEM)
```

**Multi-cloud**: Azure East US 2 (primary active) ↔ GCP Europe West 4 (warm standby DR)

---

## 🛡️ Security & Compliance

| Framework | Controls | Status |
|-----------|---------|--------|
| SOC 2 Type II | CC6.1-CC7.3 | ✅ Certified |
| PCI-DSS v4 | Req 1,2,3,4,6,7,10,11 | ✅ Compliant |
| DORA (EU) | Art 9,11,12,17 | ✅ Compliant |
| Bank of Ghana KYC | Tier 1/2/3 | ✅ Implemented |

Security toolchain: FortiCNAPP · Falco · Cilium mTLS · OPA Gatekeeper · SPIFFE/SPIRE · HashiCorp Vault · Azure Defender · Microsoft Sentinel · Cosign image signing · TruffleHog · CodeQL · Trivy

---

## 📋 Service SLOs (Production)

| Service | Availability | p99 Latency | Error Rate |
|---------|-------------|------------|-----------|
| payment-api | 99.9% | < 2s | < 0.1% |
| identity-api | 99.95% | < 500ms | < 0.05% |
| wallet-api | 99.9% | < 1s | < 0.1% |
| account-api | 99.9% | < 1s | < 0.1% |
| notification-api | 99.5% | < 5s | < 0.5% |

---

## 📚 Documentation

| Document | Link |
|---------|------|
| Well-Architected Framework | [docs/WELL-ARCHITECTED-FRAMEWORK.md](docs/WELL-ARCHITECTED-FRAMEWORK.md) |
| Architecture Decision Records | [docs/architecture-decisions/ADRs.md](docs/architecture-decisions/ADRs.md) |
| C4 Architecture Diagrams | [docs/c4-models/C4-ALL-LEVELS.md](docs/c4-models/C4-ALL-LEVELS.md) |
| Runbooks (incident response) | [docs/runbooks/RUNBOOKS.md](docs/runbooks/RUNBOOKS.md) |
| Junior Engineer Onboarding | [docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md](docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md) |
| Team Wikis | [docs/team-wikis/TEAM-WIKIS.md](docs/team-wikis/TEAM-WIKIS.md) |
| Complete Artifact Guide | [docs/artifact-guide/COMPLETE-ARTIFACT-GUIDE.md](docs/artifact-guide/COMPLETE-ARTIFACT-GUIDE.md) |

---

## 🤝 Contributing

1. Create a branch: `git checkout -b feature/SUPER-<ticket>-<description>`
2. Make changes following [coding standards](docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md#8-coding-standards--conventions)
3. Run: `make test lint security-scan`
4. Open a PR — at least 2 approvals required, 1 from a squad senior
5. CI runs automatically — all gates must pass before merge

---

*Built with ❤️ by the SuperApp Engineering Team, Ghana*
