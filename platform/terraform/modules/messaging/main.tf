###############################################################################
# SuperApp Platform — Messaging Module
# Provisions: Azure Event Hubs (managed Kafka), Strimzi config, Schema Registry
# Compliance : SOC 2 CC6.1, DORA Art.12, PCI-DSS Req.10
###############################################################################

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    helm    = { source = "hashicorp/helm",    version = "~> 2.13"  }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.29" }
  }
}

###############################################################################
# 1. Azure Event Hubs Namespace (Kafka-compatible, Premium tier)
###############################################################################

resource "azurerm_eventhub_namespace" "kafka" {
  name                     = "evhns-${var.platform_name}-${var.environment}-${var.location_code}"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  sku                      = "Premium"
  capacity                 = var.eventhub_capacity   # throughput units (2 for prod)
  auto_inflate_enabled     = false                   # Premium: manual scaling
  kafka_enabled            = true
  zone_redundant           = true
  minimum_tls_version      = "1.2"

  network_rulesets {
    default_action                 = "Deny"
    trusted_service_access_enabled = true

    dynamic "virtual_network_rule" {
      for_each = var.allowed_subnet_ids
      content {
        subnet_id = virtual_network_rule.value
      }
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.common_tags, { component = "messaging" })
}

# CMK encryption for Event Hubs namespace
resource "azurerm_eventhub_namespace_customer_managed_key" "kafka" {
  eventhub_namespace_id    = azurerm_eventhub_namespace.kafka.id
  key_vault_key_ids        = [var.eventhub_cmk_key_id]
  infrastructure_encryption_enabled = true
}

###############################################################################
# 2. Event Hubs (Topics) — mirrors SuperApp Kafka topics
###############################################################################

locals {
  event_hubs = {
    "superapp-user-events" = {
      partitions  = 12
      retention   = 7
      description = "User lifecycle events (created, updated, suspended)"
    }
    "superapp-identity-reset" = {
      partitions  = 6
      retention   = 3
      description = "Password/MFA reset request events"
    }
    "superapp-payment-source" = {
      partitions  = 24
      retention   = 7
      description = "Payment initiation events — high throughput"
    }
    "superapp-transaction-logs" = {
      partitions  = 24
      retention   = 30
      description = "Immutable transaction audit log"
    }
    "superapp-audit-logs" = {
      partitions  = 12
      retention   = 90
      description = "Platform-wide audit trail — SOC 2 CC7.2"
    }
    "superapp-notification-events" = {
      partitions  = 12
      retention   = 1
      description = "Notification dispatch events"
    }
    "superapp-wallet-events" = {
      partitions  = 12
      retention   = 7
      description = "Wallet balance change events"
    }
    "superapp-dlq" = {
      partitions  = 6
      retention   = 14
      description = "Dead-letter queue for all failed events"
    }
  }
}

resource "azurerm_eventhub" "topics" {
  for_each            = local.event_hubs
  name                = each.key
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = var.resource_group_name
  partition_count     = each.value.partitions
  message_retention   = each.value.retention

  capture_description {
    enabled             = contains(["superapp-transaction-logs", "superapp-audit-logs"], each.key)
    encoding            = "Avro"
    interval_in_seconds = 300
    size_limit_in_bytes = 314572800 # 300 MB

    destination {
      name                = "EventHubArchive.AzureBlockBlob"
      archive_name_format = "{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}"
      blob_container_name = azurerm_storage_container.kafka_archive[each.key].name
      storage_account_id  = azurerm_storage_account.kafka_archive.id
    }
  }
}

###############################################################################
# 3. Consumer Groups per service
###############################################################################

locals {
  consumer_groups = {
    "superapp-user-events"        = ["identity-api", "account-api", "notification-api"]
    "superapp-identity-reset"     = ["identity-api", "notification-api"]
    "superapp-payment-source"     = ["payment-api", "wallet-api", "notification-api"]
    "superapp-transaction-logs"   = ["audit-service", "reporting-api"]
    "superapp-audit-logs"         = ["siem-connector", "compliance-api"]
    "superapp-notification-events"= ["notification-api"]
    "superapp-wallet-events"      = ["wallet-api", "account-api"]
    "superapp-dlq"                = ["dlq-processor"]
  }
}

resource "azurerm_eventhub_consumer_group" "groups" {
  for_each = {
    for pair in flatten([
      for hub, consumers in local.consumer_groups : [
        for consumer in consumers : {
          key      = "${hub}--${consumer}"
          hub      = hub
          consumer = consumer
        }
      ]
    ]) : pair.key => pair
  }

  name                = each.value.consumer
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  eventhub_name       = each.value.hub
  resource_group_name = var.resource_group_name

  depends_on = [azurerm_eventhub.topics]
}

###############################################################################
# 4. Authorization Rules (least-privilege SASL)
###############################################################################

resource "azurerm_eventhub_namespace_authorization_rule" "producer" {
  name                = "superapp-producer"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = var.resource_group_name
  listen              = false
  send                = true
  manage              = false
}

resource "azurerm_eventhub_namespace_authorization_rule" "consumer" {
  name                = "superapp-consumer"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = var.resource_group_name
  listen              = true
  send                = false
  manage              = false
}

###############################################################################
# 5. Archive Storage for compliance (immutable blob)
###############################################################################

resource "azurerm_storage_account" "kafka_archive" {
  name                            = "st${replace(var.platform_name, "-", "")}kafka${var.environment}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 90
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.common_tags, { component = "messaging-archive" })
}

