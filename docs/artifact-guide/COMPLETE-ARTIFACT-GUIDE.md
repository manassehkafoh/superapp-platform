# 📚 SuperApp Platform — Complete Artifact Guide

> **Purpose**: Every file in this repository explained. What it is, why it exists, how to change it, and exactly what gets deployed when you touch it.
> **Audience**: Engineers at all levels — junior to principal.
> **Keep Updated**: When you add a new file, add an entry here.

---

## 🗂️ Repository Map

```
superapp-platform/
│
├── terraform/                    ← Infrastructure as Code (Azure + GCP)
│   ├── providers.tf              ← Which cloud providers and versions to use
│   ├── variables.tf              ← All input variables with validation
│   ├── main.tf                   ← Root module — orchestrates all sub-modules
│   ├── environments/
│   │   ├── prod/terraform.tfvars     ← Production environment values
│   │   ├── staging/terraform.tfvars  ← Staging environment values
│   │   └── dev/terraform.tfvars      ← Development environment values
│   └── modules/
│       ├── networking/main.tf    ← Hub-spoke VNet, Firewall, DDoS, DNS
│       ├── security/main.tf      ← Key Vault, Defender, Sentinel, Falco, Vault
│       ├── identity/main.tf      ← Azure AD, Managed Identities, RBAC
│       ├── kubernetes/main.tf    ← AKS cluster, Cilium, ArgoCD, cert-manager
│       ├── databases/main.tf     ← Azure SQL Hyperscale (5 per-service DBs)
│       ├── messaging/main.tf     ← Azure Event Hubs, Strimzi Kafka, Schema Registry
│       ├── monitoring/main.tf    ← Prometheus, Grafana, Loki, Tempo, OTel
│       └── cnapp/main.tf         ← FortiCNAPP CWPP/CSPM/KSPM/CIEM
│
├── kubernetes/
│   ├── cilium/
│   │   └── network-policies.yaml ← Zero Trust L7 network policies per service
│   └── apps/
│       └── payment-api/values.yaml ← Helm values (canary, HPA, secrets, probes)
│
├── gitops/
│   └── argocd/applications/
│       └── superapp-appset.yaml  ← ApplicationSet (6 services × 3 envs)
│
├── .github/workflows/
│   └── ci-cd.yml                 ← GitHub Actions pipeline (8 stages)
│
├── gitlab/
│   └── .gitlab-ci.yml            ← GitLab CI equivalent pipeline
│
├── scripts/
│   └── deploy.sh                 ← Single end-to-end deployment script
│
└── docs/
    ├── WELL-ARCHITECTED-FRAMEWORK.md  ← Full architecture document
    ├── c4-models/C4-ALL-LEVELS.md     ← C4 diagrams (all 4 levels)
    ├── architecture-decisions/ADRs.md ← 6 architecture decision records
    ├── runbooks/RUNBOOKS.md           ← 4 operational runbooks
    ├── onboarding/                    ← Junior engineer guide
    ├── team-wikis/TEAM-WIKIS.md       ← Per-role quick references
    └── artifact-guide/                ← This document
```

---

## 🔧 TERRAFORM ARTIFACTS

### `terraform/providers.tf`
**What it is**: Declares which Terraform providers (cloud SDKs) to use and their version constraints.
**Why it exists**: Terraform downloads provider plugins to communicate with cloud APIs. Version pinning ensures reproducible builds.

| Provider | Purpose | Version |
|---------|---------|--------|
| `azurerm` | All Azure resources | ~3.100 |
| `azuread` | Azure Active Directory | ~2.50 |
| `google` | GCP DR resources | ~5.25 |
| `kubernetes` | K8s manifests | ~2.29 |
| `helm` | Helm chart deployments | ~2.13 |
| `vault` | HashiCorp Vault config | ~3.25 |

**Backend**: Azure Blob Storage (AAD auth, no SAS keys, state locking via blob lease).

🚨 **Deployment Impact**: Changing a provider version triggers `terraform init -upgrade`. Test in dev first.

```bash
# After editing providers.tf
terraform init -upgrade
terraform providers                          # Check for conflicts
cat .terraform.lock.hcl                      # Commit this lock file!
```

