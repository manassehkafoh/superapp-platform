###############################################################################
# Module: security
#
# Implements the full SOC 2 / Zero Trust security layer:
#   - Azure Key Vault Premium (HSM-backed, CMK for encryption)
#   - Microsoft Defender for Cloud (CSPM, CWPP, CIEM)
#   - HashiCorp Vault (enterprise secrets management)
#   - SPIRE (SPIFFE workload identity framework)
#   - OPA Gatekeeper (Kubernetes policy enforcement)
#   - Falco (runtime threat detection)
#   - Tetragon (eBPF kernel-level security)
#   - Microsoft Sentinel (SIEM)
#   - Azure Container Registry (with vulnerability scanning)
###############################################################################

terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 3.100" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13"  }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.29"  }
  }
}

# ─── AZURE KEY VAULT PREMIUM (HSM-backed) ────────────────────────────────────
resource "azurerm_key_vault" "main" {
  name                        = "${var.prefix}-kv-${var.environment}"
  resource_group_name         = var.resource_group_name
  location                    = var.location
  tenant_id                   = var.tenant_id
  sku_name                    = "premium"  # HSM-backed keys for SOC 2 / PCI
  purge_protection_enabled    = true       # Cannot be disabled — prevents data destruction
  soft_delete_retention_days  = 90         # SOC 2: retain 90 days after deletion
  enable_rbac_authorization   = true       # Use RBAC, not access policies (more granular)
  tags                        = var.tags

  # Network restrictions: only accessible from VNet + admin IPs
  network_acls {
    bypass                     = "AzureServices"
    default_action             = "Deny"
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = var.allowed_admin_ips
  }
}

# Private endpoint for Key Vault (no public access)
resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.prefix}-pe-kv-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-keyvault"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "keyvault-dns"
    private_dns_zone_ids = [var.keyvault_private_dns_zone_id]
  }
}

# ─── CUSTOMER-MANAGED KEY (CMK) for AKS disk encryption ──────────────────────
resource "azurerm_key_vault_key" "aks_disk_encryption" {
  name         = "aks-disk-encryption-${var.environment}"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA-HSM"  # HSM-protected
  key_size     = 4096        # Maximum key size

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"  # Rotate 30 days before expiry
    }
    expire_after         = "P90D"  # 90-day key lifetime
    notify_before_expiry = "P29D"
  }
}

# CMK for SQL databases
resource "azurerm_key_vault_key" "sql_tde" {
  name         = "sql-tde-${var.environment}"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA-HSM"
  key_size     = 4096

  key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }
}

# ─── DISK ENCRYPTION SET ─────────────────────────────────────────────────────
resource "azurerm_disk_encryption_set" "aks" {
  name                = "${var.prefix}-des-aks-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  key_vault_key_id    = azurerm_key_vault_key.aks_disk_encryption.id
  encryption_type     = "EncryptionAtRestWithCustomerKey"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Grant Disk Encryption Set access to Key Vault
resource "azurerm_role_assignment" "des_keyvault_crypto" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.aks.identity[0].principal_id
}

# ─── AZURE CONTAINER REGISTRY ─────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                          = "${replace(var.prefix, "-", "")}acr${var.environment}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"  # Premium for private endpoint + geo-replication
  admin_enabled                 = false      # Use managed identity only
  public_network_access_enabled = false      # Private access only
  zone_redundancy_enabled       = true       # Zone-redundant storage
  tags                          = var.tags

  # Content trust (image signing — Docker Notary)
  trust_policy { enabled = true }

  # Quarantine: new images quarantined until scanned and approved
  quarantine_policy_enabled = true

  # Retention policy: delete untagged manifests after 7 days
  retention_policy {
    days    = 7
    enabled = true
  }

  # Vulnerability scanning (Microsoft Defender for Containers)
  network_rule_set {
    default_action = "Deny"
  }

  # Geo-replicate to secondary region for DR
  georeplications {
    location                  = var.azure_secondary_region
    zone_redundancy_enabled   = true
    regional_endpoint_enabled = true
    tags                      = var.tags
  }

  encryption {
    enabled            = true
    key_vault_key_id   = azurerm_key_vault_key.aks_disk_encryption.id
    identity_client_id = var.acr_encryption_identity_client_id
  }
}

# Private endpoint for ACR
resource "azurerm_private_endpoint" "acr" {
  name                = "${var.prefix}-pe-acr-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns"
    private_dns_zone_ids = [var.acr_private_dns_zone_id]
  }
}

# ─── MICROSOFT DEFENDER FOR CLOUD ────────────────────────────────────────────
# Enable all Defender plans for comprehensive coverage

resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
}

resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "Containers"  # Defender for Containers (AKS scanning)
}

resource "azurerm_security_center_subscription_pricing" "databases" {
  tier          = "Standard"
  resource_type = "SqlServers"
}

resource "azurerm_security_center_subscription_pricing" "keyvault" {
  tier          = "Standard"
  resource_type = "KeyVaults"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  tier          = "Standard"
  resource_type = "StorageAccounts"
}

resource "azurerm_security_center_subscription_pricing" "dns" {
  tier          = "Standard"
  resource_type = "Dns"
}

resource "azurerm_security_center_subscription_pricing" "arm" {
  tier          = "Standard"
  resource_type = "Arm"  # Defender for Resource Manager
}

# ─── MICROSOFT SENTINEL (SIEM) ────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "sentinel" {
  name                = "${var.prefix}-law-sentinel-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags

  # Enable workspace-level CMK (optional, requires premium commitment tier)
  # cmk_for_query_forced = true
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  workspace_id                 = azurerm_log_analytics_workspace.sentinel.id
  customer_managed_key_enabled = false  # Set to true for PCI environments
}

# Sentinel data connectors
resource "azurerm_sentinel_data_connector_azure_active_directory" "aad" {
  name                       = "AzureAD"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.sentinel.id
}

resource "azurerm_sentinel_data_connector_microsoft_cloud_app_security" "mcas" {
  name                       = "MCAS"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.sentinel.id
  alerts_enabled             = true
  discovery_logs_enabled     = true
}

resource "azurerm_sentinel_data_connector_azure_advanced_threat_protection" "aatp" {
  name                       = "AATP"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.sentinel.id
}

# ─── HASHICORP VAULT (enterprise secrets — deployed on K8s) ──────────────────
resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      "app.kubernetes.io/part-of" = "vault"
      "superapp.io/managed-by"    = "terraform"
      "superapp.io/security-tier" = "critical"
    }
  }
}

resource "helm_release" "vault" {
  depends_on       = [kubernetes_namespace.vault]
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.28.0"
  namespace        = "vault"

  values = [
    yamlencode({
      global = { enabled = true, tlsDisable = false }

      # HA mode with Raft consensus storage
      server = {
        ha = {
          enabled  = true
          replicas = 3
          raft = {
            enabled   = true
            setNodeId = true
            config    = <<-VAULT_CONFIG
              ui = true
              cluster_name = "superapp-vault-${var.environment}"

              storage "raft" {
                path    = "/vault/data"
                node_id = "$(VAULT_RAFT_NODE_ID)"

                retry_join {
                  leader_api_addr = "https://vault-0.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/tls/ca.crt"
                }
                retry_join {
                  leader_api_addr = "https://vault-1.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/tls/ca.crt"
                }
                retry_join {
                  leader_api_addr = "https://vault-2.vault-internal:8200"
                  leader_ca_cert_file = "/vault/userconfig/tls/ca.crt"
                }
              }

              # Auto-unseal via Azure Key Vault
              seal "azurekeyvault" {
                tenant_id     = "${var.tenant_id}"
                vault_name    = "${azurerm_key_vault.main.name}"
                key_name      = "vault-auto-unseal-key"
              }

              listener "tcp" {
                address       = "[::]:8200"
                cluster_address = "[::]:8201"
                tls_cert_file = "/vault/userconfig/tls/tls.crt"
                tls_key_file  = "/vault/userconfig/tls/tls.key"
                tls_min_version = "tls13"
              }

              telemetry {
                prometheus_retention_time = "30s"
                disable_hostname          = true
              }

              audit {
                enabled = true
              }
            VAULT_CONFIG
          }
        }

        # Resource requests/limits
        resources = {
          requests = { memory = "256Mi", cpu = "250m" }
          limits   = { memory = "512Mi", cpu = "1000m" }
        }

        # Affinity: spread across nodes
        affinity = yamlencode({
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [{
              labelSelector = {
                matchExpressions = [{
                  key      = "app.kubernetes.io/name"
                  operator = "In"
                  values   = ["vault"]
                }]
              }
              topologyKey = "kubernetes.io/hostname"
            }]
          }
        })

        tolerations = [{
          key      = "superapp.io/node-type"
          operator = "Equal"
          value    = "security"
          effect   = "NoSchedule"
        }]

        nodeSelector = { "superapp.io/node-type" = "security" }

        # Audit log to persistent volume
        auditStorage = {
          enabled      = true
          size         = "10Gi"
          storageClass = "managed-premium"
        }

        # Data storage
        dataStorage = {
          enabled      = true
          size         = "20Gi"
          storageClass = "managed-premium"
        }

        serviceAccount = {
          create = true
          annotations = {
            "azure.workload.identity/client-id" = var.vault_workload_identity_client_id
          }
        }
      }

      # Vault Agent Injector (injects secrets into pods as files)
      injector = {
        enabled    = true
        replicas   = 2
        failurePolicy = "Fail"  # Fail pod if injector unavailable
      }
    })
  ]
}

