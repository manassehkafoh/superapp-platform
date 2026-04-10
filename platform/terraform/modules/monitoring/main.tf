###############################################################################
# SuperApp Platform — Monitoring Module
# Stack   : kube-prometheus-stack, Loki, Tempo, OpenTelemetry Collector
# Compliance: SOC 2 CC7.1-CC7.3, DORA Art.11 (ICT incident management)
###############################################################################

terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 3.100" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.13"  }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.29"  }
  }
}

###############################################################################
# 1. Azure Monitor — Log Analytics Workspace
###############################################################################

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${var.platform_name}-${var.environment}-${var.location_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days  # 90 for prod, SOC 2 CC7.2

  cmk_for_query_forced = true

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.common_tags, { component = "monitoring" })
}

resource "azurerm_log_analytics_workspace_table" "audit_logs" {
  workspace_id    = azurerm_log_analytics_workspace.main.id
  name            = "SuperAppAuditLogs_CL"
  retention_in_days = 365
  total_retention_in_days = 2557  # 7 years — PCI-DSS Req.10.7
}

###############################################################################
# 2. Azure Monitor Action Groups & Alerts
###############################################################################

resource "azurerm_monitor_action_group" "critical" {
  name                = "ag-${var.platform_name}-critical-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "superapp-p1"

  dynamic "email_receiver" {
    for_each = var.critical_alert_emails
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  webhook_receiver {
    name        = "pagerduty"
    service_uri = var.pagerduty_webhook_url
  }

  tags = var.common_tags
}

resource "azurerm_monitor_action_group" "warning" {
  name                = "ag-${var.platform_name}-warning-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "superapp-p2"

  dynamic "email_receiver" {
    for_each = var.warning_alert_emails
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  tags = var.common_tags
}

###############################################################################
# 3. Azure Monitor Metric Alerts — DORA SLOs
###############################################################################

locals {
  metric_alerts = {
    "aks-cpu-high" = {
      description        = "AKS node CPU > 85% — SOC 2 A1.2"
      severity           = 1
      action_group_id    = azurerm_monitor_action_group.critical.id
      resource_id        = var.aks_cluster_id
      metric_namespace   = "microsoft.containerservice/managedclusters"
      metric_name        = "node_cpu_usage_percentage"
      aggregation        = "Average"
      operator           = "GreaterThan"
      threshold          = 85
      window_size        = "PT5M"
      frequency          = "PT1M"
    }
    "aks-memory-high" = {
      description        = "AKS node memory > 90%"
      severity           = 1
      action_group_id    = azurerm_monitor_action_group.critical.id
      resource_id        = var.aks_cluster_id
      metric_namespace   = "microsoft.containerservice/managedclusters"
      metric_name        = "node_memory_working_set_percentage"
      aggregation        = "Average"
      operator           = "GreaterThan"
      threshold          = 90
      window_size        = "PT5M"
      frequency          = "PT1M"
    }
  }
}

resource "azurerm_monitor_metric_alert" "alerts" {
  for_each            = local.metric_alerts
  name                = "alert-${each.key}-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.resource_id]
  description         = each.value.description
  severity            = each.value.severity
  window_size         = each.value.window_size
  frequency           = each.value.frequency

  criteria {
    metric_namespace = each.value.metric_namespace
    metric_name      = each.value.metric_name
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold
  }

  action {
    action_group_id = each.value.action_group_id
  }

  tags = var.common_tags
}

###############################################################################
# 4. Prometheus + Grafana (kube-prometheus-stack)
###############################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "60.3.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  atomic           = true
  timeout          = 900

  values = [
    yamlencode({
      global = {
        rbac = { create = true, pspEnabled = false }
      }

      prometheusOperator = {
        resources = {
          requests = { memory = "256Mi", cpu = "100m" }
          limits   = { memory = "512Mi", cpu = "500m" }
        }
      }

      prometheus = {
        prometheusSpec = {
          retention           = "30d"
          retentionSize       = "45GB"
          replicas            = var.environment == "prod" ? 2 : 1
          replicaExternalLabelName = "prometheus_replica"

          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "managed-premium"
                resources        = { requests = { storage = "50Gi" } }
              }
            }
          }

          resources = {
            requests = { memory = "2Gi",  cpu = "500m"  }
            limits   = { memory = "4Gi",  cpu = "2000m" }
          }

          additionalScrapeConfigs = [
            {
              job_name = "superapp-services"
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                  action = "keep"
                  regex  = "true"
                }
              ]
            }
          ]

          # Remote write to Azure Monitor (long-term retention)
          remoteWrite = [
            {
              url = "https://aks-${var.environment}.${var.location}.prometheus.monitor.azure.com/api/v1/write"
              azureAd = {
                cloud = "AzurePublic"
                managedIdentity = { clientId = var.aks_managed_identity_client_id }
              }
            }
          ]
        }
      }

      grafana = {
        enabled    = true
        replicas   = var.environment == "prod" ? 2 : 1
        adminPassword = "REPLACED_BY_EXTERNAL_SECRETS"

        persistence = {
          enabled          = true
          storageClassName = "managed-premium"
          size             = "10Gi"
        }

        "grafana.ini" = {
          server   = { root_url = "https://grafana.${var.domain_name}" }
          auth = {
            disable_login_form = var.environment == "prod"
          }
          "auth.azuread" = {
            enabled       = true
            name          = "Azure AD"
            allow_sign_up = true
            client_id     = var.grafana_azure_ad_client_id
            scopes        = "openid email profile offline_access"
            auth_url      = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/authorize"
            token_url     = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/token"
          }
          smtp = {
            enabled    = true
            host       = var.smtp_host
            from_address = "grafana@${var.domain_name}"
          }
        }

        additionalDataSources = [
          {
            name    = "Loki"
            type    = "loki"
            url     = "http://loki-gateway.monitoring.svc.cluster.local"
            access  = "proxy"
            isDefault = false
          },
          {
            name   = "Tempo"
            type   = "tempo"
            url    = "http://tempo.monitoring.svc.cluster.local:3100"
            access = "proxy"
            jsonData = {
              tracesToLogsV2 = {
                datasourceUid = "loki"
                spanStartTimeShift = "-1h"
                spanEndTimeShift   = "1h"
                filterByTraceID    = true
                filterBySpanID     = false
              }
              serviceMap = { datasourceUid = "prometheus" }
            }
          }
        ]

        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [
              {
                name            = "superapp"
                orgId           = 1
                folder          = "SuperApp"
                type            = "file"
                disableDeletion = true
                editable        = false
                options         = { path = "/var/lib/grafana/dashboards/superapp" }
              }
            ]
          }
        }

        resources = {
          requests = { memory = "512Mi", cpu = "250m" }
          limits   = { memory = "1Gi",   cpu = "500m" }
        }
      }

      alertmanager = {
        alertmanagerSpec = {
          replicas = var.environment == "prod" ? 3 : 1
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "managed-premium"
                resources        = { requests = { storage = "10Gi" } }
              }
            }
          }
        }

        config = {
          global = {
            resolve_timeout = "5m"
            pagerduty_url   = "https://events.pagerduty.com/v2/enqueue"
          }
          route = {
            group_by        = ["alertname", "cluster", "service"]
            group_wait      = "10s"
            group_interval  = "10s"
            repeat_interval = "12h"
            receiver        = "pagerduty-critical"
            routes = [
              {
                match    = { severity = "warning" }
                receiver = "slack-warning"
              }
            ]
          }
          receivers = [
            {
              name = "pagerduty-critical"
              pagerduty_configs = [{
                routing_key = var.pagerduty_integration_key
                description = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
              }]
            },
            {
              name = "slack-warning"
              slack_configs = [{
                api_url  = var.slack_webhook_url
                channel  = "#superapp-alerts"
                title    = "{{ .GroupLabels.alertname }} - {{ .CommonLabels.env }}"
                text     = "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
              }]
            }
          ]
        }
      }
    })
  ]
}

