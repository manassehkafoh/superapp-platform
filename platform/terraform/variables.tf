###############################################################################
# SuperApp Platform — Global Terraform Variables
#
# Convention: All variables include description, type constraints, and
#             validation rules. Sensitive values are marked sensitive=true
#             and sourced from Vault/GitHub Secrets — never set defaults.
###############################################################################

# ─── GENERAL ────────────────────────────────────────────────────────────────

variable "environment" {
  description = "Deployment environment (dev | staging | production)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "platform_name" {
  description = "Platform name used as resource name prefix"
  type        = string
  default     = "superapp"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.platform_name))
    error_message = "platform_name must be 3-20 lowercase alphanumeric chars."
  }
}

variable "owner_team" {
  description = "Team responsible for these resources (for tagging)"
  type        = string
  default     = "platform-engineering"
}

variable "cost_centre" {
  description = "Cost centre code for billing allocation"
  type        = string
}

variable "internal_domain" {
  description = "Internal DNS domain for cluster-internal services"
  type        = string
  default     = "superapp.internal"
}

# ─── AZURE CONFIGURATION ────────────────────────────────────────────────────

variable "azure_primary_region" {
  description = "Azure primary region for all production resources"
  type        = string
  default     = "westeurope"
}

variable "azure_secondary_region" {
  description = "Azure secondary region for geo-redundancy"
  type        = string
  default     = "northeurope"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
  sensitive   = true
}

# ─── GCP CONFIGURATION ──────────────────────────────────────────────────────

variable "gcp_project_id" {
  description = "GCP project ID for the secondary/DR environment"
  type        = string
}

variable "gcp_primary_region" {
  description = "GCP primary region for DR resources"
  type        = string
  default     = "europe-west1"
}

variable "gcp_secondary_region" {
  description = "GCP secondary region for cross-region DR"
  type        = string
  default     = "europe-west4"
}

# ─── NETWORKING ─────────────────────────────────────────────────────────────

variable "vnet_address_space" {
  description = "Azure VNet CIDR address space"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "aks_subnet_cidr" {
  description = "CIDR for AKS node subnet (must fit all pods: nodes * 256 pod IPs)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "aks_service_cidr" {
  description = "CIDR for Kubernetes service ClusterIPs (must not overlap VNet)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "aks_dns_service_ip" {
  description = "IP address for Kubernetes DNS service (must be within service_cidr)"
  type        = string
  default     = "172.16.0.10"
}

# ─── AKS CLUSTER CONFIGURATION ──────────────────────────────────────────────

variable "aks_kubernetes_version" {
  description = "Kubernetes version for AKS cluster"
  type        = string
  default     = "1.29"
}

variable "aks_system_node_count" {
  description = "Number of system node pool nodes (min 3 for HA)"
  type        = number
  default     = 3
  validation {
    condition     = var.aks_system_node_count >= 3
    error_message = "System node pool requires minimum 3 nodes for HA."
  }
}

variable "aks_system_vm_size" {
  description = "VM size for system node pool"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "aks_app_node_min_count" {
  description = "Minimum nodes in application node pool (autoscaler)"
  type        = number
  default     = 3
}

variable "aks_app_node_max_count" {
  description = "Maximum nodes in application node pool (autoscaler)"
  type        = number
  default     = 10
}

variable "aks_app_vm_size" {
  description = "VM size for application node pool"
  type        = string
  default     = "Standard_D8s_v5"
}

variable "aks_data_node_count" {
  description = "Number of data node pool nodes (Kafka, Redis)"
  type        = number
  default     = 3
}

variable "aks_data_vm_size" {
  description = "VM size for data node pool (memory-optimised)"
  type        = string
  default     = "Standard_E8s_v5"
}

variable "aks_enable_spot_instances" {
  description = "Enable spot instances for app node pool (cost saving for dev)"
  type        = bool
  default     = false
}

# ─── DATABASE CONFIGURATION ─────────────────────────────────────────────────

variable "sql_admin_username" {
  description = "Azure SQL administrator username"
  type        = string
  default     = "sqladmin"
}

variable "sql_sku_name" {
  description = "Azure SQL SKU (Hyperscale recommended for production)"
  type        = string
  default     = "HS_Gen5_4"  # Hyperscale, Gen5, 4 vCores
}

variable "sql_backup_retention_days" {
  description = "SQL database backup retention in days (SOC 2: min 30 days)"
  type        = number
  default     = 35
  validation {
    condition     = var.sql_backup_retention_days >= 30
    error_message = "SOC 2 requires minimum 30 days backup retention."
  }
}

variable "sql_geo_redundant_backup" {
  description = "Enable geo-redundant SQL backups (required for DORA compliance)"
  type        = bool
  default     = true
}

# ─── REDIS CONFIGURATION ────────────────────────────────────────────────────

variable "redis_sku_name" {
  description = "Redis Cache SKU (Premium required for VNet injection + clustering)"
  type        = string
  default     = "Premium"
}

variable "redis_family" {
  description = "Redis family (C=Basic/Standard, P=Premium)"
  type        = string
  default     = "P"
}

variable "redis_capacity" {
  description = "Redis cache size (P1=6GB, P2=13GB, P3=26GB, P4=53GB, P5=120GB)"
  type        = number
  default     = 2
}

# ─── SECURITY CONFIGURATION ─────────────────────────────────────────────────

variable "key_vault_sku_name" {
  description = "Azure Key Vault SKU (premium includes HSM for SOC 2)"
  type        = string
  default     = "premium"
  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku_name)
    error_message = "key_vault_sku_name must be standard or premium."
  }
}

