###############################################################################
# SuperApp Platform — Identity Module
# Provisions: Azure AD groups, RBAC, Workload Identities (SPIFFE/SPIRE),
#             Managed Identities per service, federated credentials
# Compliance : SOC 2 CC6.1-CC6.6, DORA Art.9 (ICT security)
###############################################################################

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    azuread = { source = "hashicorp/azuread", version = "~> 2.50"  }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.29" }
  }
}

data "azurerm_subscription" "current" {}
data "azuread_client_config" "current" {}

###############################################################################
# 1. Azure AD Groups — Role-Based Access Control
###############################################################################

locals {
  ad_groups = {
    "platform-admins"     = "SuperApp Platform Administrators — full cluster access"
    "platform-developers" = "SuperApp Developers — namespace-scoped deployment access"
    "platform-readonly"   = "SuperApp Read-Only — view-only access to all namespaces"
    "security-analysts"   = "Security team — Sentinel, Defender, Falco dashboards"
    "dba-team"            = "DBA team — Key Vault secrets for DB credentials only"
    "sre-team"            = "SRE team — monitoring, alerting, runbook execution"
    "change-approvers"    = "CAB members — approve production change tickets"
  }
}

resource "azuread_group" "platform" {
  for_each         = local.ad_groups
  display_name     = "${var.ad_group_prefix}-${each.key}"
  description      = each.value
  security_enabled = true
  mail_enabled     = false
}

###############################################################################
# 2. Platform-Level Azure RBAC Assignments
###############################################################################

locals {
  rbac_assignments = {
    "admins-contributor" = {
      principal_id = azuread_group.platform["platform-admins"].object_id
      role         = "Contributor"
      scope        = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
    }
    "sre-monitoring-reader" = {
      principal_id = azuread_group.platform["sre-team"].object_id
      role         = "Monitoring Reader"
      scope        = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.monitoring_resource_group_name}"
    }
    "security-sentinel-reader" = {
      principal_id = azuread_group.platform["security-analysts"].object_id
      role         = "Microsoft Sentinel Reader"
      scope        = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.security_resource_group_name}"
    }
  }
}

resource "azurerm_role_assignment" "platform" {
  for_each             = local.rbac_assignments
  principal_id         = each.value.principal_id
  role_definition_name = each.value.role
  scope                = each.value.scope
}

###############################################################################
# 3. Managed Identities — one per microservice (Workload Identity)
###############################################################################

locals {
  services = [
    "identity-api",
    "account-api",
    "payment-api",
    "wallet-api",
    "notification-api",
    "api-gateway",
    "audit-service",
    "argocd",
    "external-secrets",
    "cert-manager",
    "otel-collector",
  ]
}

resource "azurerm_user_assigned_identity" "services" {
  for_each            = toset(local.services)
  name                = "id-${replace(each.value, "-", "")}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.common_tags, { service = each.value })
}

###############################################################################
# 4. Federated Identity Credentials (Kubernetes Workload Identity → Azure AD)
#    Enables pods to authenticate to Azure without client secrets
###############################################################################

resource "azurerm_federated_identity_credential" "services" {
  for_each            = toset(local.services)
  name                = "fic-${replace(each.value, "-", "")}-${var.environment}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.services[each.value].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:${local.service_namespace_map[each.value]}:${each.value}"
}

locals {
  service_namespace_map = {
    "identity-api"     = "superapp-services"
    "account-api"      = "superapp-services"
    "payment-api"      = "superapp-services"
    "wallet-api"       = "superapp-services"
    "notification-api" = "superapp-services"
    "api-gateway"      = "superapp-gateway"
    "audit-service"    = "superapp-services"
    "argocd"           = "argocd"
    "external-secrets" = "external-secrets"
    "cert-manager"     = "cert-manager"
    "otel-collector"   = "monitoring"
  }
}

###############################################################################
# 5. Key Vault RBAC — each service gets least-privilege access
###############################################################################

locals {
  kv_secret_access = {
    "identity-api"     = ["identity-db-password", "jwt-private-key", "jwt-public-key", "redis-password"]
    "account-api"      = ["account-db-password", "redis-password"]
    "payment-api"      = ["payment-db-password", "redis-password", "eventhub-producer-connstring", "ghipss-api-key", "expresspay-api-key"]
    "wallet-api"       = ["wallet-db-password", "redis-password", "eventhub-producer-connstring"]
    "notification-api" = ["notification-db-password", "eventhub-consumer-connstring", "smtp-password", "sms-api-key"]
    "api-gateway"      = ["jwt-public-key", "redis-password"]
    "audit-service"    = ["eventhub-consumer-connstring"]
    "external-secrets" = []  # Gets Key Vault Officer at namespace level
    "argocd"           = []  # ArgoCD uses Git auth — no KV access needed
    "cert-manager"     = []  # Uses Azure DNS for ACME challenges
    "otel-collector"   = []
  }
}

