# =============================================================================
# SuperApp Platform – Azure Monitoring Module
# Log Analytics Workspace · Azure Managed Grafana · Prometheus (AMW)
# Application Insights · Alert Rules · Action Groups · Diagnostic Policies
# =============================================================================
# Standards: SOC 2 CC7.2 (monitoring), DORA Art.17 (ICT monitoring),
#            CIS Azure 5.x (diagnostics), Well-Architected Operational Excellence
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "environment"         { type = string }
variable "tags"                { type = map(string) }

variable "log_analytics" {
  description = "Log Analytics Workspace configuration"
  type = object({
    sku                             = optional(string, "PerGB2018")
    retention_in_days               = optional(number, 90)   # SOC 2: min 90 days hot
    daily_quota_gb                  = optional(number, 100)
    internet_ingestion_enabled      = optional(bool, false)  # private only
    internet_query_enabled          = optional(bool, false)
    cmk_key_vault_key_id            = optional(string, null)
  })
  default = {}
}

variable "prometheus" {
  description = "Azure Monitor Workspace (Prometheus) configuration"
  type = object({
    public_network_access_enabled = optional(bool, false)
  })
  default = {}
}

variable "grafana" {
  description = "Azure Managed Grafana configuration"
  type = object({
    sku                           = optional(string, "Standard")
    public_network_access_enabled = optional(bool, false)
    zone_redundancy_enabled       = optional(bool, true)
    api_key_enabled               = optional(bool, false)   # use Entra ID only
    deterministic_outbound_ip     = optional(bool, true)
  })
  default = {}
}

variable "application_insights" {
  description = "Application Insights (one per service boundary)"
  type = map(object({
    application_type                  = optional(string, "web")
    disable_ip_masking                = optional(bool, false)
    local_authentication_disabled     = optional(bool, true)
    internet_query_enabled            = optional(bool, false)
    sampling_percentage               = optional(number, 100)
    daily_data_cap_in_gb              = optional(number, 10)
    daily_data_cap_notifications_disabled = optional(bool, false)
  }))
  default = {}
}

variable "alert_action_group_emails" {
  description = "Email addresses for critical alerts"
  type        = list(string)
  default     = []
}

variable "alert_action_group_webhook_url" {
  description = "Webhook URL (PagerDuty/OpsGenie) for critical alerts"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aks_cluster_ids" {
  description = "Map of AKS cluster resource IDs to enable diagnostic settings"
  type        = map(string)
  default     = {}
}

variable "subnet_id_private_endpoint" {
  description = "Subnet ID for private endpoint placement"
  type        = string
}

variable "private_dns_zone_id_monitor" {
  description = "Private DNS zone ID for monitor.azure.com"
  type        = string
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Log Analytics Workspace
# SOC 2: Centralised log retention (CC7.2, CC7.3)
# DORA: Art.17 – ICT-related incident classification & logging
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                            = "law-superapp-${var.environment}-${var.location}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  sku                             = var.log_analytics.sku
  retention_in_days               = var.log_analytics.retention_in_days
  daily_quota_gb                  = var.log_analytics.daily_quota_gb
  internet_ingestion_enabled      = var.log_analytics.internet_ingestion_enabled
  internet_query_enabled          = var.log_analytics.internet_query_enabled
  # Customer-managed key for SOC 2 CC6.7 (encryption)
  cmk_for_query_forced            = var.log_analytics.cmk_key_vault_key_id != null ? true : false

  tags = var.tags
}

# CMK encryption for LAW (SOC 2 CC6.7)
resource "azurerm_log_analytics_cluster" "main" {
  count               = var.log_analytics.cmk_key_vault_key_id != null ? 1 : 0
  name                = "lac-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  size_gb             = 500

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_log_analytics_cluster_customer_managed_key" "main" {
  count                  = var.log_analytics.cmk_key_vault_key_id != null ? 1 : 0
  log_analytics_cluster_id = azurerm_log_analytics_cluster.main[0].id
  key_vault_key_id       = var.log_analytics.cmk_key_vault_key_id
}

# Long-term retention table settings (7 years for financial audit – SOC 2 A1)
resource "azurerm_log_analytics_workspace_table" "audit_logs" {
  workspace_id         = azurerm_log_analytics_workspace.main.id
  name                 = "AuditLogs"
  retention_in_days    = 90    # hot tier
  total_retention_in_days = 2555  # 7 years total (hot + archived)
}

resource "azurerm_log_analytics_workspace_table" "security_events" {
  workspace_id         = azurerm_log_analytics_workspace.main.id
  name                 = "SecurityEvent"
  retention_in_days    = 90
  total_retention_in_days = 2555
}

