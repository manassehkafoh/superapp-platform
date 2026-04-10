# SuperApp Platform — Team Quick-Reference Wikis

> Lean, scannable wikis for every team member. Bookmark this page.  
> For deep dives, see the [Junior Onboarding Guide](../onboarding/JUNIOR-ENGINEER-ONBOARDING.md) and [Well-Architected Framework](../WELL-ARCHITECTED-FRAMEWORK.md).

---

## 🏎️ WIKI-01: Developer Quick-Reference

### Daily Commands Cheatsheet

```bash
# ── KUBERNETES ──────────────────────────────────────────────────────────────
kubectl get pods -n superapp-services          # List all service pods
kubectl get pods -n superapp-services -w       # Watch pod status live
kubectl logs -l app=payment-api -f --tail=200  # Follow payment-api logs
kubectl describe pod <name> -n superapp-services # Diagnose crash/pending
kubectl top pods -n superapp-services          # CPU + memory per pod
k9s                                             # Interactive TUI for K8s

# ── ARGOCD ──────────────────────────────────────────────────────────────────
argocd app list                                # See all app sync states
argocd app sync prod-payment-api               # Manual sync to prod
argocd app rollback prod-payment-api           # Rollback last deployment
argocd app history prod-payment-api            # View deployment history

# ── KAFKA ────────────────────────────────────────────────────────────────────
# Check consumer lag (run inside kafka pod)
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --all-groups | awk '$6 > 100'     # Only show lagging topics

# Tail messages on a topic
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic superapp-payment-source --from-beginning --max-messages 5

# ── GIT ──────────────────────────────────────────────────────────────────────
git checkout -b feature/SUPER-<ticket>-<short-desc>
git commit -m "feat(service): description"     # Conventional commits required
git push origin HEAD                            # Push current branch

# ── DOTNET ──────────────────────────────────────────────────────────────────
dotnet test --filter Category!=Integration      # Unit tests only (fast)
dotnet test --collect:"XPlat Code Coverage"    # With coverage
dotnet ef migrations add <MigrationName>        # Add DB migration
dotnet ef database update                       # Apply migrations locally
dotnet watch run                                # Hot reload dev server
```

### Environment URLs

| Environment | API Base | Grafana | ArgoCD |
|-------------|----------|---------|--------|
| **Local** | http://localhost:8080 | http://localhost:3000 | N/A |
| **Dev** | https://api.dev.superapp.com.gh | https://grafana.dev.superapp.com.gh | https://argocd.dev.superapp.com.gh |
| **Staging** | https://api.staging.superapp.com.gh | https://grafana.staging.superapp.com.gh | https://argocd.staging.superapp.com.gh |
| **Production** | https://api.superapp.com.gh | https://grafana.superapp.com.gh | https://argocd.superapp.com.gh |

### Service Port Reference

| Service | Port | Health Endpoint |
|---------|------|----------------|
| api-gateway | 8080 | /health |
| identity-api | 8081 | /health/ready |
| account-api | 8082 | /health/ready |
| payment-api | 8083 | /health/ready |
| wallet-api | 8084 | /health/ready |
| notification-api | 8085 | /health/ready |

### API Error Codes Reference

| Code | Meaning | Service |
|------|---------|---------|
| `AUTH-001` | Token expired | identity-api |
| `AUTH-002` | Invalid credentials | identity-api |
| `AUTH-003` | MFA required | identity-api |
| `PAY-001` | Invalid amount | payment-api |
| `PAY-002` | Insufficient funds | payment-api |
| `PAY-003` | Payment rail unavailable | payment-api |
| `PAY-004` | Daily limit exceeded | payment-api |
| `PAY-005` | Duplicate payment ID | payment-api |
| `WAL-001` | Wallet locked | wallet-api |
| `WAL-002` | Ledger reconciliation error | wallet-api |
| `ACC-001` | Account suspended | account-api |

---

## 🔒 WIKI-02: Security Team Quick-Reference

### Daily Security Checks

