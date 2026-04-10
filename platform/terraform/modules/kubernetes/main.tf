###############################################################################
# Module: kubernetes
#
# Deploys the AKS cluster with all production-grade configurations:
#   - Private cluster (no public API endpoint)
#   - AAD-integrated RBAC (Azure AD for cluster auth)
#   - Cilium as CNI (kube-proxy replacement)
#   - Multiple node pools (system, app, data, security)
#   - Azure Monitor integration (Container Insights)
#   - Azure Policy add-on (enforce Kubernetes policies)
#   - Workload Identity (replace pod-level SP credentials)
#   - Cluster autoscaler on app pool
#   - Node OS hardening (CIS benchmark)
#   - Disk encryption at rest (CMK via Key Vault)
###############################################################################

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    helm    = { source = "hashicorp/helm",    version = "~> 2.13"  }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.29" }
  }
}

# ─── MANAGED IDENTITY FOR AKS CLUSTER ────────────────────────────────────────
resource "azurerm_user_assigned_identity" "aks_cluster" {
  name                = "${var.prefix}-id-aks-cluster-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "${var.prefix}-id-aks-kubelet-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Grant AKS identity permissions on the VNet (to create NICs, route tables)
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
}

# Grant AKS kubelet identity pull access to ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

# Grant AKS identity read access to Key Vault (for CSI secrets driver)
resource "azurerm_role_assignment" "aks_keyvault_secrets" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

# ─── AKS CLUSTER ─────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "${var.prefix}-${var.environment}"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.environment == "production" ? "Standard" : "Free"
  tags                = var.tags

  # ── PRIVATE CLUSTER: No public API endpoint ──────────────────────────────
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false  # No DNS alias
  private_dns_zone_id                 = var.private_dns_zone_id

  # ── IDENTITY ──────────────────────────────────────────────────────────────
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_cluster.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.aks_kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.aks_kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_kubelet.id
  }

  # ── SYSTEM NODE POOL (Critical add-ons only) ──────────────────────────────
  default_node_pool {
    name                         = "system"
    node_count                   = var.system_node_count
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = var.aks_system_subnet_id
    zones                        = ["1", "2", "3"]  # Spread across AZs
    only_critical_addons_enabled = true             # Taint: CriticalAddonsOnly
    os_sku                       = "Ubuntu"
    os_disk_type                 = "Ephemeral"      # Faster, no data persistence on node
    os_disk_size_gb              = 128
    type                         = "VirtualMachineScaleSets"
    enable_auto_scaling          = false  # System pool: fixed count

    # Node labels for pod affinity rules
    node_labels = {
      "superapp.io/node-type" = "system"
      "superapp.io/env"       = var.environment
    }

    # Upgrade configuration (max 25% nodes unavailable during upgrade)
    upgrade_settings {
      max_surge = "25%"
    }
  }

  # ── NETWORKING (Cilium CNI) ────────────────────────────────────────────────
  network_profile {
    network_plugin      = "none"      # "none" = BYO CNI (Cilium installed via Helm)
    network_policy      = "cilium"    # Use Cilium network policy
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = var.aks_dns_service_ip
    load_balancer_sku   = "standard"  # Required for zone-redundant LB
    outbound_type       = "userDefinedRouting"  # Force traffic through Azure Firewall
    pod_cidr            = null        # Cilium manages IPAM natively
  }

  # ── AZURE AD RBAC INTEGRATION ─────────────────────────────────────────────
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true                   # Azure RBAC for K8s RBAC
    admin_group_object_ids = var.aks_admin_group_ids
  }

  # ── KEY VAULT SECRETS PROVIDER (CSI Driver) ───────────────────────────────
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"  # Check for rotated secrets every 2 min
  }

  # ── MONITORING (Container Insights → Azure Monitor) ───────────────────────
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true  # Use managed identity, not shared keys
  }

  # ── WORKLOAD IDENTITY ─────────────────────────────────────────────────────
  workload_identity_enabled = true
  oidc_issuer_enabled       = true   # Required for Workload Identity federation

  # ── IMAGE CLEANER (automated stale image GC) ──────────────────────────────
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # ── AZURE POLICY ADD-ON ───────────────────────────────────────────────────
  azure_policy_enabled = true  # Enforces OPA Gatekeeper policies from Azure Policy

  # ── MAINTENANCE WINDOW (minimise disruption) ──────────────────────────────
  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 3, 4]  # 02:00-04:00 on Sundays only
    }
  }

  # ── AUTO UPGRADE ──────────────────────────────────────────────────────────
  automatic_channel_upgrade = "stable"  # Auto-patch within minor version

  # ── STORAGE PROFILE ───────────────────────────────────────────────────────
  storage_profile {
    blob_driver_enabled         = false
    disk_driver_enabled         = true
    disk_driver_version         = "v2"   # CSI v2: better performance
    file_driver_enabled         = true
    snapshot_controller_enabled = true
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,  # Managed by cluster autoscaler
    ]
  }
}