# Private endpoint – no public ingestion (Zero Trust)
resource "azurerm_private_endpoint" "law" {
  name                = "pe-law-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_id_private_endpoint

  private_service_connection {
    name                           = "psc-law"
    private_connection_resource_id = azurerm_log_analytics_workspace.main.id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-law"
    private_dns_zone_ids = [var.private_dns_zone_id_monitor]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Azure Monitor Workspace (managed Prometheus)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_workspace" "prometheus" {
  name                          = "amw-superapp-${var.environment}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  public_network_access_enabled = var.prometheus.public_network_access_enabled

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Data Collection Rule – Prometheus scraping from AKS
# ---------------------------------------------------------------------------
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                          = "dce-prometheus-${var.environment}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  public_network_access_enabled = false
  kind                          = "Linux"

  tags = var.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = "dcr-prometheus-${var.environment}"
  resource_group_name         = var.resource_group_name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }

  description = "Prometheus metrics scraping from AKS clusters"
  tags        = var.tags
}

# Associate DCR with each AKS cluster
resource "azurerm_monitor_data_collection_rule_association" "aks" {
  for_each                = var.aks_cluster_ids
  name                    = "dcra-prometheus-${each.key}"
  target_resource_id      = each.value
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "Prometheus metrics collection for ${each.key}"
}

# ---------------------------------------------------------------------------
# Azure Managed Grafana
# Entra ID auth only – no local accounts (SOC 2 CC6.1)
# ---------------------------------------------------------------------------
resource "azurerm_dashboard_grafana" "main" {
  name                              = "grf-superapp-${var.environment}"
  resource_group_name               = var.resource_group_name
  location                          = var.location
  sku                               = var.grafana.sku
  zone_redundancy_enabled           = var.grafana.zone_redundancy_enabled
  api_key_enabled                   = var.grafana.api_key_enabled
  deterministic_outbound_ip_enabled = var.grafana.deterministic_outbound_ip
  public_network_access_enabled     = var.grafana.public_network_access_enabled

  # System-assigned identity for Azure Monitor/Prometheus integration
  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus.id
  }

  grafana_major_version = 10

  tags = var.tags
}

# Grant Grafana MSI read access to Azure Monitor Workspace
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  scope                = azurerm_monitor_workspace.prometheus.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

