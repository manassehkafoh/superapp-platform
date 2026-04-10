# =============================================================================
# SuperApp Platform – Production terraform.tfvars
# =============================================================================
# SECURITY: This file contains sensitive configuration.
# - Commit to Git ONLY after verifying no secrets are inline.
# - Sensitive values (pagerduty_key, slack_api_url, passwords) must be
#   supplied via environment variables or CI/CD secret injection:
#     export TF_VAR_pagerduty_key="..."
#     export TF_VAR_slack_api_url="..."
#     export TF_VAR_grafana_admin_password="..."
# =============================================================================

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
environment = "prod"

# ---------------------------------------------------------------------------
# Azure
# ---------------------------------------------------------------------------
azure_subscription_id   = "00000000-0000-0000-0000-000000000001"  # REPLACE
azure_tenant_id         = "00000000-0000-0000-0000-000000000002"  # REPLACE
azure_primary_location  = "westeurope"
azure_dr_location       = "northeurope"

# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------
aws_account_id        = "123456789012"   # REPLACE
aws_primary_region    = "eu-west-1"
aws_dr_region         = "eu-central-1"

# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------
# Public IP of on-premises VPN device (HQ / T24 ESB gateway)
# Leave empty if using ExpressRoute / Direct Connect only
on_premises_public_ip = ""   # e.g. "203.0.113.10" – REPLACE or leave empty

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
alert_emails = [
  "platform-oncall@company.com",
  "security-team@company.com"
]

# Sensitive values – inject via CI/CD secrets or environment variables:
# pagerduty_key         = ""   # TF_VAR_pagerduty_key
# slack_api_url         = ""   # TF_VAR_slack_api_url
# grafana_admin_password = ""  # TF_VAR_grafana_admin_password