```bash
# ── FALCO ALERTS ─────────────────────────────────────────────────────────────
kubectl logs -l app.kubernetes.io/name=falco -n security --tail=50 | jq .
# Look for: severity "Warning" or "Critical"

# ── OPA POLICY VIOLATIONS ────────────────────────────────────────────────────
kubectl get constrainttemplate           # List policy templates
kubectl describe k8srequirelabels        # View violation details
kubectl get events --field-selector type=Warning -n superapp-services

# ── VAULT AUDIT LOG ──────────────────────────────────────────────────────────
vault audit list
kubectl exec -n vault vault-0 -- vault audit list
# Check for unexpected secret accesses

# ── FORTIRECON / CNAPP ───────────────────────────────────────────────────────
# Access FortiCNAPP console: https://fortirecon.superapp.com.gh
# Daily: review Critical + High findings under "Active Alerts"
# Weekly: review "Compliance Posture" dashboard for new deviations

# ── TRIVY (on-demand scan) ────────────────────────────────────────────────────
trivy image acrsuperapp.azurecr.io/payment-api:latest \
  --severity CRITICAL,HIGH \
  --format table

# ── SECRET SCAN ──────────────────────────────────────────────────────────────
trufflehog git https://github.com/superapp-gh/platform --json | jq .
```

### Security Incident Checklist

```
SUSPECTED CREDENTIAL LEAK
[ ] Notify CISO and Incident Commander immediately
[ ] Do NOT post details in public Slack channels
[ ] Identify the compromised credential (Vault audit log)
[ ] Rotate it: vault lease revoke -force -prefix <path>
[ ] Check Vault audit for all accesses in the past 24h
[ ] Check Azure AD sign-in logs for anomalous access
[ ] File DORA Art.17 report if financial data was accessed

SUSPECTED CONTAINER ESCAPE
[ ] Falco alert: "Terminal shell in container" or "Privilege escalation"
[ ] Isolate the pod: kubectl taint node <node> emergency:NoSchedule
[ ] Capture forensics: kubectl exec -- ps aux; netstat -an
[ ] Contact: security@superapp.com.gh + escalate to P1

DATA CLASSIFICATION REMINDER
  Public     = marketing content, public APIs docs
  Internal   = architecture docs, runbooks, non-PII config
  Confidential = PII, account numbers, transaction history
  Restricted = credentials, encryption keys, audit logs
```

### PCI-DSS Quick Controls Reference

| Req | Control | Owner | Frequency |
|-----|---------|-------|-----------|
| 1.1 | Network segmentation (Cilium policies) | Platform | Reviewed quarterly |
| 2.2 | No default passwords | Security | Automated (OPA) |
| 3.4 | Card data never logged | Dev leads | PR review |
| 6.3 | SAST in CI pipeline | DevOps | Every PR |
| 7.1 | Least-privilege access | IAM | Quarterly review |
| 10.2 | Audit log all access | Platform | Always-on (Vault+Loki) |
| 11.3 | Penetration testing | Security | Annual |

---

## 📊 WIKI-03: SRE / On-Call Quick-Reference

### On-Call Checklist (Start of Shift)

```bash
# 1. Check overall platform health (takes 2 minutes)
kubectl get pods -A | grep -v "Running\|Completed" | grep -v "^NAMESPACE"

# 2. Check Kafka consumer lag across all topics
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --all-groups 2>/dev/null | awk 'NR>1 && $6 > 1000'

# 3. Check payment success rate (last 30 min)
# Open Grafana → Payment API SLO Dashboard
# Green = fine. Yellow/Red = investigate.

# 4. Check Cilium agent health (network layer)
cilium status --wait
# Expected: "Cilium: OK" for all nodes

# 5. Check cert expiry (alert if < 30 days)
kubectl get certificates -A | grep -v "True"
```

### Escalation Matrix

| Situation | Escalate To | SLA |
|-----------|------------|-----|
| Payment API down | Payments Squad Lead + CTO | 5 min |
| Auth service down | Identity Squad Lead | 5 min |
| Database failover needed | DBA on-call | 10 min |
| Security breach suspected | CISO + CTO | Immediate |
| Data loss risk | CTO + Legal | Immediate |
| Network outage | Platform Team Lead | 10 min |

### SLO Targets (production)

| Service | Availability | p99 Latency | Error Rate |
|---------|-------------|------------|-----------|
| payment-api | 99.9% | < 2s | < 0.1% |
| identity-api | 99.95% | < 500ms | < 0.05% |
| wallet-api | 99.9% | < 1s | < 0.1% |
| account-api | 99.9% | < 1s | < 0.1% |
| notification-api | 99.5% | < 5s | < 0.5% |

### Rollback Procedures

```bash
# Quick rollback — ArgoCD
argocd app rollback prod-<service> [revision-number]

# Rollback via Argo Rollouts (for canary deployments)
kubectl argo rollouts undo rollout/<service> -n superapp-services

# Emergency — scale down and deploy previous image manually
kubectl set image deployment/<service> \
  <service>=acrsuperapp.azurecr.io/<service>:<previous-sha> \
  -n superapp-services

# Verify rollback succeeded
kubectl rollout status deployment/<service> -n superapp-services
argocd app get prod-<service>   # Should show Synced + Healthy
```

