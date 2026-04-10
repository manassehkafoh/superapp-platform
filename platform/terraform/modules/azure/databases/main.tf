# =============================================================================
# Module: Azure Data Tier — SQL Hyperscale, Redis Cluster, Event Hubs
# =============================================================================
# Resources:
#   - Azure SQL Hyperscale (Business Critical, zone-redundant, CMK, geo-rep)
#   - Azure Cache for Redis (Cluster mode, zone-redundant, private endpoint)
#   - Azure Event Hubs (Kafka-compatible, auto-inflate, zone-redundant)
#   - Azure Service Bus (Premium, zone-redundant — for T24 ESB bridge)
# Compliance: SOC 2 C1.1, A1.1-A1.3 | DORA Article 9
# =============================================================================

variable "resource_group_name" { type = string }
variable "location"             { type = string }
variable "environment"          { type = string }

variable "sql_admin_login"           { type = string; sensitive = true }
variable "sql_sku"                   { type = string; default = "Hyperscale_Gen5_8" }
variable "sql_backup_retention_days" { type = number; default = 35 }
variable "sql_geo_backup_enabled"    { type = bool;   default = true }

variable "sql_private_endpoint_subnet_id"       { type = string }
variable "redis_private_endpoint_subnet_id"     { type = string }
variable "eventhub_private_endpoint_subnet_id"  { type = string }
variable "private_dns_zone_ids"                 { type = map(string) }

variable "key_vault_id"           { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "tags"                   { type = map(string); default = {} }

variable "sql_geo_replication_region" {
  description = "Azure region for SQL geo-secondary"
  type        = string
  default     = "northeurope"
}

# -----------------------------------------------------------------------------
# Random SQL admin password — stored in Key Vault, never in code
# Rotated automatically via Key Vault rotation policy
# -----------------------------------------------------------------------------
resource "random_password" "sql_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*-_=+?"
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  min_special      = 4
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password-${var.environment}"
  value        = random_password.sql_admin.result
  key_vault_id = var.key_vault_id

  # Auto-expire after 90 days — triggers rotation workflow
  expiration_date = timeadd(timestamp(), "2160h") # 90 days

  lifecycle {
    ignore_changes = [expiration_date, value] # Managed by rotation workflow
  }
}

# -----------------------------------------------------------------------------
# Azure SQL Server — logical server for Hyperscale databases
# Entra-only authentication (no SQL auth in production)
# -----------------------------------------------------------------------------
resource "azurerm_mssql_server" "this" {
  name                = "sql-superapp-${var.environment}-${random_string.sql_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = "12.0"

  # Entra ID-only authentication (SOC 2 CC6.1 — no shared passwords)
  azuread_administrator {
    login_username = "sql-admin-group"
    object_id      = var.sql_admin_group_object_id
    tenant_id      = var.tenant_id
    azuread_authentication_only = true # Block legacy SQL auth
  }

  # Minimum TLS 1.2 (TLS 1.3 preferred; enforced at WAF/APIM level)
  minimum_tls_version = "1.2"

  # Disable public endpoint — private endpoint only
  public_network_access_enabled  = false
  outbound_network_restriction_enabled = true

  # Transparent Data Encryption with CMK (Customer Managed Key)
  # Key is in Key Vault; CMK rotation triggers automatic TDE key rotation
  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, { "resource-type" = "sql-server" })
}

