# =============================================================================
# SuperApp Platform – Production Environment Root Module
# Orchestrates all Azure + AWS + Shared modules for the PROD environment
# =============================================================================
# Usage:
#   cd terraform/environments/prod
#   terraform init
#   terraform plan -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
# =============================================================================

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.3"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state – Terraform Cloud (or Azure Blob / S3 for self-hosted)
  # ---------------------------------------------------------------------------
  backend "azurerm" {
    resource_group_name  = "rg-superapp-tfstate"
    storage_account_name = "stsuperappterraformstate"
    container_name       = "tfstate"
    key                  = "prod/terraform.tfstate"

    # Use Azure AD auth (no storage account key)
    use_azuread_auth = true
  }
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------
provider "azurerm" {
  alias           = "primary"
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
  features {
    key_vault {
      purge_soft_delete_on_destroy               = false
      recover_soft_deleted_key_vaults            = true
      purge_soft_deleted_secrets_on_destroy      = false
      purge_soft_deleted_certificates_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azurerm" {
  alias           = "north_europe"
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
  features {}
}

provider "aws" {
  alias  = "primary"
  region = var.aws_primary_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.aws_account_id}:role/TerraformDeployRole"
    session_name = "superapp-terraform-prod"
  }

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "dr_region"
  region = var.aws_dr_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.aws_account_id}:role/TerraformDeployRole"
    session_name = "superapp-terraform-prod-dr"
  }
}

# AKS provider – configured after AKS module creates cluster
provider "kubernetes" {
  alias                  = "aks"
  host                   = module.aks_primary.cluster_endpoint
  client_certificate     = base64decode(module.aks_primary.client_certificate)
  client_key             = base64decode(module.aks_primary.client_key)
  cluster_ca_certificate = base64decode(module.aks_primary.cluster_ca_certificate)
}

# EKS provider – configured after EKS module creates cluster
provider "kubernetes" {
  alias                  = "eks"
  host                   = module.eks_dr.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_dr.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks_dr.cluster_name,
      "--region", var.aws_primary_region
    ]
  }
}

provider "helm" {
  alias = "aks"
  kubernetes {
    host                   = module.aks_primary.cluster_endpoint
    client_certificate     = base64decode(module.aks_primary.client_certificate)
    client_key             = base64decode(module.aks_primary.client_key)
    cluster_ca_certificate = base64decode(module.aks_primary.cluster_ca_certificate)
  }
}

provider "helm" {
  alias = "eks"
  kubernetes {
    host                   = module.eks_dr.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_dr.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_dr.cluster_name]
    }
  }
}

# ---------------------------------------------------------------------------
# Variables (values in terraform.tfvars)
# ---------------------------------------------------------------------------
variable "environment"          { type = string; default = "prod" }
variable "azure_subscription_id" { type = string }
variable "azure_tenant_id"      { type = string }
variable "azure_primary_location" { type = string; default = "westeurope" }
variable "azure_dr_location"    { type = string; default = "northeurope" }
variable "aws_account_id"       { type = string }
variable "aws_primary_region"   { type = string; default = "eu-west-1" }
variable "aws_dr_region"        { type = string; default = "eu-central-1" }
variable "on_premises_public_ip" { type = string; default = "" }
variable "alert_emails"          { type = list(string); default = [] }
variable "pagerduty_key"         { type = string; sensitive = true; default = "" }
variable "slack_api_url"         { type = string; sensitive = true; default = "" }
variable "grafana_admin_password" { type = string; sensitive = true; default = "" }

# ---------------------------------------------------------------------------
# Local values
# ---------------------------------------------------------------------------
locals {
  environment = var.environment

  common_tags = {
    Environment     = var.environment
    Project         = "superapp"
    ManagedBy       = "terraform"
    CostCenter      = "platform-engineering"
    DataClass       = "confidential"
    Compliance      = "soc2,dora"
    Owner           = "platform-team@company.com"
    CreatedAt       = formatdate("YYYY-MM-DD", timestamp())
  }

  # CIDR allocations (non-overlapping across all environments)
  azure_hub_cidr              = "10.1.0.0/16"
  azure_aks_spoke_cidr        = "10.2.0.0/16"
  azure_data_spoke_cidr       = "10.3.0.0/16"
  azure_integration_spoke_cidr = "10.4.0.0/16"
  aws_vpc_cidr                = "10.5.0.0/16"
  on_premises_cidr            = "10.0.0.0/8"
}

