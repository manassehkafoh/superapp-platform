# 🚀 SuperApp Platform — Junior Engineer Onboarding Wiki

> **Welcome to the team!** This wiki is your complete guide to getting productive on the SuperApp platform.
> Read it end-to-end on your first day, then use it as a reference whenever you're stuck.
> If something is unclear or outdated, **please update this document** — that's your first contribution.

---

## 📋 Table of Contents

1. [What We Build](#1-what-we-build)
2. [The Tech Stack — Plain English](#2-the-tech-stack)
3. [Your First Day Setup](#3-first-day-setup)
4. [How Code Goes to Production](#4-how-code-goes-to-production)
5. [Understanding the Codebase](#5-understanding-the-codebase)
6. [Working with Kubernetes](#6-working-with-kubernetes)
7. [Secrets and Configuration](#7-secrets-and-configuration)
8. [Logging, Metrics & Tracing](#8-observability)
9. [Testing Standards](#9-testing)
10. [Security Rules You Must Know](#10-security)
11. [Your First PR Checklist](#11-first-pr)
12. [Who to Ask for Help](#12-who-to-ask)
13. [Glossary](#13-glossary)

---

## 1. What We Build

SuperApp is a **financial super-application** for Ghana that lets customers:
- Log in securely (Identity API)
- View and manage their account (Account API)
- Send and receive payments (Payment API)
- Check their wallet balance (Wallet API)
- Receive SMS/email notifications (Notification API)

All of this runs on **Microsoft Azure** (our main cloud) with a **disaster recovery copy on Google Cloud Platform (GCP)**. If Azure goes down, GCP takes over automatically within 15 minutes.

```
Customer App
     │
     ▼
[Cloudflare WAF]  ← blocks bad traffic globally
     │
[Azure Front Door] ← routes users to nearest healthy region
     │
[Azure Firewall Premium] ← company-level firewall
     │
[NGINX Ingress] ← Kubernetes entry point
     │
[API Gateway (YARP)] ← routes requests to the right service
     │
┌────┴──────────────────────────────────┐
│  identity  account  payment  wallet   │
│  notification       api         ...   │
└───────────────────────────────────────┘
     │                │
[Kafka Events]    [SQL Databases]
```

---

## 2. The Tech Stack

### 💻 Application Code
| Technology | What it is | Why we use it |
|------------|-----------|---------------|
| **C# / .NET 8** | Programming language and runtime | Fast, strongly-typed, excellent Azure integration |
| **ASP.NET Core** | Web framework | Industry standard for .NET APIs |
| **Entity Framework Core** | Database ORM | Converts C# objects to SQL automatically |
| **MassTransit** | Messaging library | Handles Kafka events and saga workflows |
| **YARP** | API gateway (reverse proxy) | Lightweight, built in .NET, very fast |

### ☁️ Infrastructure
| Technology | What it is | Why we use it |
|------------|-----------|---------------|
| **Kubernetes (AKS)** | Container orchestration | Runs our containers, handles scaling and restarts |
| **Cilium** | Network security inside K8s | Controls which services can talk to each other |
| **Terraform** | Infrastructure-as-code | We define servers in code, not by clicking buttons |
| **ArgoCD** | GitOps deployment tool | Watches Git, auto-deploys when code changes |
| **Helm** | Kubernetes package manager | Like npm but for Kubernetes configs |

### 🗄️ Data
| Technology | What it is | Why we use it |
|------------|-----------|---------------|
| **Azure SQL Hyperscale** | Our main database (Microsoft SQL Server) | Scales instantly, 35-day backups |
| **Redis** | In-memory cache | Stores sessions, rate limit counters (very fast) |
| **Apache Kafka / Azure Event Hubs** | Message queue | Services communicate via events, not direct calls |

### 🔒 Security
| Technology | What it is | Why we use it |
|------------|-----------|---------------|
| **HashiCorp Vault** | Secrets manager | All passwords/keys stored here, never hardcoded |
| **Azure Key Vault** | HSM key storage | Hardware-level key protection |
| **SPIFFE/SPIRE** | Service identity | Every service has a cryptographic ID |
| **FortiCNAPP** | Cloud-native security | Scans containers and K8s for vulnerabilities in real-time |
| **Falco** | Runtime threat detection | Alerts if something suspicious happens in a container |

### 🔭 Observability (Monitoring)
| Technology | What it is | Why we use it |
|------------|-----------|---------------|
| **Prometheus** | Metrics collection | Collects numbers (CPU, requests/sec, error rates) |
| **Grafana** | Dashboards | Visualises Prometheus metrics and logs |
| **Loki** | Log aggregation | Stores and queries all application logs |
| **Tempo** | Distributed tracing | Follows a request across multiple services |
| **OpenTelemetry** | Instrumentation standard | Adds tracing/metrics to our .NET code automatically |

---

## 3. First Day Setup

### 3.1 Prerequisites — Install These First

```bash
# macOS (use Homebrew)
brew install \
  git \
  dotnet@8 \
  docker \
  kubectl \
  helm \
  terraform \
  argocd \
  vault \
  azure-cli \
  k9s \
  cilium-cli \
  jq \
  yq \
  trivy

# Verify installs
dotnet --version        # Should be 8.x
kubectl version --client
terraform version       # Should be 1.8+
helm version
argocd version --client
```

```powershell
# Windows (use winget or scoop)
winget install Microsoft.DotNet.SDK.8
winget install Docker.DockerDesktop
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Hashicorp.Terraform
winget install Microsoft.AzureCLI
```

### 3.2 Azure Access Setup

```bash
# 1. Log in to Azure (ask your team lead for your credentials)
az login

# 2. Set the correct subscription
az account set --subscription "SuperApp-Production"

# 3. Get Kubernetes credentials for DEV cluster
az aks get-credentials \
  --resource-group rg-superapp-dev \
  --name aks-superapp-dev-eus2 \
  --overwrite-existing

# 4. Verify cluster access
kubectl get nodes
# You should see 3-5 nodes listed

# 5. Get credentials for STAGING (when you're ready)
az aks get-credentials \
  --resource-group rg-superapp-staging \
  --name aks-superapp-staging-eus2

# ⚠️  DO NOT request production credentials until after your 30-day review
```

### 3.3 Repository Setup

```bash
# 1. Clone the main repository
git clone https://github.com/superapp-gh/platform.git
cd platform

# 2. Set up git hooks (runs security scan before every commit)
chmod +x scripts/setup-git-hooks.sh
./scripts/setup-git-hooks.sh

# 3. Install .NET tools
dotnet tool restore

# 4. Restore all packages
dotnet restore SuperApp.sln

# 5. Run tests to verify your setup works
dotnet test SuperApp.sln
# All tests should pass before you write a single line of code
```

### 3.4 IDE Setup — Visual Studio / VS Code / Rider

**VS Code extensions to install:**
```
ms-dotnettools.csharp              # C# support
ms-kubernetes-tools.vscode-kubernetes-tools  # K8s files
hashicorp.terraform                # Terraform files
redhat.vscode-yaml                 # YAML validation
ms-azuretools.vscode-docker        # Docker files
grafana.vscode-jsonnet             # Grafana dashboards
```

**Rider (recommended for .NET):**
- Install Kubernetes plugin
- Install Terraform plugin
- Enable EditorConfig support (our `.editorconfig` enforces code style)

### 3.5 Local Development — Running Services

```bash
# Run a single service locally (example: payment-api)
cd src/payment-api

# Copy the example env file
cp .env.example .env.local
# Ask your team lead to fill in the DEV values

# Run with hot reload
dotnet run --environment Development

# The service starts at http://localhost:5004
# Swagger UI: http://localhost:5004/swagger
```

**Docker Compose for full local stack:**
```bash
# In the repo root
docker compose -f docker-compose.dev.yml up

# This starts:
# - All 5 microservices
# - SQL Server (local)
# - Redis
# - Kafka (single broker)
# - Grafana (http://localhost:3000)

# Stop everything
docker compose -f docker-compose.dev.yml down
```

---

## 4. How Code Goes to Production

> **Golden Rule**: Code only goes to production through the pipeline. Never deploy manually.

### The Journey of a Feature

```
1. You create a feature branch from main
   git checkout -b feature/JIRA-123-add-payment-retry

2. You write code + tests (minimum 80% coverage)

3. You open a Pull Request (PR) to main
   - GitHub runs: security scan, SAST, unit tests, coverage check
   - At least 2 engineers must approve
   - Your tech lead approves the architecture

4. PR merges to main → Pipeline triggers automatically:
   ├── Security scanning (secrets, SAST, container vulnerabilities)
   ├── Build & test (all services)
   ├── Container build → signed with Cosign → pushed to ACR
   ├── Terraform plan (shows infra changes)
   │
   ├── Deploy to DEV automatically
   │   └── Smoke tests run
   │
   ├── Deploy to STAGING automatically (if DEV passes)
   │   └── Integration + performance tests run
   │
   └── Deploy to PRODUCTION (requires manual approval + change ticket)
       └── Canary deployment: 20% → 50% → 100% traffic
           └── Auto-rollback if error rate > 0.1%
```

### Checking Your Deployment

```bash
# Watch ArgoCD sync status
argocd app list
argocd app get dev-payment-api

# Watch rollout progress (canary)
kubectl argo rollouts get rollout payment-api -n superapp-services --watch

# Check pod status
kubectl get pods -n superapp-services -w

# See recent logs from your service
kubectl logs -l app=payment-api -n superapp-services --tail=50 -f
```

---

## 5. Understanding the Codebase

### Project Structure

```
src/
├── identity-api/          # Authentication, JWT, user management
│   ├── Controllers/       # HTTP endpoints (thin — only input validation)
│   ├── Application/       # Business logic (commands, queries, handlers)
│   │   ├── Commands/      # Things that change state (CreateUser, ResetPassword)
│   │   └── Queries/       # Things that read state (GetUserById)
│   ├── Domain/            # Core business rules (User, Identity, MFA)
│   │   ├── Entities/      # Database-mapped objects
│   │   ├── ValueObjects/  # Immutable values (Email, PhoneNumber)
│   │   └── Events/        # Domain events published to Kafka
│   └── Infrastructure/    # DB access, external APIs, Kafka producers
│
├── payment-api/           # Payment initiation, saga orchestration
├── wallet-api/            # Wallet balance, double-entry ledger
├── account-api/           # Account management, statements
├── notification-api/      # SMS, email dispatch
└── api-gateway/           # YARP routing, JWT validation, rate limiting

tests/
├── identity-api.Tests/    # Unit tests (fast, no external deps)
├── identity-api.Integration.Tests/  # Integration tests (uses test DB)
└── e2e/                   # End-to-end tests (runs against DEV environment)
```

### The Architecture Pattern — Clean Architecture

Every service follows the same pattern. Here's what it means:

```
HTTP Request
    │
    ▼
[Controller]  ← only validates input, delegates immediately
    │
    ▼
[Application Layer]  ← orchestrates the business operation
    │  (Commands: CreatePaymentCommand, Queries: GetPaymentQuery)
    │
    ▼
[Domain Layer]  ← pure business rules, no framework dependencies
    │  (Payment aggregate, PaymentStatus enum, domain events)
    │
    ▼
[Infrastructure Layer]  ← talks to databases, Kafka, external APIs
       (PaymentRepository, GhIPSSAdapter, KafkaEventPublisher)
```

**Why this matters:**
- Domain logic has zero framework dependencies → easy to test
- You can swap the database without touching business rules
- Each layer only knows about the layer below it

### Making a Simple Change — Step by Step

**Example: Add a new field to payment response**

```csharp
// 1. Add to Domain entity (Domain/Entities/Payment.cs)
public string MerchantReference { get; private set; }

// 2. Add EF Core migration
dotnet ef migrations add AddMerchantReferenceToPayment \
  --project src/payment-api \
  --startup-project src/payment-api

// 3. Update the DTO (Application/Queries/GetPaymentResponse.cs)
public string MerchantReference { get; init; }

// 4. Map in the query handler
MerchantReference = payment.MerchantReference

// 5. Write a test
[Fact]
public async Task GetPayment_ShouldReturnMerchantReference_WhenPresent()
{
    // Arrange
    var payment = PaymentBuilder.WithMerchantReference("REF-001").Build();
    // ... test body
}
```

---

## 6. Working with Kubernetes

> You will mostly interact with the **DEV cluster**. Never `kubectl exec` into production without a tech lead present.

### Essential kubectl Commands

```bash
# See all pods in our namespace
kubectl get pods -n superapp-services

# See logs from a specific pod
kubectl logs payment-api-abc123 -n superapp-services

# Follow logs live
kubectl logs -l app=payment-api -n superapp-services -f --tail=100

# Describe a pod (useful for debugging crashes)
kubectl describe pod payment-api-abc123 -n superapp-services

# Exec into a running pod (DEV only)
kubectl exec -it payment-api-abc123 -n superapp-services -- /bin/sh

# Port-forward a service to your laptop (great for debugging)
kubectl port-forward svc/payment-api 8080:8080 -n superapp-services
# Now hit http://localhost:8080/swagger on your laptop

# See resource usage
kubectl top pods -n superapp-services

# See events (why is my pod crashing?)
kubectl get events -n superapp-services --sort-by=.lastTimestamp | tail -20
```

### Using k9s (Recommended UI)

```bash
# Launch k9s
k9s

# Inside k9s:
# :pods          → list pods
# :logs          → view logs
# :ns            → switch namespace
# d              → describe resource
# l              → view logs for selected pod
# ctrl+k         → kill a pod (triggers restart)
# ?              → help
```

### Understanding Namespaces

```
superapp-services   ← our microservices live here
superapp-gateway    ← API gateway lives here
superapp-data       ← Redis lives here
kafka               ← Kafka/Strimzi (dev only)
monitoring          ← Prometheus, Grafana, Loki, Tempo
argocd              ← ArgoCD deployment tool
cert-manager        ← TLS certificate automation
external-secrets    ← Key Vault sync
spire               ← Service identity
ingress-nginx       ← Kubernetes ingress controller
```

### Why Can't My Pod Talk to Another Pod?

We use **Cilium Network Policies** — a Zero Trust model. By default **all traffic is blocked**. Traffic is only allowed if there's an explicit policy.

```bash
# Check if Cilium is blocking your traffic
kubectl exec -n kube-system cilium-xxxxx -- \
  cilium monitor --type drop

# View the network policy for a service
kubectl get ciliumnetworkpolicy payment-api -n superapp-services -o yaml

# Use Hubble UI to see real-time traffic (DEV)
cilium hubble ui
# Opens browser at http://localhost:12000
```

---

## 7. Secrets and Configuration

> **CRITICAL RULE**: Never put passwords, API keys, or connection strings in code or Git. Ever.
> If you accidentally commit a secret, tell your tech lead **immediately** — do not try to fix it yourself.

### How Secrets Work

```
Azure Key Vault (HSM)
      │
      ▼
External Secrets Operator (reads KV every 5 minutes)
      │
      ▼
Kubernetes Secret (encrypted at rest with CMK)
      │
      ▼
Your Pod (secret mounted as env var or file)
```

### Getting a Secret Value (DEV only)

```bash
# List all secrets in a namespace
kubectl get secrets -n superapp-services

# Read a secret value (base64 encoded)
kubectl get secret payment-api-secrets -n superapp-services -o jsonpath='{.data.CONNECTION_STRING__PaymentDb}' | base64 -d

# Or use Vault CLI directly (ask for DEV Vault token from your lead)
export VAULT_ADDR='https://vault.dev.superapp.com.gh'
vault login  # use your token
vault kv get secret/payment-api/database
```

### Adding a New Secret

```bash
# 1. Add the secret value to Azure Key Vault
az keyvault secret set \
  --vault-name kv-superapp-dev \
  --name my-new-api-key \
  --value "the-actual-value"

# 2. Add the secret reference to the ExternalSecret in the Helm values
# kubernetes/apps/payment-api/values.yaml
externalSecrets:
  data:
    - secretKey: MY_NEW_API_KEY    # ← env var name in your pod
      remoteRef:
        key: my-new-api-key        # ← Key Vault secret name

# 3. Reference it in your appsettings.json
{
  "ExternalService": {
    "ApiKey": ""  // loaded from env var MY_NEW_API_KEY
  }
}

# 4. In your C# code
var apiKey = configuration["ExternalService:ApiKey"];
```

### Non-Secret Configuration

```bash
# Config that isn't sensitive lives in Kubernetes ConfigMaps
# or Helm values — committed to Git is fine

# Example: Feature flags
kubectl get configmap payment-api-config -n superapp-services -o yaml

# Edit config (DEV)
kubectl edit configmap payment-api-config -n superapp-services
```

---

## 8. Observability

### Accessing Dashboards

| Dashboard | URL | Credentials |
|-----------|-----|-------------|
| Grafana | https://grafana.dev.superapp.com.gh | SSO with Azure AD |
| ArgoCD | https://argocd.dev.superapp.com.gh | SSO with Azure AD |
| Hubble (Cilium) | `cilium hubble ui` (port-forward) | No auth in dev |
| Vault | https://vault.dev.superapp.com.gh | Ask team lead |

### Finding Your Service's Logs (Grafana → Loki)

```
1. Open Grafana → Explore → Select "Loki" data source
2. Use LogQL query:
   {namespace="superapp-services", app="payment-api"} |= "error"
3. Filter by correlation ID:
   {namespace="superapp-services"} |= "correlationId=abc-123"
```

### Tracing a Request End-to-End (Grafana → Tempo)

```
1. Open Grafana → Explore → Select "Tempo" data source
2. Search by trace ID (from logs or response header X-Trace-Id)
3. See the full journey: gateway → payment-api → wallet-api → kafka
4. Click any span to see timing and attributes
```

### Key Metrics to Watch

```promql
# Error rate for your service
rate(http_requests_total{service="payment-api",code!~"2.."}[5m])
  / rate(http_requests_total{service="payment-api"}[5m])

# p99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{service="payment-api"}[5m])) by (le))

# Kafka consumer lag
kafka_consumer_group_current_offset - kafka_consumer_group_committed_offset
```

### Writing Good Log Lines

```csharp
// ✅ GOOD — structured, searchable, includes context
_logger.LogInformation(
    "Payment initiated. {PaymentId} {Amount} {Currency} {CustomerId}",
    payment.Id, payment.Amount, payment.Currency, payment.CustomerId);

// ✅ GOOD — error with full context
_logger.LogError(ex,
    "Payment failed for {PaymentId}. ErrorCode: {ErrorCode}",
    paymentId, ex.ErrorCode);

// ❌ BAD — not searchable, no context
_logger.LogInformation($"Payment {paymentId} done");

// ❌ BAD — logs PII/PAN (compliance violation)
_logger.LogInformation("Card {CardNumber} charged", cardNumber);
```

---

## 9. Testing Standards

### The Testing Pyramid

```
          /\
         /e2e\          ← few, slow, expensive (10-20 tests)
        /──────\         runs against DEV environment
       /integr. \       ← moderate (50-100 tests per service)
      /──────────\       uses real DB via TestContainers
     /   unit     \     ← many, fast, cheap (200-500 per service)
    ──────────────────   no external dependencies, uses mocks
```

### Writing Unit Tests (xUnit + FluentAssertions)

```csharp
public class PaymentSagaTests
{
    [Fact]
    public async Task Payment_ShouldTransitionToDebiting_WhenInitiated()
    {
        // Arrange — set up the scenario
        var harness = new InMemoryTestHarness();
        var saga = harness.StateMachineSaga<PaymentSaga, PaymentSagaState>();

        await harness.Start();

        // Act — perform the operation
        await harness.Bus.Publish(new PaymentInitiatedEvent
        {
            PaymentId  = Guid.NewGuid(),
            Amount     = 100.00m,
            Currency   = "GHS",
            CustomerId = Guid.NewGuid()
        });

        // Assert — verify the outcome
        (await saga.Exists(state => state.CurrentState == "Debiting",
            timeout: TimeSpan.FromSeconds(5))).Should().BeTrue();

        await harness.Stop();
    }
}
```

### Writing Integration Tests (TestContainers)

```csharp
// Uses a real SQL Server container — no mocks
public class PaymentRepositoryTests : IClassFixture<DatabaseFixture>
{
    private readonly PaymentRepository _repo;

    public PaymentRepositoryTests(DatabaseFixture db)
    {
        _repo = new PaymentRepository(db.CreateContext());
    }

    [Fact]
    public async Task Save_ShouldPersistPayment_WithCorrectAmount()
    {
        var payment = PaymentBuilder.Valid().WithAmount(50.00m).Build();

        await _repo.SaveAsync(payment);
        var retrieved = await _repo.GetByIdAsync(payment.Id);

        retrieved.Amount.Should().Be(50.00m);
    }
}
```

### Running Tests

```bash
# All tests
dotnet test SuperApp.sln

# Specific project
dotnet test tests/payment-api.Tests

# With coverage report (opens in browser)
dotnet test --collect:"XPlat Code Coverage"
reportgenerator -reports:"**/coverage.cobertura.xml" -targetdir:"coverage-report" -reporttypes:Html
open coverage-report/index.html

# Watch mode (auto-runs on file save)
dotnet watch test --project tests/payment-api.Tests
```

---

## 10. Security Rules You Must Know

> Violating these rules can result in data breaches affecting real customers' financial data.

### ❌ Never Do These Things

```
1. NEVER hardcode secrets, passwords, API keys, or connection strings in code
2. NEVER log PII (names, phone numbers, account numbers, card numbers)
3. NEVER disable TLS verification (e.g., ServicePointManager.ServerCertificateValidationCallback)
4. NEVER use SELECT * in queries against payment/wallet tables
5. NEVER execute arbitrary SQL (always use parameterised queries / EF Core)
6. NEVER commit to main directly — always use PRs
7. NEVER share your Azure/Kubernetes credentials with anyone
8. NEVER kubectl exec into production without a tech lead
9. NEVER store card PAN, CVV, or PIN — route directly to payment rails
10. NEVER push Docker images without Cosign signing
```

### ✅ Always Do These Things

```
1. Use parameterised queries / EF Core for all DB access
2. Validate all input before processing (FluentValidation)
3. Return generic error messages to clients (never internal error details)
4. Check authentication + authorisation on every endpoint
5. Use correlation IDs in all log lines
6. Set timeouts on all external HTTP calls (never fire-and-forget)
7. Use CancellationTokens in async methods
8. Run `trivy image` on your container before raising a PR
9. Respond to FortiCNAPP/Falco alerts within 4 hours (P2 SLA)
```

### Correlation IDs (Required)

```csharp
// Every request must carry a correlation ID throughout the system
// The API gateway injects X-Correlation-Id if not present

// In your controller:
var correlationId = HttpContext.Request.Headers["X-Correlation-Id"].ToString();

// Include in all log calls:
using (_logger.BeginScope(new { CorrelationId = correlationId }))
{
    _logger.LogInformation("Processing payment...");
}

// Pass to downstream services:
httpClient.DefaultRequestHeaders.Add("X-Correlation-Id", correlationId);
```

---

## 11. Your First PR Checklist

Before raising a PR, run through this checklist:

```
Code Quality
  [ ] Tests pass: dotnet test
  [ ] Coverage ≥ 80%: check the coverage report
  [ ] No linting errors: dotnet format --verify-no-changes
  [ ] No TODO comments in production code paths

Security
  [ ] No secrets hardcoded (run: git secrets --scan)
  [ ] No SQL injection risks (using EF Core / parameterised only)
  [ ] No PII in log statements
  [ ] Trivy image scan passes: trivy image myimage:tag

Documentation
  [ ] Public methods have XML doc comments
  [ ] README updated if you changed how to run the service
  [ ] New environment variables documented in .env.example

Testing
  [ ] Unit tests for business logic
  [ ] Integration test for new DB queries
  [ ] Tested locally with docker-compose

Database
  [ ] EF Core migration generated and reviewed
  [ ] Migration is backward-compatible (no breaking column drops)
  [ ] Index added for new WHERE clause columns

PR Description Template
  [ ] JIRA ticket linked
  [ ] "What changed" section completed
  [ ] "How to test" section completed
  [ ] Screenshots for any UI changes
```

---

## 12. Who to Ask for Help

| Question Topic | Who to Ask | Channel |
|---------------|-----------|---------|
| "I can't get the cluster working" | Any senior dev | #platform-help |
| "My PR has been waiting 2 days" | Your tech lead | Direct message |
| "I think I committed a secret" | **Security team immediately** | #security-alerts |
| "The pipeline is broken for everyone" | Platform team | #platform-incidents |
| "Architecture / design question" | Your tech lead | In your PR comments |
| "I don't understand the business logic" | Product team | #product-questions |
| "Kubernetes question" | SRE team | #sre-help |
| "Database migration help" | DBA team | #database-help |

### 🙋 How to Ask Good Questions

```
BAD:  "My code doesn't work"

GOOD: "I'm getting a 403 Forbidden from payment-api when I call 
       POST /api/v1/payments from the test. I've checked:
       1. My JWT token is valid (tested in jwt.io)
       2. My pod is running (kubectl get pods shows Running)
       3. The log shows: 'Authorization failed. Required role: payments.write'
       
       I think it's a RBAC policy issue but I'm not sure where to change it.
       Relevant code: [link to file]"
```

---

## 13. Glossary

| Term | Meaning |
|------|---------|
| **AKS** | Azure Kubernetes Service — Microsoft's managed Kubernetes |
| **Canary deployment** | Release to 20% of users first, monitor, then roll out to all |
| **Cilium** | eBPF-based network security layer inside Kubernetes |
| **CNAPP** | Cloud-Native Application Protection Platform (FortiCNAPP) |
| **DDD** | Domain-Driven Design — organising code around business concepts |
| **DR** | Disaster Recovery — the GCP backup that activates if Azure fails |
| **eBPF** | Extended Berkeley Packet Filter — Linux kernel-level networking (used by Cilium) |
| **ESO** | External Secrets Operator — syncs Key Vault secrets into Kubernetes |
| **GitOps** | Infrastructure defined in Git, deployed automatically by ArgoCD |
| **Helm** | Kubernetes package manager — like npm for K8s configs |
| **HPA** | Horizontal Pod Autoscaler — auto-scales pod count based on CPU/memory |
| **HSM** | Hardware Security Module — tamper-proof hardware for key storage |
| **mTLS** | Mutual TLS — both sides verify each other's certificate |
| **PITR** | Point-In-Time Recovery — restore database to any point in time |
| **PCI-DSS** | Payment Card Industry security standard |
| **Saga** | Distributed transaction pattern using compensating transactions |
| **SAST** | Static Application Security Testing — scans code for vulnerabilities |
| **SPIFFE** | Secure Production Identity Framework — gives each service a certificate ID |
| **SLO** | Service Level Objective — the target we aim for (e.g., 99.9% uptime) |
| **WAF** | Web Application Firewall — blocks OWASP Top 10 attacks at the edge |
| **Zero Trust** | Security model: trust nothing by default, verify everything explicitly |