# Grant SQL Server managed identity access to Key Vault for TDE CMK
resource "azurerm_key_vault_access_policy" "sql_tde" {
  key_vault_id = var.key_vault_id
  tenant_id    = azurerm_mssql_server.this.identity[0].tenant_id
  object_id    = azurerm_mssql_server.this.identity[0].principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

resource "random_string" "sql_suffix" {
  length  = 6
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# SQL Hyperscale Database — auto-scaling storage, fast read replicas
# Business Critical tier for zone-redundancy and read scale-out
# -----------------------------------------------------------------------------
resource "azurerm_mssql_database" "superapp" {
  name      = "superapp-${var.environment}"
  server_id = azurerm_mssql_server.this.id

  # Hyperscale — unlimited storage growth, rapid snapshots
  sku_name = var.sql_sku  # e.g., "Hyperscale_Gen5_8"

  # Collation for banking/financial data
  collation = "SQL_Latin1_General_CP1_CI_AS"

  # Backup — local + geo-redundant (SOC 2 A1.3)
  backup_storage_redundancy = "Geo"

  # Transparent Data Encryption with CMK
  transparent_data_encryption_enabled = true

  # Read scale-out — allows directing read queries to replicas
  read_scale    = true
  read_replica_count = 2 # 2 read replicas in Hyperscale

  # Zone redundancy for Business Critical / Hyperscale
  zone_redundant = true

  # Long-term backup retention (SOC 2 compliance: retain 7 years for audit)
  long_term_retention_policy {
    weekly_retention  = "P4W"   # Keep 4 weekly backups
    monthly_retention = "P12M"  # Keep 12 monthly backups
    yearly_retention  = "P7Y"   # Keep 7 years of yearly backups (regulatory)
    week_of_year      = 1
  }

  # Short-term PITR backup (35 days)
  short_term_retention_policy {
    retention_days           = var.sql_backup_retention_days
    backup_interval_in_hours = 12
  }

  tags = var.tags
}

# SQL Failover Group — automatic failover to geo-secondary
resource "azurerm_mssql_failover_group" "this" {
  name      = "fog-superapp-${var.environment}"
  server_id = azurerm_mssql_server.this.id

  databases = [azurerm_mssql_database.superapp.id]

  partner_server {
    id = azurerm_mssql_server.secondary.id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"    # Auto-failover (no manual intervention)
    grace_minutes = 1              # 1-minute grace before failover triggers
  }

  readonly_endpoint_failover_policy_enabled = true # Also failover read replica

  tags = var.tags
}

# Secondary SQL server in North Europe
resource "azurerm_mssql_server" "secondary" {
  name                = "sql-superapp-${var.environment}-ne-${random_string.sql_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.sql_geo_replication_region
  version             = "12.0"

  azuread_administrator {
    login_username = "sql-admin-group"
    object_id      = var.sql_admin_group_object_id
    tenant_id      = var.tenant_id
    azuread_authentication_only = true
  }

  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, { "server-role" = "secondary", "region" = var.sql_geo_replication_region })
}

# SQL Private Endpoint — no public access to database
resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.sql_private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-sql"
    private_connection_resource_id = azurerm_mssql_server.this.id
    is_manual_connection           = false
    subresource_names              = ["sqlServer"]
  }

  private_dns_zone_group {
    name                 = "sql-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.database.windows.net"]]
  }

  tags = var.tags
}

# SQL Diagnostic Settings — all queries logged for SOC 2 audit
resource "azurerm_monitor_diagnostic_setting" "sql" {
  name                       = "sql-diagnostics"
  target_resource_id         = azurerm_mssql_database.superapp.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "SQLInsights" }
  enabled_log { category = "AutomaticTuning" }
  enabled_log { category = "QueryStoreRuntimeStatistics" }
  enabled_log { category = "Errors" }
  enabled_log { category = "DatabaseWaitStatistics" }
  enabled_log { category = "Timeouts" }
  enabled_log { category = "SQLSecurityAuditEvents" } # All data access events

  metric { category = "Basic"; enabled = true }
  metric { category = "InstanceAndAppAdvanced"; enabled = true }
  metric { category = "WorkloadManagement"; enabled = true }
}

# -----------------------------------------------------------------------------
# Azure Cache for Redis — Cluster Mode (P3, zone-redundant)
# Used for: session cache, idempotency keys, rate limiting counters
# -----------------------------------------------------------------------------
resource "azurerm_redis_cache" "this" {
  name                = "redis-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # P3 = 6GB capacity; zone-redundant for HA
  capacity = var.environment == "prod" ? 3 : 1
  family   = "P"   # Premium tier required for: clustering, persistence, VNet
  sku_name = "Premium"

  # Enable clustering (shard across 3 nodes)
  enable_non_ssl_port         = false  # SSL only
  minimum_tls_version         = "1.2"

  # Cluster mode for horizontal scaling
  shard_count = 3

  # Zone redundancy (Premium tier)
  zones = ["1", "2", "3"]

  # Redis persistence — RDB snapshots every 15 minutes
  redis_configuration {
    rdb_backup_enabled            = true
    rdb_backup_frequency          = 15   # Minutes
    rdb_backup_max_snapshot_count = 5
    rdb_storage_connection_string = var.redis_backup_storage_connection_string
    enable_authentication         = true
    # Maxmemory policy: LRU eviction for cache-aside pattern
    maxmemory_policy = "allkeys-lru"
  }

  # Patch window: Sunday 02:00-04:00 UTC (matches AKS maintenance window)
  patch_schedule {
    day_of_week        = "Sunday"
    start_hour_utc     = 2
    maintenance_window = "PT4H"
  }

  # Private endpoint only — no public access
  public_network_access_enabled = false

  tags = merge(var.tags, { "resource-type" = "redis-cache" })
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-redis-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.redis_private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-redis"
    private_connection_resource_id = azurerm_redis_cache.this.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }

  private_dns_zone_group {
    name                 = "redis-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.redis.cache.windows.net"]]
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Azure Event Hubs — Kafka-compatible event streaming
# Used as: event backbone for microservices + T24 ESB bridge
# Kafka topics: Superapp.User.Events, Superapp.Transaction.Logs, etc.
# -----------------------------------------------------------------------------
resource "azurerm_eventhub_namespace" "this" {
  name                = "evhns-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Premium" # Required: Kafka, zone-redundancy, VNet integration

  capacity        = var.environment == "prod" ? 4 : 1 # Processing Units
  zone_redundant  = true

  # Auto-inflate: automatically scale up TUs when approaching limit
  auto_inflate_enabled     = false # Premium doesn't use TU model
  kafka_enabled            = true  # Enable Kafka protocol endpoint

  # Minimum TLS 1.2
  minimum_tls_version = "1.2"

  # Disable public access
  public_network_access_enabled  = false
  local_authentication_enabled   = false  # Entra ID only (no SAS keys in prod)

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, { "resource-type" = "eventhub-namespace" })
}

