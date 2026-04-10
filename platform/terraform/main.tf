###############################################################################
# SuperApp Platform — Root Terraform Module
#
# Orchestrates all sub-modules in correct dependency order:
#   1. Resource Groups (foundation)
#   2. Networking (VNets, Firewall, Private DNS)
#   3. Security (Key Vault, ACR, Defender, Vault, Falco, SPIRE)
#   4. Kubernetes (AKS cluster + Cilium + ArgoCD)
#   5. Databases (SQL Hyperscale + Redis, per-service)
#   6. Messaging (Kafka/Event Hubs)
#   7. Monitoring (Log Analytics, Prometheus, Grafana)
#   8. Identity (Azure AD, Workload Identity, RBAC)
#
# Usage:
#   terraform init -backend-config=environments/production/backend.tfvars
#   terraform plan  -var-file=environments/production/terraform.tfvars
#   terraform apply -var-file=environments/production/terraform.tfvars
###############################################################################

# ─── RESOURCE GROUPS ─────────────────────────────────────────────────────────
# Separate RGs for blast-radius isolation and lifecycle management

resource "azurerm_resource_group" "platform" {
  name     = "rg-${var.platform_name}-platform-${var.environment}"
  location = var.azure_primary_region
  tags     = local.common_tags
}

resource "azurerm_resource_group" "network" {
  name     = "rg-${var.platform_name}-network-${var.environment}"
  location = var.azure_primary_region
  tags     = local.common_tags
}

resource "azurerm_resource_group" "security" {
  name     = "rg-${var.platform_name}-security-${var.environment}"
  location = var.azure_primary_region
  tags     = local.common_tags
}

resource "azurerm_resource_group" "data" {
  name     = "rg-${var.platform_name}-data-${var.environment}"
  location = var.azure_primary_region
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-${var.platform_name}-monitoring-${var.environment}"
  location = var.azure_primary_region
  tags     = local.common_tags
}

# ─── NETWORKING MODULE ────────────────────────────────────────────────────────
module "networking" {
  source              = "./modules/networking"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.network.name
  location            = var.azure_primary_region
  spoke_address_space = var.aks_subnet_cidr
  enable_ddos_protection = var.enable_ddos_protection
  tags                = local.common_tags

  # Pass firewall TLS cert secret ID (created in security module)
  # Order matters: networking depends on security for cert, but security
  # depends on networking for subnet IDs. Break the cycle:
  # firewall_tls_cert_secret_id is passed in as a variable from the security
  # module in a subsequent apply, or use a placeholder in first run.
  firewall_tls_cert_secret_id = var.firewall_tls_cert_secret_id
  allowed_admin_ips           = var.allowed_admin_ips
}

# ─── SECURITY MODULE ──────────────────────────────────────────────────────────
module "security" {
  source              = "./modules/security"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.security.name
  location            = var.azure_primary_region
  tenant_id           = data.azurerm_client_config.current.tenant_id
  subscription_id     = data.azurerm_subscription.current.subscription_id

  # Network dependencies (from networking module)
  vnet_id                     = module.networking.spoke_vnet_id
  allowed_subnet_ids          = [
    module.networking.aks_app_subnet_id,
    module.networking.aks_system_subnet_id,
    module.networking.aks_data_subnet_id,
  ]
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  allowed_admin_ips           = var.allowed_admin_ips

  # DNS zones (from networking module)
  keyvault_private_dns_zone_id = module.networking.keyvault_private_dns_zone_id
  acr_private_dns_zone_id      = module.networking.acr_private_dns_zone_id

  # Azure regions
  azure_secondary_region = var.azure_secondary_region

  # Monitoring
  log_retention_days = var.log_retention_days
  security_alert_emails = var.alert_email_addresses

  # Runtime security integrations
  slack_webhook_url     = var.slack_webhook_url
  pagerduty_routing_key = var.pagerduty_integration_key
  event_hub_namespace   = module.messaging.event_hub_namespace_name

  # Workload Identity for Vault
  vault_workload_identity_client_id = module.identity.vault_workload_identity_client_id
  acr_encryption_identity_client_id = module.identity.acr_encryption_identity_client_id

  # ArgoCD OIDC (Azure AD integration)
  azure_tenant_id            = data.azurerm_client_config.current.tenant_id
  argocd_azure_client_id     = module.identity.argocd_client_id
  argocd_admin_group_id      = var.argocd_admin_group_id
  argocd_developer_group_id  = var.argocd_developer_group_id

  tags = local.common_tags

  depends_on = [module.networking]
}

# ─── IDENTITY MODULE ──────────────────────────────────────────────────────────
module "identity" {
  source      = "./modules/identity"
  prefix      = var.platform_name
  environment = var.environment
  tenant_id   = data.azurerm_client_config.current.tenant_id
  tags        = local.common_tags
}

# ─── KUBERNETES (AKS) MODULE ─────────────────────────────────────────────────
module "aks_cluster" {
  source              = "./modules/kubernetes"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.azure_primary_region