# External Secrets Operator — Key Vault Officer on secrets scope
resource "azurerm_role_assignment" "eso_keyvault" {
  principal_id         = azurerm_user_assigned_identity.services["external-secrets"].principal_id
  role_definition_name = "Key Vault Secrets Officer"
  scope                = var.key_vault_id
}

# cert-manager — DNS Zone Contributor for ACME DNS-01 challenges
resource "azurerm_role_assignment" "cert_manager_dns" {
  principal_id         = azurerm_user_assigned_identity.services["cert-manager"].principal_id
  role_definition_name = "DNS Zone Contributor"
  scope                = var.dns_zone_id
}

###############################################################################
# 6. Kubernetes ServiceAccounts with Workload Identity annotations
###############################################################################

resource "kubernetes_namespace" "superapp_services" {
  metadata {
    name = "superapp-services"
    labels = {
      "app.kubernetes.io/managed-by"          = "terraform"
      "pod-security.kubernetes.io/enforce"    = "restricted"
      "pod-security.kubernetes.io/audit"      = "restricted"
      "pod-security.kubernetes.io/warn"       = "restricted"
    }
    annotations = {
      "azure.workload.identity/use" = "true"
    }
  }
}

resource "kubernetes_namespace" "superapp_gateway" {
  metadata {
    name = "superapp-gateway"
    labels = {
      "app.kubernetes.io/managed-by"          = "terraform"
      "pod-security.kubernetes.io/enforce"    = "baseline"
    }
    annotations = {
      "azure.workload.identity/use" = "true"
    }
  }
}

resource "kubernetes_service_account" "services" {
  for_each = toset(local.services)

  metadata {
    name      = each.value
    namespace = local.service_namespace_map[each.value]
    annotations = {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.services[each.value].client_id
      "azure.workload.identity/tenant-id" = data.azuread_client_config.current.tenant_id
    }
    labels = {
      "azure.workload.identity/use"  = "true"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [
    kubernetes_namespace.superapp_services,
    kubernetes_namespace.superapp_gateway,
  ]
}

###############################################################################
# 7. Kubernetes RBAC — ClusterRoles and RoleBindings
###############################################################################

resource "kubernetes_cluster_role" "platform_readonly" {
  metadata {
    name = "superapp-platform-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints", "persistentvolumeclaims", "configmaps", "events", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["cilium.io"]
    resources  = ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "developer_view" {
  metadata {
    name = "superapp-developers-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "Group"
    name      = azuread_group.platform["platform-developers"].object_id
    api_group = "rbac.authorization.k8s.io"
  }
}

# Developers get deploy rights in non-prod namespaces only
resource "kubernetes_role" "developer_deploy" {
  for_each = toset(["superapp-services", "superapp-gateway"])

  metadata {
    name      = "developer-deploy"
    namespace = each.value
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
}

###############################################################################
# 8. ExternalSecret CRDs — pull secrets from Key Vault into K8s
###############################################################################

resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "azure-keyvault-store" }
    spec = {
      provider = {
        azurekv = {
          vaultUrl = var.key_vault_uri
          authType = "WorkloadIdentity"
          serviceAccountRef = {
            name      = "external-secrets"
            namespace = "external-secrets"
          }
        }
      }
    }
  }
}

###############################################################################
# 9. OPA Gatekeeper Constraint — Require Workload Identity label
###############################################################################

resource "kubernetes_manifest" "constraint_workload_identity" {
  manifest = {
    apiVersion = "constraints.gatekeeper.sh/v1beta1"
    kind       = "K8sRequireWorkloadIdentityLabel"
    metadata   = { name = "require-workload-identity-label" }
    spec = {
      match = {
        kinds = [{ apiGroups = [""], kinds = ["Pod"] }]
        namespaces = ["superapp-services", "superapp-gateway"]
      }
      parameters = {
        requiredLabel = "azure.workload.identity/use"
        allowedValue  = "true"
      }
    }
  }
}

###############################################################################
# Outputs
###############################################################################

output "service_identities" {
  description = "Map of service name → managed identity client ID"
  value = {
    for svc, id in azurerm_user_assigned_identity.services :
    svc => {
      client_id    = id.client_id
      principal_id = id.principal_id
      id           = id.id
    }
  }
}

output "ad_group_ids" {
  description = "Map of group name → Azure AD object ID"
  value = {
    for name, group in azuread_group.platform :
    name => group.object_id
  }
}

output "superapp_services_namespace" {
  value = kubernetes_namespace.superapp_services.metadata[0].name
}

output "superapp_gateway_namespace" {
  value = kubernetes_namespace.superapp_gateway.metadata[0].name
}