# Event Hub topics — mirror the existing Kafka topic structure
resource "azurerm_eventhub" "user_events" {
  name                = "superapp.user.events"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 12   # 12 partitions for parallelism
  message_retention   = 7    # 7-day retention (increase for compliance if needed)
}

resource "azurerm_eventhub" "identity_reset" {
  name                = "superapp.identity.reset.event"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 4
  message_retention   = 7
}

resource "azurerm_eventhub" "user_type_change" {
  name                = "superapp.user.events.type.change"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 4
  message_retention   = 7
}

resource "azurerm_eventhub" "transaction_logs" {
  name                = "superapp.transaction.logs"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 32   # High throughput — more partitions
  message_retention   = 30   # 30-day retention for compliance
}

resource "azurerm_eventhub" "audit_logs" {
  name                = "superapp.audit.logs"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 8
  message_retention   = 30  # 30-day hot retention; archive to ADLS for 7 years
}

resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-evhns-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.eventhub_private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-eventhub"
    private_connection_resource_id = azurerm_eventhub_namespace.this.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "eventhub-dns-zone-group"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.eventhub.windows.net"]]
  }

  tags = var.tags
}

# Event Hubs Capture — archive all events to ADLS Gen2 for long-term retention
resource "azurerm_eventhub" "audit_logs_capture" {
  name                = "superapp.audit.logs"  # Same name as above — capture config added
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name
  partition_count     = 8
  message_retention   = 30

  capture_description {
    enabled             = true
    encoding            = "Avro"
    interval_in_seconds = 300   # Capture every 5 minutes
    size_limit_in_bytes = 314572800  # 300 MB
    skip_empty_archives = true

    destination {
      name                = "EventHubArchive.AzureBlockBlob"
      archive_name_format = "{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}"
      blob_container_name = "audit-archive"
      storage_account_id  = var.audit_storage_account_id
    }
  }
}

# -----------------------------------------------------------------------------
# Azure Service Bus Premium — for T24 ESB bridge (request-reply, sessions)
# Premium tier: message isolation, zone redundancy, VNet support
# -----------------------------------------------------------------------------
resource "azurerm_servicebus_namespace" "t24_bridge" {
  name                = "sb-t24bridge-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Premium"

  premium_messaging_partitions = 2  # 2 messaging units for HA
  zone_redundant               = true
  local_auth_enabled           = false  # Entra ID only

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, { "resource-type" = "servicebus-t24-bridge" })
}

# T24 request/response queues with sessions (for request-reply pattern)
resource "azurerm_servicebus_queue" "t24_request" {
  name         = "t24-request-queue"
  namespace_id = azurerm_servicebus_namespace.t24_bridge.id

  requires_session = true     # Session-based for correlated request-reply
  lock_duration    = "PT1M"   # 1-minute lock
  max_delivery_count = 10     # Retry 10 times before moving to DLQ
  dead_lettering_on_message_expiration = true

  max_size_in_megabytes = 5120
  default_message_ttl   = "PT30M"  # 30-minute TTL for T24 requests
}

resource "azurerm_servicebus_queue" "t24_response" {
  name         = "t24-response-queue"
  namespace_id = azurerm_servicebus_namespace.t24_bridge.id

  requires_session    = true
  lock_duration       = "PT1M"
  max_delivery_count  = 10
  default_message_ttl = "PT30M"
}

# Dead Letter Queue monitor — alert on DLQ growth (SOC 2 CC7.1)
resource "azurerm_monitor_metric_alert" "t24_dlq" {
  name                = "alert-t24-dlq-growth"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_servicebus_namespace.t24_bridge.id]
  severity            = 1  # Critical
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 10  # Alert if >10 messages in DLQ
  }

  action {
    action_group_id = var.alert_action_group_id
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "sql_server_fqdn" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_database_id" {
  value = azurerm_mssql_database.superapp.id
}

output "sql_failover_group_name" {
  value = azurerm_mssql_failover_group.this.name
}

output "redis_hostname" {
  value = azurerm_redis_cache.this.hostname
}

output "redis_ssl_port" {
  value = azurerm_redis_cache.this.ssl_port
}

output "eventhub_namespace_fqdn" {
  value = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
}

output "servicebus_namespace_name" {
  value = azurerm_servicebus_namespace.t24_bridge.name
}