---

## 🏗️ WIKI-04: Platform / DevOps Quick-Reference

### Terraform Workflows

```bash
# ── STANDARD WORKFLOW ────────────────────────────────────────────────────────
cd terraform

# Authenticate (uses OIDC — no stored credentials)
az login --federated-token $AZURE_FEDERATED_TOKEN \
  --tenant $TENANT_ID --service-principal --username $CLIENT_ID

# Initialise backend for an environment
terraform init \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="resource_group_name=rg-superapp-tfstate" \
  -backend-config="storage_account_name=stsuperappterraform" \
  -backend-config="container_name=tfstate"

# Plan (always review before apply)
terraform plan -var-file="environments/prod/terraform.tfvars" -out=tfplan

# Show human-readable plan
terraform show tfplan | head -100

# Apply
terraform apply tfplan

# ── IMPORT EXISTING RESOURCE ─────────────────────────────────────────────────
terraform import azurerm_resource_group.platform \
  /subscriptions/<sub-id>/resourceGroups/rg-superapp-prod

# ── TARGETED APPLY (use sparingly — last resort) ──────────────────────────────
terraform apply -target=module.messaging.azurerm_eventhub.topics \
  -var-file="environments/prod/terraform.tfvars"

# ── DESTROY (only dev environments!) ─────────────────────────────────────────
terraform destroy -var-file="environments/dev/terraform.tfvars"
# NEVER run terraform destroy against staging or prod
```

### Helm Workflows

```bash
# Add the superapp chart repo
helm repo add superapp https://charts.superapp.com.gh
helm repo update

# Render templates locally (without applying)
helm template payment-api kubernetes/apps/payment-api \
  -f kubernetes/apps/payment-api/values.yaml \
  -f kubernetes/apps/payment-api/environments/prod/values.yaml | less

# Diff against what's running (requires helm-diff plugin)
helm diff upgrade payment-api kubernetes/apps/payment-api \
  -f kubernetes/apps/payment-api/values.yaml \
  -n superapp-services

# Manual upgrade (normally handled by ArgoCD)
helm upgrade payment-api kubernetes/apps/payment-api \
  -f kubernetes/apps/payment-api/values.yaml \
  --namespace superapp-services --atomic --timeout 10m
```

### Node Pool Management

```bash
# Check node pool utilisation
kubectl describe nodes | grep -A5 "Allocated resources"

# Cordon a node (stop scheduling new pods)
kubectl cordon <node-name>

# Drain a node for maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Uncordon after maintenance
kubectl uncordon <node-name>

# Force scale a node pool (via Azure CLI)
az aks nodepool scale \
  --resource-group rg-superapp-platform-prod \
  --cluster-name aks-superapp-prod \
  --name apppool \
  --node-count 8
```

---

## 🗄️ WIKI-05: DBA Quick-Reference

### Database Connection Info

```bash
# Never connect to production DB directly!
# Use the bastion host + Just-In-Time access

# Request JIT access (Azure Portal → Security Center → JIT access)
az security jit-policy initiate \
  --resource-group rg-superapp-platform-prod \
  --vm bastion-superapp-prod \
  --ports "[{\"number\":22,\"endTimeUtc\":\"$(date -d '+2 hours' --utc +%Y-%m-%dT%H:%M:%SZ)\"}]"

# Then SSH through bastion
ssh -i ~/.ssh/superapp-bastion azureuser@<bastion-ip>

# Use sqlcmd or Azure Data Studio through the bastion tunnel
sqlcmd -S sql-payment-prod.database.windows.net \
       -d PaymentDB \
       -G                    # Azure AD auth — no password needed
```

### Common DB Maintenance Tasks

```sql
-- Check active connections per database
SELECT DB_NAME(database_id) AS DatabaseName,
       COUNT(*) AS ActiveConnections
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY database_id
ORDER BY ActiveConnections DESC;

-- Check long-running queries (> 10 seconds)
SELECT TOP 20
    r.session_id,
    r.status,
    r.command,
    SUBSTRING(st.text, (r.statement_start_offset/2)+1, 256) AS QueryText,
    r.total_elapsed_time / 1000 AS ElapsedSeconds,
    r.cpu_time / 1000 AS CpuSeconds
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.total_elapsed_time > 10000
ORDER BY r.total_elapsed_time DESC;

-- Check Hyperscale replica lag
SELECT *
FROM sys.dm_database_replica_states
WHERE is_primary_replica = 0;

-- Trigger manual geo-failover (ONLY with IC authorisation)
-- ALTER DATABASE PaymentDB FAILOVER;
```

