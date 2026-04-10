###############################################################################
# SuperApp Platform — Terraform Providers & Backend Configuration
# 
# Purpose : Declares all providers (Azure + GCP + Kubernetes + Helm + Vault)
#           and configures remote state storage (Azure Blob backend)
#
# SOC 2   : State files contain sensitive data; backend uses encryption +
#           Azure RBAC access control + immutable versioning
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    # Populated via -backend-config flags in CI/CD — NEVER hardcode keys
    resource_group_name  = "rg-superapp-tfstate"
    storage_account_name = "stgsuperapptfstate"
    container_name       = "tfstate"
    key                  = "superapp.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 3.100" }
    azuread    = { source = "hashicorp/azuread",    version = "~> 2.50"  }
    google     = { source = "hashicorp/google",     version = "~> 5.25"  }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.25" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.29"  }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13"  }
    vault      = { source = "hashicorp/vault",      version = "~> 3.25"  }
    random     = { source = "hashicorp/random",     version = "~> 3.6"   }
    tls        = { source = "hashicorp/tls",        version = "~> 4.0"   }
    time       = { source = "hashicorp/time",       version = "~> 0.11"  }
  }
}

provider "azurerm" {
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
    virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = true
      skip_shutdown_and_force_delete = false
    }
  }
  use_oidc = true
}

provider "azuread" { use_oidc = true }

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_primary_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_primary_region
}

provider "kubernetes" {
  alias = "aks"
  host  = module.aks_cluster.kube_config.host
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--environment", "AzurePublicCloud",
                   "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
                   "--login", "workloadidentity"]
  }
}

provider "kubernetes" {
  alias                  = "gke"
  host                   = "https://${module.gke_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke_cluster.ca_certificate)
}

provider "helm" {
  alias = "aks"
  kubernetes {
    host = module.aks_cluster.kube_config.host
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = ["get-token", "--environment", "AzurePublicCloud",
                     "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
                     "--login", "workloadidentity"]
    }
  }
}

provider "vault" {
  address = "https://vault.${var.internal_domain}:8200"
  auth_login {
    path       = "auth/kubernetes/login"
    parameters = { role = "terraform", jwt = file("/var/run/secrets/kubernetes.io/serviceaccount/token") }
  }
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}
data "google_client_config" "default" {}
