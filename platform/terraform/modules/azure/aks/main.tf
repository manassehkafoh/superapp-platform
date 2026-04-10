# =============================================================================
# Module: Azure Kubernetes Service (AKS) — Enterprise Grade
# =============================================================================
# Features:
#   - Cilium as CNI (replaces kubenet/Azure CNI)
#   - Entra ID integration for RBAC
#   - System + workload + spot node pools (availability zones)
#   - Private cluster (no public API server endpoint)
#   - Microsoft Defender for Containers enabled
#   - OIDC + Workload Identity for pod-level Azure auth
#   - Azure Key Vault Secrets Provider (CSI driver)
#   - Auto-upgrade channel + node OS patching
#   - Pod Identity replaced by Workload Identity (modern approach)
# Compliance: SOC 2 CC6.1, CC6.3, CC8.1 | DORA Article 9
# =============================================================================

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.110" }
    azuread = { source = "hashicorp/azuread", version = "~> 2.52" }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Resource group name for AKS cluster and related resources"
  type        = string
}

variable "location" {
  description = "Azure region for deployment"
  type        = string
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Use AKS LTS version for production."
  type        = string
}

variable "node_resource_group" {
  description = "Name for the auto-created node resource group (MC_* by default)"
  type        = string
}

variable "vnet_subnet_id" {
  description = "Subnet ID for AKS nodes (must be large enough: /22 minimum)"
  type        = string
}

variable "pod_cidr" {
  description = "CIDR for Cilium pod networking overlay"
  type        = string
  default     = "10.100.0.0/14"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services (must not overlap with VNet)"
  type        = string
  default     = "10.200.0.0/16"
}

variable "dns_service_ip" {
  description = "IP within service_cidr for the DNS service"
  type        = string
  default     = "10.200.0.10"
}

variable "admin_group_object_ids" {
  description = "List of Entra ID group object IDs for AKS cluster admin access"
  type        = list(string)
}

variable "system_node_pool" {
  description = "System node pool configuration"
  type = object({
    vm_size    = string
    node_count = number
    min_count  = number
    max_count  = number
  })
  default = {
    vm_size    = "Standard_D4s_v5"
    node_count = 3
    min_count  = 3
    max_count  = 9
  }
}

variable "workload_node_pool" {
  description = "Workload node pool configuration"
  type = object({
    vm_size    = string
    min_count  = number
    max_count  = number
    node_taints = list(string)
    node_labels = map(string)
  })
  default = {
    vm_size     = "Standard_D8s_v5"
    min_count   = 3
    max_count   = 30
    node_taints = []
    node_labels = { "workload-type" = "application" }
  }
}

variable "spot_node_pool" {
  description = "Spot node pool for cost-optimised non-critical workloads"
  type = object({
    enabled    = bool
    vm_size    = string
    min_count  = number
    max_count  = number
  })
  default = {
    enabled   = false  # Enable in prod; disable in dev
    vm_size   = "Standard_D4s_v5"
    min_count = 0
    max_count = 20
  }
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID for AKS diagnostics"
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for AKS private cluster"
  type        = string
  default     = "System" # Let AKS create its own private DNS zone
}

