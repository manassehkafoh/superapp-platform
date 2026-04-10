# =============================================================================
# SuperApp Platform – AWS Databases Module
# Aurora PostgreSQL (Babelfish – MSSQL wire-compat) · MSK (Kafka) · ElastiCache
# =============================================================================
# Standards: SOC 2 CC6.7 (encryption), CC9.2 (vendor risk), A1.2 (availability),
#            DORA Art.12 (ICT continuity), CIS AWS RDS / ElastiCache benchmarks
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "environment"             { type = string }
variable "aws_region"              { type = string }
variable "tags"                    { type = map(string) }
variable "db_subnet_group_name"    { type = string }
variable "private_subnet_ids"      { type = list(string) }
variable "vpc_id"                  { type = string }
variable "vpc_cidr"                { type = string }
variable "elasticache_subnet_group_name" { type = string }
variable "kms_key_arn"             { type = string }

variable "aurora" {
  description = "Aurora PostgreSQL Babelfish cluster configuration"
  type = object({
    engine_version             = optional(string, "15.4")
    instance_class             = optional(string, "db.r8g.xlarge")
    instance_count             = optional(number, 3)  # 1 writer + 2 readers
    deletion_protection        = optional(bool, true)
    backup_retention_days      = optional(number, 35)  # SOC 2: min 30 days
    backup_window              = optional(string, "02:00-03:00")
    maintenance_window         = optional(string, "sun:04:00-sun:05:00")
    enable_performance_insights = optional(bool, true)
    performance_insights_retention = optional(number, 731)  # 2 years
    monitoring_interval        = optional(number, 30)
    auto_minor_version_upgrade = optional(bool, true)
    publicly_accessible        = optional(bool, false)
    iam_database_authentication = optional(bool, true)  # no static passwords
    skip_final_snapshot        = optional(bool, false)
    apply_immediately          = optional(bool, false)
    enable_babelfish           = optional(bool, true)   # MSSQL wire compatibility
    # Babelfish migration mode: single-db | multi-db
    babelfish_migration_mode   = optional(string, "multi-db")
  })
  default = {}
}

variable "msk" {
  description = "MSK (Kafka) cluster configuration"
  type = object({
    kafka_version              = optional(string, "3.6.0")
    broker_instance_type       = optional(string, "kafka.m7g.xlarge")
    number_of_brokers          = optional(number, 3)   # 1 per AZ
    ebs_volume_size_gb         = optional(number, 1024)
    auto_create_topics         = optional(bool, false)
    default_replication_factor = optional(number, 3)
    min_insync_replicas        = optional(number, 2)
    encryption_in_transit_client = optional(string, "TLS")   # TLS only
    encryption_in_transit_broker = optional(string, "TLS")
    enhanced_monitoring        = optional(string, "PER_TOPIC_PER_PARTITION")
    sasl_iam_enabled           = optional(bool, true)    # IAM auth (no credentials)
    sasl_scram_enabled         = optional(bool, false)   # disabled in favour of IAM
  })
  default = {}
}

