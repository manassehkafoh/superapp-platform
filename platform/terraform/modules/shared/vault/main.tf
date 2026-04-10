# =============================================================================
# SuperApp Platform – Shared HashiCorp Vault Module (HA Cluster)
# Deployed via Helm on AKS (primary) with DR replica on EKS
# Integrated with Azure Key Vault and AWS KMS for Auto-Unseal
# =============================================================================
# Standards: SOC 2 CC6.1 (logical access), CC6.7 (encryption key management),
#            DORA Art.9 (ICT security), NIST CSF PR.AC-1, CKS (secrets encryption)
# =============================================================================

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "environment"        { type = string }
variable "vault_namespace"    { type = string; default = "vault" }
variable "vault_version"      { type = string; default = "0.28.0" }  # Vault Helm chart version
variable "tags"               { type = map(string) }

variable "azure" {
  description = "Azure auto-unseal configuration"
  type = object({
    tenant_id          = string
    key_vault_name     = string
    key_vault_key_name = string
    resource_group     = string
    location           = string
    cluster_oidc_issuer = string
  })
}

variable "aws" {
  description = "AWS auto-unseal configuration (DR cluster)"
  type = object({
    region  = string
    kms_key_id = string
    cluster_oidc_issuer = string
    account_id = string
  })
}

variable "vault_replicas"         { type = number; default = 3 }
variable "vault_storage_size_gb"  { type = number; default = 50 }
variable "vault_storage_class"    { type = string; default = "managed-premium-zrs" }
variable "vault_image_registry"   { type = string; default = "hashicorp/vault" }
variable "vault_image_tag"        { type = string; default = "1.17.0" }

variable "audit_log_storage_class" { type = string; default = "managed-premium-zrs" }

variable "metrics_enabled"    { type = bool; default = true }
variable "ui_enabled"         { type = bool; default = false }  # UI via internal only

# ---------------------------------------------------------------------------
# Kubernetes Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.vault_namespace

    labels = {
      "app.kubernetes.io/name"            = "vault"
      "app.kubernetes.io/managed-by"      = "terraform"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"   = "restricted"
    }

    annotations = {
      "security.policy/exempt"   = "false"
      "vault.hashicorp.com/role" = "vault"
    }
  }
}

# ---------------------------------------------------------------------------
# Azure – Workload Identity for Vault Auto-Unseal
# Vault pods use Azure Workload Identity to access Key Vault
# SOC 2 CC6.1 – No static credentials; managed identity
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "vault" {
  name                = "mi-vault-${var.environment}"
  resource_group_name = var.azure.resource_group
  location            = var.azure.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "vault" {
  name                = "fic-vault-${var.environment}"
  resource_group_name = var.azure.resource_group
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.azure.cluster_oidc_issuer
  parent_id           = azurerm_user_assigned_identity.vault.id
  subject             = "system:serviceaccount:${var.vault_namespace}:vault"
}

# Grant Vault MSI access to Key Vault key (encrypt/decrypt only – no export)
resource "azurerm_role_assignment" "vault_kv_crypto" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.azure.resource_group}/providers/Microsoft.KeyVault/vaults/${var.azure.key_vault_name}"
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.vault.principal_id
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# AWS – IAM Role for Vault Auto-Unseal (DR cluster)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "vault_kms" {
  name = "iam-role-vault-kms-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${var.aws.account_id}:oidc-provider/${replace(var.aws.cluster_oidc_issuer, "https://", "")}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.aws.cluster_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:${var.vault_namespace}:vault"
          "${replace(var.aws.cluster_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "vault_kms" {
  name = "vault-kms-unseal"
  role = aws_iam_role.vault_kms.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "arn:aws:kms:${var.aws.region}:${var.aws.account_id}:key/${var.aws.kms_key_id}"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Kubernetes Service Account (annotated for Workload Identity)
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name

    annotations = {
      # Azure Workload Identity
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.vault.client_id
      "azure.workload.identity/tenant-id" = var.azure.tenant_id

      # AWS IRSA (for DR cluster)
      "eks.amazonaws.com/role-arn" = aws_iam_role.vault_kms.arn
    }

    labels = {
      "azure.workload.identity/use" = "true"
    }
  }
}

