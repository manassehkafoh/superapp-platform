###############################################################################
# SuperApp Platform — FortiCNAPP Integration Module
# Fortinet Cloud-Native Application Protection Platform
# Covers: CWPP, CSPM, Vuln Mgmt, Network Security, Secrets Scanning
# Compliance: SOC 2 CC7.1-CC7.3, PCI-DSS Req.6.3, DORA Art.9
###############################################################################

terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 3.100" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.13"  }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.29"  }
  }
}

###############################################################################
# 1. FortiCNAPP Namespace + RBAC
###############################################################################

resource "kubernetes_namespace" "forticnapp" {
  metadata {
    name = "forticnapp"
    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce" = "privileged"
      "security.forticnapp.io/monitored"   = "false"
    }
  }
}

resource "kubernetes_service_account" "forticnapp_agent" {
  metadata {
    name      = "forticnapp-agent"
    namespace = kubernetes_namespace.forticnapp.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = var.forticnapp_managed_identity_client_id
    }
  }
}

resource "kubernetes_cluster_role" "forticnapp_agent" {
  metadata { name = "forticnapp-agent" }

  rule {
    api_groups = ["", "apps", "batch", "autoscaling", "networking.k8s.io",
                  "rbac.authorization.k8s.io", "cilium.io"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  # Quarantine: create/update CiliumNetworkPolicy to block compromised pod
  rule {
    api_groups = ["cilium.io"]
    resources  = ["ciliumnetworkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "forticnapp_agent" {
  metadata { name = "forticnapp-agent" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.forticnapp_agent.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.forticnapp_agent.metadata[0].name
    namespace = kubernetes_namespace.forticnapp.metadata[0].name
  }
}

###############################################################################
# 2. Credentials synced from Azure Key Vault via External Secrets Operator
###############################################################################

resource "kubernetes_manifest" "forticnapp_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "forticnapp-credentials"
      namespace = kubernetes_namespace.forticnapp.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "azure-keyvault-store", kind = "ClusterSecretStore" }
      target          = { name = "forticnapp-credentials", creationPolicy = "Owner" }
      data = [
        { secretKey = "ACCESS_KEY", remoteRef = { key = "forticnapp-access-key" } },
        { secretKey = "SECRET_KEY", remoteRef = { key = "forticnapp-secret-key" } },
      ]
    }
  }
}

###############################################################################
# 3. FortiCNAPP Helm Chart — Agent DaemonSet + Orchestrator
###############################################################################