# Immutable storage policy — SOC 2 CC6.1, PCI-DSS Req.10.5
resource "azurerm_storage_management_policy" "kafka_archive" {
  storage_account_id = azurerm_storage_account.kafka_archive.id

  rule {
    name    = "archive-lifecycle"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = 2557 # 7 years
      }
    }
  }
}

resource "azurerm_storage_container" "kafka_archive" {
  for_each              = { for k in keys(local.event_hubs) : k => k if contains(["superapp-transaction-logs", "superapp-audit-logs"], k) }
  name                  = replace(each.key, "-", "")
  storage_account_name  = azurerm_storage_account.kafka_archive.name
  container_access_type = "private"
}

###############################################################################
# 6. Strimzi Kafka Operator + Cluster (in-cluster for dev/staging)
#    Production: Azure Event Hubs replaces in-cluster Kafka
###############################################################################

resource "helm_release" "strimzi_operator" {
  count            = var.environment != "prod" ? 1 : 0
  name             = "strimzi-kafka-operator"
  repository       = "https://strimzi.io/charts/"
  chart            = "strimzi-kafka-operator"
  version          = "0.41.0"
  namespace        = "kafka"
  create_namespace = true
  atomic           = true
  timeout          = 600

  values = [
    yamlencode({
      watchNamespaces  = ["kafka"]
      logLevel         = "INFO"
      fullReconciliationIntervalMs = 120000

      resources = {
        requests = { memory = "384Mi", cpu = "200m" }
        limits   = { memory = "512Mi", cpu = "500m" }
      }

      leaderElection = {
        enable = true
      }

      tolerations = [{
        key      = "workload"
        operator = "Equal"
        value    = "kafka"
        effect   = "NoSchedule"
      }]
    })
  ]
}