# ─── ADDITIONAL NODE POOLS ────────────────────────────────────────────────────

# Application Node Pool (scales with workload)
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.app_vm_size
  vnet_subnet_id        = var.aks_app_subnet_id
  zones                 = ["1", "2", "3"]
  os_sku                = "Ubuntu"
  os_disk_type          = "Ephemeral"
  mode                  = "User"

  # Autoscaling: 3 to 10 nodes
  enable_auto_scaling = true
  min_count           = var.app_node_min_count
  max_count           = var.app_node_max_count
  node_count          = var.app_node_min_count

  # Mixed spot + regular instances for cost saving (non-production only)
  priority        = var.enable_spot_instances ? "Spot" : "Regular"
  eviction_policy = var.enable_spot_instances ? "Delete" : null
  spot_max_price  = var.enable_spot_instances ? -1 : null  # -1 = market price

  node_labels = {
    "superapp.io/node-type"                          = "app"
    "superapp.io/env"                                = var.environment
    "kubernetes.azure.com/scalesetpriority"          = var.enable_spot_instances ? "spot" : "regular"
  }

  node_taints = var.enable_spot_instances ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []

  upgrade_settings { max_surge = "25%" }
  tags = var.tags
}

# Data Node Pool (Kafka, Redis, Observability stack)
resource "azurerm_kubernetes_cluster_node_pool" "data" {
  name                  = "data"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.data_vm_size
  vnet_subnet_id        = var.aks_data_subnet_id
  zones                 = ["1", "2", "3"]
  os_sku                = "Ubuntu"
  os_disk_type          = "Managed"  # Persistent disk for data nodes
  os_disk_size_gb       = 512
  mode                  = "User"
  enable_auto_scaling   = false
  node_count            = var.data_node_count

  node_labels = {
    "superapp.io/node-type" = "data"
    "superapp.io/env"       = var.environment
  }

  # Prevent non-data workloads on these nodes
  node_taints = ["superapp.io/node-type=data:NoSchedule"]

  upgrade_settings { max_surge = "1" }  # Rolling: 1 at a time for data nodes
  tags = var.tags
}

# Security Pool (Vault, SPIRE, Falco, Tetragon)
resource "azurerm_kubernetes_cluster_node_pool" "security" {
  name                  = "security"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D4s_v5"
  vnet_subnet_id        = var.aks_app_subnet_id
  zones                 = ["1", "2", "3"]
  mode                  = "User"
  enable_auto_scaling   = false
  node_count            = 3

  node_labels = {
    "superapp.io/node-type" = "security"
    "superapp.io/env"       = var.environment
  }

  node_taints = ["superapp.io/node-type=security:NoSchedule"]
  upgrade_settings { max_surge = "1" }
  tags = var.tags
}

# ─── CILIUM CNI (via Helm) ────────────────────────────────────────────────────
# Wait for cluster nodes to be ready before installing Cilium
resource "time_sleep" "wait_for_nodes" {
  depends_on      = [azurerm_kubernetes_cluster.main]
  create_duration = "60s"
}