###############################################################################
# 5. Loki (distributed log aggregation)
###############################################################################

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.6.3"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  atomic     = true
  timeout    = 600

  values = [
    yamlencode({
      loki = {
        auth_enabled = false
        commonConfig = { replication_factor = var.environment == "prod" ? 3 : 1 }

        storage = {
          type = "azure"
          azure = {
            account_name   = var.loki_storage_account_name
            container_name = "loki-chunks"
            use_federated_token = true
          }
        }

        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "azure"
            schema       = "v13"
            index        = { prefix = "loki_index_", period = "24h" }
          }]
        }

        limits_config = {
          retention_period         = "744h"   # 31 days
          ingestion_rate_mb        = 32
          ingestion_burst_size_mb  = 64
          max_query_parallelism    = 32
        }

        rulerConfig = {
          enable_api    = true
          enable_alerting_rules = true
        }
      }

      singleBinary = {
        replicas = var.environment == "prod" ? 0 : 1
      }

      backend = {
        replicas = var.environment == "prod" ? 3 : 0
      }

      read = {
        replicas = var.environment == "prod" ? 3 : 0
      }

      write = {
        replicas = var.environment == "prod" ? 3 : 0
      }
    })
  ]
}

###############################################################################
# 6. Grafana Tempo (distributed tracing)
###############################################################################

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo-distributed"
  version    = "1.9.10"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  atomic     = true
  timeout    = 600

  values = [
    yamlencode({
      global = {
        clusterDomain = "cluster.local"
      }

      tempo = {
        reportingEnabled = false
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
        }
        storage = {
          trace = {
            backend = "azure"
            azure = {
              container_name      = "tempo-traces"
              storage_account_name = var.tempo_storage_account_name
              use_federated_token = true
            }
          }
        }
        retention = "720h"   # 30 days
      }

      distributor = { replicas = var.environment == "prod" ? 3 : 1 }
      ingester    = { replicas = var.environment == "prod" ? 3 : 1 }
      compactor   = { replicas = 1 }
      querier     = { replicas = var.environment == "prod" ? 3 : 1 }

      metricsGenerator = {
        enabled  = true
        replicas = 1
        config = {
          storage = {
            remote_write = [{
              url = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
            }]
          }
          processor = {
            service_graphs = {
              dimensions = ["superapp.service.name", "superapp.environment"]
            }
            span_metrics = {
              dimensions = ["superapp.service.name", "superapp.operation.name"]
            }
          }
        }
      }
    })
  ]
}