resource "kubernetes_manifest" "kafka_cluster" {
  count = var.environment != "prod" ? 1 : 0

  manifest = {
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name      = "superapp-kafka"
      namespace = "kafka"
      labels    = { "app.kubernetes.io/part-of" = "superapp-platform" }
    }
    spec = {
      kafka = {
        version  = "3.7.0"
        replicas = var.kafka_replicas  # min 3
        listeners = [
          {
            name = "plain"
            port = 9092
            type = "internal"
            tls  = false
          },
          {
            name = "tls"
            port = 9093
            type = "internal"
            tls  = true
            authentication = { type = "tls" }
          }
        ]
        config = {
          "offsets.topic.replication.factor"         = "3"
          "transaction.state.log.replication.factor" = "3"
          "transaction.state.log.min.isr"            = "2"
          "default.replication.factor"               = "3"
          "min.insync.replicas"                      = "2"
          "auto.create.topics.enable"                = "false"
          "log.retention.hours"                      = "168"
          "message.max.bytes"                        = "10485760"  # 10MB
          "compression.type"                         = "lz4"
        }
        storage = {
          type = "jbod"
          volumes = [{
            id   = 0
            type = "persistent-claim"
            size = "${var.kafka_storage_gb}Gi"
            class = "managed-premium"
            deleteClaim = false
          }]
        }
        resources = {
          requests = { memory = "4Gi",  cpu = "1000m" }
          limits   = { memory = "8Gi",  cpu = "2000m" }
        }
        jvmOptions = {
          "-Xms" = "2048m"
          "-Xmx" = "4096m"
          gcLoggingEnabled = false
        }
        metricsConfig = {
          type = "jmxPrometheusExporter"
          valueFrom = {
            configMapKeyRef = {
              name = "kafka-metrics"
              key  = "kafka-metrics-config.yml"
            }
          }
        }
      }

      zookeeper = {
        replicas = 3
        storage = {
          type  = "persistent-claim"
          size  = "10Gi"
          class = "managed-premium"
          deleteClaim = false
        }
        resources = {
          requests = { memory = "1Gi",  cpu = "500m"  }
          limits   = { memory = "2Gi",  cpu = "1000m" }
        }
      }

      entityOperator = {
        topicOperator = {
          resources = {
            requests = { memory = "256Mi", cpu = "100m" }
            limits   = { memory = "512Mi", cpu = "500m" }
          }
        }
        userOperator = {
          resources = {
            requests = { memory = "256Mi", cpu = "100m" }
            limits   = { memory = "512Mi", cpu = "500m" }
          }
        }
      }
    }
  }

  depends_on = [helm_release.strimzi_operator]
}

###############################################################################
# 7. Confluent Schema Registry (via Helm — Apicurio)
###############################################################################

resource "helm_release" "schema_registry" {
  name             = "apicurio-registry"
  repository       = "https://apicurio.github.io/apicurio-registry-helm-chart/"
  chart            = "apicurio-registry"
  version          = "1.3.1"
  namespace        = "kafka"
  create_namespace = true
  atomic           = true

  set {
    name  = "image.tag"
    value = "2.6.2.Final"
  }

  set {
    name  = "persistence.enabled"
    value = "true"
  }

  set {
    name  = "podAnnotations.prometheus\\.io/scrape"
    value = "true"
  }
}

###############################################################################
# 8. Private Endpoint for Event Hubs
###############################################################################

resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-evhns-${var.platform_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "evhns-privateserviceconnection"
    private_connection_resource_id = azurerm_eventhub_namespace.kafka.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "eventhub-dns-zone-group"
    private_dns_zone_ids = [var.eventhub_private_dns_zone_id]
  }

  tags = var.common_tags
}

###############################################################################
# 9. Diagnostic Settings — SOC 2 CC7.2
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "eventhub" {
  name                       = "diag-evhns-${var.environment}"
  target_resource_id         = azurerm_eventhub_namespace.kafka.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "ArchiveLogs"          }
  enabled_log { category = "OperationalLogs"       }
  enabled_log { category = "AutoScaleLogs"         }
  enabled_log { category = "KafkaCoordinatorLogs"  }
  enabled_log { category = "KafkaUserErrorLogs"    }
  enabled_log { category = "EventHubVNetConnectionEvent" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

###############################################################################
# Outputs
###############################################################################

output "eventhub_namespace_name" {
  value = azurerm_eventhub_namespace.kafka.name
}

output "eventhub_bootstrap_servers" {
  description = "Kafka-compatible bootstrap endpoint for Event Hubs"
  value       = "${azurerm_eventhub_namespace.kafka.name}.servicebus.windows.net:9093"
}

output "eventhub_producer_connection_string_secret" {
  description = "Key Vault secret name storing producer SAS"
  value       = "eventhub-producer-connstring"
  sensitive   = true
}

output "eventhub_consumer_connection_string_secret" {
  description = "Key Vault secret name storing consumer SAS"
  value       = "eventhub-consumer-connstring"
  sensitive   = true
}

output "schema_registry_url" {
  value = "http://apicurio-registry.kafka.svc.cluster.local:8080/apis/ccompat/v6"
}