---

### `terraform/variables.tf`
**What it is**: All input variables with types, defaults, and validation rules.

Variable groups: core config, networking CIDRs, AKS node pools, database SKUs, Redis, messaging, security, monitoring, compliance flags, common tags.

🚨 **Deployment Impact**: Adding a variable without a default requires it in ALL three `terraform.tfvars` files or `plan` will prompt interactively (blocking CI).

```hcl
# Correct pattern for new variables:
variable "feature_x_enabled" {
  description = "Enable feature X — SOC 2 CC6.1 control reference"
  type        = bool
  default     = false
  validation {
    condition     = can(tobool(var.feature_x_enabled))
    error_message = "Must be true or false."
  }
}
# Then add to: environments/dev/terraform.tfvars
#              environments/staging/terraform.tfvars
#              environments/prod/terraform.tfvars
```

---

### `terraform/main.tf`
**What it is**: Root orchestrator — calls all 8 modules in dependency order.

**Module execution order (dependency chain):**
```
networking → security → identity → kubernetes → databases → messaging → monitoring → cnapp
     ↑            ↑          ↑           ↑
  VNet/DNS    Key Vault   Mgd IDs     AKS OIDC issuer URL needed by identity
```

🚨 **Deployment Impact**: Syntax error here breaks the entire plan. Always run `terraform validate` before pushing.

```bash
terraform validate                           # Syntax check (no Azure call)
terraform graph | dot -Tsvg > graph.svg      # Dependency graph (needs graphviz)
terraform apply -target=module.monitoring    # Target single module (last resort)
```

---

### `terraform/modules/networking/main.tf`
**What it is**: Hub-spoke network topology, Azure Firewall Premium, DDoS protection, private DNS.

**Resources created:**
- Hub VNet + Spoke VNet + VNet Peering
- Azure Firewall Premium (IDPS `Deny` mode in prod)
- Azure Bastion Standard (no public SSH/RDP)
- DDoS Protection Standard
- 6 NSGs (deny-all default, explicit allows)
- Route Tables (UDR) forcing all egress through firewall
- 7 Private DNS Zones (SQL, Redis, EventHubs, KeyVault, ACR, Storage, AKS)
- Firewall FQDN rules: payment rails only (ghipss.com.gh, expresspay.com.gh, api.hubtel.com)

🔒 **Security**: All pod internet egress is blocked except explicit FQDN allowlist. Firewall IDPS in Deny mode blocks known exploit patterns at wire speed.

🚨 **Deployment Impact**: VNet CIDR changes require subnet recreation → AKS node pool rebuild → maintenance window required.

```bash
# Check firewall blocked traffic (investigate unexpected denials)
az monitor log-analytics query \
  --workspace law-superapp-prod-eus2 \
  --analytics-query "AzureFirewallNetworkRule | where Action=='Deny' | take 20"

# Test FQDN egress from a payment-api pod
kubectl exec -n superapp-services deploy/payment-api -- \
  curl -I https://ghipss.com.gh --max-time 5
```

---

### `terraform/modules/security/main.tf`
**What it is**: All security infrastructure in one module.

| Resource | Purpose | Key Config |
|---------|---------|-----------|
| Azure Key Vault Premium | HSM-backed secrets, CMK | Purge protection, 90-day soft delete, RBAC auth |
| CMK Key (RSA-HSM 4096) | Encrypts AKS disks, SQL TDE, Storage | 90-day auto-rotation |
| ACR Premium | Container registry | Content trust (Cosign), quarantine, geo-replication |
| Microsoft Defender for Cloud | Threat detection | All plans enabled: Servers, Containers, SQL, KV, DNS |
| Microsoft Sentinel | SIEM | AAD + MCAS + AATP data connectors |
| HashiCorp Vault HA (3 replicas) | Dynamic secrets, PKI, DB creds | Azure KV auto-unseal, TLS 1.3, audit log |
| OPA Gatekeeper | K8s policy enforcement | Blocks non-compliant pod specs |
| Falco (eBPF) | Runtime kernel security | Custom payment/identity rules, PD+Slack alerts |
| SPIRE | SPIFFE workload identity | Trust domain: `superapp.{env}.internal` |

