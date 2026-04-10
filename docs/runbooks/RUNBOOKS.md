# SuperApp Platform — Operational Runbooks

---

## RB-001: Production Incident Response (P1/P2)

**Owner**: SRE Team  
**Review Date**: Quarterly  
**Last Updated**: 2024-Q1

### Severity Classification

| Severity | Definition | Response Time | Examples |
|----------|-----------|---------------|---------|
| P1 | Payment processing down, auth unavailable | 15 min | API gateway down, payment-api crash loop |
| P2 | Degraded performance, partial feature loss | 30 min | p99 latency > 5s, one AZ unhealthy |
| P3 | Non-critical feature impacted | 2 hours | Notification delays, reporting lag |
| P4 | Minor bug, no user impact | Next sprint | UI glitch, log noise |

### P1 Response Checklist

**T+0 — Alert fires (PagerDuty)**
```
1. Acknowledge PagerDuty alert within 5 minutes
2. Join #superapp-incident Slack channel
3. Assign Incident Commander (IC) and Communications Lead (CL)
4. Post: "INCIDENT STARTED — [brief description] — IC: @name — Bridge: [zoom link]"
```

**T+5 — Triage**
```bash
# Check overall cluster health
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed

# Check recent events
kubectl get events -A --sort-by=.lastTimestamp | tail -50

# Check Cilium connectivity
cilium connectivity test --test-namespace superapp-services

# Check payment API health
kubectl rollout status deployment/payment-api -n superapp-services
kubectl logs -l app=payment-api -n superapp-services --tail=100 | grep -i "error\|fatal"

# Check Kafka consumer lag
kubectl exec -n kafka kafka-0 -- bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --all-groups | grep -v 0$
```

**T+10 — Mitigation Options**
```bash
# Option 1: Rollback last deployment
argocd app rollback prod-payment-api
kubectl argo rollouts undo rollout/payment-api -n superapp-services

# Option 2: Scale up if resource starvation
kubectl scale deployment payment-api --replicas=10 -n superapp-services

# Option 3: Disable non-critical features via feature flags
kubectl patch configmap payment-api-config -n superapp-services \
  --type merge -p '{"data":{"FEATURE_SCHEDULED_PAYMENTS":"false"}}'

# Option 4: Enable circuit breaker to external rail (prevent cascade)
kubectl patch configmap api-gateway-config -n superapp-gateway \
  --type merge -p '{"data":{"CIRCUIT_BREAKER_GHIPSS":"open"}}'
```

**T+30 — Communications Template**
```
STATUS PAGE UPDATE (public):
We are experiencing [brief description]. Our team is actively investigating.
Affected: [list services]
Status: Investigating | Identified | Monitoring | Resolved
Next update in 30 minutes.
```

**T+60 — Escalation**
```
If not resolved: Page CTO + Head of Engineering
If data breach suspected: Page CISO immediately, do NOT post to public Slack
If payment data affected: Engage legal + compliance within 2 hours (DORA Art.17 — 4h reporting window)
```

**Post-Incident (within 48h)**
```
1. Write Post-Incident Review (PIR) in Confluence
2. 5-Whys root cause analysis
3. Action items with owners and due dates
4. Update this runbook if gaps found
5. File DORA incident report if ICT-disrupting event per Art.17
```

---

## RB-002: Azure → GCP DR Failover

**Owner**: Platform Team  
**RTO Target**: 15 minutes  
**RPO Target**: 1 hour  
**Last Tested**: [DATE] — Results: [LINK]

### Pre-Conditions
- [ ] P1 incident declared, Azure region confirmed unavailable
- [ ] IC authorisation received from CTO
- [ ] Change ticket created: [ITSM URL]

### Step 1 — Verify GCP Cluster is Ready (T+0)
```bash
# Switch kubectl context to GCP DR cluster
gcloud container clusters get-credentials superapp-dr \
  --region europe-west4 --project superapp-prod-dr
kubectl config use-context gke_superapp-prod-dr_europe-west4_superapp-dr

# Verify nodes are healthy
kubectl get nodes -o wide

# Verify ArgoCD is running on DR cluster
kubectl get pods -n argocd
```

### Step 2 — Verify Data Replication is Current (T+2)
```bash
# Check Azure SQL → GCP Cloud SQL replication lag
gcloud sql instances list --project superapp-prod-dr
gcloud sql operations list --instance payment-db-dr

# Check Kafka MirrorMaker replication lag
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group mirrormaker2

# ACCEPTABLE: lag < 5000 messages per partition
# UNACCEPTABLE (data loss risk): lag > 50000 — notify CTO before proceeding
```

### Step 3 — Promote GCP Databases to Primary (T+5)
```bash
# Azure SQL failover (if Azure is reachable)
az sql failover-group set-primary \
  --name fg-payment-db --resource-group rg-superapp-data-prod \
  --server sql-payment-prod

# If Azure unreachable — force promote GCP Cloud SQL
gcloud sql instances patch payment-db-dr \
  --project superapp-prod-dr \
  --activation-policy=ALWAYS

# Update connection strings in Vault (GCP cluster)
vault kv put secret/payment-api/database \
  connection_string="Server=payment-db-dr.europe-west4.internal;..."
```

### Step 4 — Sync ArgoCD Apps on GCP (T+8)
```bash
# Point ArgoCD to current image tags from ACR
argocd login $ARGOCD_SERVER --auth-token $ARGOCD_DR_TOKEN

for service in identity-api account-api payment-api wallet-api notification-api api-gateway; do
  argocd app set dr-$service --helm-set image.tag=$(cat /tmp/current-image-tags/$service)
  argocd app sync dr-$service --force --timeout 300
done
```

