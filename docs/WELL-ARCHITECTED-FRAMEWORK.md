# SuperApp Platform — Well-Architected Framework Document
> **Version:** 2.0.0 | **Classification:** CONFIDENTIAL | **Status:** APPROVED
> **Authors:** Platform Engineering Office | **Last Updated:** 2026-04-10
> **Compliance Scope:** SOC 2 Type II · ISO 27001 · DORA · PCI-DSS L1 · GDPR

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis](#2-current-state-analysis)
3. [Target Architecture Vision](#3-target-architecture-vision)
4. [Multi-Cloud Strategy](#4-multi-cloud-strategy)
5. [Security Architecture (SOC 2 / Zero Trust)](#5-security-architecture)
6. [Resilience & DORA Compliance](#6-resilience--dora-compliance)
7. [Kubernetes, Cilium & CNAPP](#7-kubernetes-cilium--cnapp)
8. [Observability & Platform Engineering](#8-observability--platform-engineering)
9. [Data Architecture](#9-data-architecture)
10. [Network Architecture](#10-network-architecture)
11. [C4 Model Hierarchy](#11-c4-model-hierarchy)
12. [Architecture Decision Records](#12-architecture-decision-records)
13. [Non-Functional Requirements & SLAs](#13-non-functional-requirements--slas)
14. [Operational Runbooks](#14-operational-runbooks)

---

## 1. Executive Summary

### 1.1 Platform Overview

SuperApp is a **financial services super-application** targeting retail and SME customers. It aggregates banking, payments, investments, pensions, and wallet services into a single digital platform. The platform integrates with core banking (Temenos T24), third-party payment rails (GhIPSS, ExpressPay, ACH, Hubtel, ITC), and internal financial infrastructure.

### 1.2 Architecture Imperatives

| Imperative | Target | Rationale |
|---|---|---|
| **Availability** | 99.99% (52 min/yr downtime) | Financial services regulation |
| **RTO** | < 4 hours | DORA Article 12 |
| **RPO** | < 1 hour | DORA Article 12 |
| **Security Posture** | SOC 2 Type II + Zero Trust | Regulatory + customer trust |
| **Deployment Frequency** | Daily (main), On-demand (hotfix) | DORA delivery metrics |
| **MTTR** | < 1 hour | DORA Article 11 |
| **Change Failure Rate** | < 5% | DORA delivery metrics |

### 1.3 Key Architectural Decisions

1. **Multi-cloud active-active** (Azure primary + GCP secondary) with unified control plane
2. **Kubernetes everywhere** with Cilium eBPF CNI as the universal data-plane
3. **Zero-Trust** enforced at every layer via SPIFFE/SPIRE workload identity
4. **GitOps** (ArgoCD) as the single source of truth for all deployments
5. **CNAPP** (Prisma Cloud / Defender CSPM) for continuous posture management
6. **Event-driven core** with Apache Kafka for all cross-domain communication

---

## 2. Current State Analysis

### 2.1 Existing Components Identified

```
┌─────────────────────────────────────────────────────────────┐
│                    CURRENT ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────┤
│  Client → Azure Front Door → On-Prem Firewall               │
│                            → Azure Cloud Firewall            │
│        → WAF + ALB → Kubernetes (2 nodes)                   │
│                   → YARP API Gateway (ASP.NET)               │
│                   → Microservices:                           │
│                     ├── Identity API    (JWT, User Mgmt)     │
│                     ├── Account API    (Bank/Invest/Pension) │
│                     ├── Payment API    (GIP, ACH, Bills)     │
│                     ├── Logging & Notification API           │
│                     └── WalletSystem API (Ledger)            │
│  Shared Services:                                            │
│    ├── Apache Kafka   (event streaming)                      │
│    ├── Redis Cache                                           │
│    ├── SQL DB (MSSQL) (shared — IdentityDB/AccountDB/...)   │
│    ├── APIHive (OpenAPI)                                     │
│    ├── ESB (GHIPSS, ExpressPay, ACH, ITC, Hubtel)           │
│    └── T24 Core Banking                                      │
│  DB Replication: Prod Azure → Standby HQ → Standby DR       │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Critical Gaps & Risks

| # | Gap | Risk Level | Impact |
|---|-----|-----------|--------|
| G-01 | Shared SQL DB (all services share one DB server) | 🔴 Critical | Blast radius = total outage |
| G-02 | No mutual TLS between services | 🔴 Critical | Lateral movement risk |
| G-03 | Basic CNI, no network policy enforcement | 🔴 Critical | Zero-trust gap |
| G-04 | Single Kubernetes cluster (no HA control plane) | 🔴 Critical | Single point of failure |
| G-05 | No secrets management (assume env vars) | 🔴 Critical | Secret sprawl, SOC 2 gap |
| G-06 | No distributed tracing | 🟠 High | MTTR elevated |
| G-07 | No chaos engineering / resilience testing | 🟠 High | DORA gap |
| G-08 | ESB is a monolithic integration point | 🟠 High | Single point of failure |
| G-09 | No CNAPP / cloud security posture management | 🟠 High | SOC 2 gap |
| G-10 | MSSQL locks vendor to Azure SQL; no multi-cloud DB | 🟡 Medium | Multi-cloud blocker |
| G-11 | Correlation-ID injected at gateway, no propagation | 🟡 Medium | Observability gap |
| G-12 | No formal DR playbook (manual failover) | 🟡 Medium | DORA non-compliance |

---

## 3. Target Architecture Vision

### 3.1 Architecture Principles

```
AP-01  Security-First     Every design decision starts with threat modelling
AP-02  Immutable Infra    No manual changes to production — GitOps enforced
AP-03  Loose Coupling     Services communicate only via events or gRPC/REST  
AP-04  Bulkhead Pattern   Each service has isolated compute, data, and network
AP-05  Observability-In   Metrics, traces, logs are NOT afterthoughts
AP-06  Resilience-By-Default  Every service handles partial failures gracefully
AP-07  Data Sovereignty   Customer PII never leaves approved jurisdictions
AP-08  Open Standards     Vendor lock-in minimised via CNCF tooling
AP-09  Shift-Left         Security, compliance checks run in the pipeline
AP-10  Cost Transparency  Every resource tagged, every cloud spend visible
```

### 3.2 High-Level Target Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           SUPERAPP PLATFORM v2                                    │
│                    Secure Multi-Cloud · Zero-Trust · GitOps                      │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                           GLOBAL EDGE LAYER                                 │  │
│  │   Cloudflare CDN/WAF ─── Azure Front Door ─── DDoS Protection              │  │
│  │   GeoDNS Load Balancing  │  Rate Limiting      Bot Management              │  │
│  └─────────────────────────┼───────────────────────────────────────────────────┘  │
│                            │                                                      │
│  ┌─────────────────────────▼───────────────────────────────────────────────────┐  │
│  │                    CLOUD NETWORK PERIMETER                                  │  │
│  │   Azure Firewall Premium ─── Network Security Groups ─── Private DNS       │  │
│  │   DDoS Standard Plan         Azure Policy           GCP Cloud Armor        │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
│  ┌──────────────────────────────┐    ┌──────────────────────────────────────┐    │
│  │   AZURE PRIMARY CLUSTER       │    │    GCP SECONDARY CLUSTER             │    │
│  │   AKS + Cilium               │    │    GKE + Cilium                      │    │
│  │   ┌──────────────────────┐   │    │    ┌──────────────────────────────┐  │    │
│  │   │  Ingress Tier         │   │    │    │  Ingress Tier                │  │    │
│  │   │  NGINX + Cert-Manager │   │    │    │  NGINX + Cert-Manager        │  │    │
│  │   └──────────┬───────────┘   │    │    └───────────┬──────────────────┘  │    │
│  │   ┌──────────▼───────────┐   │    │    ┌───────────▼──────────────────┐  │    │
│  │   │  API Gateway          │   │    │    │  API Gateway (replica)        │  │    │
│  │   │  YARP + Ocelot        │   │    │    │  YARP + Ocelot               │  │    │
│  │   └──────────┬───────────┘   │◄──►│    └───────────┬──────────────────┘  │    │
│  │   ┌──────────▼───────────┐   │    │    ┌───────────▼──────────────────┐  │    │
│  │   │  SERVICE MESH         │   │    │    │  SERVICE MESH                │  │    │
│  │   │  Cilium + mTLS        │   │    │    │  Cilium + mTLS               │  │    │
│  │   │  SPIFFE/SPIRE Identity│   │    │    │  SPIFFE/SPIRE Identity       │  │    │
│  │   └──────────────────────┘   │    │    └──────────────────────────────┘  │    │
│  │   Microservices (all):        │    │    Microservices (stateless):        │    │
│  │   • identity-svc             │    │    • identity-svc                    │    │
│  │   • account-svc              │    │    • account-svc                     │    │
│  │   • payment-svc              │    │    • payment-svc                     │    │
│  │   • wallet-svc               │    │    • wallet-svc                      │    │
│  │   • notification-svc         │    │    • notification-svc                │    │
│  │   • audit-svc                │    │                                      │    │
│  └──────────────────────────────┘    └──────────────────────────────────────┘    │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                         DATA TIER (Resilient)                               │  │
│  │   Azure SQL Hyperscale (PRI)  ←geo-rep→  Cloud SQL (GCP SEC)               │  │
│  │   Azure Cache for Redis        ←repl→    Memorystore (GCP)                 │  │
│  │   Azure Event Hubs / Kafka     ←mirror→  Confluent Cloud (GCP)             │  │
│  │   Azure Key Vault              ←sync→    GCP Secret Manager                │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │              SECURITY & COMPLIANCE PLANE                                    │  │
│  │   CNAPP (Prisma Cloud)  │  SIEM (Azure Sentinel)  │  PAM (CyberArk)         │  │
│  │   OPA / Kyverno Policies│  Falco Runtime Security │  Vault (HashiCorp)      │  │
│  │   Tetragon eBPF Audit   │  CSPM continuous scan   │  mTLS everywhere        │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                OBSERVABILITY STACK (Full-Stack)                              │  │
│  │   OpenTelemetry Collector → Tempo (traces) + Loki (logs) + Prometheus       │  │
│  │   Grafana Dashboards     │  PagerDuty Alerting   │  SLO Dashboards          │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                    GITOPS & PLATFORM LAYER                                  │  │
│  │   GitHub / GitLab → GitHub Actions / GitLab CI → ArgoCD → Kubernetes       │  │
│  │   Terraform Cloud  │  Atlantis  │  OPA Sentinel policies  │  Trivy Scans   │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Multi-Cloud Strategy

### 4.1 Cloud Topology

```
┌─────────────────────────────────────────────────────────────┐
│              MULTI-CLOUD TOPOLOGY                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  AZURE (Primary — Active)                                    │
│  Region: West Europe (Primary), North Europe (Secondary)     │
│  Role: All production traffic + stateful data               │
│  Services: AKS, Azure SQL, Azure Cache, Event Hubs, Vault   │
│           Azure Front Door, Azure Firewall Premium           │
│           Azure Monitor, Microsoft Sentinel                  │
│                                                              │
│  GCP (Secondary — Active Standby / DR)                       │
│  Region: europe-west1 (Primary), europe-west4 (Secondary)   │
│  Role: DR failover + read workloads + analytics              │
│  Services: GKE, Cloud SQL, Memorystore, Pub/Sub             │
│           Cloud Armor, GCP Security Command Center          │
│                                                              │
│  INTERCONNECT: Azure ExpressRoute ↔ GCP Partner Interconnect │
│                via dedicated 10Gbps private backbone         │
│                                                              │
│  CONTROL PLANE: Unified via:                                 │
│   • Terraform (IaC across both clouds)                       │
│   • ArgoCD (GitOps for Kubernetes workloads)                 │
│   • Prisma Cloud (CNAPP — unified posture view)              │
│   • HashiCorp Vault (secrets — deployed on both clouds)      │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Workload Distribution

| Service | Azure (Active) | GCP (Standby/DR) | Failover Time |
|---|---|---|---|
| Identity API | Primary | Hot Standby | < 30s (auto) |
| Account API | Primary | Warm Standby | < 2min |
| Payment API | Primary | Hot Standby | < 30s (auto) |
| Wallet API | Primary | Hot Standby | < 30s (auto) |
| Notification API | Primary | Warm Standby | < 5min |
| Kafka | Azure Event Hubs | Confluent GCP | Transparent (mirror) |
| SQL Databases | Azure SQL Hyperscale | Cloud SQL (replicated) | < 15min (manual promote) |
| Redis Cache | Azure Cache for Redis | Cloud Memorystore | < 2min |

---

## 5. Security Architecture

### 5.1 Zero-Trust Architecture

```
ZERO TRUST PRINCIPLES APPLIED:

Layer 1 — Identity (Who are you?)
  ├── Human Identity: Azure AD / Entra ID (MFA enforced, phishing-resistant)
  ├── Service Identity: SPIFFE/SPIRE (X.509 SVIDs auto-rotated every 1 hour)
  ├── Machine Identity: AKS Managed Identity + Workload Identity Federation
  └── Third Party: OAuth2 + PKCE for all external integrations

Layer 2 — Device (Is this device trusted?)
  ├── MDM: Intune-managed devices only for admin access
  ├── Certificate-based device auth for service-to-service
  └── Hardware Security Keys (FIDO2) for privileged access

Layer 3 — Network (Should this packet flow?)
  ├── Cilium Network Policies: Default-DENY-ALL, explicit allow-list
  ├── Mutual TLS (mTLS): All service mesh traffic encrypted in-transit
  ├── eBPF-enforced L7 policies: HTTP/gRPC method-level controls
  └── Tetragon: Kernel-level syscall auditing

Layer 4 — Application (Is this request valid?)
  ├── YARP Gateway: JWT validation, rate limiting, CORS enforcement
  ├── OPA/Rego: Fine-grained authorization policies per endpoint
  ├── Input validation: All inputs validated server-side (FluentValidation)
  └── Output encoding: All responses sanitized

Layer 5 — Data (Is this data protected?)
  ├── Encryption at rest: AES-256 (TDE for SQL, CMK in Key Vault)
  ├── Encryption in transit: TLS 1.3 minimum
  ├── Column-level encryption: PAN, SSN, account numbers
  ├── Tokenization: PCI-DSS card data via Tokenization Service
  └── Key rotation: Automated 90-day rotation via Azure Key Vault
```

### 5.2 SOC 2 Compliance Mapping

| SOC 2 Trust Service Criteria | Control Implementation |
|---|---|
| **CC1 - Control Environment** | OPA policies, RBAC, change management via GitOps |
| **CC2 - Communication** | Audit logs in immutable storage, SIEM alerts |
| **CC3 - Risk Assessment** | CNAPP continuous scanning, threat modelling per sprint |
| **CC4 - Monitoring** | Prometheus + Grafana SLO dashboards, PagerDuty |
| **CC5 - Control Activities** | GitHub branch protection, signed commits, Trivy scans |
| **CC6 - Logical Access** | Zero-trust + MFA + PAM (CyberArk) for privileged access |
| **CC7 - System Ops** | ArgoCD GitOps, immutable infra, automated rollback |
| **CC8 - Change Management** | GitFlow + PR approvals + automated pipeline gates |
| **CC9 - Risk Mitigation** | Multi-cloud DR, chaos engineering programme |
| **A1 - Availability** | 99.99% SLA, AZ-redundant deployments |
| **C1 - Confidentiality** | CMK encryption, network segmentation, DLP policies |
| **PI1 - Processing Integrity** | Idempotency keys, distributed transactions (Saga pattern) |
| **P - Privacy** | GDPR data mapping, right-to-erasure workflow, DPO reviewed |

### 5.3 Secret Management Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 SECRET MANAGEMENT FLOW                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Developers                                                  │
│     │                                                        │
│     ▼                                                        │
│  HashiCorp Vault (Primary — Azure AKS)                       │
│  HashiCorp Vault (DR — GCP GKE)                              │
│     │                                                        │
│     ├── Azure Key Vault (HSM-backed, FIPS 140-2 Level 3)    │
│     ├── GCP Secret Manager (mirror)                          │
│     │                                                        │
│     ▼                                                        │
│  Vault Agent Injector / CSI Driver                          │
│     │  (injects secrets as in-memory tmpfs volumes)         │
│     │  (NO secrets in env vars or ConfigMaps)               │
│     ▼                                                        │
│  Kubernetes Pods                                             │
│     │  (secrets ephemeral — rotated on pod restart)         │
│     ▼                                                        │
│  External Secrets Operator                                   │
│     │  (sync from Vault → Kubernetes Secret objects)        │
│     │  (encrypted at rest via Sealed Secrets)               │
│     ▼                                                        │
│  Audit Log → SIEM (all secret access logged)                │
│                                                              │
│  Key Hierarchy:                                              │
│  Master Key (HSM) → DEK per service → Rotated every 90 days │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. Resilience & DORA Compliance

### 6.1 DORA Regulatory Requirements (EU Regulation 2022/2554)

| DORA Article | Requirement | Implementation |
|---|---|---|
| Art. 5-16 | ICT Risk Management Framework | Risk register, threat model per service |
| Art. 17 | ICT-related incident management | PagerDuty + Slack + runbooks |
| Art. 18 | Incident classification | P0/P1/P2/P3 severity with SLA per tier |
| Art. 19 | Incident reporting to authorities | Automated FCA/ECB report generation |
| Art. 24-27 | Digital Operational Resilience Testing | Chaos engineering quarterly programme |
| Art. 28-30 | Third-party ICT risk management | Vendor TPRM programme |
| Art. 32 | TLPT (Threat-Led Penetration Testing) | Annual red team engagement |

### 6.2 Resilience Patterns

```
PATTERN 1: Circuit Breaker (Polly .NET)
  ├── Threshold: 5 failures in 30s window → Open circuit
  ├── Half-open: 1 probe request after 30s
  └── Applied to: All external service calls (T24, ESB, third-parties)

PATTERN 2: Bulkhead
  ├── Thread pool isolation per downstream dependency
  ├── Separate connection pools per service
  └── K8s: LimitRange per namespace, no shared resource pools

PATTERN 3: Retry with Exponential Backoff + Jitter
  ├── Max retries: 3
  ├── Base delay: 200ms, multiplier: 2x, max: 5s
  ├── Jitter: ±20% of calculated delay
  └── Applied to: All idempotent operations

PATTERN 4: Timeout Cascade Prevention
  ├── Gateway timeout: 30s
  ├── Service-to-service: 10s
  ├── Database queries: 5s (with connection pool timeout: 30s)
  └── Deadlines propagated via gRPC metadata

PATTERN 5: Saga Pattern (Distributed Transactions)
  ├── Payment Saga: Debit → Notify → Reconcile (with compensating tx)
  ├── Account Creation Saga: Create → KYC → Activate
  ├── Implemented via: Kafka + Outbox Pattern (guaranteed delivery)
  └── Correlation tracked via X-Correlation-Id header

PATTERN 6: Outbox Pattern (Transactional Messaging)
  ├── Write to domain DB + outbox table in same transaction
  ├── Outbox worker polls and publishes to Kafka
  ├── At-least-once delivery with idempotency keys
  └── Dead Letter Queue for poison messages
```

### 6.3 Chaos Engineering Programme

```
QUARTERLY CHAOS EXPERIMENT SCHEDULE:

Q1: Infrastructure Chaos
  ├── Kill random AKS node (steady-state: <30s pod rescheduling)
  ├── Inject 500ms latency on payment service → circuit breaker fires
  └── Simulate Azure region outage → GCP failover validates

Q2: Application Chaos  
  ├── Kill Identity API → verify cached tokens still work
  ├── Flood Kafka topic → verify consumer backpressure
  └── Inject DB connection errors → verify retry logic

Q3: Data Chaos
  ├── Promote GCP replica to primary (DR drill)
  ├── Corrupt Redis cache → verify cache-miss fallback to DB
  └── Simulate Kafka broker failure → verify consumer lag recovery

Q4: Security Chaos
  ├── Rotate all mTLS certificates → verify zero downtime
  ├── Revoke a service account → verify SPIFFE re-issuance
  └── Simulate supply chain attack on container image
```

### 6.4 DR Plan & RPO/RTO

```
SCENARIO 1: Single AKS Node Failure
  Detection: < 30s (Kubernetes liveness probe)
  Recovery:  Automatic (pod rescheduling)
  RTO: < 2 min | RPO: 0 (stateless services)

SCENARIO 2: AKS Cluster Control Plane Failure
  Detection: < 1 min (Prometheus alert)
  Recovery:  Activate GCP GKE cluster (ArgoCD already synced)
  RTO: < 30 min | RPO: < 5 min (Kafka lag)

SCENARIO 3: Primary SQL DB Failure
  Detection: < 1 min (Azure Monitor)
  Recovery:  Auto-failover to geo-secondary (Azure SQL)
  RTO: < 15 min | RPO: < 1 min

SCENARIO 4: Azure Region Outage
  Detection: < 5 min (Front Door health probe failure)
  Recovery:  Traffic shifted to GCP via Front Door policy
  RTO: < 1 hour | RPO: < 15 min

SCENARIO 5: Ransomware / Data Breach
  Detection: Falco + Tetragon alert (real-time)
  Recovery:  Isolate → Eradicate → Restore from immutable backup
  RTO: < 4 hours | RPO: < 1 hour
```

---

## 7. Kubernetes, Cilium & CNAPP

### 7.1 Kubernetes Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  AKS CLUSTER ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CONTROL PLANE (Azure Managed)                                   │
│   ├── kube-apiserver    (HA, 3 replicas, private endpoint only) │
│   ├── etcd              (encrypted, 3 replicas, Azure Disk CSI)  │
│   ├── kube-scheduler    (Descheduler also deployed)             │
│   └── kube-controller-manager                                   │
│                                                                  │
│  NODE POOLS:                                                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  SYSTEM POOL (3 nodes, D4s_v5, taints: CriticalAddons) │    │
│  │  • CoreDNS, kube-proxy (replaced by Cilium), metrics    │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  APP POOL (3-10 nodes autoscale, D8s_v5, spot+regular) │    │
│  │  • All application microservices                        │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  DATA POOL (3 nodes, E8s_v5, storage-optimised)        │    │
│  │  • Kafka brokers, Redis cluster, observability stack    │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  SECURITY POOL (3 nodes, dedicated security workloads)  │    │
│  │  • Vault, SPIRE, OPA, Falco, Tetragon                  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  CNI: Cilium v1.15+ (kube-proxy replacement enabled)           │
│  CSI: Azure Disk CSI v2 + Azure File CSI                       │
│  Ingress: NGINX Ingress Controller (HA, 3 replicas)            │
│  Cert: cert-manager + Let's Encrypt / DigiCert                 │
│  DNS: ExternalDNS + CoreDNS (custom zone for .cluster.local)   │
│  GitOps: ArgoCD (HA mode, 3 replicas)                          │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Cilium eBPF Architecture

```
CILIUM FEATURES ENABLED:

1. NETWORKING
   ├── kube-proxy replacement: FULL (eBPF-native service routing)
   ├── IPAM mode: azure (ENI-based, /24 per node)
   ├── Tunnel mode: disabled (native routing for performance)
   ├── BGP control plane: enabled (for LoadBalancer IPs)
   └── BIG-TCP: enabled (10GbE optimisation)

2. SECURITY
   ├── Network Policies: All L3/L4/L7 policies via CiliumNetworkPolicy CRDs
   ├── mTLS: Cilium Mutual Auth (SPIFFE-based, no sidecar needed)
   ├── DNS-based policies: FQDN enforcement for egress
   ├── Tetragon: eBPF-powered runtime security (TracingPolicy CRDs)
   └── Transparent encryption: WireGuard (node-to-node, in-cluster)

3. OBSERVABILITY
   ├── Hubble: L7 flow visibility (Hubble Relay + Hubble UI)
   ├── Hubble metrics: Prometheus endpoint exposed
   ├── Policy verdict logging: all drops logged to SIEM
   └── Network topology: auto-discovered, visualised in Hubble UI

4. PERFORMANCE
   ├── XDP acceleration: enabled (hardware offload where available)
   ├── Host networking: bypass iptables entirely
   ├── Connection tracking: eBPF maps (not conntrack)
   └── Load balancing: Maglev consistent hashing

EXAMPLE CILIUM NETWORK POLICY (L7):
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: payment-svc-policy
    namespace: payments
  spec:
    endpointSelector:
      matchLabels:
        app: payment-svc
    ingress:
      - fromEndpoints:
          - matchLabels:
              app: api-gateway
        toPorts:
          - ports:
              - port: "8080"
                protocol: TCP
            rules:
              http:
                - method: "POST"
                  path: "^/api/v[0-9]+/payments$"
    egress:
      - toEndpoints:
          - matchLabels:
              app: wallet-svc
        toPorts:
          - ports:
              - port: "8080"
                protocol: TCP
      - toFQDNs:
          - matchName: "ghipss.com.gh"
          - matchName: "expresspay.com.gh"
        toPorts:
          - ports:
              - port: "443"
                protocol: TCP
```

### 7.3 CNAPP Integration (Prisma Cloud)

```
CNAPP COVERAGE PILLARS:

1. CSPM (Cloud Security Posture Management)
   ├── Continuous Azure + GCP resource scanning
   ├── CIS Benchmark compliance reporting
   ├── Automated remediation for low-risk findings
   └── Daily posture report to security team

2. CWPP (Cloud Workload Protection Platform)
   ├── Container image scanning (pre-deploy: Twistlock scan in pipeline)
   ├── Runtime container protection (behavioural anomaly detection)
   ├── Host-level protection on AKS nodes
   └── Serverless function scanning (if used)

3. CIEM (Cloud Infrastructure Entitlements Management)
   ├── IAM overprivilege detection
   ├── Unused permission cleanup recommendations
   ├── Cross-cloud identity graph
   └── Just-In-Time access for break-glass scenarios

4. DSPM (Data Security Posture Management)
   ├── Sensitive data discovery (PII, PAN, bank accounts)
   ├── Data flow mapping
   ├── Misconfigurations (public storage buckets, unencrypted DBs)
   └── GDPR data residency validation

5. CODE SECURITY (Shift-Left)
   ├── IaC scanning (Terraform, Helm charts): pre-merge
   ├── SCA (Software Composition Analysis): dependency CVE scan
   ├── SAST: integrated into GitHub Actions
   └── Secrets detection: Detect hardcoded secrets in code
```

---

## 8. Observability & Platform Engineering

### 8.1 Observability Stack

```
THE THREE PILLARS + PROFILING:

METRICS (Prometheus → Grafana)
├── Instrumentation: OpenTelemetry SDK (all services)
├── Collection: Prometheus (with remote write to Grafana Cloud)
├── Dashboards: Grafana (SLO dashboards, RED metrics, K8s dashboards)
├── Alerting: Prometheus AlertManager → PagerDuty → Slack
└── SLO tracking: Sloth (SLO generator) + Grafana SLO plugin

LOGS (Loki → Grafana)
├── Collection: Fluent Bit DaemonSet → Loki
├── Structured logging: JSON format, correlation IDs, trace IDs
├── Retention: 30 days hot, 1 year cold (Azure Blob)
├── SIEM forwarding: Critical events → Microsoft Sentinel
└── Compliance: Immutable log archive for SOC 2 / DORA evidence

TRACES (Jaeger/Tempo → Grafana)
├── Instrumentation: OpenTelemetry auto-instrumentation
├── Sampling: Tail-based sampling (100% errors, 10% success)
├── Storage: Grafana Tempo
├── Correlation: Trace ID injected into logs + metrics
└── SLI: p50/p95/p99 latency per service per endpoint

PROFILING (Pyroscope)
├── Continuous CPU + memory profiling
├── Go, .NET, Java agents supported
└── Flame graphs linked to traces

SYNTHETIC MONITORING
├── Grafana k6 for API synthetic checks
├── Every 30s for critical paths (login, payment, balance)
└── Alerts on availability < 99.9% per 5-min window
```

### 8.2 DORA Metrics Dashboard

```
FOUR KEY DORA METRICS TRACKED:

1. Deployment Frequency
   Source: GitHub Actions / GitLab CI webhook → Grafana
   Target: Daily deployments to production

2. Lead Time for Changes
   Source: Git commit timestamp → production deployment timestamp
   Target: < 1 day (elite performer)

3. Change Failure Rate
   Source: Deployments with rollback / hotfix in 24h
   Target: < 5%

4. MTTR (Mean Time to Restore)
   Source: PagerDuty incident open → resolved
   Target: < 1 hour
```

---

## 9. Data Architecture

### 9.1 Database Per Service Pattern

```
BEFORE (Current - Shared DB Anti-Pattern):
  All services → Single SQL Server → Multiple databases

AFTER (Target - DB per Bounded Context):
  identity-svc  → Azure SQL (identity schema, dedicated server)
  account-svc   → Azure SQL (account schema, dedicated server)
  payment-svc   → Azure SQL (payment schema) + Redis (idempotency)
  wallet-svc    → Azure SQL (ledger schema, immutable audit log)
  notification  → CosmosDB (log store, partitioned by tenant)
  audit-svc     → Azure Data Lake (append-only, immutable)

ISOLATION BENEFITS:
  ✓ Independent scaling per service
  ✓ Blast radius contained to single service on DB failure
  ✓ Independent schema migrations
  ✓ Different DB engines per service (polyglot persistence)
```

### 9.2 Event Architecture (Apache Kafka)

```
KAFKA TOPIC TAXONOMY:

Domain Events (fact records — immutable, retained forever):
  superapp.identity.v1.user-registered
  superapp.identity.v1.user-deactivated
  superapp.identity.v1.password-reset-requested
  superapp.account.v1.bank-account-linked
  superapp.account.v1.investment-account-linked
  superapp.payment.v1.payment-initiated
  superapp.payment.v1.payment-completed
  superapp.payment.v1.payment-failed
  superapp.wallet.v1.funds-credited
  superapp.wallet.v1.funds-debited
  superapp.audit.v1.security-event-detected

Command Topics (temporary — 7-day retention):
  superapp.commands.payment.initiate
  superapp.commands.notification.send
  superapp.commands.kyc.verify

Notification Topics:
  superapp.notifications.push
  superapp.notifications.sms
  superapp.notifications.email

KAFKA CONFIGURATION:
  Replication factor: 3 (fault tolerant)
  Min ISR: 2 (no data loss)
  Retention: 7 days (commands), 90 days (events), forever (audit)
  Compaction: enabled for state topics
  Security: SASL/OAUTHBEARER + TLS + Kafka ACLs
```

---

## 10. Network Architecture

### 10.1 Network Segmentation

```
VNet Architecture (Azure):

10.0.0.0/8  — SuperApp Platform VNet

  10.1.0.0/16 — Production
    10.1.1.0/24  — AKS System Node Pool
    10.1.2.0/24  — AKS App Node Pool
    10.1.3.0/24  — AKS Data Node Pool
    10.1.4.0/24  — AKS Security Node Pool
    10.1.10.0/24 — Azure SQL Private Endpoints
    10.1.11.0/24 — Azure Cache for Redis Private Endpoints
    10.1.12.0/24 — Azure Event Hubs Private Endpoints
    10.1.20.0/24 — Bastion / Jump Host (admin only)
    10.1.100.0/24 — Azure Firewall

  10.2.0.0/16 — Staging
    (same subnet pattern, /24 per tier)

  10.3.0.0/16 — Development
    (same subnet pattern, /24 per tier)

  10.100.0.0/16 — Management / Hub VNet
    10.100.1.0/24 — Azure Firewall (centralised)
    10.100.2.0/24 — ExpressRoute Gateway
    10.100.3.0/24 — VPN Gateway (for on-premises HQ)
    10.100.10.0/24 — DNS Private Resolver

DNS Architecture:
  *.superapp.internal  → Azure Private DNS Zone
  *.svc.cluster.local  → CoreDNS (Kubernetes internal)
  External domains     → Azure DNS + Cloudflare
```

---

## 11. C4 Model Hierarchy

> Detailed C4 models are in `docs/c4-models/` directory.
> See [C1-Context](c4-models/C1-CONTEXT.md), [C2-Container](c4-models/C2-CONTAINER.md),
> [C3-Component](c4-models/C3-COMPONENT.md) for full diagrams.

### 11.1 C1 — System Context

```
                    ┌──────────────────────────────────┐
                    │        EXTERNAL ACTORS            │
                    └──────────────────────────────────┘
                         │              │
              ┌──────────┘              └──────────────┐
              │                                         │
        ┌─────▼────┐                          ┌────────▼───────┐
        │  Customer │                          │  Bank Admin    │
        │  (Mobile/ │                          │  (Portal)      │
        │  Web App) │                          └────────┬───────┘
        └─────┬─────┘                                   │
              │                                         │
              ▼                                         ▼
     ┌────────────────────────────────────────────────────────────┐
     │                                                            │
     │                    SUPERAPP PLATFORM                       │
     │                  [Software System]                         │
     │   Digital financial services: payments, wallets,          │
     │   accounts, identity, notifications                       │
     │                                                            │
     └────────────┬─────────────────────┬──────────────┬─────────┘
                  │                     │              │
          ┌───────▼──────┐    ┌─────────▼──────┐  ┌───▼────────────┐
          │  T24 Core    │    │  GhIPSS/ACH    │  │  Hubtel/       │
          │  Banking     │    │  Payment Rails  │  │  ExpressPay    │
          │  [External]  │    │  [External]     │  │  [External]    │
          └──────────────┘    └────────────────┘  └────────────────┘
```

---

## 12. Architecture Decision Records

### ADR-001: Cilium as CNI

- **Status:** ACCEPTED
- **Decision:** Use Cilium eBPF as the sole CNI plugin, replacing kube-proxy
- **Rationale:** Native L7 network policy, mTLS without sidecars, 40% better network throughput vs. iptables, Hubble observability built-in
- **Consequences:** Requires Linux kernel ≥ 5.10; kernel must be pinned in node image

### ADR-002: YARP as API Gateway

- **Status:** ACCEPTED
- **Decision:** Keep YARP (Yet Another Reverse Proxy) as the API Gateway
- **Rationale:** Native .NET integration, high performance, extensible middleware pipeline
- **Enhancement:** Add Ocelot for advanced rate limiting + circuit breakers; add OpenTelemetry middleware
- **Consequences:** Must deploy as K8s Deployment (not DaemonSet), min 3 replicas for HA

### ADR-003: HashiCorp Vault for Secrets

- **Status:** ACCEPTED
- **Decision:** All secrets managed via HashiCorp Vault + External Secrets Operator
- **Rationale:** Vendor-agnostic, works across Azure + GCP, dynamic secrets, fine-grained audit
- **Consequences:** Vault must be HA (3 replicas), Raft storage backend, auto-unseal via Azure Key Vault

### ADR-004: Saga Pattern for Distributed Transactions

- **Status:** ACCEPTED
- **Decision:** Orchestration-based Sagas via MassTransit (C#) for all cross-service transactions
- **Rationale:** No distributed 2PC, compensating transactions for failures, full audit trail
- **Consequences:** Each saga must implement idempotency; state stored in dedicated saga DB table

### ADR-005: Multi-Cloud Active-Standby (Azure Primary, GCP DR)

- **Status:** ACCEPTED
- **Decision:** Azure as primary active cloud, GCP as warm standby DR
- **Rationale:** Meets DORA Art. 12 multi-provider resilience; avoids single CSP lock-in
- **Consequences:** Latency overhead for cross-cloud data sync; additional cost ~20%

---

## 13. Non-Functional Requirements & SLAs

| NFR | Target | Measurement | Alert Threshold |
|---|---|---|---|
| Availability | 99.99% | Uptime monitoring (k6 synthetic) | < 99.95% |
| API Latency (p50) | < 100ms | OpenTelemetry trace | > 200ms |
| API Latency (p99) | < 500ms | OpenTelemetry trace | > 1000ms |
| Payment Processing | < 2s end-to-end | Business transaction trace | > 5s |
| DB Query Latency (p99) | < 50ms | DB slow query log | > 100ms |
| Throughput | 10,000 RPS sustained | Prometheus rate() | < 5,000 RPS |
| Error Rate | < 0.1% | Prometheus error budget | > 0.5% |
| Container Start Time | < 30s | Kubernetes events | > 60s |
| Deployment Duration | < 10 min | CI/CD pipeline metric | > 20 min |

---

## 14. Operational Runbooks

### Runbook 001: Payment Service Degradation

```
TRIGGER: Payment API error rate > 5% over 5 minutes
SEVERITY: P1

STEPS:
1. Check Grafana dashboard: superapp-payments-slo
2. Check circuit breaker status: 
   kubectl exec -n payments deploy/payment-svc -- curl localhost:8080/health/circuit
3. Check Kafka consumer lag:
   kubectl exec -n kafka kafka-consumer-groups.sh --describe --group payment-consumers
4. If T24 upstream: check ESB connectivity
   kubectl logs -n integrations deploy/esb-adapter -f
5. If DB: check Azure SQL alerts in Azure Monitor
6. Rollback if needed:
   argocd app rollback superapp-payment --revision HEAD~1
```

### Runbook 002: AKS Node Failure

```
TRIGGER: Node NotReady > 5 minutes
SEVERITY: P2

STEPS:
1. kubectl describe node <node-name>
2. Check Azure portal for VM health
3. Drain node: kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
4. If corrupted, cordon + delete: kubectl cordon + kubectl delete node
5. VMSS auto-replace will provision new node within 5 min
6. Verify pods rescheduled: kubectl get pods -A | grep -v Running
```

---

*Document continues in supplementary files:*
- `docs/c4-models/` — Full C4 diagrams
- `terraform/` — IaC scripts
- `kubernetes/` — K8s manifests
- `.github/workflows/` — CI/CD pipelines
