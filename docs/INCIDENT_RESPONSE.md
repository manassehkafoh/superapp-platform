# SuperApp Incident Response Plan

**Standard**: DORA Art.17 | **Owner**: SRE Team | **Reviewed**: Quarterly

## Severity Classification

| Severity | Criteria | Response Time | Examples |
|----------|---------|--------------|---------|
| **P1 — Critical** | Payment processing stopped, data breach, full outage | IC in 5 min, update every 30 min | payment-api down, DB unreachable, security breach |
| **P2 — High** | Major feature broken, >10% error rate, SLO breach | IC in 15 min, update every hour | Auth failures >5%, wallet calculation errors |
| **P3 — Medium** | Single feature degraded, <5% error rate | Response within 2h | Notification delays, slow queries |
| **P4 — Low** | Minor issue, no customer impact | Next business day | UI glitches, non-critical alerts |

## Response Procedure

### T+0 — Alert fires
```
PagerDuty → On-call SRE paged
└── P1/P2: also pages squad lead + CTO (escalation chain)
└── P3/P4: on-call only
```

### T+5 — Incident Commander declares incident
```bash
# 1. Post in #superapp-incident Slack:
"🚨 P1 INCIDENT DECLARED — [brief description]
IC: @your-name | Bridge: [Zoom link]
Current status: INVESTIGATING"

# 2. Open PagerDuty incident — set severity
# 3. Start incident timeline in Confluence
# 4. Check Grafana dashboards:
#    - SuperApp Services SLO
#    - Payment API error rate
#    - Kafka consumer lag
```

### T+10 — Initial diagnosis
```bash
# Check pod status
kubectl get pods -n superapp-services | grep -v Running

# Check recent deployments (did we deploy recently?)
argocd app history prod-payment-api --limit 5

# Check error logs
kubectl logs -l app=payment-api -n superapp-services --tail=100 | grep -i error

# Check correlation of errors
{app="payment-api"} |= "ERROR" | json | line_format "{{.CorrelationId}} {{.Message}}"
```

### T+30 — Escalation decision
- Resolved? → Move to post-incident review
- Not resolved? → Consider rollback
- Data involved? → Notify CISO immediately
- DORA threshold exceeded? → File regulatory notification

### Rollback Procedure
```bash
# Option 1: ArgoCD rollback (preferred)
argocd app rollback prod-payment-api

# Option 2: Argo Rollouts abort + undo
kubectl argo rollouts abort payment-api -n superapp-services
kubectl argo rollouts undo payment-api -n superapp-services

# Option 3: Manual kubectl (emergency)
kubectl set image deployment/payment-api \
  payment-api=acrsuperapp.azurecr.io/payment-api:<previous-sha> \
  -n superapp-services
```

## DORA Art.17 — Regulatory Reporting

### Reporting Thresholds (Bank of Ghana + EU DORA)
| Threshold | Trigger | Report Within |
|-----------|---------|--------------|
| Major ICT incident | Payment processing disruption > 15 min | 4 hours (initial) |
| Data breach | Any PII/financial data exposed | 72 hours (GDPR) |
| System recovery | After P1 resolved | 24 hours (final report) |

### Incident Report Template
```markdown
## DORA Art.17 Incident Report

**Incident ID**: INC-YYYY-NNN
**Date/Time**: [start] → [end] UTC
**Duration**: X hours Y minutes
**Severity**: P1/P2
**Services Affected**: payment-api, wallet-api

### Customer Impact
- Transactions failed: ~NNN
- Users affected: ~NNN
- Financial exposure: GHS XXX,XXX

### Root Cause
[Technical description]

### Timeline
- HH:MM UTC — [event]
- HH:MM UTC — [event]

### Remediation
- Immediate: [what was done]
- Preventive: [what will be done]

### Control Effectiveness
- Detected by: [alert/monitor]
- MTTR: X minutes (target: 15 min)
```

## Post-Incident Review
- Blameless post-mortem within 48h of P1/P2 resolution
- Template: [Confluence PIR Template](https://confluence.superapp.com.gh/pir)
- Actions tracked in Jira with owner + due date
- DORA metrics updated: MTTR, change failure rate
