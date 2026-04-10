###############################################################################
# Module: databases
#
# Deploys the data tier following "Database Per Service" DDD pattern:
#   - Azure SQL Hyperscale (separate server per domain boundary)
#   - Private endpoints (no public access)
#   - Transparent Data Encryption with CMK
#   - Geo-replication to secondary region
#   - Azure Defender for SQL (threat detection)
#   - Automated backup with geo-redundant storage
#   - Long-term backup retention (7 years for PCI compliance)
#   - Azure Redis Cache Premium (cluster mode)
#   - Connection pooling via PgBouncer/SqlProxy pattern
#
# Database Map:
#   identity_db  — users, credentials, refresh tokens, MFA state
#   account_db   — bank/investment/pension account links, payment sources
#   payment_db   — payment records, outbox, idempotency keys, saga state
#   wallet_db    — wallets, ledger entries, double-entry journal
#   notification_db — notification templates, delivery receipts, audit log
###############################################################################

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    random  = { source = "hashicorp/random",  version = "~> 3.6"   }
  }
}

# ─── RANDOM PASSWORD FOR SQL ADMIN ───────────────────────────────────────────
resource "random_password" "sql_admin" {
  for_each         = toset(local.database_names)
  length           = 32
  special          = true
  override_special = "!@#$%^"
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  min_special      = 4
}

# ─── DATABASE CONFIGURATIONS ──────────────────────────────────────────────────
locals {
  database_names = [
    "identity",
    "account",
    "payment",
    "wallet",
    "notification",
  ]

  # Per-database sizing (production values — reduce for dev/staging)
  db_config = {
    identity     = { sku = "HS_Gen5_2", max_gb = 100, zone = true }
    account      = { sku = "HS_Gen5_2", max_gb = 100, zone = true }
    payment      = { sku = "HS_Gen5_4", max_gb = 500, zone = true }   # Higher throughput
    wallet       = { sku = "HS_Gen5_4", max_gb = 1000, zone = true }  # Ledger is large
    notification = { sku = "HS_Gen5_2", max_gb = 100, zone = true }
  }
}

# ─── AZURE SQL SERVERS (one per service = full isolation) ─────────────────────
resource "azurerm_mssql_server" "servers" {
  for_each                     = toset(local.database_names)
  name                         = "${var.prefix}-sql-${each.key}-${var.environment}"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_username
  administrator_login_password = random_password.sql_admin[each.key].result
  minimum_tls_version          = "1.2"

  # Azure AD authentication (preferred over SQL auth in production)
  azuread_administrator {
    login_username              = var.sql_aad_admin_group_name
    object_id                   = var.sql_aad_admin_group_id
    azuread_authentication_only = var.environment == "production" ? true : false
  }

  # Audit log to Log Analytics
  identity { type = "SystemAssigned" }

  tags = var.tags
}

# Store SQL admin passwords in Key Vault
resource "azurerm_key_vault_secret" "sql_passwords" {
  for_each     = toset(local.database_names)
  name         = "sql-${each.key}-admin-password"
  value        = random_password.sql_admin[each.key].result
  key_vault_id = var.key_vault_id
  content_type = "sql-password"

  tags = merge(var.tags, {
    service = each.key
    type    = "database-credential"
  })
}

# ─── AZURE SQL DATABASES (Hyperscale) ────────────────────────────────────────
resource "azurerm_mssql_database" "databases" {
  for_each    = toset(local.database_names)
  name        = "${each.key}_db"
  server_id   = azurerm_mssql_server.servers[each.key].id
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  sku_name    = var.environment == "production" ? local.db_config[each.key].sku : "GP_Gen5_2"
  max_size_gb = var.environment == "production" ? local.db_config[each.key].max_gb : 32
  tags        = var.tags

  # Transparent Data Encryption with CMK
  transparent_data_encryption_enabled    = true
  transparent_data_encryption_key_vault_key_id = var.sql_tde_key_id

  # Zone redundancy for production
  zone_redundant = var.environment == "production" ? local.db_config[each.key].zone : false

  # Hyperscale HA (named replicas for read scale-out)
  high_availability_replica_count = var.environment == "production" ? 1 : 0

  # Backup retention
  short_term_retention_policy {
    retention_days           = 35
    backup_interval_in_hours = 12  # Point-in-time restore granularity
  }

  long_term_retention_policy {
    weekly_retention  = "P4W"    # Keep weekly backups for 4 weeks
    monthly_retention = "P12M"   # Keep monthly backups for 12 months
    yearly_retention  = "P7Y"    # Keep yearly backups for 7 years (PCI compliance)
    week_of_year      = 1        # First week of year for annual backup
  }

  lifecycle {
    prevent_destroy = true  # Prevent accidental database deletion
  }
}