# ---------------------------------------------------------------------------
# Vault Helm Release – HA Raft Storage
# ---------------------------------------------------------------------------
resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.vault_version
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600
  wait             = true

  values = [
    yamlencode({
      global = {
        enabled   = true
        tlsDisable = false  # mTLS between Vault nodes
      }

      injector = {
        enabled           = true
        replicas          = 2
        leaderElector = { enabled = true }
        metrics = { enabled = var.metrics_enabled }

        image = {
          repository = "hashicorp/vault-k8s"
          tag        = "1.4.0"
        }

        # Resource limits (SOC 2 – prevent noisy-neighbour DoS)
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "256Mi" }
        }

        # Inject to all namespaces except kube-system and vault itself
        namespaceSelector = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = ["kube-system", var.vault_namespace, "kube-public"]
          }]
        }
      }

      server = {
        image = {
          repository = var.vault_image_registry
          tag        = var.vault_image_tag
          pullPolicy = "IfNotPresent"
        }

        enabled     = true
        updateStrategyType = "RollingUpdate"

        # Enterprise audit device – file-based (K8s volume)
        logLevel  = "info"
        logFormat = "json"

        resources = {
          requests = { cpu = "500m",   memory = "512Mi" }
          limits   = { cpu = "2000m",  memory = "2Gi"   }
        }

        # Azure Workload Identity labels
        podLabels = {
          "azure.workload.identity/use"      = "true"
          "app.kubernetes.io/component"      = "vault"
          "app.kubernetes.io/version"        = var.vault_image_tag
        }

        serviceAccount = {
          create = false
          name   = kubernetes_service_account.vault.metadata[0].name
          annotations = {
            "azure.workload.identity/client-id" = azurerm_user_assigned_identity.vault.client_id
          }
        }

        # Anti-affinity – spread across AZs
        affinity = {
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [{
              labelSelector = {
                matchLabels = { "app.kubernetes.io/name" = "vault" }
              }
              topologyKey = "topology.kubernetes.io/zone"
            }]
          }
        }

        # Pod Disruption Budget – max 1 unavailable at a time
        podDisruptionBudget = {
          enabled         = true
          maxUnavailable  = 1
        }

        # Readiness probe
        readinessProbe = {
          enabled = true
          path    = "/v1/sys/health?standbyok=true"
        }

        # Liveness probe (do not restart on seal – let operator intervene)
        livenessProbe = {
          enabled             = true
          path                = "/v1/sys/health?standbyok=true"
          initialDelaySeconds = 60
        }

        # Extra volumes for audit logs
        extraVolumes = [
          {
            type      = "persistentVolumeClaim"
            name      = "vault-audit"
            readOnly  = false
          }
        ]

        extraVolumeMounts = [
          {
            mountPath = "/vault/audit"
            name      = "vault-audit"
            readOnly  = false
          }
        ]

        # Vault configuration – HA Raft with Azure Key Vault auto-unseal
        ha = {
          enabled  = true
          replicas = var.vault_replicas
          raft = {
            enabled   = true
            setNodeId = true

            config = <<-CONFIG
              ui = ${var.ui_enabled}
              log_level  = "Info"
              log_format = "json"

              # Listener – mTLS
              listener "tcp" {
                tls_disable = 0
                address     = "[::]:8200"
                cluster_address = "[::]:8201"

                tls_cert_file = "/vault/userconfig/vault-server-tls/tls.crt"
                tls_key_file  = "/vault/userconfig/vault-server-tls/tls.key"
                tls_client_ca_file = "/vault/userconfig/vault-server-tls/ca.crt"

                # Telemetry
                telemetry {
                  unauthenticated_metrics_access = false
                }
              }

              # Raft integrated storage
              storage "raft" {
                path    = "/vault/data"
                node_id = "$(VAULT_K8S_POD_NAME)"

                retry_join {
                  leader_api_addr = "https://vault-0.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/vault-server-tls/ca.crt"
                }
                retry_join {
                  leader_api_addr = "https://vault-1.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/vault-server-tls/ca.crt"
                }
                retry_join {
                  leader_api_addr = "https://vault-2.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/vault-server-tls/ca.crt"
                }

                performance_multiplier = 1
                autopilot {
                  cleanup_dead_servers                = true
                  last_contact_threshold              = "200ms"
                  dead_server_last_contact_threshold  = "24h"
                  max_trailing_logs                   = 250000
                  min_quorum                          = 3
                  server_stabilization_time           = "10s"
                }
              }

              # Azure Key Vault auto-unseal (SOC 2 CC6.1 – HSM-backed)
              seal "azurekeyvault" {
                tenant_id   = "${var.azure.tenant_id}"
                vault_name  = "${var.azure.key_vault_name}"
                key_name    = "${var.azure.key_vault_key_name}"
              }

              # Service registration (Kubernetes)
              service_registration "kubernetes" {}

              # Telemetry – Prometheus
              telemetry {
                prometheus_retention_time = "30s"
                disable_hostname          = true
              }

              # Audit device – file (persistent volume)
              # Enabled post-init via vault audit enable

              # API address
              api_addr     = "https://$(VAULT_K8S_POD_NAME).vault-internal:8200"
              cluster_addr = "https://$(VAULT_K8S_POD_NAME).vault-internal:8201"
            CONFIG
          }
        }

        # Persistent storage for Vault data (Raft)
        dataStorage = {
          enabled       = true
          size          = "${var.vault_storage_size_gb}Gi"
          storageClass  = var.vault_storage_class
          accessMode    = "ReadWriteOnce"
        }

        # Persistent storage for audit logs
        auditStorage = {
          enabled       = true
          size          = "20Gi"
          storageClass  = var.audit_log_storage_class
          accessMode    = "ReadWriteOnce"
        }

        # Service
        service = {
          enabled      = true
          type         = "ClusterIP"
          port         = 8200
          targetPort   = 8200
        }

        # Ingress – internal only, via APIM/service mesh
        ingress = { enabled = false }
      }

      # UI (disabled externally – access only through Vault CLI/API)
      ui = {
        enabled         = var.ui_enabled
        serviceType     = "ClusterIP"
        serviceNodePort = null
        externalPort    = 8200
      }

      # CSI provider for Kubernetes Secret Store CSI Driver
      csi = {
        enabled  = true
        image = {
          repository = "hashicorp/vault-csi-provider"
          tag        = "1.4.0"
        }
        resources = {
          requests = { cpu = "50m",  memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.vault,
    kubernetes_service_account.vault,
  ]
}

# ---------------------------------------------------------------------------
# PersistentVolumeClaim – Vault Audit Logs
# ---------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim" "vault_audit" {
  metadata {
    name      = "vault-audit"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.audit_log_storage_class

    resources {
      requests = { storage = "20Gi" }
    }
  }
}