### Step 5 — Cut DNS to GCP (T+12)
```bash
# Update Azure Front Door origin group weights
az network front-door backend-pool backend update \
  --resource-group rg-superapp-prod \
  --front-door-name fd-superapp-prod \
  --pool-name BackendPool \
  --backend-address gcp-dr.superapp.com.gh \
  --weight 1000

# Verify via DNS propagation check
for i in 1 2 3 4 5; do
  dig +short api.superapp.com.gh
  sleep 10
done
```

### Step 6 — Smoke Test DR Traffic (T+14)
```bash
./scripts/smoke-test.sh dr

# Manual verification checklist:
# [ ] Login works (identity-api)
# [ ] Balance displayed (account-api)
# [ ] Payment initiation returns 202 (payment-api)
# [ ] Wallet balance updated (wallet-api)
# [ ] SMS notification received (notification-api)
```

### Failback Procedure (after Azure recovery)
```
1. Verify Azure services fully restored
2. Sync all data from GCP → Azure (Kafka MirrorMaker reverse direction)
3. Verify replication lag < 5000 messages
4. Gradual traffic shift (10% → 50% → 100% Azure) over 30 minutes
5. Monitor error rates during each shift
6. Update DORA incident record with timeline
```

---

## RB-003: Secret Rotation (Scheduled + Emergency)

**Owner**: Security Team  
**Schedule**: DB credentials — 90 days, JWT keys — 30 days  
**Emergency**: Rotate immediately if credential leak suspected

### Scheduled DB Credential Rotation
```bash
# HashiCorp Vault dynamic credentials (auto-rotated every 15 minutes)
# Manual rotation only needed for break-glass accounts

# Check current lease TTL for payment-api DB credentials
vault lease lookup database/creds/payment-api-role

# Force revoke and regenerate
vault lease revoke -force -prefix database/creds/payment-api-role

# ESO will pick up new credentials within 5 minutes (refresh interval)
# Verify pods restarted with new credentials (rolling restart triggered by ESO)
kubectl rollout restart deployment/payment-api -n superapp-services
```

### JWT Key Rotation (Zero-Downtime)
```bash
# 1. Generate new RSA-4096 key pair in Azure Key Vault
az keyvault key create \
  --vault-name kv-superapp-prod \
  --name jwt-signing-key-v2 \
  --kty RSA \
  --size 4096 \
  --ops sign verify

# 2. Update Vault with new key — identity-api reads both old + new during rotation window
vault kv put secret/identity-api/jwt \
  private_key_v1="$(az keyvault key download ...)" \
  private_key_v2="$(az keyvault key download ...)" \
  active_version="v2" \
  rotation_window_end="$(date -d '+24 hours' --utc +%Y-%m-%dT%H:%M:%SZ)"

# 3. Deploy identity-api with dual-key validation support (PR required)
# 4. After 24h rotation window, remove v1 key from Vault

# Verify no v1-signed tokens in circulation (check Redis token cache)
redis-cli -n 1 KEYS "token:v1:*" | wc -l  # Should approach 0 after 1h
```

### Emergency Credential Revocation (Suspected Breach)
```bash
# STOP — Notify CISO and Incident Commander FIRST

# 1. Revoke ALL dynamic DB credentials immediately
vault lease revoke -force -prefix database/creds/

# 2. Rotate all static secrets
vault kv metadata delete secret/payment-api/ghipss
vault kv put secret/payment-api/ghipss api_key="[NEW_KEY_FROM_GHIPSS_SUPPORT]"

# 3. Force pod restart across all services (picks up rotated secrets)
for ns in superapp-services superapp-gateway; do
  kubectl rollout restart deployment -n $ns
done

# 4. Revoke all outstanding JWT tokens (Redis flush for token blocklist)
redis-cli -n 1 FLUSHDB  # All users re-authenticate on next request

# 5. Audit Vault access logs for the suspected leak window
vault audit list
vault audit enable file file_path=/var/log/vault/audit.log

# 6. Create DORA incident report (required if ICT security event)
```

---

## RB-004: Kafka Consumer Lag Remediation

**Owner**: Platform Team  
**Trigger**: Consumer lag > 100,000 messages on `superapp-payment-source`

### Diagnosis
```bash
# Check consumer group lag
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group payment-api | sort -k5 -rn

# Check payment-api pod resource usage
kubectl top pods -n superapp-services -l app=payment-api

# Check Kafka broker health
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic superapp-payment-source
```

### Remediation Options
```bash
# Option 1: Scale payment-api consumers
kubectl scale deployment payment-api --replicas=12 -n superapp-services

# Option 2: Increase partition count (requires rebalance)
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --alter --topic superapp-payment-source --partitions 48

# Option 3: Pause non-critical topics to reduce broker load
kubectl annotate pod -l app=notification-api \
  kafka.consumer.pause="true" -n superapp-services

# Option 4: Reset consumer offset (ONLY if messages are reprocessable — confirm with IC)
kubectl exec -n kafka kafka-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group payment-api --reset-offsets --to-latest \
  --topic superapp-payment-source --execute
```

### Post-Remediation
```
1. Monitor lag for 30 minutes
2. Update HPA min replicas if this was a scaling miss
3. File P3 ticket to review Kafka partition sizing
```
