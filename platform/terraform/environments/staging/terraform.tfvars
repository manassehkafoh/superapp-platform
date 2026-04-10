###############################################################################
# SuperApp Platform — Staging Environment Variables
# Mirror of production with reduced scale — used for pre-prod validation
###############################################################################

environment   = "staging"
platform_name = "superapp"
location      = "eastus2"
location_code = "eus2"

hub_vnet_cidr   = "10.10.0.0/16"
spoke_vnet_cidr = "10.11.0.0/16"

subnet_cidrs = {
  firewall          = "10.10.0.0/26"
  bastion           = "10.10.0.64/26"
  gateway           = "10.10.0.128/27"
  aks_system        = "10.11.0.0/23"
  aks_app           = "10.11.2.0/22"
  aks_data          = "10.11.6.0/23"
  aks_security      = "10.11.8.0/24"
  private_endpoints = "10.11.9.0/24"
  pod_cidr          = "10.245.0.0/16"
  service_cidr      = "10.97.0.0/16"
  dns_service_ip    = "10.97.0.10"
}

aks_system_node_count   = 2
aks_system_vm_size      = "Standard_D2ds_v5"
aks_app_min_count       = 2
aks_app_max_count       = 8
aks_app_vm_size         = "Standard_D4ds_v5"
aks_data_min_count      = 1
aks_data_max_count      = 3
aks_data_vm_size        = "Standard_E4ds_v5"
aks_security_node_count = 1
aks_security_vm_size    = "Standard_D2ds_v5"
kubernetes_version      = "1.30"

sql_sku_name                   = "GP_Gen5_2"
sql_max_size_gb                = 32
sql_backup_retention_days      = 14
sql_geo_redundant_backup       = false
sql_failover_grace_period_mins = 60

redis_sku         = "Standard"
redis_family      = "C"
redis_capacity    = 1

eventhub_capacity = 2
kafka_replicas    = 3
kafka_storage_gb  = 50

key_vault_sku       = "standard"
log_retention_days  = 30
grafana_replicas    = 1

deployment_approval_required = false
change_ticket_required       = false
canary_weight_initial        = 50

common_tags = {
  environment  = "staging"
  platform     = "superapp"
  owner        = "platform-team"
  cost_centre  = "PLAT-001"
  managed_by   = "terraform"
  compliance   = "soc2-dora-pci"
  data_classification = "internal"
}

domain_name     = "staging.superapp.com.gh"
acme_email      = "platform@superapp.com.gh"
tls_cert_issuer = "letsencrypt-prod"

# Data node pool autoscaling
data_node_min_count = 1
data_node_max_count = 4