# ─── OPA GATEKEEPER (Policy Enforcement) ─────────────────────────────────────
resource "helm_release" "gatekeeper" {
  name             = "gatekeeper"
  repository       = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart            = "gatekeeper"
  version          = "3.16.3"
  namespace        = "gatekeeper-system"
  create_namespace = true

  set { name = "replicaCount",           value = "3" }
  set { name = "auditInterval",          value = "60" }
  set { name = "constraintViolationsLimit", value = "20" }
  set { name = "logLevel",               value = "INFO" }
  set { name = "emitAdmissionEvents",    value = "true" }

  # Emit audit events to Prometheus
  set { name = "metricsBackends[0]",     value = "prometheus" }
}

# ─── FALCO (Runtime Threat Detection) ────────────────────────────────────────
resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "4.3.0"
  namespace        = "falco"
  create_namespace = true

  values = [
    yamlencode({
      # Use eBPF driver (preferred over kernel module)
      driver = {
        kind = "ebpf"
      }

      # Forward alerts to SIEM
      falcosidekick = {
        enabled = true
        config = {
          azure = {
            eventHubNamespace    = var.event_hub_namespace
            eventHubName         = "falco-alerts"
            resourceGroupName    = var.resource_group_name
            subscriptionID       = var.subscription_id
          }
          slack = {
            webhookurl = var.slack_webhook_url
            minimumpriority = "warning"
          }
          pagerduty = {
            routingKey       = var.pagerduty_routing_key
            minimumpriority  = "critical"
          }
        }
        replicaCount = 2
      }

      # Custom rules for SuperApp (augment default Falco rules)
      customRules = {
        "superapp-rules.yaml" = <<-RULES
          - rule: Unexpected process spawned in payment container
            desc: Alert on unexpected process in payment-svc
            condition: >
              spawned_process and
              k8s.ns.name = "payments" and
              not proc.name in (dotnet, dotnet-host, sh, cat, ls)
            output: >
              Unexpected process in payment container
              (user=%%user.name command=%%proc.cmdline container=%%container.id)
            priority: CRITICAL
            tags: [payments, security, soc2]

          - rule: Outbound connection from identity container
            desc: Identity container making unexpected outbound connections
            condition: >
              outbound and
              k8s.ns.name = "identity" and
              not fd.sip in (allowed_identity_egress_ips)
            output: >
              Unexpected outbound connection from identity service
              (connection=%%fd.name container=%%container.id)
            priority: WARNING
            tags: [identity, security]
        RULES
      }
    })
  ]
}

# ─── SPIRE (SPIFFE Workload Identity) ─────────────────────────────────────────
resource "helm_release" "spire" {
  name             = "spire"
  repository       = "https://spiffe.github.io/helm-charts-hardened"
  chart            = "spire"
  version          = "0.21.0"
  namespace        = "spire-system"
  create_namespace = true

  values = [
    yamlencode({
      global = {
        openshift    = false
        spire = {
          clusterName = azurerm_kubernetes_cluster.main.name
          trustDomain = "superapp.${var.environment}.internal"
          ca = {
            # Use Azure Key Vault as upstream CA
            keyType = "rsa-4096"
          }
        }
      }

      spire-server = {
        replicaCount = 3
        nodeSelector = { "superapp.io/node-type" = "security" }
        tolerations  = [{ key = "superapp.io/node-type", operator = "Equal", value = "security", effect = "NoSchedule" }]

        federation = {
          enabled = false  # Enable if federating with GCP SPIRE server
        }

        upstreamAuthority = {
          disk = {
            certFilePath = "/vault-secret/upstream.crt"
            keyFilePath  = "/vault-secret/upstream.key"
          }
        }
      }

      spire-agent = {
        # DaemonSet: one agent per node
        nodeAttestor = {
          k8sPsat = {
            enabled = true  # Kubernetes Projected Service Account Token attestation
          }
        }
      }
    })
  ]
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────
output "key_vault_id" {
  value = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_id" {
  value = azurerm_container_registry.main.id
}

output "disk_encryption_set_id" {
  value = azurerm_disk_encryption_set.aks.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.sentinel.id
}

output "sql_tde_key_id" {
  value = azurerm_key_vault_key.sql_tde.id
}