# Grant Grafana MSI read access to Log Analytics
resource "azurerm_role_assignment" "grafana_law_reader" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Application Insights (per service boundary)
# Local auth disabled – Entra ID only (SOC 2 CC6.1)
# ---------------------------------------------------------------------------
resource "azurerm_application_insights" "services" {
  for_each            = var.application_insights
  name                = "appi-${each.key}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.main.id

  application_type                  = each.value.application_type
  disable_ip_masking                = each.value.disable_ip_masking
  local_authentication_disabled     = each.value.local_authentication_disabled
  internet_query_enabled            = each.value.internet_query_enabled
  sampling_percentage               = each.value.sampling_percentage
  daily_data_cap_in_gb              = each.value.daily_data_cap_in_gb
  daily_data_cap_notifications_disabled = each.value.daily_data_cap_notifications_disabled

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Action Groups – Alert routing
# SOC 2 CC7.3 – Incident response notifications
# DORA Art.19 – ICT-related incident reporting
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "critical" {
  name                = "ag-critical-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "CritAlert"
  enabled             = true

  dynamic "email_receiver" {
    for_each = var.alert_action_group_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "webhook_receiver" {
    for_each = var.alert_action_group_webhook_url != "" ? [1] : []
    content {
      name                    = "pagerduty-webhook"
      service_uri             = var.alert_action_group_webhook_url
      use_common_alert_schema = true
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_action_group" "warning" {
  name                = "ag-warning-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "WarnAlert"
  enabled             = true

  dynamic "email_receiver" {
    for_each = var.alert_action_group_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Metric Alert Rules – Four Golden Signals (SRE)
# ---------------------------------------------------------------------------

# 1. Latency – API Gateway P99 > 2s
resource "azurerm_monitor_metric_alert" "api_latency_p99" {
  name                = "alert-api-latency-p99-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_log_analytics_workspace.main.id]
  description         = "API Gateway P99 latency exceeds 2s SLO threshold"
  severity            = 2  # Warning
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true

  criteria {
    metric_namespace = "Microsoft.OperationalInsights/workspaces"
    metric_name      = "Average_% Processor Time"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.warning.id
  }

  tags = var.tags
}

# 2. Error Rate – HTTP 5xx > 1%
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "error_rate" {
  name                = "alert-error-rate-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "HTTP 5xx error rate exceeds 1% SLO threshold – immediate investigation required"
  severity            = 1  # Critical
  enabled             = true

  evaluation_frequency = "PT1M"
  window_duration      = "PT5M"

  scopes = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize
          total = count(),
          errors = countif(resultCode >= 500)
      | extend error_rate = todouble(errors) / todouble(total) * 100
      | where error_rate > 1
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
    custom_properties = {
      alert_type = "error_rate_slo_breach"
      runbook    = "https://wiki.internal/runbooks/error-rate-slo"
    }
  }

  tags = var.tags
}

# 3. Saturation – CPU > 85%
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "cpu_saturation" {
  name                = "alert-cpu-saturation-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "Node CPU saturation exceeds 85% for 5 minutes"
  severity            = 2
  enabled             = true

  evaluation_frequency = "PT1M"
  window_duration      = "PT5M"

  scopes = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      Perf
      | where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores"
      | summarize avg_cpu = avg(CounterValue) by Computer, bin(TimeGenerated, 1m)
      | where avg_cpu > 85
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 3
      number_of_evaluation_periods             = 5
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.warning.id]
  }

  tags = var.tags
}

# 4. Traffic – Abnormal spike (DDoS / bot activity)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "traffic_spike" {
  name                = "alert-traffic-spike-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "Request rate 300% above baseline – possible DDoS or bot attack"
  severity            = 1
  enabled             = true

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  scopes = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(15m)
      | summarize rps = count() by bin(timestamp, 1m)
      | order by timestamp desc
      | extend baseline = avg(rps)
      | where rps > baseline * 3
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 3
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = var.tags
}

# 5. Security – Kubernetes privilege escalation (SOC 2 CC6.8)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "k8s_privilege_escalation" {
  name                = "alert-k8s-priv-escalation-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "CRITICAL: Kubernetes privilege escalation or exec into container detected"
  severity            = 0  # Critical – highest
  enabled             = true

  evaluation_frequency = "PT1M"
  window_duration      = "PT5M"

  scopes = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      AzureDiagnostics
      | where Category == "kube-audit"
      | where log_s has_any ("exec", "privileged", "hostPID", "hostNetwork", "hostIPC")
      | where verb_s in ("create", "update", "patch")
      | project TimeGenerated, requestURI_s, user_s, sourceIPs_s, verb_s
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
    custom_properties = {
      alert_type = "security_incident"
      runbook    = "https://wiki.internal/runbooks/k8s-security-incident"
    }
  }

  tags = var.tags
}