resource "helm_release" "forticnapp" {
  name             = "forticnapp"
  repository       = "https://charts.forticnapp.fortinet.com"
  chart            = "forticnapp-agent"
  version          = var.forticnapp_chart_version
  namespace        = kubernetes_namespace.forticnapp.metadata[0].name
  atomic           = true
  timeout          = 600

  values = [yamlencode({
    global = {
      tenantId      = var.forticnapp_tenant_id
      clusterName   = "${var.platform_name}-${var.environment}"
      clusterRegion = var.location
      environment   = var.environment
      credentialsSecretName = "forticnapp-credentials"
      tls = { enabled = true, verifyCloud = true }
    }

    agent = {
      enabled = true
      ebpf    = { enabled = true, fallbackToKernelModule = false }
      resources = {
        requests = { memory = "256Mi", cpu = "100m" }
        limits   = { memory = "512Mi", cpu = "500m" }
      }
      hostPID     = true
      hostNetwork = true
      hostIPC     = false
      tolerations = [
        { operator = "Exists", effect = "NoSchedule" },
        { operator = "Exists", effect = "NoExecute"  },
      ]
      securityContext = { privileged = true }
      updateStrategy  = { type = "RollingUpdate", rollingUpdate = { maxUnavailable = 1 } }
    }

    orchestrator = {
      enabled  = true
      replicas = var.environment == "prod" ? 2 : 1
      resources = {
        requests = { memory = "512Mi", cpu = "200m" }
        limits   = { memory = "1Gi",   cpu = "1000m" }
      }
      persistence = { enabled = true, storageClassName = "managed-premium", size = "10Gi" }
    }

    workloadProtection = {
      enabled             = true
      learningPeriodHours = 48
      processAnomalyDetection = {
        enabled = true
        action  = var.environment == "prod" ? "alert-and-block" : "alert-only"
      }
      fileIntegrityMonitoring = {
        enabled = true
        paths   = ["/etc/ssl/certs", "/var/run/secrets", "/usr/local/bin", "/app"]
        excludePaths = ["/tmp", "/proc", "/sys"]
      }
      cryptoMiningDetection       = { enabled = true, action = "quarantine", confidence = "high" }
      containerEscapeDetection    = { enabled = true, action = "block-and-alert" }
      lateralMovementDetection    = { enabled = true }
      autoQuarantine = {
        enabled         = true
        namespaces      = ["superapp-services", "superapp-gateway"]
        notifyPagerDuty = var.environment == "prod"
        slackWebhook    = var.slack_webhook_url
      }
    }

    postureMgmt = {
      enabled      = true
      scanInterval = "6h"
      benchmarks   = ["cis-kubernetes-1.8", "cis-azure-1.5", "pci-dss-v4", "soc2-type2", "iso-27001-2022"]
      admissionControl = {
        enabled                        = true
        blockOnCriticalVulnerabilities = var.environment == "prod"
        blockOnHighVulnerabilities     = false
      }
    }

    vulnMgmt = {
      enabled     = true
      scanOnAdmit = true
      scanSchedule = "0 2 * * *"
      imageSignatureVerification = {
        enabled     = true
        signingKeys = [var.cosign_public_key]
        action      = var.environment == "prod" ? "block" : "audit"
      }
      thresholds = { block = "CRITICAL", alert = "HIGH", warn = "MEDIUM" }
      registryScanning = {
        enabled      = true
        registryUrl  = var.acr_server
        scanOnPush   = true
      }
    }

    secretsScanning = {
      enabled  = true
      patterns = [
        "-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----",
        "AZURE_CLIENT_SECRET",
        "password\\s*=\\s*['\"][^'\"]{8,}",
        "ghp_[A-Za-z0-9]{36}",
      ]
      action = "alert"
    }

    networkSecurity = {
      enabled             = true
      dnsTunnelDetection  = { enabled = true, action = "alert-and-block" }
      c2Detection         = { enabled = true, threatIntelFeed = "fortiguard", updateInterval = "1h", action = "block" }
      egressAnomalyDetection = { enabled = true, baselinePeriodH = 48, action = "alert" }
    }

    integrations = {
      sentinel  = { enabled = true, eventHubName = var.sentinel_event_hub_name }
      pagerduty = { enabled = var.environment == "prod", severities = ["CRITICAL"] }
      slack     = { enabled = true, webhookUrl = var.slack_webhook_url, channel = "#security-alerts", severities = ["CRITICAL", "HIGH"] }
      jira      = { enabled = var.environment == "prod", projectKey = "SEC", issueType = "Security Bug", autoCreate = true, severities = ["CRITICAL", "HIGH"] }
    }

    metrics = {
      enabled = true
      port    = 9090
      serviceMonitor = {
        enabled   = true
        namespace = "monitoring"
        labels    = { "app.kubernetes.io/part-of" = "kube-prometheus-stack" }
        interval  = "30s"
      }
    }
  })]

  depends_on = [kubernetes_manifest.forticnapp_external_secret]
}

###############################################################################
# 4. FortiCNAPP Admission Policy
###############################################################################

resource "kubernetes_manifest" "forticnapp_admission_policy" {
  manifest = {
    apiVersion = "admission.forticnapp.io/v1"
    kind       = "AdmissionPolicy"
    metadata   = { name = "superapp-admission-policy" }
    spec = {
      namespaces = ["superapp-services", "superapp-gateway"]
      rules = [
        { name = "block-unsigned-images",  enabled = var.environment == "prod", check = "image.signature.verified == true", action = "block", message = "Image must be Cosign-signed for production" },
        { name = "block-critical-cve",     enabled = true, check = "image.vulnerabilities.critical.count == 0", action = var.environment == "prod" ? "block" : "audit", message = "Image has CRITICAL CVEs" },
        { name = "require-resource-limits", enabled = true, check = "pod.containers.all(c, c.resources.limits.memory != null)", action = "block", message = "All containers must have memory limits" },
        { name = "require-non-root",       enabled = true, check = "pod.spec.securityContext.runAsNonRoot == true", action = "block", message = "Containers must not run as root" },
        { name = "block-privileged",       enabled = true, check = "!pod.containers.any(c, c.securityContext.privileged == true)", action = "block", exceptions = ["forticnapp", "cilium"], message = "Privileged containers not allowed" },
        { name = "require-readonly-rootfs", enabled = true, check = "pod.containers.all(c, c.securityContext.readOnlyRootFilesystem == true)", action = var.environment == "prod" ? "block" : "audit", message = "Root filesystem must be read-only" },
      ]
    }
  }
  depends_on = [helm_release.forticnapp]
}

###############################################################################
# Outputs
###############################################################################

output "forticnapp_namespace"     { value = kubernetes_namespace.forticnapp.metadata[0].name }
output "forticnapp_console_url"   { value = "https://forticnapp.fortinet.com/tenant/${var.forticnapp_tenant_id}" }
output "forticnapp_dashboard_url" { value = "https://grafana.${var.domain_name}/d/forticnapp-overview" }
