# =============================================================================
# Module: Azure Security — CNAPP, Key Vault, Defender, Sentinel, Policies
# =============================================================================
# Components:
#   - Azure Key Vault (CMK for all encrypted resources)
#   - Microsoft Defender for Cloud (CSPM + CWPP — CNAPP Azure side)
#   - Microsoft Sentinel (SIEM/SOAR)
#   - Azure Policy (governance + compliance automation)
#   - Azure Container Registry (with vulnerability scanning)
#   - Managed Identity for CI/CD (OIDC, no passwords)
# Compliance: SOC 2 CC3.1, CC6.1, CC6.6, CC7.1-7.4 | DORA Article 9,17
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "resource_group_name" { type = string }
variable "location"             { type = string }
variable "environment"          { type = string }
variable "tenant_id"            { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "allowed_ip_ranges" {
  description = "IP ranges allowed to access Key Vault (management only)"
  type        = list(string)
  default     = []
}

variable "aks_vnet_cidr"  { type = string }
variable "data_vnet_cidr" { type = string }
variable "tags"           { type = map(string); default = {} }

variable "enable_sentinel"          { type = bool; default = true }
variable "enable_defender"          { type = bool; default = true }
variable "acr_georeplications"      { type = list(string); default = ["northeurope"] }

variable "github_oidc_subject" {
  description = "GitHub OIDC subject claim for CI/CD federation (e.g., repo:org/repo:environment:prod)"
  type        = string
}

# -----------------------------------------------------------------------------
# Azure Key Vault — Hardware Security Module (HSM) backed in production
# All secrets, keys, and certificates managed here
# Soft-delete + purge protection: prevents accidental or malicious deletion
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                = "kv-superapp-${var.environment}-${random_string.kv_suffix.result}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id

  # SKU: Premium = HSM-backed keys (required for CMK compliance)
  sku_name = var.environment == "prod" ? "premium" : "standard"

  # Soft-delete retention: 90 days (max) — SOC 2 C1.2 requirement
  soft_delete_retention_days = 90

  # Purge protection: prevents permanent deletion even by admins
  # Once enabled, cannot be disabled (intentional — compliance requirement)
  purge_protection_enabled = true

  # Disable public network access — access via Private Endpoint only
  public_network_access_enabled = false

  # RBAC authorization model (vs access policies — better for audit)
  enable_rbac_authorization = true

  network_acls {
    default_action = "Deny"         # Deny all by default
    bypass         = "AzureServices" # Allow trusted Azure services
    ip_rules       = var.allowed_ip_ranges
    virtual_network_subnet_ids = []  # Access via Private Endpoint only
  }

  tags = merge(var.tags, { "resource-type" = "key-vault" })
}

resource "random_string" "kv_suffix" {
  length  = 4
  special = false
  upper   = false
}

# Key Vault Private Endpoint — access only from within VNet
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-kv-superapp"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.vaultcore.azure.net"]]
  }

  tags = var.tags
}

# Diagnostic settings for Key Vault — log all access attempts
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "kv-diagnostics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }   # All operations (read/write/delete)
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# -----------------------------------------------------------------------------
# Azure Container Registry (ACR) — enterprise-grade image registry
# Geo-replicated, with Defender vulnerability scanning enabled
# Quarantine mode: images must pass scan before they can be pulled
# -----------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = "acrsuperapp${var.environment}${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium" # Required for geo-replication + Private Link

  # Disable admin account — only managed identity / RBAC access
  admin_enabled = false

  # Quarantine policy — images must pass vulnerability scan before pull
  quarantine_policy_enabled = true

  # Content trust (image signing via Cosign/Notary)
  trust_policy {
    enabled = true
  }

  # Retention policy for untagged images (reduce storage cost)
  retention_policy {
    days    = 30
    enabled = true
  }

  # Geo-replication for DR and reduced latency
  dynamic "georeplications" {
    for_each = var.acr_georeplications
    content {
      location                  = georeplications.value
      regional_endpoint_enabled = true
      zone_redundancy_enabled   = true
      tags                      = var.tags
    }
  }

  # Disable public access — pull only via Private Endpoint
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"

  # Encryption with CMK
  encryption {
    enabled            = true
    key_vault_key_id   = azurerm_key_vault_key.acr_cmk.id
    identity_client_id = azurerm_user_assigned_identity.acr_cmk.client_id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr_cmk.id]
  }

  tags = merge(var.tags, { "resource-type" = "container-registry" })
}

resource "random_string" "acr_suffix" {
  length  = 4
  special = false
  upper   = false
}

# CMK identity for ACR
resource "azurerm_user_assigned_identity" "acr_cmk" {
  name                = "id-acr-cmk-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_key_vault_key" "acr_cmk" {
  name         = "acr-cmk-${var.environment}"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 4096
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic { time_before_expiry = "P30D" }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }
}

# ACR Private Endpoint
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }

  private_dns_zone_group {
    name                 = "acr-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.azurecr.io"]]
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Microsoft Defender for Cloud — CNAPP (Azure side)
# Enables: Defender for Containers, DevOps, APIs, SQL, Storage, Key Vault
# -----------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "ContainerRegistry"
}

resource "azurerm_security_center_subscription_pricing" "aks" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "KubernetesService"
  subplan       = "DefenderDForContainers"
}

resource "azurerm_security_center_subscription_pricing" "sql" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "SqlServers"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "StorageAccounts"
}

resource "azurerm_security_center_subscription_pricing" "key_vault" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "KeyVaults"
}