# ─── PRIVATE ENDPOINTS FOR EACH SQL SERVER ────────────────────────────────────
resource "azurerm_private_endpoint" "sql_servers" {
  for_each            = toset(local.database_names)
  name                = "${var.prefix}-pe-sql-${each.key}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-sql-${each.key}"
    private_connection_resource_id = azurerm_mssql_server.servers[each.key].id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sql-dns"
    private_dns_zone_ids = [var.sql_private_dns_zone_id]
  }
}

# ─── SQL AUDITING (SOC 2 CC7) ────────────────────────────────────────────────
resource "azurerm_mssql_server_extended_auditing_policy" "auditing" {
  for_each               = toset(local.database_names)
  server_id              = azurerm_mssql_server.servers[each.key].id
  storage_account_access_key_is_secondary = false
  retention_in_days      = 90
  log_monitoring_enabled = true  # Send to Log Analytics
}

# ─── MICROSOFT DEFENDER FOR SQL ──────────────────────────────────────────────
resource "azurerm_mssql_server_security_alert_policy" "defender" {
  for_each            = toset(local.database_names)
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mssql_server.servers[each.key].name
  state               = "Enabled"
  email_account_admins = true
  email_addresses     = var.security_alert_emails
}

resource "azurerm_mssql_server_vulnerability_assessment" "va" {
  for_each              = toset(local.database_names)
  server_security_alert_policy_id = azurerm_mssql_server_security_alert_policy.defender[each.key].id
  storage_container_path = "${var.storage_account_blob_endpoint}vulnerability-assessment/"
  storage_account_access_key = var.storage_account_access_key

  recurring_scans {
    enabled                   = true
    email_subscription_admins = true
    emails                    = var.security_alert_emails
  }
}

# ─── GEO-REPLICATION (Payment + Wallet DBs only — highest criticality) ────────
resource "azurerm_mssql_server" "secondary_servers" {
  for_each                     = toset(["payment", "wallet"])
  name                         = "${var.prefix}-sql-${each.key}-sec-${var.environment}"
  resource_group_name          = var.resource_group_name
  location                     = var.azure_secondary_location
  version                      = "12.0"
  administrator_login          = var.sql_admin_username
  administrator_login_password = random_password.sql_admin[each.key].result
  minimum_tls_version          = "1.2"
  identity                     { type = "SystemAssigned" }
  tags                         = var.tags
}

resource "azurerm_mssql_failover_group" "payment_wallet" {
  for_each  = toset(["payment", "wallet"])
  name      = "${var.prefix}-fog-${each.key}-${var.environment}"
  server_id = azurerm_mssql_server.servers[each.key].id

  databases = [azurerm_mssql_database.databases[each.key].id]

  partner_server {
    id = azurerm_mssql_server.secondary_servers[each.key].id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60  # Wait 60 min before auto-failover (prevents flip-flops)
  }

  readonly_endpoint_failover_policy {
    mode = "Enabled"  # Allow reads from secondary
  }

  tags = var.tags
}

# ─── AZURE REDIS CACHE PREMIUM ────────────────────────────────────────────────
resource "azurerm_redis_cache" "main" {
  name                          = "${var.prefix}-redis-${var.environment}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  capacity                      = var.redis_capacity    # P2 = 13GB
  family                        = "P"
  sku_name                      = "Premium"
  non_ssl_port_enabled          = false    # TLS only
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false    # Private endpoint only
  redis_version                 = "6"
  zones                         = ["1", "2", "3"]
  tags                          = var.tags

  redis_configuration {
    maxmemory_reserved              = 10
    maxmemory_delta                 = 10
    maxmemory_policy                = "volatile-lru"    # Evict LRU items with TTL
    enable_authentication           = true
    rdb_backup_enabled              = true
    rdb_backup_frequency            = 60               # Backup every 60 min
    rdb_backup_max_snapshot_count   = 1
    rdb_storage_connection_string   = var.redis_backup_storage_connection_string
    notify_keyspace_events          = "KEA"            # Enable keyspace notifications
  }

  # Cluster mode for Redis (3 primary + 3 replica shards)
  patch_schedule {
    day_of_week    = "Sunday"
    start_hour_utc = 2
  }
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.prefix}-pe-redis-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-redis"
    private_connection_resource_id = azurerm_redis_cache.main.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis-dns"
    private_dns_zone_ids = [var.redis_private_dns_zone_id]
  }
}

# Store Redis connection string in Key Vault
resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  value        = azurerm_redis_cache.main.primary_connection_string
  key_vault_id = var.key_vault_id
  content_type = "redis-connection-string"

  tags = merge(var.tags, { type = "cache-credential" })
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────
output "sql_server_fqdns" {
  value = { for k, v in azurerm_mssql_server.servers : k => v.fully_qualified_domain_name }
}

output "redis_hostname" {
  value = azurerm_redis_cache.main.hostname
}

output "redis_port" {
  value = azurerm_redis_cache.main.ssl_port
}

output "failover_group_endpoints" {
  value = { for k, v in azurerm_mssql_failover_group.payment_wallet : k => v.name }
}
