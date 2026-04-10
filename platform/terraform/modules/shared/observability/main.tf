# =============================================================================
# SuperApp Platform – Shared Observability Stack
# kube-prometheus-stack · Loki · Tempo · OpenTelemetry Collector
# Deployed via Helm on both AKS (primary) and EKS (DR)
# =============================================================================
# Standards: SOC 2 CC7.2 (monitoring), DORA SRE metrics (4 golden signals),
#            OpenTelemetry W3C TraceContext, NIST SP800-92 (log management)
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
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "environment"      { type = string }
variable "cluster_name"     { type = string }
variable "cloud_provider"   { type = string }  # "azure" or "aws"
variable "tags"             { type = map(string) }

variable "observability_namespace" {
  type    = string
  default = "observability"
}

variable "prometheus" {
  type = object({
    replicas              = optional(number, 2)
    retention             = optional(string, "90d")
    storage_size_gb       = optional(number, 200)
    storage_class         = optional(string, "managed-premium-zrs")
    enable_remote_write   = optional(bool, true)
    remote_write_endpoint = optional(string, "")   # Azure Monitor Workspace / AMP endpoint
    scrape_interval       = optional(string, "15s")
    evaluation_interval   = optional(string, "15s")
  })
  default = {}
}

variable "alertmanager" {
  type = object({
    replicas          = optional(number, 2)
    pagerduty_key     = optional(string, "")
    slack_api_url     = optional(string, "")
    slack_channel     = optional(string, "#alerts-platform")
    opsgenie_api_key  = optional(string, "")
  })
  default  = {}
  sensitive = true
}

variable "loki" {
  type = object({
    replicas          = optional(number, 3)
    storage_size_gb   = optional(number, 100)
    storage_class     = optional(string, "managed-premium-zrs")
    retention_days    = optional(number, 90)   # SOC 2: 90 days hot
    # S3/Azure Blob backend for long-term log storage
    object_storage_endpoint = optional(string, "")
    object_storage_bucket   = optional(string, "")
  })
  default = {}
}

variable "tempo" {
  type = object({
    replicas           = optional(number, 2)
    storage_size_gb    = optional(number, 50)
    storage_class      = optional(string, "managed-premium-zrs")
    retention_hours    = optional(number, 720)   # 30 days
    max_trace_ttl_days = optional(number, 90)
  })
  default = {}
}

variable "otel_collector" {
  type = object({
    replicas = optional(number, 2)
    # Endpoints to forward to
    prometheus_endpoint = optional(string, "")
    loki_endpoint       = optional(string, "")
    tempo_endpoint      = optional(string, "")
  })
  default = {}
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = ""
}

# ---------------------------------------------------------------------------
# Kubernetes Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "observability" {
  metadata {
    name = var.observability_namespace

    labels = {
      "app.kubernetes.io/managed-by"        = "terraform"
      "pod-security.kubernetes.io/enforce"  = "privileged"  # Prometheus needs host metrics
      "pod-security.kubernetes.io/warn"     = "privileged"
    }
  }
}