  # Network
  vnet_id              = module.networking.spoke_vnet_id
  aks_system_subnet_id = module.networking.aks_system_subnet_id
  aks_app_subnet_id    = module.networking.aks_app_subnet_id
  aks_data_subnet_id   = module.networking.aks_data_subnet_id
  aks_service_cidr     = var.aks_service_cidr
  aks_dns_service_ip   = var.aks_dns_service_ip
  private_dns_zone_id  = module.networking.aks_private_dns_zone_id

  # Security
  key_vault_id                  = module.security.key_vault_id
  acr_id                        = module.security.acr_id
  disk_encryption_set_id        = module.security.disk_encryption_set_id
  log_analytics_workspace_id    = module.security.log_analytics_workspace_id

  # Cluster config
  kubernetes_version    = var.aks_kubernetes_version
  system_node_count     = var.aks_system_node_count
  system_vm_size        = var.aks_system_vm_size
  app_node_min_count    = var.aks_app_node_min_count
  app_node_max_count    = var.aks_app_node_max_count
  app_vm_size           = var.aks_app_vm_size
  data_node_count       = var.aks_data_node_count
  data_vm_size          = var.aks_data_vm_size
  enable_spot_instances = var.aks_enable_spot_instances

  # AAD RBAC
  aks_admin_group_ids        = var.aks_admin_group_ids
  azure_tenant_id            = data.azurerm_client_config.current.tenant_id

  # ArgoCD config
  argocd_azure_client_id    = module.identity.argocd_client_id
  argocd_admin_group_id     = var.argocd_admin_group_id
  argocd_developer_group_id = var.argocd_developer_group_id
  argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  internal_domain            = var.internal_domain

  # Internal refs
  slack_webhook_url = var.slack_webhook_url

  tags = local.common_tags

  depends_on = [
    module.networking,
    module.security,
    module.identity,
  ]
}

# ─── DATABASES MODULE ─────────────────────────────────────────────────────────
module "databases" {
  source              = "./modules/databases"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.data.name
  location            = var.azure_primary_region
  azure_secondary_location = var.azure_secondary_region

  # Security
  key_vault_id             = module.security.key_vault_id
  sql_tde_key_id           = module.security.sql_tde_key_id
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  sql_private_dns_zone_id  = module.networking.sql_private_dns_zone_id
  redis_private_dns_zone_id = module.networking.redis_private_dns_zone_id

  # SQL config
  sql_admin_username         = var.sql_admin_username
  sql_aad_admin_group_id     = var.sql_aad_admin_group_id
  sql_aad_admin_group_name   = var.sql_aad_admin_group_name
  sql_backup_retention_days  = var.sql_backup_retention_days
  sql_geo_redundant_backup   = var.sql_geo_redundant_backup
  security_alert_emails      = var.alert_email_addresses

  # Redis config
  redis_capacity = var.redis_capacity

  # Backup storage (for SQL vulnerability assessments)
  storage_account_blob_endpoint  = module.monitoring.backup_storage_blob_endpoint
  storage_account_access_key     = module.monitoring.backup_storage_access_key
  redis_backup_storage_connection_string = module.monitoring.backup_storage_connection_string

  tags = local.common_tags

  depends_on = [
    module.networking,
    module.security,
  ]
}

# ─── MESSAGING MODULE (Kafka / Azure Event Hubs) ─────────────────────────────
module "messaging" {
  source              = "./modules/messaging"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.data.name
  location            = var.azure_primary_region
  kafka_broker_count  = var.kafka_broker_count
  kafka_storage_gb    = var.kafka_storage_gb
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  eventhub_private_dns_zone_id = module.networking.eventhub_private_dns_zone_id
  key_vault_id        = module.security.key_vault_id
  log_analytics_workspace_id = module.security.log_analytics_workspace_id
  tags                = local.common_tags

  depends_on = [module.networking, module.security]
}

# ─── MONITORING MODULE ────────────────────────────────────────────────────────
module "monitoring" {
  source              = "./modules/monitoring"
  prefix              = var.platform_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = var.azure_primary_region
  log_retention_days  = var.log_retention_days
  alert_email_addresses = var.alert_email_addresses
  pagerduty_integration_key = var.pagerduty_integration_key
  tags                = local.common_tags
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────
output "aks_cluster_name" {
  description = "AKS cluster name (use with: az aks get-credentials)"
  value       = module.aks_cluster.cluster_name
}

output "acr_login_server" {
  description = "Container registry login server URL"
  value       = module.security.acr_login_server
}

output "key_vault_uri" {
  description = "Key Vault URI for secret references"
  value       = module.security.key_vault_uri
}

output "sql_server_fqdns" {
  description = "SQL server FQDNs per service"
  value       = module.databases.sql_server_fqdns
  sensitive   = true
}

output "redis_hostname" {
  description = "Redis cache hostname"
  value       = module.databases.redis_hostname
  sensitive   = true
}

output "argocd_url" {
  description = "ArgoCD web UI URL (internal DNS)"
  value       = "https://argocd.${var.internal_domain}"
}

output "hubble_ui_url" {
  description = "Cilium Hubble UI URL (port-forward required)"
  value       = "kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
}