variable "elasticache" {
  description = "ElastiCache Redis (Valkey 8) configuration"
  type = object({
    node_type                  = optional(string, "cache.r7g.xlarge")
    num_cache_clusters         = optional(number, 3)    # 1 primary + 2 replicas
    engine_version             = optional(string, "8.0")  # Valkey 8 / Redis 8
    port                       = optional(number, 6380)  # TLS port
    maintenance_window         = optional(string, "sun:05:00-sun:06:00")
    snapshot_retention_limit   = optional(number, 7)
    snapshot_window            = optional(string, "03:00-04:00")
    automatic_failover_enabled = optional(bool, true)
    multi_az_enabled           = optional(bool, true)
    transit_encryption_enabled = optional(bool, true)  # TLS in transit
    at_rest_encryption_enabled = optional(bool, true)
    auth_token_enabled         = optional(bool, true)
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "aurora" {
  name        = "sg-aurora-${var.environment}"
  description = "Aurora PostgreSQL – accept from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Babelfish TDS port (MSSQL wire protocol)
  ingress {
    description = "Babelfish TDS from VPC"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-aurora-${var.environment}" })
}

resource "aws_security_group" "msk" {
  name        = "sg-msk-${var.environment}"
  description = "MSK Kafka – TLS from VPC only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Kafka TLS from VPC"
    from_port   = 9094  # TLS listener
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Kafka IAM/SASL-TLS from VPC"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "ZooKeeper TLS (internal MSK)"
    from_port   = 2182
    to_port     = 2182
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-msk-${var.environment}" })
}

resource "aws_security_group" "elasticache" {
  name        = "sg-elasticache-${var.environment}"
  description = "ElastiCache Redis TLS – from VPC only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis TLS from VPC"
    from_port   = 6380
    to_port     = 6380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-elasticache-${var.environment}" })
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL – Babelfish for SQL Server compatibility
# Allows MSSQL workloads to migrate to Aurora without app changes
# SOC 2 A1.2 – High availability with multi-AZ
# ---------------------------------------------------------------------------

# Custom parameter group enabling Babelfish
resource "aws_rds_cluster_parameter_group" "babelfish" {
  name        = "pg-aurora-babelfish-${var.environment}"
  family      = "aurora-postgresql15"
  description = "Aurora PostgreSQL with Babelfish enabled – ${var.environment}"

  # Enable Babelfish
  parameter {
    name  = "rds.babelfish_status"
    value = var.aurora.enable_babelfish ? "on" : "off"
    apply_method = "pending-reboot"
  }

  # Migration mode
  parameter {
    name  = "babelfishpg_tsql.migration_mode"
    value = var.aurora.babelfish_migration_mode
    apply_method = "pending-reboot"
  }

  # Performance settings
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,auto_explain,pg_cron,babelfishpg_common,babelfishpg_tsql,babelfishpg_tds"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"  # Log queries > 1 second
    apply_method = "immediate"
  }

  parameter {
    name  = "pgaudit.log"
    value = "all"  # SOC 2 CC7.2 – full audit
    apply_method = "immediate"
  }

  tags = var.tags
}

resource "aws_db_parameter_group" "babelfish_instance" {
  name   = "pg-instance-babelfish-${var.environment}"
  family = "aurora-postgresql15"

  parameter {
    name  = "log_connections"
    value = "1"
    apply_method = "immediate"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
    apply_method = "immediate"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
    apply_method = "immediate"
  }

  tags = var.tags
}

# Enhanced monitoring role
resource "aws_iam_role" "rds_monitoring" {
  name = "iam-role-rds-enhanced-monitoring-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Aurora cluster
resource "aws_rds_cluster" "main" {
  cluster_identifier     = "aurora-superapp-${var.environment}"
  engine                 = "aurora-postgresql"
  engine_version         = var.aurora.engine_version
  engine_mode            = "provisioned"
  database_name          = "superapp"
  master_username        = "superapp_admin"

  # Manage password via Secrets Manager – no static credentials
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name            = var.db_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.babelfish.name

  storage_encrypted  = true
  kms_key_id         = var.kms_key_arn
  storage_type       = "aurora-iopt2"  # I/O-optimised for financial workloads

  backup_retention_period      = var.aurora.backup_retention_days
  preferred_backup_window      = var.aurora.backup_window
  preferred_maintenance_window = var.aurora.maintenance_window

  deletion_protection              = var.aurora.deletion_protection
  skip_final_snapshot              = var.aurora.skip_final_snapshot
  final_snapshot_identifier        = "aurora-superapp-${var.environment}-final"
  copy_tags_to_snapshot            = true
  apply_immediately                = var.aurora.apply_immediately

  iam_database_authentication_enabled = var.aurora.iam_database_authentication
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade", "audit"]

  # Serverless v2 scaling configuration
  serverlessv2_scaling_configuration {
    min_capacity = var.environment == "prod" ? 2.0  : 0.5
    max_capacity = var.environment == "prod" ? 64.0 : 8.0
  }

  lifecycle {
    ignore_changes = [master_password]
  }

  tags = merge(var.tags, {
    Name            = "aurora-superapp-${var.environment}"
    DataClass       = "Confidential"
    BackupRequired  = "true"
  })
}

# Aurora instances (writer + readers)
resource "aws_rds_cluster_instance" "main" {
  count = var.aurora.instance_count

  identifier         = "aurora-superapp-${var.environment}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.aurora.instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  # Distribute readers across AZs
  availability_zone = var.private_subnet_ids[count.index % length(var.private_subnet_ids)] != "" ? null : null

  db_parameter_group_name    = aws_db_parameter_group.babelfish_instance.name
  auto_minor_version_upgrade = var.aurora.auto_minor_version_upgrade
  publicly_accessible        = var.aurora.publicly_accessible

  # Performance Insights (SOC 2 CC7.2 – anomaly detection)
  performance_insights_enabled          = var.aurora.enable_performance_insights
  performance_insights_kms_key_id       = var.aurora.enable_performance_insights ? var.kms_key_arn : null
  performance_insights_retention_period = var.aurora.performance_insights_retention

  # Enhanced monitoring
  monitoring_interval = var.aurora.monitoring_interval
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = merge(var.tags, {
    Name = "aurora-superapp-${var.environment}-${count.index + 1}"
    Role = count.index == 0 ? "writer" : "reader"
  })
}

# ---------------------------------------------------------------------------
# MSK (Managed Kafka) – Event streaming (DORA distributed system resilience)
# Topics: Superapp.User.Events, Superapp.Identity.Reset.Event,
#         Superapp.Transaction.Logs, Superapp.Audit.Logs (retained from existing)
# ---------------------------------------------------------------------------

# MSK Configuration
resource "aws_msk_configuration" "main" {
  name              = "msk-config-superapp-${var.environment}"
  kafka_versions    = [var.msk.kafka_version]
  description       = "SuperApp MSK Configuration – ${var.environment}"

  server_properties = <<-PROPS
    # Replication and durability
    default.replication.factor=${var.msk.default_replication_factor}
    min.insync.replicas=${var.msk.min_insync_replicas}
    num.partitions=6
    
    # Security
    allow.everyone.if.no.acl.found=false
    auto.create.topics.enable=${var.msk.auto_create_topics}
    
    # Log retention (SOC 2 audit requirements)
    log.retention.hours=168
    log.retention.bytes=-1
    
    # Compression
    compression.type=lz4
    
    # Performance
    num.io.threads=8
    num.network.threads=5
    socket.send.buffer.bytes=102400
    socket.receive.buffer.bytes=102400
    socket.request.max.bytes=104857600
    
    # Unclean leader election disabled (no data loss on failover)
    unclean.leader.election.enable=false
  PROPS
}

resource "aws_msk_cluster" "main" {
  cluster_name           = "msk-superapp-${var.environment}"
  kafka_version          = var.msk.kafka_version
  number_of_broker_nodes = var.msk.number_of_brokers

  broker_node_group_info {
    instance_type   = var.msk.broker_instance_type
    client_subnets  = slice(var.private_subnet_ids, 0, min(length(var.private_subnet_ids), var.msk.number_of_brokers))
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk.ebs_volume_size_gb

        provisioned_throughput {
          enabled           = true
          volume_throughput = 250  # MiB/s per broker
        }
      }
    }

    connectivity_info {
      public_access {
        type = "DISABLED"  # VPC-only access (Zero Trust)
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  # Encryption – in transit and at rest
  encryption_info {
    encryption_in_transit {
      client_broker = var.msk.encryption_in_transit_client  # TLS only
      in_cluster    = true
    }
    encryption_at_rest_kms_key_arn = var.kms_key_arn
  }

  # Authentication – IAM only (no username/password)
  client_authentication {
    sasl {
      iam   = var.msk.sasl_iam_enabled
      scram = var.msk.sasl_scram_enabled
    }
    unauthenticated_access = false
  }

  # Enhanced monitoring
  enhanced_monitoring = var.msk.enhanced_monitoring

  open_monitoring {
    prometheus {
      jmx_exporter  { enabled_in_broker = true }
      node_exporter { enabled_in_broker = true }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }

      s3 {
        enabled = true
        bucket  = aws_s3_bucket.msk_logs.id
        prefix  = "msk-logs/"
      }
    }
  }

  tags = merge(var.tags, {
    Name = "msk-superapp-${var.environment}"
  })
}

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/superapp-${var.environment}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_s3_bucket" "msk_logs" {
  bucket = "superapp-msk-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name      = "superapp-msk-logs-${var.environment}"
    DataClass = "Internal"
  })
}

resource "aws_s3_bucket_versioning" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "msk_logs" {
  bucket                  = aws_s3_bucket.msk_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# MSK topics (via CLI post-provisioning – Terraform MSK topic resource limited)
# These align with existing Kafka topics from the original architecture:
# - Superapp.User.Events
# - Superapp.Identity.Reset.Event
# - Superapp.Transaction.Logs
# - Superapp.Audit.Logs
# Provisioned via aws_msk_replicator or Kafka AdminClient in Helm hooks

# ---------------------------------------------------------------------------
# ElastiCache (Valkey 8 / Redis 8) – Session cache, rate limiting
# SOC 2 CC6.7 – Encrypted at rest and in transit
# ---------------------------------------------------------------------------

# Random auth token (stored in Secrets Manager)
resource "random_password" "redis_auth" {
  length  = 64
  special = false  # Redis AUTH token: alphanumeric only
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "superapp/${var.environment}/redis-auth-token"
  description             = "ElastiCache Redis AUTH token"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "ec-superapp-${var.environment}"
  description                = "SuperApp ElastiCache – ${var.environment}"
  engine                     = "valkey"  # Valkey 8 (Redis fork, open-source)
  engine_version             = var.elasticache.engine_version
  node_type                  = var.elasticache.node_type
  num_cache_clusters         = var.elasticache.num_cache_clusters
  port                       = var.elasticache.port
  parameter_group_name       = aws_elasticache_parameter_group.main.name
  subnet_group_name          = var.elasticache_subnet_group_name
  security_group_ids         = [aws_security_group.elasticache.id]

  automatic_failover_enabled = var.elasticache.automatic_failover_enabled
  multi_az_enabled           = var.elasticache.multi_az_enabled

  # Encryption (SOC 2 CC6.7)
  at_rest_encryption_enabled  = var.elasticache.at_rest_encryption_enabled
  transit_encryption_enabled  = var.elasticache.transit_encryption_enabled
  transit_encryption_mode     = "required"  # enforce TLS (no plaintext)
  kms_key_id                  = var.kms_key_arn
  auth_token                  = var.elasticache.auth_token_enabled ? random_password.redis_auth.result : null
  auth_token_update_strategy  = "ROTATE"  # enable token rotation

  maintenance_window         = var.elasticache.maintenance_window
  snapshot_retention_limit   = var.elasticache.snapshot_retention_limit
  snapshot_window            = var.elasticache.snapshot_window

  # Auto-upgrade minor versions
  auto_minor_version_upgrade = true

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.elasticache_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.elasticache_engine.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  tags = merge(var.tags, {
    Name = "ec-superapp-${var.environment}"
  })
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "pg-valkey-${var.environment}"
  family = "valkey8"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"  # evict oldest keys when memory full
  }

  parameter {
    name  = "notify-keyspace-events"
    value = "KEA"  # keyspace notifications for auditing
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "elasticache_slow" {
  name              = "/aws/elasticache/superapp-${var.environment}/slow-log"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "elasticache_engine" {
  name              = "/aws/elasticache/superapp-${var.environment}/engine-log"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms – Database health
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  alarm_name          = "aurora-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora CPU above 80% for 15 minutes"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag" {
  alarm_name          = "aurora-replica-lag-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 5000  # 5 seconds
  alarm_description   = "Aurora replica lag exceeds 5s – RPO at risk"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "redis-memory-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.main.id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint"
  value       = aws_rds_cluster.main.endpoint
  sensitive   = true
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint (load-balanced across replicas)"
  value       = aws_rds_cluster.main.reader_endpoint
  sensitive   = true
}

output "aurora_babelfish_tds_endpoint" {
  description = "Aurora Babelfish TDS endpoint (MSSQL wire protocol port 1433)"
  value       = "${aws_rds_cluster.main.endpoint}:1433"
  sensitive   = true
}

output "aurora_port" {
  description = "Aurora PostgreSQL port"
  value       = aws_rds_cluster.main.port
}

output "aurora_master_secret_arn" {
  description = "ARN of Secrets Manager secret containing Aurora master credentials"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "msk_bootstrap_brokers_tls" {
  description = "MSK bootstrap brokers (TLS)"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
  sensitive   = true
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "MSK bootstrap brokers (SASL/IAM)"
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
  sensitive   = true
}

output "msk_zookeeper_connect_string" {
  description = "MSK ZooKeeper connection string (TLS)"
  value       = aws_msk_cluster.main.zookeeper_connect_string_tls
  sensitive   = true
}

output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.main.arn
}

output "redis_primary_endpoint" {
  description = "ElastiCache primary endpoint (TLS)"
  value       = "${aws_elasticache_replication_group.main.primary_endpoint_address}:${var.elasticache.port}"
  sensitive   = true
}

output "redis_reader_endpoint" {
  description = "ElastiCache reader endpoint"
  value       = "${aws_elasticache_replication_group.main.reader_endpoint_address}:${var.elasticache.port}"
  sensitive   = true
}

output "redis_auth_secret_arn" {
  description = "ARN of Secrets Manager secret containing Redis AUTH token"
  value       = aws_secretsmanager_secret.redis_auth.arn
}