# ---------------------------------------------------------------------------
# kube-prometheus-stack
# Includes: Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter
# ---------------------------------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.0.0"
  namespace        = kubernetes_namespace.observability.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600
  wait             = true

  # Force update CRDs
  set {
    name  = "crds.enabled"
    value = "true"
  }

  values = [
    yamlencode({
      nameOverride     = "prom"
      fullnameOverride = "kube-prometheus-stack"

      # ------------------------------------
      # Prometheus
      # ------------------------------------
      prometheus = {
        enabled = true

        prometheusSpec = {
          replicas         = var.prometheus.replicas
          retention        = var.prometheus.retention
          scrapeInterval   = var.prometheus.scrape_interval
          evaluationInterval = var.prometheus.evaluation_interval

          # Storage
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.prometheus.storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = { storage = "${var.prometheus.storage_size_gb}Gi" }
                }
              }
            }
          }

          # Remote write to managed Prometheus (Azure Monitor / AMP)
          remoteWrite = var.prometheus.enable_remote_write && var.prometheus.remote_write_endpoint != "" ? [
            {
              url = var.prometheus.remote_write_endpoint
              sigv4 = var.cloud_provider == "aws" ? {
                region = "eu-west-1"
              } : null
              azureAd = var.cloud_provider == "azure" ? {
                cloud = "AzurePublic"
                managedIdentity = { clientId = "system-assigned" }
              } : null
              queueConfig = {
                capacity          = 10000
                maxSamplesPerSend = 1000
                batchSendDeadline = "5s"
              }
              metadataConfig = { send = true }
            }
          ] : []

          # Discover all ServiceMonitors and PodMonitors across all namespaces
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
          probeSelectorNilUsesHelmValues          = false

          # Resources
          resources = {
            requests = { cpu = "500m",  memory = "2Gi" }
            limits   = { cpu = "2000m", memory = "8Gi" }
          }

          # Security context
          securityContext = {
            runAsNonRoot = true
            runAsUser    = 65534
            fsGroup      = 65534
            seccompProfile = { type = "RuntimeDefault" }
          }

          # Pod anti-affinity
          podAntiAffinity = "soft"
          topologySpreadConstraints = [{
            maxSkew            = 1
            topologyKey        = "topology.kubernetes.io/zone"
            whenUnsatisfiable  = "DoNotSchedule"
            labelSelector = {
              matchLabels = { "app.kubernetes.io/name" = "prometheus" }
            }
          }]

          # Additional scrape configs for Cilium and Vault
          additionalScrapeConfigs = [
            {
              job_name = "cilium-agent"
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_k8s_app"]
                  action        = "keep"
                  regex         = "cilium"
                }
              ]
            },
            {
              job_name = "vault"
              static_configs = [{ targets = ["vault.vault.svc.cluster.local:8200"] }]
              scheme = "https"
              tls_config = { insecure_skip_verify = false }
              metrics_path = "/v1/sys/metrics"
              params = { format = ["prometheus"] }
              bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
            }
          ]
        }

        # PDB
        podDisruptionBudget = {
          enabled        = true
          minAvailable   = 1
        }
      }

      # ------------------------------------
      # Alertmanager
      # ------------------------------------
      alertmanager = {
        enabled = true

        alertmanagerSpec = {
          replicas = var.alertmanager.replicas

          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.prometheus.storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = { storage = "10Gi" }
                }
              }
            }
          }

          resources = {
            requests = { cpu = "100m",  memory = "256Mi" }
            limits   = { cpu = "500m",  memory = "512Mi" }
          }
        }

        config = {
          global = {
            resolve_timeout    = "5m"
            slack_api_url      = var.alertmanager.slack_api_url
            pagerduty_url      = "https://events.pagerduty.com/v2/enqueue"
          }

          inhibit_rules = [
            {
              source_matchers = ["severity=critical"]
              target_matchers = ["severity=warning"]
              equal           = ["alertname", "cluster", "service"]
            }
          ]

          route = {
            group_by        = ["alertname", "cluster", "severity"]
            group_wait      = "10s"
            group_interval  = "5m"
            repeat_interval = "1h"
            receiver        = "null"

            routes = [
              {
                matchers  = ["alertname=Watchdog"]
                receiver  = "null"
              },
              {
                matchers  = ["severity=critical"]
                receiver  = "pagerduty-critical"
                continue  = true
              },
              {
                matchers  = ["severity=critical|warning"]
                receiver  = "slack-alerts"
              }
            ]
          }

          receivers = [
            {
              name = "null"
            },
            {
              name = "pagerduty-critical"
              pagerduty_configs = var.alertmanager.pagerduty_key != "" ? [{
                service_key = var.alertmanager.pagerduty_key
                description = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
                details = {
                  cluster     = "{{ .CommonLabels.cluster }}"
                  environment = var.environment
                }
              }] : []
            },
            {
              name = "slack-alerts"
              slack_configs = var.alertmanager.slack_api_url != "" ? [{
                channel   = var.alertmanager.slack_channel
                send_resolved = true
                title     = "[{{ .Status | toUpper }}{{ if eq .Status \"firing\" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}"
                text      = "{{ range .Alerts }}*Alert:* {{ .Annotations.summary }}\n*Description:* {{ .Annotations.description }}\n*Severity:* `{{ .Labels.severity }}`\n{{ end }}"
                icon_url  = "https://avatars3.githubusercontent.com/u/3380462"
              }] : []
            }
          ]
        }
      }

      # ------------------------------------
      # Grafana
      # ------------------------------------
      grafana = {
        enabled         = true
        adminPassword   = var.grafana_admin_password != "" ? var.grafana_admin_password : null
        defaultDashboardsEnabled = true
        defaultDashboardsTimezone = "UTC"

        # Disable local accounts – use Entra ID / Cognito SSO
        grafana_ini = {
          auth = {
            disable_login_form   = false  # keep for emergency break-glass
            oauth_auto_login     = false
            signout_redirect_url = ""
          }
          security = {
            admin_user    = "admin"
            cookie_secure = true
            strict_transport_security = true
          }
          analytics = {
            reporting_enabled = false
            check_for_updates = false
          }
          log = {
            mode  = "console"
            level = "info"
          }
        }

        persistence = {
          enabled          = true
          storageClassName = var.prometheus.storage_class
          size             = "10Gi"
        }

        resources = {
          requests = { cpu = "200m",  memory = "256Mi" }
          limits   = { cpu = "1000m", memory = "1Gi"  }
        }

        # Sidecar for auto-loading dashboards from ConfigMaps
        sidecar = {
          dashboards = {
            enabled          = true
            searchNamespace  = "ALL"
            label            = "grafana_dashboard"
            labelValue       = "1"
          }
          datasources = {
            enabled = true
            searchNamespace = "ALL"
          }
        }

        # Pre-configured datasources
        additionalDataSources = [
          {
            name   = "Loki"
            type   = "loki"
            url    = "http://loki-gateway.${var.observability_namespace}.svc.cluster.local"
            access = "proxy"
            jsonData = {
              maxLines = 1000
            }
          },
          {
            name   = "Tempo"
            type   = "tempo"
            url    = "http://tempo.${var.observability_namespace}.svc.cluster.local:3100"
            access = "proxy"
            jsonData = {
              tracesToLogsV2 = {
                datasourceUid = "loki"
                tags          = [{ key = "service.name", value = "service" }]
              }
              serviceMap = {
                datasourceUid = "prometheus"
              }
              nodeGraph = { enabled = true }
            }
          }
        ]
      }

      # ------------------------------------
      # Node Exporter
      # ------------------------------------
      nodeExporter = {
        enabled = true
        hostRootfs = true
        tolerations = [{
          operator = "Exists"
          effect   = "NoSchedule"
        }]
      }

      # ------------------------------------
      # kube-state-metrics
      # ------------------------------------
      kubeStateMetrics = {
        enabled = true
        resources = {
          requests = { cpu = "50m",  memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # ------------------------------------
      # Default PrometheusRules (SLO alerts)
      # ------------------------------------
      additionalPrometheusRulesMap = {
        superapp-slo-rules = {
          groups = [
            {
              name = "superapp.slo"
              interval = "1m"
              rules = [
                {
                  record = "job:superapp_http_requests:rate5m"
                  expr   = "sum(rate(http_requests_total{job=~\"superapp-.*\"}[5m])) by (job, status_code)"
                },
                {
                  record = "job:superapp_http_errors:rate5m"
                  expr   = "sum(rate(http_requests_total{job=~\"superapp-.*\", status_code=~\"5..\"}[5m])) by (job)"
                },
                {
                  alert  = "SuperAppSLOErrorBudgetBurn"
                  expr   = "(job:superapp_http_errors:rate5m / job:superapp_http_requests:rate5m) > 0.01"
                  for    = "5m"
                  labels = { severity = "critical", team = "platform" }
                  annotations = {
                    summary     = "SuperApp SLO error budget burning fast"
                    description = "Error rate {{ $value | humanizePercentage }} exceeds SLO threshold"
                    runbook     = "https://wiki.internal/runbooks/slo-burn"
                  }
                },
                {
                  alert  = "SuperAppHighLatencyP99"
                  expr   = "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job=~\"superapp-.*\"}[5m])) by (le, job)) > 2"
                  for    = "5m"
                  labels = { severity = "warning", team = "platform" }
                  annotations = {
                    summary     = "SuperApp P99 latency exceeds 2s SLO"
                    description = "P99 latency {{ $value }}s for {{ $labels.job }}"
                    runbook     = "https://wiki.internal/runbooks/high-latency"
                  }
                }
              ]
            }
          ]
        }
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# Loki – Log aggregation (Kubernetes-native)
# ---------------------------------------------------------------------------
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.6.2"
  namespace        = kubernetes_namespace.observability.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  values = [
    yamlencode({
      loki = {
        auth_enabled = false  # multi-tenancy disabled (single cluster)

        server = {
          http_listen_port = 3100
          grpc_listen_port = 9096
        }

        commonConfig = {
          replication_factor = var.loki.replicas
        }

        storage = {
          type = var.loki.object_storage_endpoint != "" ? "s3" : "filesystem"
        }

        # Retention
        limits_config = {
          retention_period = "${var.loki.retention_days * 24}h"
          max_streams_per_user = 0  # unlimited
          max_line_size        = 256000  # 256KB max log line
          ingestion_rate_mb    = 16
          ingestion_burst_size_mb = 32
        }

        # Structured metadata (for trace correlation)
        schema_config = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "filesystem"
            schema       = "v13"
            index = {
              prefix = "loki_index_"
              period = "24h"
            }
          }]
        }
      }

      # Deployment mode – simple scalable (3 replicas)
      deploymentMode = "SimpleScalable"

      backend = {
        replicas   = var.loki.replicas
        resources = {
          requests = { cpu = "200m",  memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "2Gi"  }
        }
        persistence = {
          storageClass = var.loki.storage_class
          size         = "${var.loki.storage_size_gb}Gi"
        }
      }

      read = {
        replicas  = 2
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "1Gi"  }
        }
      }

      write = {
        replicas  = var.loki.replicas
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "2Gi" }
        }
        persistence = {
          storageClass = var.loki.storage_class
          size         = "20Gi"
        }
      }

      # Promtail (log shipper)
      promtail = { enabled = false }  # we use OTEL collector for log forwarding

      # Gateway (nginx reverse proxy)
      gateway = {
        enabled  = true
        replicas = 2
        resources = {
          requests = { cpu = "50m",  memory = "64Mi"  }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      monitoring = {
        serviceMonitor = { enabled = true }
        selfMonitoring = { enabled = false }
        lokiCanary     = { enabled = false }
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# Tempo – Distributed tracing (OpenTelemetry native)
# ---------------------------------------------------------------------------
resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo-distributed"
  version          = "1.9.10"
  namespace        = kubernetes_namespace.observability.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  values = [
    yamlencode({
      tempo = {
        server = {
          http_listen_port = 3100
          grpc_listen_port = 9095
        }

        storage = {
          trace = {
            backend = "local"  # upgrade to object storage in production
            local = {
              path = "/var/tempo/traces"
            }
          }
        }

        compactor = {
          compaction = {
            block_retention = "${var.tempo.retention_hours}h"
          }
        }

        # Distributed search
        distributor = {
          receivers = {
            otlp = {
              protocols = {
                http = { endpoint = "0.0.0.0:4318" }
                grpc = { endpoint = "0.0.0.0:4317" }
              }
            }
            zipkin  = {}
            jaeger = {
              protocols = {
                thrift_compact  = {}
                thrift_binary   = {}
                thrift_http     = {}
                grpc            = {}
              }
            }
          }
        }
      }

      distributor = {
        replicas = 2
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "2Gi" }
        }
      }

      ingester = {
        replicas = var.tempo.replicas
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "2Gi" }
        }
        persistence = {
          enabled          = true
          storageClassName = var.tempo.storage_class
          size             = "${var.tempo.storage_size_gb}Gi"
        }
      }

      querier = {
        replicas = 2
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "1Gi"  }
        }
      }

      queryFrontend = {
        replicas = 2
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      # Service monitors for Prometheus
      serviceMonitor = { enabled = true }

      # Tags
      global_overrides = {
        max_traces_per_user         = 0
        max_search_duration         = "0s"
        ingestion_rate_limit_bytes  = 15000000
        ingestion_burst_size_bytes  = 20000000
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# OpenTelemetry Collector – Unified telemetry pipeline
# Receives from all services → routes to Prometheus, Loki, Tempo
# ---------------------------------------------------------------------------
resource "helm_release" "otel_collector" {
  name             = "otel-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = "0.94.0"
  namespace        = kubernetes_namespace.observability.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 300

  values = [
    yamlencode({
      mode = "deployment"

      replicaCount = var.otel_collector.replicas

      image = {
        repository = "otel/opentelemetry-collector-contrib"
        tag        = "0.103.0"
      }

      resources = {
        requests = { cpu = "200m",  memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "2Gi"  }
      }

      config = {
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = {
                endpoint = "0.0.0.0:4318"
                cors = {
                  allowed_origins = ["*"]
                  allowed_headers = ["*"]
                }
              }
            }
          }

          # Kubernetes events as logs
          k8s_events = {
            namespaces = []  # all namespaces
          }

          # Prometheus scrape (pull metrics from services)
          prometheus = {
            config = {
              scrape_configs = [{
                job_name = "otel-collector-self"
                static_configs = [{ targets = ["0.0.0.0:8888"] }]
              }]
            }
          }

          # Host metrics (node-level)
          hostmetrics = {
            root_path            = "/hostfs"
            collection_interval  = "30s"
            scrapers = {
              cpu        = {}
              disk       = {}
              filesystem = {}
              load       = {}
              memory     = {}
              network    = {}
              paging     = {}
              processes  = {}
            }
          }
        }

        processors = {
          # Batch for efficiency
          batch = {
            timeout           = "5s"
            send_batch_size   = 10000
            send_batch_max_size = 11000
          }

          # Memory limiter (prevent OOM)
          memory_limiter = {
            limit_percentage      = 80
            spike_limit_percentage = 25
            check_interval        = "5s"
          }

          # Resource detection (add cloud metadata)
          resourcedetection = {
            detectors = ["env", "k8s_node", var.cloud_provider == "azure" ? "azure" : "ec2"]
            timeout   = "10s"
          }

          # K8s attribute enrichment (add pod/namespace labels to traces)
          k8sattributes = {
            auth_type        = "serviceAccount"
            passthrough      = false
            extract = {
              metadata = [
                "k8s.pod.name", "k8s.pod.uid", "k8s.deployment.name",
                "k8s.namespace.name", "k8s.node.name", "k8s.container.name"
              ]
              labels = [
                { from = "pod", key = "app.kubernetes.io/version", tag_name = "app.version" },
                { from = "pod", key = "app.kubernetes.io/component", tag_name = "app.component" }
              ]
            }
          }

          # Tail sampling – keep 100% of error traces, sample 5% of normal
          tail_sampling = {
            decision_wait             = "10s"
            num_traces                = 50000
            expected_new_traces_per_sec = 1000
            policies = [
              {
                name = "errors-policy"
                type = "status_code"
                status_code = { status_codes = ["ERROR"] }
              },
              {
                name = "latency-policy"
                type = "latency"
                latency = { threshold_ms = 2000 }
              },
              {
                name = "probabilistic-policy"
                type = "probabilistic"
                probabilistic = { sampling_percentage = 5 }
              }
            ]
          }

          # Security – filter out sensitive attributes
          attributes = {
            actions = [
              { key = "http.request.header.authorization", action = "delete" },
              { key = "http.request.header.cookie",        action = "delete" },
              { key = "db.statement",                      action = "delete" }  # no SQL in traces
            ]
          }
        }

        exporters = {
          # Prometheus remote write
          prometheusremotewrite = {
            endpoint = var.otel_collector.prometheus_endpoint != "" ? var.otel_collector.prometheus_endpoint : "http://kube-prometheus-stack-prometheus.${var.observability_namespace}.svc.cluster.local:9090/api/v1/write"
            tls = { insecure = false }
          }

          # Loki (logs)
          loki = {
            endpoint = var.otel_collector.loki_endpoint != "" ? var.otel_collector.loki_endpoint : "http://loki-gateway.${var.observability_namespace}.svc.cluster.local/loki/api/v1/push"
            tls = { insecure = true }
            default_labels_enabled = {
              exporter = false
              job      = true
            }
          }

          # Tempo (traces via OTLP)
          otlp = {
            endpoint = var.otel_collector.tempo_endpoint != "" ? var.otel_collector.tempo_endpoint : "tempo.${var.observability_namespace}.svc.cluster.local:4317"
            tls = { insecure = true }
          }

          # Debug (dev/staging only)
          debug = {
            verbosity = var.environment != "prod" ? "detailed" : "basic"
          }
        }

        service = {
          pipelines = {
            traces = {
              receivers  = ["otlp"]
              processors = ["memory_limiter", "k8sattributes", "resourcedetection", "attributes", "tail_sampling", "batch"]
              exporters  = ["otlp"]
            }
            metrics = {
              receivers  = ["otlp", "prometheus", "hostmetrics"]
              processors = ["memory_limiter", "k8sattributes", "resourcedetection", "batch"]
              exporters  = ["prometheusremotewrite"]
            }
            logs = {
              receivers  = ["otlp", "k8s_events"]
              processors = ["memory_limiter", "k8sattributes", "resourcedetection", "attributes", "batch"]
              exporters  = ["loki"]
            }
          }

          telemetry = {
            logs    = { level = "info" }
            metrics = { level = "detailed", address = "0.0.0.0:8888" }
          }
        }
      }

      # Service for receiving OTLP from all pods
      service = {
        type = "ClusterIP"
        ports = {
          otlp-grpc = { port = 4317, targetPort = 4317 }
          otlp-http = { port = 4318, targetPort = 4318 }
          metrics   = { port = 8888, targetPort = 8888 }
        }
      }

      # Pod security context
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 10001
        seccompProfile = { type = "RuntimeDefault" }
      }

      securityContext = {
        allowPrivilegeEscalation = false
        capabilities = { drop = ["ALL"] }
        readOnlyRootFilesystem   = true
      }

      # Anti-affinity
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchLabels = { "app.kubernetes.io/name" = "opentelemetry-collector" }
              }
              topologyKey = "topology.kubernetes.io/zone"
            }
          }]
        }
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# Grafana Dashboards (ConfigMaps – auto-loaded by sidecar)
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "grafana_dashboard_platform" {
  metadata {
    name      = "grafana-dashboard-platform"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "platform-overview.json" = jsonencode({
      title   = "SuperApp Platform Overview"
      uid     = "superapp-platform-overview"
      refresh = "30s"
      panels  = []  # Panels defined post-deployment via Grafana API
    })
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "prometheus_endpoint" {
  description = "Prometheus internal endpoint"
  value       = "http://kube-prometheus-stack-prometheus.${var.observability_namespace}.svc.cluster.local:9090"
}

output "alertmanager_endpoint" {
  description = "Alertmanager internal endpoint"
  value       = "http://kube-prometheus-stack-alertmanager.${var.observability_namespace}.svc.cluster.local:9093"
}

output "grafana_endpoint" {
  description = "Grafana internal endpoint"
  value       = "http://kube-prometheus-stack-grafana.${var.observability_namespace}.svc.cluster.local:80"
}

output "loki_endpoint" {
  description = "Loki log push endpoint"
  value       = "http://loki-gateway.${var.observability_namespace}.svc.cluster.local/loki/api/v1/push"
}

output "tempo_endpoint" {
  description = "Tempo OTLP gRPC endpoint"
  value       = "tempo.${var.observability_namespace}.svc.cluster.local:4317"
}

output "otel_collector_grpc_endpoint" {
  description = "OTel Collector gRPC endpoint (for OTLP export from services)"
  value       = "otel-collector-opentelemetry-collector.${var.observability_namespace}.svc.cluster.local:4317"
}

output "observability_namespace" {
  description = "Observability namespace name"
  value       = kubernetes_namespace.observability.metadata[0].name
}