variable "tags" {
  description = "Resource tags (merged with mandatory tags)"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# Get current Azure client config for OIDC federation setup
data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name

  # Kubernetes version — pin to LTS, upgrade via pipeline
  kubernetes_version = var.kubernetes_version

  # Node resource group name (override default MC_ naming)
  node_resource_group = var.node_resource_group

  # DNS prefix for the Kubernetes API FQDN
  dns_prefix_private_cluster = "${var.cluster_name}-api"

  # ---------------------------------------------------------------------------
  # Private Cluster — API server not exposed to public internet
  # Required for Zero Trust compliance (CC6.3)
  # ---------------------------------------------------------------------------
  private_cluster_enabled             = true
  private_dns_zone_id                 = var.private_dns_zone_id
  private_cluster_public_fqdn_enabled = false

  # ---------------------------------------------------------------------------
  # System Node Pool — runs Kubernetes system pods (kube-system, etc.)
  # Must use on-demand VMs (no spot) for reliability
  # Spread across availability zones for HA
  # ---------------------------------------------------------------------------
  default_node_pool {
    name           = "system"
    vm_size        = var.system_node_pool.vm_size
    node_count     = var.system_node_pool.node_count
    min_count      = var.system_node_pool.min_count
    max_count      = var.system_node_pool.max_count
    vnet_subnet_id = var.vnet_subnet_id

    # Availability zones — spread across 3 AZs for HA
    zones = ["1", "2", "3"]

    # Node OS disk — ephemeral for better IOPS and no extra cost
    os_disk_type          = "Ephemeral"
    os_disk_size_gb       = 128
    os_sku                = "AzureLinux" # Microsoft's hardened Linux distro

    # Auto-scaling
    enable_auto_scaling   = true

    # Only run system pods on this pool
    only_critical_addons_enabled = true

    # Node labels
    node_labels = {
      "node-role"     = "system"
      "workload-type" = "system"
    }

    # Upgrade settings — 33% surge allows rolling upgrades
    upgrade_settings {
      max_surge = "33%"
    }

    tags = var.tags
  }

  # ---------------------------------------------------------------------------
  # Networking — Cilium CNI
  # azure: uses Azure IPAM with Cilium overlay for pod IPs
  # ---------------------------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # Required for Cilium overlay mode
    network_policy      = "cilium"  # AKS-managed Cilium network policy
    ebpf_data_plane     = "cilium"  # Enable Cilium eBPF data plane

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    # Load balancer SKU must be Standard for zone-redundant configurations
    load_balancer_sku = "standard"

    # Outbound type: User-defined routes for traffic via Azure Firewall
    outbound_type = "userDefinedRouting"
  }

  # ---------------------------------------------------------------------------
  # Identity — System-assigned managed identity
  # Used for AKS control plane operations (ACR pull, VNet peering, etc.)
  # ---------------------------------------------------------------------------
  identity {
    type = "SystemAssigned"
  }

  # ---------------------------------------------------------------------------
  # Entra ID RBAC — replaces legacy certificate-based admin
  # Admin access restricted to specific Entra ID groups
  # ---------------------------------------------------------------------------
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
    tenant_id              = data.azurerm_client_config.current.tenant_id
  }

  # ---------------------------------------------------------------------------
  # OIDC Issuer + Workload Identity
  # Required for pods to authenticate with Azure services without secrets
  # (Replaces Pod Identity / AAD Pod Identity — deprecated)
  # ---------------------------------------------------------------------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # ---------------------------------------------------------------------------
  # Key Vault Secrets Store CSI Driver
  # Mounts Vault/Key Vault secrets as files in pod volumes
  # Eliminates need for secrets in environment variables
  # ---------------------------------------------------------------------------
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m" # Re-sync secrets every 2 minutes
  }

  # ---------------------------------------------------------------------------
  # Microsoft Defender for Containers (CWPP component of CNAPP)
  # ---------------------------------------------------------------------------
  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  # ---------------------------------------------------------------------------
  # Auto-upgrade — patch channel updates node OS automatically
  # ---------------------------------------------------------------------------
  automatic_channel_upgrade = "patch" # Auto-apply patch releases

  node_os_channel_upgrade = "NodeImage" # Upgrade node OS images automatically

  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 3, 4] # Maintenance window: Sunday 02:00-04:00 UTC
    }
  }

  # ---------------------------------------------------------------------------
  # Monitoring — Container Insights
  # ---------------------------------------------------------------------------
  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  # ---------------------------------------------------------------------------
  # Azure Monitor managed Prometheus
  # ---------------------------------------------------------------------------
  azure_monitor_option {
    enabled = true
  }

  # ---------------------------------------------------------------------------
  # Disk encryption — Customer Managed Key via Key Vault
  # SOC 2 C1.1 — data encryption at rest
  # ---------------------------------------------------------------------------
  disk_encryption_set_id = azurerm_disk_encryption_set.aks.id

  # ---------------------------------------------------------------------------
  # API server access profile — restrict to VNet + management CIDRs only
  # ---------------------------------------------------------------------------
  api_server_access_profile {
    authorized_ip_ranges     = [] # Private cluster — IP ranges not applicable
    vnet_integration_enabled = true
    subnet_id                = var.vnet_subnet_id
  }

  # Prevent accidental deletion (Terraform lifecycle guard)
  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # Managed by cluster autoscaler
      kubernetes_version,              # Managed by upgrade pipeline
    ]
    prevent_destroy = false # Set to true for production after initial deploy
  }

  tags = merge(var.tags, {
    "resource-type" = "aks-cluster"
    "k8s-version"   = var.kubernetes_version
  })
}