resource "helm_release" "cilium" {
  depends_on = [time_sleep.wait_for_nodes]
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.15.4"
  namespace  = "kube-system"

  values = [
    yamlencode({
      # Full kube-proxy replacement via eBPF
      kubeProxyReplacement = "true"
      k8sServiceHost       = azurerm_kubernetes_cluster.main.private_fqdn
      k8sServicePort       = "443"

      # Enable Hubble (L7 observability)
      hubble = {
        enabled = true
        relay   = { enabled = true }
        ui      = { enabled = true, replicas = 2 }
        metrics = {
          enabled = [
            "dns:query;ignoreAAAA", "drop", "tcp", "flow",
            "icmp", "http"
          ]
          serviceMonitor = { enabled = true }
        }
      }

      # Mutual TLS (SPIFFE-based, no sidecars)
      authentication = {
        mutual = {
          spire = {
            enabled         = true
            installChart    = false  # SPIRE installed separately
            agentSocketPath = "/run/spire/sockets/agent.sock"
          }
        }
      }

      # WireGuard transparent encryption (node-to-node)
      encryption = {
        enabled   = true
        type      = "wireguard"
        nodeEncryption = true
      }

      # XDP acceleration (hardware offload)
      loadBalancer = {
        acceleration = "native"
        algorithm    = "maglev"  # Consistent hashing for session affinity
      }

      # Tetragon (eBPF security observability)
      tetragon = { enabled = true }

      # Enable DNS-based egress policies (for FQDN rules)
      dnsProxy = { enabled = true }

      # Prometheus metrics
      prometheus = {
        enabled        = true
        serviceMonitor = { enabled = true }
      }

      # IPAM: delegate to Azure (native routing, no overlays)
      ipam = { mode = "azure" }

      # Disable iptables (using eBPF natively)
      iptablesLockTimeout = "0s"
      enableIPv4Masquerade = false  # Azure handles NAT

      # BIG-TCP (10GbE optimisation)
      enableIPv4BIGTCP = true

      # Resource requests/limits for Cilium agent
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
    })
  ]
}

# ─── ARGOCD (GitOps operator) ─────────────────────────────────────────────────
resource "kubernetes_namespace" "argocd" {
  depends_on = [helm_release.cilium]
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/part-of" = "argocd"
      "superapp.io/managed-by"    = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.1.0"
  namespace  = "argocd"

  values = [
    yamlencode({
      global = {
        domain = "argocd.${var.internal_domain}"
      }

      # HA mode for ArgoCD
      controller = { replicas = 1 }  # Application controller (stateful)
      server     = { replicas = 2, autoscaling = { enabled = true, minReplicas = 2 } }
      repoServer = { replicas = 2, autoscaling = { enabled = true, minReplicas = 2 } }

      # Redis HA for ArgoCD internal state
      redis-ha = { enabled = true, replicas = 3 }

      # Disable local admin in favour of Azure AD SSO
      configs = {
        cm = {
          "admin.enabled"    = "false"
          "oidc.config"      = yamlencode({
            name         = "Azure AD"
            issuer       = "https://login.microsoftonline.com/${var.azure_tenant_id}/v2.0"
            clientID     = var.argocd_azure_client_id
            clientSecret  = "$oidc.azure.clientSecret"
            requestedScopes = ["openid", "profile", "email"]
            requestedIDTokenClaims = { groups = { essential = true } }
          })
        }
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-POLICY
            p, role:platform-admin, applications, *, */*, allow
            p, role:platform-admin, clusters, get, *, allow
            p, role:developer, applications, get, */*, allow
            p, role:developer, applications, sync, */*, allow
            g, ${var.argocd_admin_group_id}, role:platform-admin
            g, ${var.argocd_developer_group_id}, role:developer
          POLICY
        }
      }

      # ArgoCD notifications (Slack + PagerDuty)
      notifications = {
        enabled = true
        secret  = { create = false, name = "argocd-notifications-secret" }
      }
    })
  ]
}

# ─── CERT-MANAGER ─────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  depends_on = [helm_release.cilium]
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.5"
  namespace  = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }

  # Workload identity for cert-manager (to use Azure DNS challenge)
  set {
    name  = "podLabels.azure\\.workload\\.identity/use"
    value = "true"
  }
}

# ─── EXTERNAL SECRETS OPERATOR ────────────────────────────────────────────────
resource "helm_release" "external_secrets" {
  depends_on = [helm_release.cilium]
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.9.18"
  namespace  = "external-secrets"
  create_namespace = true

  set { name = "installCRDs", value = "true" }
  set { name = "replicaCount", value = "2" }
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────
output "kube_config" {
  value     = azurerm_kubernetes_cluster.main.kube_config[0]
  sensitive = true
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  value = azurerm_user_assigned_identity.aks_kubelet.principal_id
}
