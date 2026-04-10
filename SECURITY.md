# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main branch | ✅ Active |
| Tagged releases | ✅ 12 months |
| Older | ❌ No |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

### Private Disclosure
Email: **security@superapp.com.gh**
PGP: Available on request

Include:
- Description of the vulnerability
- Steps to reproduce
- Affected service(s) and version
- Potential impact assessment
- Any suggested mitigations

### Response SLAs (DORA Art.17 aligned)
| Severity | Acknowledgement | Fix Target |
|----------|----------------|------------|
| Critical | 2 hours | 24 hours |
| High | 8 hours | 72 hours |
| Medium | 24 hours | 14 days |
| Low | 72 hours | 90 days |

### Scope
In scope: All services in this repository, deployed infrastructure, API endpoints.
Out of scope: Third-party integrations (GhIPSS, ExpressPay), social engineering attacks.

## Security Controls Summary
- **Authentication**: JWT (RS256), MFA, short-lived access tokens (1h), refresh tokens (30d)
- **Authorisation**: RBAC via Azure AD, OPA policy enforcement on Kubernetes
- **Secrets**: HashiCorp Vault (dynamic credentials, 15-min TTL), Azure Key Vault HSM
- **Network**: Cilium eBPF Zero Trust (default deny-all, L7 HTTP policies)
- **Runtime**: FortiCNAPP CWPP (eBPF enforcement), Falco kernel security
- **Supply chain**: Cosign image signing, SBOM (CycloneDX), Trivy in CI
- **Compliance**: SOC 2 Type II, PCI-DSS v4, DORA, Bank of Ghana KYC tiers
