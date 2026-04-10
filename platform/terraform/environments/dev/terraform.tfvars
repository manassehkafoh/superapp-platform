###############################################################################
# SuperApp Platform — Development Environment Variables
# Minimal footprint for developer iteration — cost-optimised
###############################################################################

environment   = "dev"
platform_name = "superapp"
location      = "eastus2"
location_code = "eus2"

hub_vnet_cidr   = "10.20.0.0/16"
spoke_vnet_cidr = "10.21.0.0/16"

subnet_cidrs = {
  firewall          = "10.20.0.0/26"
  bastion           = "10.20.0.64/26"
  gateway           = "10.20.0.128/27"
  aks_system        = "10.21.0.0/23"
  aks_app           = "10.21.2.0/22"
  aks_data          = "10.21.6.0/23"
  aks_security      = "10.21.8.0/24"
  private_endpoints = "10.21.9.0/24"
  pod_cidr          = "10.246.0.0/16"
  service_cidr      = "10.98.0.0/16"
  dns_service_ip    = "10.98.0.10"
}

# Dev: single-node pools for cost savings
aks_system_node_count   = 1
aks_system_vm_size      = "Standard_D2ds_v5"
aks_app_min_count       = 1
aks_app_max_count       = 4
aks_app_vm_size         = "Standard_D4ds_v5"
aks_data_min_count      = 1
aks_data_max_count      = 2
aks_data_vm_size        = "Standard_D4ds_v5"   # Standard (not memory-opt) for dev
aks_security_node_count = 1
aks_security_vm_size    = "Standard_D2ds_v5"
kubernetes_version      = "1.30"

sql_sku_name                   = "GP_Gen5_2"
sql_max_size_gb                = 16
sql_backup_retention_days      = 7
sql_geo_redundant_backup       = false
sql_failover_grace_period_mins = 60

redis_sku         = "Basic"
redis_family      = "C"
redis_capacity    = 0           # 250MB Basic — dev only

eventhub_capacity = 1
kafka_replicas    = 1           # Single broker OK for dev
kafka_storage_gb  = 20

key_vault_sku       = "standard"
log_retention_days  = 14
grafana_replicas    = 1

deployment_approval_required = false
change_ticket_required       = false
canary_weight_initial        = 100  # Direct deploy in dev

common_tags = {
  environment  = "dev"
  platform     = "superapp"
  owner        = "platform-team"
  cost_centre  = "PLAT-001"
  managed_by   = "terraform"
  compliance   = "none"
  data_classification = "internal"
}

domain_name     = "dev.superapp.com.gh"
acme_email      = "platform@superapp.com.gh"
tls_cert_issuer = "letsencrypt-staging"  # Use staging ACME for dev

# Data node pool autoscaling
data_node_min_count = 1
data_node_max_count = 4
