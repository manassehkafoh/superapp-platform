# SuperApp Data Classification Policy

**Effective Date**: 2024-Q1 | **Owner**: CISO | **Review**: Annually

## Classification Levels

| Level | Label | Description | Examples | Controls |
|-------|-------|-------------|---------|---------|
| **L1 — Public** | `PUBLIC` | Freely shareable | Marketing, API docs, README | None required |
| **L2 — Internal** | `INTERNAL` | Internal use only | Architecture docs, runbooks | Access control, NDA |
| **L3 — Confidential** | `CONFIDENTIAL` | Business sensitive | PII, account numbers, transaction history | Encryption at rest + transit, RBAC, audit log |
| **L4 — Restricted** | `RESTRICTED` | Highest sensitivity | Credentials, encryption keys, audit logs | HSM, Vault, strict RBAC, 7-year retention, immutable storage |

## Data Inventory

### L3 — Confidential (PII / Financial)
| Data Element | Service | Storage | Encryption | Retention | Legal Basis |
|-------------|---------|---------|-----------|---------|------------|
| Full name | identity-api | IdentityDB | TDE + CMK | Account + 7yr | Contract |
| Email address | identity-api | IdentityDB | TDE + CMK | Account + 7yr | Contract |
| Phone number | identity-api | IdentityDB | TDE + CMK | Account + 7yr | Contract |
| National ID / Passport | identity-api | IdentityDB | TDE + CMK | KYC + 7yr | Legal obligation |
| Account number | account-api | AccountDB | TDE + CMK | Account + 7yr | Contract |
| Wallet balance | wallet-api | WalletDB | TDE + CMK | Account + 7yr | Contract |
| Transaction amount | payment-api | PaymentDB | TDE + CMK | 7yr | Legal obligation |
| IP address | All services | Loki logs | At-rest | 90 days | Legitimate interest |

### L4 — Restricted
| Data Element | Location | Control |
|-------------|---------|---------|
| DB credentials (dynamic) | HashiCorp Vault | 15-min TTL, auto-rotate |
| JWT signing key | Azure Key Vault HSM | RSA-4096, 90-day rotation |
| API keys (GhIPSS, ExpressPay) | Azure Key Vault | External Secrets Operator |
| Audit logs | Azure Blob (immutable) | 7-year WORM, no delete |
| Encryption keys (CMK) | Azure Key Vault HSM | HSM-backed, purge-protected |

## Data Handling Rules

### NEVER log these fields (PCI-DSS Req.3.4)
```csharp
// PROHIBITED in any log statement:
// password, pin, cvv, card_number, pan, secret, token, key, credential
// Enforced by OTel PII-redaction pipeline in monitoring module
```

### Data Residency
- Primary: Azure East US 2 (USA)
- DR replica: GCP Europe West 4 (Belgium)
- Customer data (Ghana): does not leave Azure East US 2 in normal operations
- Bank of Ghana data localisation requirements: under review

### Deletion / Right to Erasure
GDPR / BoG requests handled via `DELETE /api/v1/users/{id}` — triggers:
1. Anonymise PII fields (name → "DELETED", email → hash)
2. Retain transaction records (legal obligation — 7 years)
3. Publish `UserDataDeleted` domain event
4. Propagate to all services via Kafka within 24h