variable "allowed_admin_ips" {
  description = "List of IP addresses/CIDRs allowed for admin operations"
  type        = list(string)
  default     = []
  # IMPORTANT: Keep this list minimal. All other access via Bastion/ZT.
}

variable "enable_ddos_protection" {
  description = "Enable Azure DDoS Network Protection Standard (high cost but required for production)"
  type        = bool
  default     = true
}

# ─── KAFKA CONFIGURATION ────────────────────────────────────────────────────

variable "kafka_broker_count" {
  description = "Number of Kafka brokers (min 3 for replication factor 3)"
  type        = number
  default     = 3
  validation {
    condition     = var.kafka_broker_count >= 3
    error_message = "Kafka requires minimum 3 brokers for replication factor 3."
  }
}

variable "kafka_storage_gb" {
  description = "Storage per Kafka broker in GB"
  type        = number
  default     = 100
}

# ─── MONITORING CONFIGURATION ───────────────────────────────────────────────

variable "log_retention_days" {
  description = "Log Analytics workspace retention (SOC 2: min 90 days)"
  type        = number
  default     = 90
  validation {
    condition     = var.log_retention_days >= 90
    error_message = "SOC 2 requires minimum 90 days log retention."
  }
}

variable "alert_email_addresses" {
  description = "Email addresses for monitoring alerts"
  type        = list(string)
  default     = []
}

variable "pagerduty_integration_key" {
  description = "PagerDuty integration key for alerts"
  type        = string
  sensitive   = true
  default     = ""
}

# ─── GITOPS CONFIGURATION ───────────────────────────────────────────────────

variable "argocd_admin_password_bcrypt" {
  description = "Bcrypt hash of ArgoCD admin password (generated: htpasswd -nbBC 10 '' password)"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub organisation for GitOps repository"
  type        = string
  default     = "superapp-platform"
}

variable "gitops_repo_url" {
  description = "GitOps repository URL (ArgoCD source)"
  type        = string
  default     = "https://github.com/superapp-platform/superapp-gitops"
}

# ─── TAGS ───────────────────────────────────────────────────────────────────
# Common tags applied to all resources for governance, cost allocation,
# SOC 2 asset inventory, and DORA ICT asset register

locals {
  common_tags = {
    environment     = var.environment
    platform        = var.platform_name
    owner           = var.owner_team
    cost_centre     = var.cost_centre
    managed_by      = "terraform"
    compliance      = "soc2-dora-pci"
    data_class      = "confidential"
    backup_required = "true"
    created_date    = timestamp()
  }
}