# -----------------------------------------------------------------------------
# Workload Node Pool — Application pods
# Separate from system pool to avoid resource contention
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  name                  = "workload"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.workload_node_pool.vm_size
  vnet_subnet_id        = var.vnet_subnet_id

  # Availability zones
  zones = ["1", "2", "3"]

  # Auto-scaling
  enable_auto_scaling = true
  min_count           = var.workload_node_pool.min_count
  max_count           = var.workload_node_pool.max_count

  # Node configuration
  os_disk_type    = "Ephemeral"
  os_disk_size_gb = 256
  os_sku          = "AzureLinux"

  # Labels for pod scheduling
  node_labels = merge(var.workload_node_pool.node_labels, {
    "node-role" = "workload"
  })

  node_taints = var.workload_node_pool.node_taints

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Spot Node Pool — Cost-optimised for fault-tolerant batch / dev workloads
# NOT suitable for stateful services or T24-critical paths
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.spot_node_pool.enabled ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.spot_node_pool.vm_size
  vnet_subnet_id        = var.vnet_subnet_id

  zones = ["1", "2", "3"]

  # Spot configuration
  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # Pay the current spot price up to the on-demand price

  enable_auto_scaling = true
  min_count           = var.spot_node_pool.min_count
  max_count           = var.spot_node_pool.max_count

  os_disk_type = "Ephemeral"
  os_sku       = "AzureLinux"

  node_labels = {
    "node-role"       = "spot"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  # Taint spot nodes so only tolerant pods schedule here
  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Disk Encryption Set — for AKS node OS and data disks (CMK)
# SOC 2 C1.1 — data at rest encryption with customer-managed keys
# -----------------------------------------------------------------------------
resource "azurerm_disk_encryption_set" "aks" {
  name                = "${var.cluster_name}-des"
  resource_group_name = var.resource_group_name
  location            = var.location
  key_vault_key_id    = azurerm_key_vault_key.aks_disk.id

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Key Vault key for disk encryption — RSA 4096
resource "azurerm_key_vault_key" "aks_disk" {
  name         = "${var.cluster_name}-disk-key"
  key_vault_id = var.key_vault_id  # Passed from security module
  key_type     = "RSA"
  key_size     = 4096

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  # Auto-rotate every 90 days (SOC 2 CC6.6)
  rotation_policy {
    automatic {
      time_before_expiry = "P30D"  # Rotate 30 days before expiry
    }
    expire_after         = "P90D" # 90-day key lifetime
    notify_before_expiry = "P29D"
  }
}

# Grant disk encryption set access to Key Vault
resource "azurerm_key_vault_access_policy" "des" {
  key_vault_id = var.key_vault_id
  tenant_id    = azurerm_disk_encryption_set.aks.identity[0].tenant_id
  object_id    = azurerm_disk_encryption_set.aks.identity[0].principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

# -----------------------------------------------------------------------------
# ACR Pull RBAC — Allow AKS to pull images from Azure Container Registry
# Uses managed identity (no registry credentials stored anywhere)
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_id  # Passed from registry module
  skip_service_principal_aad_check = true
}

# -----------------------------------------------------------------------------
# Diagnostic Settings — stream all AKS logs to Log Analytics
# Required for: SOC 2 CC4.1, CC7.1 | DORA Article 17 (audit logs)
# -----------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "${var.cluster_name}-diagnostics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Enable all log categories
  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit"           # All kubectl commands
  }
  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
  enabled_log {
    category = "cloud-controller-manager"
  }
  enabled_log {
    category = "guard"               # Entra ID auth events
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# -----------------------------------------------------------------------------
# Outputs — consumed by Helm providers and downstream modules
# -----------------------------------------------------------------------------
output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "kube_config" {
  description = "AKS cluster kubeconfig (sensitive)"
  value       = azurerm_kubernetes_cluster.this.kube_config[0]
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for Workload Identity federation"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity (for RBAC assignments)"
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "node_resource_group" {
  description = "Resource group name created for AKS nodes"
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}