# ---------------------------------------------------------------------------
# Azure Resource Groups
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "primary" {
  provider = azurerm.primary
  name     = "rg-superapp-${var.environment}-${var.azure_primary_location}"
  location = var.azure_primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "dr" {
  provider = azurerm.north_europe
  name     = "rg-superapp-${var.environment}-${var.azure_dr_location}"
  location = var.azure_dr_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Module: Azure Networking (Hub-Spoke)
# ---------------------------------------------------------------------------
module "azure_networking" {
  source = "../../modules/azure/networking"

  providers = { azurerm = azurerm.primary }

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.azure_primary_location
  environment         = var.environment
  tags                = local.common_tags

  hub_vnet_cidr             = local.azure_hub_cidr
  aks_spoke_vnet_cidr       = local.azure_aks_spoke_cidr
  data_spoke_vnet_cidr      = local.azure_data_spoke_cidr
  integration_spoke_vnet_cidr = local.azure_integration_spoke_cidr
}

# ---------------------------------------------------------------------------
# Module: Azure Security (Key Vault, ACR, Defender, Sentinel)
# ---------------------------------------------------------------------------
module "azure_security" {
  source = "../../modules/azure/security"

  providers = { azurerm = azurerm.primary }

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.azure_primary_location
  environment         = var.environment
  tags                = local.common_tags
  tenant_id           = var.azure_tenant_id

  subnet_id_private_endpoint = module.azure_networking.aks_subnet_id

  private_dns_zone_ids = {
    key_vault = module.azure_networking.private_dns_zone_id_key_vault
    acr       = module.azure_networking.private_dns_zone_id_acr
  }

  github_oidc_subjects = [
    "repo:your-org/superapp-platform:environment:production",
    "repo:your-org/superapp-services:environment:production"
  ]
}

# ---------------------------------------------------------------------------
# Module: Azure AKS (Primary Cluster)
# ---------------------------------------------------------------------------
module "aks_primary" {
  source = "../../modules/azure/aks"

  providers = { azurerm = azurerm.primary }

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.azure_primary_location
  environment         = var.environment
  tags                = local.common_tags

  cluster_name         = "aks-superapp-${var.environment}-primary"
  kubernetes_version   = "1.30"
  private_cluster_enabled = true

  vnet_subnet_id       = module.azure_networking.aks_subnet_id
  log_analytics_workspace_id = module.azure_monitoring.law_workspace_id
  acr_id               = module.azure_security.acr_id

  # Node pools
  system_node_pool = {
    vm_size    = "Standard_D4ds_v5"
    node_count = 3
    zones      = ["1", "2", "3"]
  }

  workload_node_pools = {
    general = {
      vm_size       = "Standard_D8ds_v5"
      min_count     = 3
      max_count     = 20
      node_labels   = { workload = "general" }
    }
    t24_integration = {
      vm_size       = "Standard_D4ds_v5"
      min_count     = 2
      max_count     = 8
      node_labels   = { workload = "t24-integration" }
      node_taints   = ["workload=t24-integration:NoSchedule"]
    }
  }
}

# ---------------------------------------------------------------------------
# Module: Azure Monitoring
# ---------------------------------------------------------------------------
module "azure_monitoring" {
  source = "../../modules/azure/monitoring"

  providers = { azurerm = azurerm.primary }

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.azure_primary_location
  environment         = var.environment
  tags                = local.common_tags

  subnet_id_private_endpoint  = module.azure_networking.aks_subnet_id
  private_dns_zone_id_monitor = module.azure_networking.private_dns_zone_id_monitor

  alert_action_group_emails    = var.alert_emails
  alert_action_group_webhook_url = var.pagerduty_key

  aks_cluster_ids = {
    primary = module.aks_primary.cluster_id
  }

  application_insights = {
    "api-gateway"         = { application_type = "web" }
    "user-service"        = { application_type = "web" }
    "account-service"     = { application_type = "web" }
    "payment-service"     = { application_type = "web" }
    "notification-service" = { application_type = "web" }
    "t24-adapter"         = { application_type = "web" }
  }
}

# ---------------------------------------------------------------------------
# Module: Azure Databases (SQL Hyperscale, Redis, Event Hubs)
# ---------------------------------------------------------------------------
module "azure_databases" {
  source = "../../modules/azure/databases"

  providers = { azurerm = azurerm.primary }

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.azure_primary_location
  dr_location         = var.azure_dr_location
  environment         = var.environment
  tags                = local.common_tags

  subnet_id_private_endpoint = module.azure_networking.data_subnet_id

  private_dns_zone_ids = {
    sql       = module.azure_networking.private_dns_zone_id_sql
    redis     = module.azure_networking.private_dns_zone_id_redis
    eventhubs = module.azure_networking.private_dns_zone_id_eventhubs
  }

  key_vault_id = module.azure_security.key_vault_id
  log_analytics_workspace_id = module.azure_monitoring.law_workspace_id
}

# ---------------------------------------------------------------------------
# Module: AWS Networking (VPC, Subnets, TGW, VPN)
# ---------------------------------------------------------------------------
module "aws_networking" {
  source = "../../modules/aws/networking"

  providers = { aws = aws.primary }

  environment  = var.environment
  aws_region   = var.aws_primary_region
  tags         = local.common_tags

  vpc = {
    cidr = local.aws_vpc_cidr
  }

  availability_zones = ["${var.aws_primary_region}a", "${var.aws_primary_region}b", "${var.aws_primary_region}c"]

  private_subnet_cidrs  = ["10.5.1.0/24", "10.5.2.0/24", "10.5.3.0/24"]
  public_subnet_cidrs   = ["10.5.11.0/24", "10.5.12.0/24", "10.5.13.0/24"]
  database_subnet_cidrs = ["10.5.21.0/24", "10.5.22.0/24", "10.5.23.0/24"]

  on_premises_public_ip  = var.on_premises_public_ip
  on_premises_cidr       = local.on_premises_cidr
  azure_primary_cidr     = local.azure_hub_cidr
  azure_dr_cidr          = "10.2.0.0/16"
  kms_key_arn            = module.aws_security.kms_key_arn
}

# ---------------------------------------------------------------------------
# Module: AWS Security (KMS, GuardDuty, Security Hub)
# ---------------------------------------------------------------------------
module "aws_security" {
  source = "../../modules/aws/security"   # to be created in follow-on

  providers = { aws = aws.primary }

  environment = var.environment
  tags        = local.common_tags
  aws_region  = var.aws_primary_region
  aws_account_id = var.aws_account_id
}

# ---------------------------------------------------------------------------
# Module: AWS EKS (DR Cluster)
# ---------------------------------------------------------------------------
module "eks_dr" {
  source = "../../modules/aws/eks"

  providers = { aws = aws.primary }

  environment    = var.environment
  aws_region     = var.aws_primary_region
  tags           = local.common_tags

  cluster_name   = "eks-superapp-${var.environment}-dr"
  cluster_version = "1.30"

  vpc_id          = module.aws_networking.vpc_id
  subnet_ids      = module.aws_networking.private_subnet_ids
  kms_key_arn     = module.aws_security.kms_key_arn

  node_group = {
    instance_types = ["m7g.2xlarge"]
    desired_size   = 3
    min_size       = 2
    max_size       = 10
    capacity_type  = "ON_DEMAND"
  }
}

# ---------------------------------------------------------------------------
# Module: AWS Databases (Aurora Babelfish, MSK, ElastiCache)
# ---------------------------------------------------------------------------
module "aws_databases" {
  source = "../../modules/aws/databases"

  providers = { aws = aws.primary }

  environment       = var.environment
  aws_region        = var.aws_primary_region
  tags              = local.common_tags
  vpc_id            = module.aws_networking.vpc_id
  vpc_cidr          = module.aws_networking.vpc_cidr
  private_subnet_ids = module.aws_networking.private_subnet_ids
  db_subnet_group_name = module.aws_networking.db_subnet_group_name
  elasticache_subnet_group_name = module.aws_networking.elasticache_subnet_group_name
  kms_key_arn       = module.aws_security.kms_key_arn
}

# ---------------------------------------------------------------------------
# Module: HashiCorp Vault (Primary – AKS)
# ---------------------------------------------------------------------------
module "vault_primary" {
  source = "../../modules/shared/vault"

  providers = {
    helm       = helm.aks
    kubernetes = kubernetes.aks
    azurerm    = azurerm.primary
    aws        = aws.primary
  }

  environment = var.environment
  tags        = local.common_tags

  azure = {
    tenant_id           = var.azure_tenant_id
    key_vault_name      = module.azure_security.key_vault_name
    key_vault_key_name  = "vault-auto-unseal"
    resource_group      = azurerm_resource_group.primary.name
    location            = var.azure_primary_location
    cluster_oidc_issuer = module.aks_primary.oidc_issuer_url
  }

  aws = {
    region              = var.aws_primary_region
    kms_key_id          = module.aws_security.kms_key_id
    cluster_oidc_issuer = module.eks_dr.oidc_issuer_url
    account_id          = var.aws_account_id
  }

  vault_replicas   = 3
  ui_enabled       = false
  metrics_enabled  = true
}

# ---------------------------------------------------------------------------
# Module: Observability Stack (Primary – AKS)
# ---------------------------------------------------------------------------
module "observability_primary" {
  source = "../../modules/shared/observability"

  providers = {
    helm       = helm.aks
    kubernetes = kubernetes.aks
  }

  environment    = var.environment
  cluster_name   = "aks-superapp-${var.environment}-primary"
  cloud_provider = "azure"
  tags           = local.common_tags

  prometheus = {
    replicas             = 2
    retention            = "90d"
    storage_size_gb      = 200
    storage_class        = "managed-premium-zrs"
    enable_remote_write  = true
    remote_write_endpoint = module.azure_monitoring.prometheus_query_endpoint
  }

  alertmanager = {
    replicas         = 2
    pagerduty_key    = var.pagerduty_key
    slack_api_url    = var.slack_api_url
    slack_channel    = "#alerts-prod"
  }

  loki = {
    replicas        = 3
    storage_size_gb = 200
    retention_days  = 90
    storage_class   = "managed-premium-zrs"
  }

  tempo = {
    replicas        = 2
    storage_size_gb = 100
    retention_hours = 720
  }

  grafana_admin_password = var.grafana_admin_password
}

# ---------------------------------------------------------------------------
# Module: Observability Stack (DR – EKS)
# ---------------------------------------------------------------------------
module "observability_dr" {
  source = "../../modules/shared/observability"

  providers = {
    helm       = helm.eks
    kubernetes = kubernetes.eks
  }

  environment    = var.environment
  cluster_name   = "eks-superapp-${var.environment}-dr"
  cloud_provider = "aws"
  tags           = local.common_tags

  prometheus = {
    replicas             = 2
    retention            = "30d"  # shorter on DR
    storage_size_gb      = 100
    storage_class        = "gp3"
    enable_remote_write  = false
  }

  alertmanager = {
    replicas = 1
  }

  loki = {
    replicas        = 2
    storage_size_gb = 100
    retention_days  = 30
    storage_class   = "gp3"
  }

  tempo = {
    replicas        = 1
    storage_size_gb = 50
    retention_hours = 168  # 7 days on DR
  }

  grafana_admin_password = var.grafana_admin_password
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "aks_cluster_name" {
  description = "AKS primary cluster name"
  value       = module.aks_primary.cluster_name
}

output "eks_cluster_name" {
  description = "EKS DR cluster name"
  value       = module.eks_dr.cluster_name
}

output "acr_login_server" {
  description = "Azure Container Registry login server"
  value       = module.azure_security.acr_login_server
}

output "vault_address" {
  description = "Vault cluster address"
  value       = module.vault_primary.vault_address
}

output "grafana_endpoint" {
  description = "Grafana dashboard URL"
  value       = module.azure_monitoring.grafana_endpoint
}

output "aurora_cluster_endpoint" {
  description = "Aurora Babelfish writer endpoint (DR)"
  value       = module.aws_databases.aurora_cluster_endpoint
  sensitive   = true
}

output "msk_bootstrap_brokers" {
  description = "MSK Kafka bootstrap brokers (DR)"
  value       = module.aws_databases.msk_bootstrap_brokers_sasl_iam
  sensitive   = true
}