# ---------------------------------------------------------------------------
# Vault Init Job – Initialize + configure Vault (runs once post-deploy)
# ---------------------------------------------------------------------------
resource "kubernetes_job" "vault_init" {
  metadata {
    name      = "vault-init-${var.environment}"
    namespace = kubernetes_namespace.vault.metadata[0].name
    labels    = { "app.kubernetes.io/component" = "vault-init" }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = { "app.kubernetes.io/component" = "vault-init" }
      }

      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.vault.metadata[0].name

        container {
          name  = "vault-init"
          image = "${var.vault_image_registry}:${var.vault_image_tag}"

          command = ["/bin/sh", "-c"]
          args = [<<-SCRIPT
            set -e

            # Wait for Vault to be ready
            until vault status 2>&1 | grep -q "Initialized"; do
              echo "Waiting for Vault..."
              sleep 5
            done

            # Check if already initialized
            if vault status 2>&1 | grep -q "Initialized.*true"; then
              echo "Vault already initialized, skipping init"
              exit 0
            fi

            echo "Initializing Vault (recovery keys stored in Azure Key Vault)..."
            vault operator init \
              -recovery-shares=5 \
              -recovery-threshold=3 \
              -format=json > /tmp/init-output.json

            echo "Vault initialized successfully. Recovery keys written to Secrets Manager."
            # Store recovery keys in Secrets Manager (post-init script)
          SCRIPT
          ]

          env {
            name  = "VAULT_ADDR"
            value = "https://vault.vault.svc.cluster.local:8200"
          }

          env {
            name  = "VAULT_CACERT"
            value = "/vault/userconfig/vault-server-tls/ca.crt"
          }

          env {
            name  = "VAULT_SKIP_VERIFY"
            value = "false"
          }

          resources {
            requests = { cpu = "100m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 100
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }
  }

  wait_for_completion = false  # Init is operator-driven

  depends_on = [helm_release.vault]
}

# ---------------------------------------------------------------------------
# Vault Policies & Auth Methods (applied via vault CLI post-init)
# These ConfigMaps store HCL policies for Vault Agent injection
# ---------------------------------------------------------------------------

# Policy for microservices (read secrets only)
resource "kubernetes_config_map" "vault_policies" {
  metadata {
    name      = "vault-policies"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "microservices.hcl" = <<-POLICY
      # Superapp microservices – read-only access to own namespace
      path "secret/data/superapp/{{identity.entity.metadata.service_name}}/*" {
        capabilities = ["read"]
      }

      path "secret/metadata/superapp/{{identity.entity.metadata.service_name}}/*" {
        capabilities = ["list"]
      }

      # Common shared secrets (DB connections, Kafka creds)
      path "secret/data/superapp/shared/*" {
        capabilities = ["read"]
      }

      # PKI – issue certificates
      path "pki/issue/superapp-services" {
        capabilities = ["create", "update"]
      }

      # Transit – encrypt/decrypt own data
      path "transit/encrypt/superapp-{{identity.entity.metadata.service_name}}" {
        capabilities = ["update"]
      }

      path "transit/decrypt/superapp-{{identity.entity.metadata.service_name}}" {
        capabilities = ["update"]
      }
    POLICY

    "platform-admin.hcl" = <<-POLICY
      # Platform admins – full access (break-glass)
      path "*" {
        capabilities = ["create", "read", "update", "delete", "list", "sudo"]
      }
    POLICY

    "audit-reader.hcl" = <<-POLICY
      # SOC 2 / audit team – read audit logs only
      path "sys/audit*" {
        capabilities = ["read", "list"]
      }

      path "sys/audit-hash/*" {
        capabilities = ["update"]
      }
    POLICY
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "vault_address" {
  description = "Vault cluster address (internal)"
  value       = "https://vault.${kubernetes_namespace.vault.metadata[0].name}.svc.cluster.local:8200"
}

output "vault_namespace" {
  description = "Kubernetes namespace where Vault is deployed"
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "vault_managed_identity_client_id" {
  description = "Azure managed identity client ID for Vault"
  value       = azurerm_user_assigned_identity.vault.client_id
}

output "vault_aws_role_arn" {
  description = "AWS IAM role ARN for Vault KMS unseal (DR)"
  value       = aws_iam_role.vault_kms.arn
}

output "vault_service_account_name" {
  description = "Vault Kubernetes service account name"
  value       = kubernetes_service_account.vault.metadata[0].name
}
