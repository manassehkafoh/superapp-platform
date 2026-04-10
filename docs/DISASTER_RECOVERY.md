# SuperApp Disaster Recovery Plan

**RTO Target**: 15 minutes | **RPO Target**: 5 minutes | **Owner**: SRE Team | **Tested**: Quarterly

## DR Architecture
```
Azure East US 2 (Primary Active)
  ├── AKS Cluster (all 6 services, 3 AZs)
  ├── Azure SQL Hyperscale (payment + wallet failover groups)
  ├── Azure Event Hubs Premium (zone-redundant)
  └── Azure Key Vault HSM

        ↕ Azure ExpressRoute ↔ GCP Partner Interconnect (10Gbps)

GCP Europe West 4 (Warm Standby DR)
  ├── GKE Cluster (scaled to 0, auto-scales on failover)
  ├── Cloud SQL (replica of payment + wallet DBs)
  └── GCP Secret Manager (replica of critical secrets)
```

## Failure Scenarios & Procedures

### Scenario 1: Single AZ Failure
**Detection**: Azure Monitor alert → PagerDuty → 2 min
**Action**: Kubernetes automatically reschedules pods to healthy AZs (HPA + topology spread)
**RTO**: 0 (automatic) | **RPO**: 0 (no data loss)

### Scenario 2: Azure Region Partial Degradation
**Detection**: Grafana SLO burn-rate alert → PagerDuty P2 → 5 min
**Runbook**: See [RB-002](runbooks/RUNBOOKS.md#rb-002)

```bash
# Step 1: Verify degradation
az monitor metrics list --resource /subscriptions/$SUB/resourceGroups/rg-superapp-platform-prod

# Step 2: Initiate Azure → GCP failover
./platform/scripts/deploy.sh --environment prod --phase 2 --dr-failover

# Step 3: Update DNS (Cloudflare) to point to GCP ingress
# Step 4: Verify payment processing from GCP
# Step 5: Notify Bank of Ghana (regulatory requirement)
```

### Scenario 3: Full Azure Region Failure
**RTO**: 15 minutes | **RPO**: 5 minutes (async replication lag)

**Incident Commander Checklist**:
- [ ] Declare P1 incident in PagerDuty
- [ ] Notify CTO + CISO immediately
- [ ] Activate GCP DR cluster: `kubectl config use-context gke-superapp-dr`
- [ ] Scale GKE node pools: `gcloud container clusters resize superapp-dr --num-nodes=6`
- [ ] Promote Cloud SQL (payment): `gcloud sql instances patch payment-replica --activation-policy=ALWAYS`
- [ ] Promote Cloud SQL (wallet): same as above
- [ ] Point Cloudflare DNS to GCP load balancer IP
- [ ] Verify smoke tests: `./platform/scripts/deploy.sh --environment prod --phase 7`
- [ ] Notify customers via status page + SMS
- [ ] File DORA Art.17 incident report within 4 hours

### Scenario 4: Database Corruption / Ransomware
**Action**: Point-in-time restore from Azure SQL PITR (35 days)

```sql
-- Restore payment DB to 30 minutes before incident
RESTORE DATABASE PaymentDB_Restored
FROM DATABASE_SNAPSHOT = 'PaymentDB'
TO '2024-01-15T14:30:00Z';
-- Verify row counts before cutover
```

### Scenario 5: Kafka Topic Data Loss
**Action**: Replay from Event Hubs Avro archive (7 years, Azure Blob)

```bash
# Replay audit-logs topic from 6 hours ago
az eventhubs eventhub consumer-group create \
  --namespace evhns-superapp-prod-eus2 \
  --eventhub-name superapp-audit-logs \
  --name dr-replay-$(date +%Y%m%d)
```

## DR Testing Schedule
| Test | Frequency | Last Tested | Result |
|------|-----------|------------|--------|
| AZ failover (chaos) | Monthly | 2024-03-01 | ✅ Pass |
| Azure → GCP failover | Quarterly | 2024-01-15 | ✅ Pass |
| DB PITR restore | Quarterly | 2024-02-01 | ✅ Pass |
| Secret rotation | Monthly | 2024-03-15 | ✅ Pass |
| Full DR drill | Annually | 2024-01-15 | ✅ RTO 12m |