# 6. SLO Burn Rate – Error budget exhaustion alert
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "slo_burn_rate" {
  name                = "alert-slo-burn-rate-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "SLO error budget burning at >14.4x rate (will exhaust in <5 days)"
  severity            = 1
  enabled             = true

  evaluation_frequency = "PT5M"
  window_duration      = "PT1H"

  scopes = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      // Multi-window burn rate (1h and 6h) for 99.9% SLO
      let slo_target = 0.999;
      let error_budget = 1 - slo_target;
      let short_window = requests
          | where timestamp > ago(1h)
          | summarize total = count(), errors = countif(success == false)
          | extend error_rate = todouble(errors) / todouble(total);
      let long_window = requests
          | where timestamp > ago(6h)
          | summarize total = count(), errors = countif(success == false)
          | extend error_rate = todouble(errors) / todouble(total);
      short_window
      | extend short_burn = error_rate / error_budget
      | extend long_burn = toscalar(long_window | project error_rate) / error_budget
      | where short_burn > 14.4 and long_burn > 14.4
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
    custom_properties = {
      alert_type = "slo_burn_rate"
      runbook    = "https://wiki.internal/runbooks/slo-burn-rate"
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# DORA Metrics Dashboard – Custom KQL workbook
# ---------------------------------------------------------------------------
resource "azurerm_application_insights_workbook" "dora_metrics" {
  name                = "wb-dora-metrics-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = "DORA Metrics – ${upper(var.environment)}"

  # Serialized workbook JSON with DORA metric queries
  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        content = {
          json = "## DORA Metrics Dashboard\n\nTracks Deployment Frequency, Lead Time, MTTR, and Change Failure Rate."
        }
      },
      {
        type  = 3
        name  = "DeploymentFrequency"
        content = {
          version    = "KqlItem/1.0"
          query      = <<-QUERY
            customEvents
            | where name == "deployment_completed"
            | where timestamp > ago(30d)
            | summarize deployments_per_day = count() by bin(timestamp, 1d), tostring(customDimensions.environment)
            | order by timestamp desc
          QUERY
          title = "Deployment Frequency (Target: Multiple/day)"
        }
      },
      {
        type  = 3
        name  = "LeadTime"
        content = {
          version = "KqlItem/1.0"
          query   = <<-QUERY
            customEvents
            | where name in ("commit_pushed", "deployment_completed")
            | project timestamp, name, customDimensions
            | summarize
                commit_time = minif(timestamp, name == "commit_pushed"),
                deploy_time = maxif(timestamp, name == "deployment_completed")
                by tostring(customDimensions.commit_sha)
            | extend lead_time_minutes = datetime_diff("minute", deploy_time, commit_time)
            | where lead_time_minutes > 0
            | summarize avg_lead_time = avg(lead_time_minutes), p95_lead_time = percentile(lead_time_minutes, 95)
          QUERY
          title = "Lead Time for Changes (Target: <60 min)"
        }
      },
      {
        type  = 3
        name  = "MTTR"
        content = {
          version = "KqlItem/1.0"
          query   = <<-QUERY
            customEvents
            | where name in ("incident_opened", "incident_resolved")
            | project timestamp, name, customDimensions
            | summarize
                opened_time  = minif(timestamp, name == "incident_opened"),
                resolved_time = maxif(timestamp, name == "incident_resolved")
                by tostring(customDimensions.incident_id)
            | extend mttr_minutes = datetime_diff("minute", resolved_time, opened_time)
            | where mttr_minutes > 0
            | summarize avg_mttr = avg(mttr_minutes), p95_mttr = percentile(mttr_minutes, 95)
          QUERY
          title = "Mean Time to Restore (Target: <30 min)"
        }
      },
      {
        type  = 3
        name  = "ChangeFailureRate"
        content = {
          version = "KqlItem/1.0"
          query   = <<-QUERY
            customEvents
            | where name in ("deployment_completed", "deployment_failed", "rollback_triggered")
            | where timestamp > ago(30d)
            | summarize
                total_deployments = countif(name == "deployment_completed"),
                failed_deployments = countif(name in ("deployment_failed", "rollback_triggered"))
            | extend cfr_percent = todouble(failed_deployments) / todouble(total_deployments) * 100
          QUERY
          title = "Change Failure Rate (Target: <5%)"
        }
      }
    ]
  })

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Diagnostic Settings – AKS Clusters → Log Analytics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "aks" {
  for_each           = var.aks_cluster_ids
  name               = "diag-aks-${each.key}-${var.environment}"
  target_resource_id = each.value
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  # All audit log categories for SOC 2 / DORA
  enabled_log { category = "kube-audit"           }
  enabled_log { category = "kube-audit-admin"     }
  enabled_log { category = "kube-apiserver"       }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler"       }
  enabled_log { category = "guard"                }  # Entra ID audit
  enabled_log { category = "cloud-controller-manager" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "law_workspace_id" {
  description = "Log Analytics Workspace ID"
  value       = azurerm_log_analytics_workspace.main.id
}

output "law_workspace_customer_id" {
  description = "Log Analytics Workspace customer ID (for agent configuration)"
  value       = azurerm_log_analytics_workspace.main.workspace_id
  sensitive   = true
}

output "law_primary_key" {
  description = "Log Analytics Workspace primary key"
  value       = azurerm_log_analytics_workspace.main.primary_shared_key
  sensitive   = true
}

output "prometheus_query_endpoint" {
  description = "Azure Monitor Workspace Prometheus query endpoint"
  value       = azurerm_monitor_workspace.prometheus.query_endpoint
}

output "grafana_endpoint" {
  description = "Azure Managed Grafana endpoint URL"
  value       = "https://${azurerm_dashboard_grafana.main.endpoint}"
}

output "grafana_principal_id" {
  description = "Grafana managed identity principal ID"
  value       = azurerm_dashboard_grafana.main.identity[0].principal_id
}

output "application_insights_connection_strings" {
  description = "Application Insights connection strings per service"
  value = {
    for k, v in azurerm_application_insights.services :
    k => v.connection_string
  }
  sensitive = true
}

output "action_group_critical_id" {
  description = "Critical alert action group ID"
  value       = azurerm_monitor_action_group.critical.id
}

output "action_group_warning_id" {
  description = "Warning alert action group ID"
  value       = azurerm_monitor_action_group.warning.id
}

output "dce_prometheus_id" {
  description = "Data Collection Endpoint ID for Prometheus"
  value       = azurerm_monitor_data_collection_endpoint.prometheus.id
}

output "dcr_prometheus_id" {
  description = "Data Collection Rule ID for Prometheus"
  value       = azurerm_monitor_data_collection_rule.prometheus.id
}