###############################################################################
# 7. OpenTelemetry Collector (DaemonSet + Deployment)
###############################################################################

resource "helm_release" "opentelemetry_collector" {
  name       = "opentelemetry-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.95.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  atomic     = true

  values = [
    yamlencode({
      mode = "daemonset"

      image = {
        repository = "otel/opentelemetry-collector-contrib"
        tag        = "0.103.0"
      }

      config = {
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
          prometheus = {
            config = {
              scrape_configs = [{
                job_name        = "otel-collector"
                scrape_interval = "10s"
                static_configs  = [{ targets = ["0.0.0.0:8888"] }]
              }]
            }
          }
        }

        processors = {
          batch = {
            timeout    = "1s"
            send_batch_size = 1024
          }
          "memory_limiter" = {
            check_interval  = "1s"
            limit_mib       = 400
            spike_limit_mib = 100
          }
          "resource/superapp" = {
            attributes = [
              { action = "insert", key = "k8s.cluster.name",      value = var.cluster_name       },
              { action = "insert", key = "superapp.environment",   value = var.environment        },
              { action = "insert", key = "superapp.region",        value = var.location           },
            ]
          }
          # Redact sensitive fields — PCI-DSS Req.3.4
          "transform/redact_pii" = {
            error_mode    = "ignore"
            trace_statements = [
              {
                context    = "span"
                statements = [
                  "replace_pattern(attributes[\"http.request.body\"], \"\\\"(pan|cvv|pin|password)\\\":\\s*\\\"[^\\\"]+\\\"\", \"\\\"$1\\\":\\\"***\\\"\")"
                ]
              }
            ]
          }
        }

        exporters = {
          otlp = {
            endpoint = "tempo.monitoring.svc.cluster.local:4317"
            tls      = { insecure = true }
          }
          "loki" = {
            endpoint = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
          }
          prometheus = {
            endpoint = "0.0.0.0:8889"
          }
        }

        service = {
          pipelines = {
            traces  = { receivers = ["otlp"], processors = ["memory_limiter", "resource/superapp", "transform/redact_pii", "batch"], exporters = ["otlp"] }
            metrics = { receivers = ["otlp", "prometheus"], processors = ["memory_limiter", "batch"], exporters = ["prometheus"] }
            logs    = { receivers = ["otlp"], processors = ["memory_limiter", "resource/superapp", "transform/redact_pii", "batch"], exporters = ["loki"] }
          }
        }
      }

      resources = {
        requests = { memory = "256Mi", cpu = "100m" }
        limits   = { memory = "512Mi", cpu = "500m" }
      }
    })
  ]
}