resource "azurerm_security_center_subscription_pricing" "api" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Standard"
  resource_type = "Api"
}

# Defender for Cloud Security Contact — for breach notifications (SOC 2 CC2.1)
resource "azurerm_security_center_contact" "this" {
  count              = var.enable_defender ? 1 : 0
  email              = var.security_contact_email
  phone              = var.security_contact_phone
  alert_notifications = true
  alerts_to_admins    = true
}

# Auto-provisioning: automatically deploy Defender agents to new VMs/nodes
resource "azurerm_security_center_auto_provisioning" "log_analytics" {
  auto_provision = "On"
}

# -----------------------------------------------------------------------------
# Microsoft Sentinel — SIEM/SOAR
# Connects to Log Analytics workspace; all cloud logs flow here
# -----------------------------------------------------------------------------
resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  count        = var.enable_sentinel ? 1 : 0
  workspace_id = var.log_analytics_workspace_id
}

# Sentinel Data Connectors — ingest signals from all sources
resource "azurerm_sentinel_data_connector_azure_active_directory" "entra_id" {
  count                      = var.enable_sentinel ? 1 : 0
  name                       = "connector-entra-id"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tenant_id                  = var.tenant_id
}

resource "azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection" "mdatp" {
  count                      = var.enable_sentinel ? 1 : 0
  name                       = "connector-defender-mtp"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tenant_id                  = var.tenant_id
}

resource "azurerm_sentinel_data_connector_azure_security_center" "asc" {
  count                      = var.enable_sentinel ? 1 : 0
  name                       = "connector-defender-cloud"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  subscription_id            = var.subscription_id
}

# Sentinel Analytical Rule — High severity alerts require immediate action
resource "azurerm_sentinel_alert_rule_scheduled" "critical_k8s_events" {
  count                      = var.enable_sentinel ? 1 : 0
  name                       = "superapp-critical-k8s-security-events"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  display_name               = "SuperApp — Critical Kubernetes Security Event"
  severity                   = "High"
  enabled                    = true

  # KQL query: detect suspicious K8s API calls
  query = <<-QUERY
    AzureDiagnostics
    | where Category == "kube-audit"
    | where verb_s in ("create", "update", "patch", "delete")
    | where objectRef_resource_s in ("secrets", "rolebindings", "clusterrolebindings", "serviceaccounts")
    | where user_username_s !startswith "system:"
    | where user_username_s != "aks-service"
    | project TimeGenerated, user_username_s, verb_s, objectRef_resource_s, objectRef_name_s, sourceIPs_s
  QUERY

  query_frequency = "PT5M"
  query_period    = "PT15M"
  trigger_operator   = "GreaterThan"
  trigger_threshold  = 0

  tactics = ["PrivilegeEscalation", "LateralMovement"]
}

# -----------------------------------------------------------------------------
# Azure Policy — enforce governance rules automatically
# Policies marked [Deny] prevent non-compliant resources from being created
# Policies marked [DeployIfNotExists] auto-remediate missing configs
# -----------------------------------------------------------------------------

# Policy: Require Private Endpoints for Key Vault
resource "azurerm_resource_policy_assignment" "kv_private_endpoint" {
  name         = "require-kv-private-endpoint"
  resource_id  = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/55615ac9-af46-4a59-874e-391cc3dfb490"
  display_name = "Key Vault should use a private link service"
  enforce      = true
}

# Policy: Require AKS to use RBAC
resource "azurerm_resource_policy_assignment" "aks_rbac" {
  name         = "require-aks-rbac"
  resource_id  = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/ac4a19c2-fa67-49b4-be9d-a3a9d2ff9cee"
  display_name = "Role-Based Access Control (RBAC) should be used on Kubernetes Services"
  enforce      = true
}

# Policy: No privileged containers in Kubernetes
resource "azurerm_resource_policy_assignment" "no_privileged_containers" {
  name         = "no-privileged-k8s-containers"
  resource_id  = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/95edb821-ddaf-4404-9732-666045e056b4"
  display_name = "Kubernetes clusters should not allow container privilege escalation"
  enforce      = true
}

# Policy: Allowed container registries — only internal ACR
resource "azurerm_resource_policy_assignment" "allowed_registries" {
  name         = "allowed-container-registries"
  resource_id  = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/febd0533-8e55-448f-b837-bd0e06f16469"
  display_name = "Kubernetes clusters should only use allowed container image registries"
  enforce      = true

  parameters = jsonencode({
    allowedContainerImagesRegex = {
      value = "^${azurerm_container_registry.this.login_server}/"
    }
  })
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC Federation — no client secrets in CI/CD
# Terraform and Docker push use managed identity via OIDC
# SOC 2 CC6.1 — no long-lived credentials in pipelines
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "id-github-actions-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "github_actions" {
  name                = "github-actions-oidc"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  parent_id           = azurerm_user_assigned_identity.github_actions.id

  # Subject: restricts which GitHub repo/environment can assume this identity
  subject = var.github_oidc_subject
}

# Grant CI/CD identity rights to push to ACR and manage AKS
resource "azurerm_role_assignment" "github_acr_push" {
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
  role_definition_name = "AcrPush"
  scope                = azurerm_container_registry.this.id
}

resource "azurerm_role_assignment" "github_aks_developer" {
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  scope                = var.aks_cluster_id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "acr_id" {
  value = azurerm_container_registry.this.id
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "github_actions_identity_client_id" {
  value = azurerm_user_assigned_identity.github_actions.client_id
}

output "github_actions_identity_principal_id" {
  value = azurerm_user_assigned_identity.github_actions.principal_id
}