### Migration Deployment Process

```bash
# 1. Generate migration in dev
dotnet ef migrations add AddPaymentLimitTable \
  --project src/payment-api \
  --startup-project src/payment-api

# 2. Review the generated SQL
dotnet ef migrations script \
  --project src/payment-api \
  --output migration.sql
code migration.sql  # Review carefully!

# 3. Apply to dev (CI does this automatically)
dotnet ef database update --project src/payment-api

# 4. Staging: CI applies on merge to main
# 5. Production: DBA reviews script, applies in maintenance window
#    (Migrations are applied by CI but DBA must review for large tables)
```

---

## 📱 WIKI-06: Product / QA Quick-Reference

### Testing Environments

| Environment | Purpose | Data | Reset Frequency |
|-------------|---------|------|----------------|
| **Dev** | Developer testing, CI smoke tests | Synthetic | On every deploy |
| **Staging** | Pre-release validation, QA testing | Anonymised prod copy | Weekly |
| **Production** | Real customers | Real | Never reset |

### Test User Accounts (Dev + Staging Only)

```
Standard User:    test.user@superapp.com.gh / TestPass123!
Premium User:     test.premium@superapp.com.gh / TestPass123!
Admin User:       test.admin@superapp.com.gh / TestPass123!
Suspended User:   test.suspended@superapp.com.gh / TestPass123!

MFA Test Code (staging): Use Google Authenticator app with seed: JBSWY3DPEHPK3PXP
```

### Postman Collection
Import: `https://api.dev.superapp.com.gh/postman-collection.json`

Key collection folders:
- `Authentication` — login, refresh token, MFA
- `Payments` — initiate, status, history
- `Wallets` — balance, transactions, topup
- `Accounts` — open, enquiry, statement

### Bug Report Template
```markdown
**Service**: payment-api
**Environment**: staging
**Severity**: P2 (payment processing blocked)
**Steps to Reproduce**:
  1. POST /api/v1/payments/initiate with amount=0
  2. Expected: 422 Unprocessable Entity with code PAY-001
  3. Actual: 500 Internal Server Error

**Correlation ID**: [from X-Correlation-ID response header]
**Timestamp**: 2024-02-15 14:23:11 UTC

**Logs**: [Paste Loki query result or link to Grafana]
```

---

## 🔄 WIKI-07: Change Management Quick-Reference

### Change Categories

| Category | Examples | Approval Required | Deployment Window |
|----------|---------|-------------------|------------------|
| **Standard** | Dependency upgrades, config changes | Squad lead | Any time (dev/staging), weekdays 06-14 UTC (prod) |
| **Normal** | Feature releases, schema migrations | CAB (2 approvers) | Planned maintenance window |
| **Emergency** | P1 hotfix | CTO verbal + post-hoc CAB | Any time |

### Production Deployment Checklist

```markdown
Pre-Deployment:
[ ] Change ticket created and approved in ITSM
[ ] Code review: 2 approvals including squad lead
[ ] All tests passing in staging (smoke + integration + perf)
[ ] Rollback plan documented in change ticket
[ ] DBA reviewed if DB migrations included
[ ] On-call SRE notified

Deployment:
[ ] Deploy within approved change window
[ ] Monitor error rates during canary (20% → 50% → 100%)
[ ] Verify smoke tests pass at each canary step
[ ] SRE watching Grafana during deployment

Post-Deployment:
[ ] Verify no error rate increase in 30 minutes post-deploy
[ ] Close change ticket
[ ] Update release notes in Confluence
[ ] Notify #superapp-deployments channel
```

### Emergency Hotfix Process

```
1. Declare P1 incident in PagerDuty
2. Get CTO verbal approval to bypass CAB
3. Create hotfix branch from production tag:
   git checkout -b hotfix/SUPER-<ticket> v<last-prod-tag>
4. Make MINIMAL change — the smallest fix possible
5. PR review: 1 senior approval acceptable for P1
6. CI runs full pipeline (cannot be skipped)
7. Deploy via ArgoCD with SRE watching live
8. Post-hoc CAB review within 24 hours
9. Retrospective within 48 hours
```
