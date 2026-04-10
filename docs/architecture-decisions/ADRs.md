# Architecture Decision Records — SuperApp Platform

---

## ADR-001: Cilium as Primary CNI and Service Mesh

**Status**: Accepted  
**Date**: 2024-01-15  
**Deciders**: Platform Team, Security Team

### Context

The SuperApp platform requires:
- Network policy enforcement at L3/L4/L7
- Mutual TLS between services without sidecar overhead
- Compliance with PCI-DSS network segmentation requirements (Req.1)
- High-throughput payment workloads with minimal latency overhead

Traditional options evaluated: Calico, Istio/Envoy sidecar, Linkerd, Azure CNI.

### Decision

Adopt **Cilium** as the CNI with `kube-proxy` replacement mode, eBPF-based dataplane, and Hubble for observability.

Key capabilities activated:
- `--enable-mTLS-with-spiffe` — SPIFFE-based mTLS without sidecars
- `--enable-wireguard` — transparent node-to-node encryption
- `--kube-proxy-replacement=strict` — eBPF L4LB replaces kube-proxy
- `--enable-hubble` — L7 visibility for audit trails

### Consequences

**Positive:**
- Zero-overhead mTLS (eBPF vs. userspace proxy = ~50% lower latency at p99)
- CiliumNetworkPolicy supports L7 HTTP rules (method + path filtering)
- Hubble provides SOC 2 CC7.2 network audit trail without application changes
- XDP acceleration for payment rail gateway pods

**Negative:**
- Linux kernel ≥ 5.15 required — constrains node pool OS (Ubuntu 22.04 LTS)
- Cilium Tetragon adds ~15% memory overhead per node for eBPF maps
- Learning curve for operators unfamiliar with eBPF debugging

**Mitigations:**  
Cilium Hubble UI + CLI replaces `kubectl exec` debugging. Team training planned Q1.

---

## ADR-002: YARP + Ocelot Hybrid API Gateway

**Status**: Accepted  
**Date**: 2024-01-18  
**Deciders**: Architecture Review Board

### Context

The existing YARP (Yet Another Reverse Proxy) gateway handles JWT validation, rate limiting, CORS, and correlation ID injection. The system needs:
- Per-route circuit breakers
- Advanced rate limiting (per-user, per-tenant, per-IP)
- Distributed caching of route config
- OpenTelemetry propagation
- Plugin extensibility without full rewrite risk

### Decision

**Retain YARP** as the routing engine (battle-tested, .NET-native, minimal allocations).  
**Layer Ocelot middleware** for: rate limiting (Redis-backed), circuit breakers (Polly), and route-level auth policies.  
**Add OpenTelemetry SDK** for W3C trace context propagation.

YARP handles: L7 load balancing, health checks, connection pooling, HTTP/2+gRPC proxying.  
Ocelot handles: auth, rate limiting, circuit breaking, cache headers.

### Consequences

**Positive:**
- No rewrite risk — incremental enhancement
- Sub-millisecond overhead (YARP benchmarks at ~1.5μs per request)
- Redis-backed rate limiting supports multi-replica gateway pods
- Polly circuit breakers prevent cascade failures to payment rail

**Negative:**
- Two gateway libraries increase dependency surface
- Ocelot configuration (JSON) is verbose — mitigated by Terraform-generated config

---

## ADR-003: HashiCorp Vault for Secrets Management

**Status**: Accepted  
**Date**: 2024-01-20  
**Deciders**: Security Team, Platform Team

### Context

Requirements: dynamic DB credentials, automatic rotation, audit trail for all secret reads, support for Azure Key Vault HSM, Kubernetes auth method, and multi-cloud (Azure + GCP) compatibility.

### Decision

Deploy **HashiCorp Vault** (OSS, HA Raft mode, 3 replicas) with:
- Azure Key Vault auto-unseal (no manual unseal after pod restart)
- Kubernetes auth method — pods authenticate via service account JWT
- Database secrets engine — dynamic SQL credentials (15-min TTL)
- PKI secrets engine — internal CA for service certificates
- Agent injector disabled — use **External Secrets Operator** for K8s-native integration

**External Secrets Operator** syncs Vault/Azure KV secrets to K8s Secrets (AES-256 encrypted at rest via Azure Disk CMK).

### Consequences

**Positive:**
- Zero long-lived DB passwords in K8s Secrets
- Every secret access is audited in Vault audit log (SOC 2 CC6.3)
- Azure Key Vault Premium HSM as root of trust for Vault unseal keys
- Platform-agnostic — same Vault API works on GCP DR cluster