###############################################################################
# 8. Prometheus Rules — SLO Burn Rates (DORA + Availability)
###############################################################################

resource "kubernetes_manifest" "slo_payment_api" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "superapp-slo-payment"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels    = { "app.kubernetes.io/part-of" = "kube-prometheus-stack" }
    }
    spec = {
      groups = [
        {
          name = "superapp.payment.slo"
          rules = [
            {
              # SLO: 99.9% success rate for payment API
              alert  = "PaymentAPIErrorBudgetBurn"
              expr   = "sum(rate(http_requests_total{service='payment-api',code!~'2..'}[1h])) / sum(rate(http_requests_total{service='payment-api'}[1h])) > 0.001"
              for    = "5m"
              labels = { severity = "critical", slo = "payment-success-rate" }
              annotations = {
                summary     = "Payment API error budget burning fast"
                description = "Error rate {{ $value | humanizePercentage }} exceeds SLO threshold (0.1%). Runbook: https://runbooks.superapp.internal/payment-api-errors"
              }
            },
            {
              # SLO: p99 latency < 2s
              alert  = "PaymentAPILatencyHigh"
              expr   = "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service='payment-api'}[5m])) by (le)) > 2"
              for    = "5m"
              labels = { severity = "warning", slo = "payment-latency" }
              annotations = {
                summary     = "Payment API p99 latency above SLO"
                description = "p99 latency is {{ $value }}s. SLO target: <2s."
              }
            }
          ]
        },
        {
          name = "superapp.deployment.dora"
          rules = [
            {
              # DORA: Track deployment frequency
              record = "superapp:dora:deployment_frequency"
              expr   = "increase(argocd_app_sync_total{phase='Succeeded'}[24h])"
            },
            {
              # DORA: Track change failure rate
              record = "superapp:dora:change_failure_rate"
              expr   = "increase(argocd_app_sync_total{phase='Failed'}[7d]) / increase(argocd_app_sync_total[7d])"
            }
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

###############################################################################
# Outputs
###############################################################################

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_key" {
  value     = azurerm_log_analytics_workspace.main.primary_shared_key
  sensitive = true
}

output "grafana_url" {
  value = "https://grafana.${var.domain_name}"
}

output "prometheus_url" {
  value = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
}

output "otel_grpc_endpoint" {
  value = "opentelemetry-collector.monitoring.svc.cluster.local:4317"
}