🚨 **Critical**: Key Vault purge protection means **you cannot re-create a KV with the same name for 90 days** after deletion. Never delete KVs without a recovery plan.

```bash
# Check Vault seal status
kubectl exec -n vault vault-0 -- vault status

# Check Falco detections live
kubectl logs -l app.kubernetes.io/name=falco -n security -f | jq .

# List OPA violations
kubectl get k8srequirelabels.constraints.gatekeeper.sh \
  -o jsonpath='{.items[*].status.totalViolations}'
```

---

### `terraform/modules/identity/main.tf`
**What it is**: All identity constructs — Azure AD groups, Managed Identities, Federated Credentials, Kubernetes RBAC.

**Key concept — Workload Identity (no stored secrets):**
```
Pod → K8s OIDC token → exchanged for → Azure AD access token → Key Vault
No client secrets. No passwords. Tokens expire in 24h automatically.
```

11 Managed Identities (one per service), 11 Federated Credentials, 7 Azure AD Groups, namespaces with Pod Security Standards enforced.

✏️ **Adding a new service**: Add the service name to `locals.services` list. Terraform creates the Managed Identity, Federated Credential, and ServiceAccount automatically.

```bash
# Verify workload identity works for a pod
kubectl exec -n superapp-services deploy/payment-api -- \
  curl -sf "http://169.254.169.254/metadata/identity/oauth2/token\
?api-version=2018-02-01&resource=https://vault.azure.net" \
  -H "Metadata: true" | jq .access_token | wc -c   # Should print token length > 0

# Force ESO to re-sync secrets
kubectl annotate externalsecret payment-api-secrets \
  force-sync=$(date +%s) -n superapp-services --overwrite
```

---

### `terraform/modules/kubernetes/main.tf`
**What it is**: AKS private cluster + all in-cluster platform tooling via Helm.

**Cluster configuration:**
- Private cluster (no public Kubernetes API endpoint)
- Azure AD RBAC (Azure AD groups map to K8s roles)
- 4 node pools: system / app / data / security (node taint isolation)
- Customer-Managed Key disk encryption
- Azure Container Insights + Azure Policy add-on