**Negative:**
- Vault HA adds operational complexity vs. Azure Key Vault alone
- ESO sync interval (5m) means brief lag for rotated secrets — acceptable given 15-min DB credential TTL

---

## ADR-004: Saga Pattern via MassTransit for Distributed Transactions

**Status**: Accepted  
**Date**: 2024-01-25  
**Deciders**: Engineering Leads

### Context

Payment processing requires coordination across:
- `payment-api` (orchestrator)
- `wallet-api` (debit source wallet)
- `account-api` (update account balance)
- `notification-api` (send confirmation)
- External payment rails (GhIPSS, ExpressPay)

Database-per-service pattern prevents cross-service transactions. Need distributed consistency with compensating transactions for failures.

### Decision

Implement the **Choreography-Orchestration hybrid Saga** using **MassTransit StateMachine**:

1. `payment-api` publishes `PaymentInitiatedEvent` → Kafka
2. MassTransit StateMachine tracks saga state in `payment-api` DB
3. Compensating transaction on any failure rolls back debited wallet
4. Saga timeout: 30 seconds; failure publishes `PaymentFailedEvent`

Outbox pattern ensures event publication is atomic with DB write.

### Consequences

**Positive:**
- Guaranteed eventual consistency across services
- Compensating transactions prevent partial failures (wallet debited, payment failed)
- MassTransit provides automatic retry with exponential backoff
- Saga state is queryable for customer support and audit

**Negative:**
- Saga introduces complexity vs. simple REST calls — requires developer training
- Debugging failed sagas requires Hubble + Tempo correlation

---

## ADR-005: Multi-Cloud (Azure Primary + GCP DR)

**Status**: Accepted  
**Date**: 2024-02-01  
**Deciders**: CTO, Architecture Review Board

### Context

DORA Article 12 requires financial institutions to have multi-provider ICT resilience. Single-cloud architectures risk correlated cloud provider failures.

Business requirements: RTO ≤ 4 hours, RPO ≤ 1 hour for payment processing.

### Decision

**Active-Passive multi-cloud** topology:
- **Azure East US 2**: Primary active region, all production traffic
- **GCP Europe West 4**: Warm standby DR, ~15-minute RTO activation
- **Azure West Europe**: Hot standby within Azure for Az-level DR

Data replication:
- Azure SQL Hyperscale active geo-replication → GCP Cloud SQL (Kafka CDC stream)
- Redis Enterprise active-passive replication
- Kafka MirrorMaker 2 streams all topics to Confluent Cloud (GCP)

Interconnect: Azure ExpressRoute ↔ GCP Partner Interconnect (10Gbps dedicated, <5ms latency GH-EU).

### Consequences

**Positive:**
- DORA Art.12 compliance — documented multi-provider exit strategy
- GCP provides geographic diversity from Azure
- GCP GKE + Cilium mirrors Azure AKS — same Helm charts deploy to both

**Negative:**
- 2× compute cost for standby GCP cluster (mitigated by preemptible node pools)
- Data egress costs for CDC replication (~$200/month estimated at current volume)
- DR runbooks required for each failover scenario

---

## ADR-006: Database-Per-Service with Azure SQL Hyperscale

**Status**: Accepted  
**Date**: 2024-02-05  
**Deciders**: Architecture Review Board, DBA Team

### Context

Current architecture uses a **shared MSSQL instance** with 5 databases. This creates:
- Single point of failure (G-01 critical gap)
- Resource contention between payment (high I/O) and notification (bursty writes)
- Blast radius = total platform outage on DB failure
- Prevents independent scaling per service

### Decision

**Separate Azure SQL Hyperscale instance per service**:
- `sql-identity`, `sql-account`, `sql-payment`, `sql-wallet`, `sql-notification`
- Payment + Wallet databases: **failover groups** with 1-hour grace period (RPO alignment)
- Hyperscale tier: instant backup snapshots, read scale-out replicas, 100GB+ scaling without downtime
- **No direct cross-service DB queries** — data sharing via Kafka events or API calls

### Consequences

**Positive:**
- Isolated blast radius — payment DB failure does not affect identity/account services
- Independent scaling — payment DB can scale vCores during month-end processing
- Hyperscale 35-day PITR covers all PCI-DSS Req.9.5 requirements
- Dynamic credentials via HashiCorp Vault DB engine (each service gets unique SQL login)

**Negative:**
- 5× SQL server cost vs. shared instance (offset by right-sized SKUs)
- Cross-service reporting requires data warehouse (Synapse) rather than direct SQL JOIN
- DBA team must manage 5 failover groups — runbooks required