**Helm releases deployed:**
| Chart | Version | Purpose |
|-------|---------|---------|
| Cilium | 1.15.4 | CNI, eBPF, mTLS, WireGuard, Hubble |
| ArgoCD | 7.1.0 | GitOps controller (HA, Azure AD SSO) |
| cert-manager | 1.14.5 | TLS certificate automation (Let's Encrypt) |
| External Secrets Operator | 0.9.18 | Key Vault → K8s Secret sync |
| NGINX Ingress | latest | External traffic ingress |
| Argo Rollouts | latest | Canary / Blue-Green deployments |

```bash
# Upgrade AKS Kubernetes version (plan maintenance window)
az aks upgrade \
  --resource-group rg-superapp-platform-prod \
  --name aks-superapp-prod \
  --kubernetes-version 1.31 \
  --node-image-only false

# Check Cilium health after upgrade
cilium status --wait

# Access Hubble UI (Cilium network observability)
cilium hubble ui   # Opens browser with L7 flow visualization
```

---

### `terraform/modules/databases/main.tf`
**What it is**: 5 isolated Azure SQL Hyperscale instances + Redis Premium.

**DB-per-service layout:**
| Instance | DB | Tier (prod) | Failover Group |
|---------|-----|------------|----------------|
| sql-identity-prod | IdentityDB | HS_Gen5_2 | No |
| sql-account-prod | AccountDB | HS_Gen5_2 | No |
| sql-payment-prod | PaymentDB | HS_Gen5_4 | ✅ Yes (60-min grace) |
| sql-wallet-prod | WalletDB | HS_Gen5_4 | ✅ Yes (60-min grace) |
| sql-notification-prod | NotificationDB | GP_Gen5_2 | No |

All instances: TDE with CMK, Defender for SQL, private endpoint, 35-day PITR, 7-year LTR.

```bash
# Check failover readiness before DR drill
az sql failover-group show \
  --resource-group rg-superapp-data-prod \
  --server sql-payment-prod --name fg-payment-db \
  --query "replicationState"   # Must be "SYNCHRONIZED" before failover

# Get Vault-managed DB credentials (expires in 15 min)
vault read database/creds/payment-api-role
```

---

### `terraform/modules/messaging/main.tf`
**What it is**: Azure Event Hubs Premium (Kafka-compatible) for prod; Strimzi Kafka for dev/staging; Apicurio Schema Registry.

**8 topics with retention and archival rules** (transaction-logs and audit-logs archived to immutable Blob with 7-year lifecycle).

Production uses Azure Event Hubs — no Kafka brokers to manage, SLA-backed, geo-redundant.
Dev/Staging uses Strimzi — full Kafka semantics for realistic testing.

```bash
# Check Event Hubs namespace (production)
az eventhubs namespace show \
  --resource-group rg-superapp-messaging-prod \
  --name evhns-superapp-prod-eus2 \
  --query "provisioningState"

# Get Kafka bootstrap endpoint for app config
terraform output -module=messaging eventhub_bootstrap_servers
```

---

### `terraform/modules/monitoring/main.tf`
**What it is**: Full observability stack: metrics, logs, traces, dashboards, alerting.

**Observability pipeline:**
```
.NET App → OpenTelemetry SDK
             ├── Traces  → OTel Collector → Tempo (30-day retention in Azure Blob)
             ├── Metrics → OTel Collector → Prometheus → Azure Monitor (long-term)
             └── Logs    → OTel Collector → Loki (31-day retention in Azure Blob)
                                                     ↓
                                                  Grafana (Azure AD SSO)
                                                     ↓
                                              AlertManager → PagerDuty / Slack
```

Pre-installed PrometheusRules: Payment API SLO burn-rate alerts, DORA metric recording rules.
PII redaction in OTel pipeline: regex strips `pan`, `cvv`, `pin`, `password` fields from spans.

```bash
# Access Grafana (port-forward locally)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# → http://localhost:3000 (admin / admin in dev)

# Query payment API error rate (last 5 min)
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# → PromQL: sum(rate(http_requests_total{service="payment-api",code!~"2.."}[5m]))
#         / sum(rate(http_requests_total{service="payment-api"}[5m]))
```

---

### `terraform/modules/cnapp/main.tf`
**What it is**: FortiCNAPP integration — Fortinet's Cloud-Native Application Protection Platform.

| Capability | Mode (prod) | What It Does |
|-----------|-------------|-------------|
| CWPP | Enforce | eBPF runtime security — kills non-compliant container actions |
| CSPM | Audit (6h) | Azure subscription misconfiguration scan vs. CIS/PCI/DORA |
| KSPM | Audit (4h) | Kubernetes CIS benchmark, RBAC analysis, pod security |
| CIEM | Continuous | Maps all identities → effective permissions, flags dormant roles |
| Supply Chain | On pod start | Cosign signature verification + SBOM collection |

Custom rules: block exec into payment-api pods, alert on large DB result sets (exfiltration), block crypto miners, FIM on `/app`.

All findings forwarded to Microsoft Sentinel as `FortiCNAPPFindings` custom table.

```bash
# Check FortiCNAPP agent health
kubectl get daemonset fortirecon-agent -n fortirecon
kubectl get pods -n fortirecon -o wide

# View recent runtime alerts
kubectl logs -l app.kubernetes.io/name=fortirecon-agent -n fortirecon \
  --tail=100 | jq 'select(.severity == "critical" or .severity == "high")'

# FortiCNAPP console
echo "https://app.fortirecon.com/clusters/superapp-${ENVIRONMENT}"
```

---

## ☸️ KUBERNETES ARTIFACTS

### `kubernetes/cilium/network-policies.yaml`
**What it is**: CiliumNetworkPolicy CRDs enforcing Zero Trust inside the cluster.

**Policies:**
- `default-deny-all` — every pod starts with DENY ALL ingress and egress (except DNS)
- `identity-api` — allow ingress from gateway on auth/user HTTP paths only
- `payment-api` — allow FQDN egress to payment rails (GhIPSS, ExpressPay, Hubtel), deny all else
- `wallet-api` — allow inbound from gateway + payment-api internal calls
- `api-gateway` — allow ingress from NGINX, egress to all backend services
- `deny-imds-access` — cluster-wide: block all pods from Azure IMDS (credential theft prevention)

**L7 example** (more powerful than standard NetworkPolicy):
```yaml
rules:
  http:
    - method: "POST"
      path: "/api/v1/payments/.*"   # ← Only this exact path allowed, NOT /api/v1/payments/delete
```

```bash
# Verify policy is working (should timeout — wallet cannot call identity)
kubectl exec -n superapp-services deploy/wallet-api -- \
  curl http://identity-api.superapp-services:8080/health --max-time 3

# See dropped packets in Hubble
hubble observe --verdict DROPPED --namespace superapp-services

# Validate policy syntax before applying
cilium policy validate kubernetes/cilium/network-policies.yaml
```

---

### `kubernetes/apps/payment-api/values.yaml`
**What it is**: Helm values for the payment-api — the most security-critical service.

Key configs: Argo Rollouts canary (20%→50%→100%), AnalysisTemplate (99.9% SLO gate, auto-rollback), Pod Security Standards (non-root, read-only filesystem, seccomp), HPA (3-20 replicas), PDB (minAvailable: 2), topology spread across AZs, 8 ExternalSecrets from Key Vault.

```bash
# Watch canary live
kubectl argo rollouts get rollout payment-api -n superapp-services --watch

# Manually promote (emergency — skips analysis)
kubectl argo rollouts promote payment-api -n superapp-services --full

# Abort and rollback
kubectl argo rollouts abort payment-api -n superapp-services
```

---

## 🔄 GITOPS & CI/CD ARTIFACTS

### `gitops/argocd/applications/superapp-appset.yaml`
**What it is**: ArgoCD ApplicationSet generating 18 Applications (6 services × 3 envs) from a single template.

Image updates flow: ACR push → ArgoCD Image Updater detects new digest → updates `image.tag` in Git → ArgoCD syncs to cluster.

Production: manual sync only, weekday 06:00-14:00 UTC sync window, change ticket verification.

```bash
argocd app list                              # All 18 apps + sync state
argocd app sync prod-payment-api             # Manual prod deploy
argocd app rollback prod-payment-api         # Emergency rollback
argocd app history prod-payment-api          # Deployment history
```

---

### `.github/workflows/ci-cd.yml` / `gitlab/.gitlab-ci.yml`
**What it is**: 8-stage CI/CD pipeline (GitHub Actions + GitLab CI equivalent).

**Stages**: security-scan → build (matrix 5 services) → terraform-plan → deploy-dev → deploy-staging → [manual gate] → deploy-prod → dora-metrics.

**Gates that will fail the pipeline:**
- TruffleHog detects a secret in code
- CodeQL finds a high/critical vulnerability
- Trivy finds CRITICAL/HIGH CVEs in container image or IaC
- Unit test coverage < 80%
- OPA Terraform policy has DENY rules
- Smoke tests fail in dev or staging
- Canary AnalysisTemplate: error rate > 0.1%

---

## 📖 DOCUMENTATION ARTIFACTS

| File | Audience | Update Frequency |
|------|---------|-----------------|
| `docs/WELL-ARCHITECTED-FRAMEWORK.md` | CTO, Principal Engineers | Quarterly or on major arch change |
| `docs/c4-models/C4-ALL-LEVELS.md` | All engineers | When system boundaries change |
| `docs/architecture-decisions/ADRs.md` | All engineers | Every significant tech decision |
| `docs/runbooks/RUNBOOKS.md` | SRE, On-call | After every incident, quarterly test |
| `docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md` | New joiners | When workflow changes |
| `docs/team-wikis/TEAM-WIKIS.md` | All roles | When tools/URLs/processes change |
| `docs/artifact-guide/COMPLETE-ARTIFACT-GUIDE.md` | All engineers | When adding/removing files |

---

*Last updated: 2024-Q1 | Owner: Platform Team | PRs welcome*
