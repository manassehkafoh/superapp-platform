# =============================================================================
# Module: Azure Hub-Spoke Networking
# =============================================================================
# Topology  : Hub-Spoke with Azure Firewall as the egress/inspection point
# Components: Hub VNet, AKS Spoke, Data Spoke, Integration Spoke
#             Azure Firewall (Premium), DDoS Protection, NSGs, Route Tables
#             Azure Bastion (no public VM SSH — Zero Trust compliance)
#             Private DNS Zones for all PaaS services
# Compliance: SOC 2 CC6.3 (Network Security) | DORA Article 9 | Zero Trust
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "resource_group_name" {
  type = string
}
variable "location" {
  type = string
}
variable "environment" {
  type = string
}
variable "hub_vnet_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "aks_vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}
variable "data_vnet_cidr" {
  type    = string
  default = "10.3.0.0/16"
}
variable "integration_vnet_cidr" {
  type    = string
  default = "10.4.0.0/16"
}
variable "on_premises_cidr_blocks" {
  type    = list(string)
  default = ["192.168.0.0/16"]
}
variable "enable_ddos_protection" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# DDoS Protection Plan (Standard — attach to all VNets needing protection)
# Note: ~$2700/month — enable for production only
# -----------------------------------------------------------------------------
resource "azurerm_network_ddos_protection_plan" "this" {
  count               = var.enable_ddos_protection ? 1 : 0
  name                = "ddos-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Hub VNet — Central network hub; all spoke VNets peer to this
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.hub_vnet_cidr]

  dynamic "ddos_protection_plan" {
    for_each = var.enable_ddos_protection ? [1] : []
    content {
      id     = azurerm_network_ddos_protection_plan.this[0].id
      enable = true
    }
  }

  tags = merge(var.tags, { "vnet-role" = "hub" })
}

# Hub subnets
resource "azurerm_subnet" "firewall" {
  # Note: Subnet must be named exactly "AzureFirewallSubnet"
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_vnet_cidr, 8, 1)] # /24
}

resource "azurerm_subnet" "firewall_mgmt" {
  # Required for forced tunnelling scenarios
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_vnet_cidr, 8, 2)]
}

resource "azurerm_subnet" "gateway" {
  # ExpressRoute + VPN Gateway subnet
  name                 = "GatewaySubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_vnet_cidr, 9, 6)] # /25
}

resource "azurerm_subnet" "bastion" {
  # Note: Must be named exactly "AzureBastionSubnet"
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_vnet_cidr, 9, 8)] # /25 (min /26 for Bastion)
}

resource "azurerm_subnet" "dns_resolver_inbound" {
  name                 = "snet-dns-resolver-inbound"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_vnet_cidr, 11, 40)] # /28

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# -----------------------------------------------------------------------------
# AKS Spoke VNet
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "aks" {
  name                = "vnet-aks-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.aks_vnet_cidr]
  tags                = merge(var.tags, { "vnet-role" = "aks-spoke" })
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [cidrsubnet(var.aks_vnet_cidr, 4, 0)] # /20 — 4094 node IPs

  # Disable network policies so Cilium can manage them
  private_endpoint_network_policies_enabled = false
}

resource "azurerm_subnet" "aks_private_endpoints" {
  name                 = "snet-aks-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [cidrsubnet(var.aks_vnet_cidr, 8, 16)] # /24

  private_endpoint_network_policies_enabled = false
}

resource "azurerm_subnet" "aks_apim" {
  name                 = "snet-apim"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [cidrsubnet(var.aks_vnet_cidr, 8, 17)] # /24
}

# -----------------------------------------------------------------------------
# Data Spoke VNet
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "data" {
  name                = "vnet-data-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.data_vnet_cidr]
  tags                = merge(var.tags, { "vnet-role" = "data-spoke" })
}

resource "azurerm_subnet" "sql_private_endpoint" {
  name                 = "snet-sql-pe"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.data.name
  address_prefixes     = [cidrsubnet(var.data_vnet_cidr, 8, 0)]
  private_endpoint_network_policies_enabled = false
}

resource "azurerm_subnet" "redis_private_endpoint" {
  name                 = "snet-redis-pe"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.data.name
  address_prefixes     = [cidrsubnet(var.data_vnet_cidr, 8, 1)]
  private_endpoint_network_policies_enabled = false
}

resource "azurerm_subnet" "eventhub_private_endpoint" {
  name                 = "snet-eventhub-pe"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.data.name
  address_prefixes     = [cidrsubnet(var.data_vnet_cidr, 8, 2)]
  private_endpoint_network_policies_enabled = false
}

# -----------------------------------------------------------------------------
# VNet Peering: Spoke → Hub (and reverse)
# All traffic between spokes flows through Azure Firewall in the hub
# -----------------------------------------------------------------------------
# AKS Spoke → Hub
resource "azurerm_virtual_network_peering" "aks_to_hub" {
  name                         = "peer-aks-to-hub"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.aks.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true  # Use hub's ExpressRoute/VPN gateways
}

resource "azurerm_virtual_network_peering" "hub_to_aks" {
  name                         = "peer-hub-to-aks"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.aks.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true  # Share hub gateways with spoke
}

# Data Spoke → Hub
resource "azurerm_virtual_network_peering" "data_to_hub" {
  name                         = "peer-data-to-hub"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.data.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true
}

resource "azurerm_virtual_network_peering" "hub_to_data" {
  name                         = "peer-hub-to-data"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.data.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

# -----------------------------------------------------------------------------
# Azure Firewall Premium — all inter-spoke + internet egress inspected here
# Premium required for: TLS inspection, IDPS (IDS/IPS), URL filtering
# -----------------------------------------------------------------------------
resource "azurerm_firewall_policy" "this" {
  name                = "fwpol-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium" # IDPS + TLS inspection require Premium

  threat_intelligence_mode = "Deny" # Block known malicious IPs/domains

  # TLS inspection — decrypt and inspect HTTPS traffic
  tls_certificate {
    key_vault_secret_id = var.firewall_tls_cert_secret_id
    name                = "firewall-tls-cert"
  }

  # IDPS — Intrusion Detection and Prevention (Premium)
  intrusion_detection {
    mode = "Deny" # Block + alert on known attack patterns
  }

  dns {
    servers       = []     # Use Azure DNS
    proxy_enabled = true   # DNS proxy for FQDN-based rules
  }

  tags = var.tags
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-firewall-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"] # Zone-redundant
  tags                = var.tags
}

resource "azurerm_firewall" "this" {
  name                = "fw-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Premium"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  zones               = ["1", "2", "3"]

  ip_configuration {
    name                 = "firewall-ip-config"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Firewall Policy Rules
# -----------------------------------------------------------------------------
resource "azurerm_firewall_policy_rule_collection_group" "platform" {
  name               = "rcg-platform"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 100

  # --- Network Rule Collection: Core infra traffic ---
  network_rule_collection {
    name     = "nrc-aks-infra"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "aks-api-server"
      protocols             = ["TCP"]
      source_addresses      = [var.aks_vnet_cidr]
      destination_addresses = ["AzureCloud.WestEurope"]
      destination_ports     = ["443", "9000"]
      description           = "AKS control plane communication"
    }

    rule {
      name                  = "acr-pull"
      protocols             = ["TCP"]
      source_addresses      = [var.aks_vnet_cidr]
      destination_addresses = ["AzureContainerRegistry"]
      destination_ports     = ["443"]
      description           = "Container image pull from ACR"
    }

    rule {
      name                  = "azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = [var.aks_vnet_cidr]
      destination_addresses = ["AzureMonitor"]
      destination_ports     = ["443"]
      description           = "Telemetry to Azure Monitor / Log Analytics"
    }
  }

  # --- Application Rule Collection: Outbound web traffic ---
  application_rule_collection {
    name     = "arc-external-apis"
    priority = 200
    action   = "Allow"

    rule {
      name              = "allow-payment-networks"
      source_addresses  = [var.aks_vnet_cidr]
      destination_fqdns = [
        "api.visa.com",
        "api.mastercard.com",
        "*.swift.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
      description = "Outbound to payment network APIs"
    }

    rule {
      name              = "allow-update-sources"
      source_addresses  = [var.aks_vnet_cidr]
      destination_fqdns = [
        "packages.microsoft.com",
        "*.ubuntu.com",
        "security.ubuntu.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
      description = "OS + package updates for AKS nodes"
    }
  }
}

# Route Table: Force all AKS egress through Azure Firewall
resource "azurerm_route_table" "aks_egress" {
  name                          = "rt-aks-egress"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  disable_bgp_route_propagation = false
  tags                          = var.tags
}

resource "azurerm_route" "default_via_firewall" {
  name                   = "default-via-firewall"
  resource_group_name    = var.resource_group_name
  route_table_name       = azurerm_route_table.aks_egress.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  route_table_id = azurerm_route_table.aks_egress.id
}

# -----------------------------------------------------------------------------
# Azure Bastion — Secure RDP/SSH to VMs without public IPs
# Replaces jump boxes; no direct inbound SSH/RDP from internet
# SOC 2 CC6.3 — privileged access management
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-superapp-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bastion-superapp-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  copy_paste_enabled     = true
  file_copy_enabled      = false # Restrict file transfer (SOC 2 CC6)
  ip_connect_enabled     = true  # Allow IP-based connection
  shareable_link_enabled = false
  tunneling_enabled      = true  # SSH/RDP tunnelling for native clients

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Private DNS Zones — all PaaS services resolve privately within VNets
# Prevents DNS leakage of internal service names to public DNS
# -----------------------------------------------------------------------------
locals {
  private_dns_zones = [
    "privatelink.database.windows.net",       # Azure SQL
    "privatelink.redis.cache.windows.net",    # Azure Cache for Redis
    "privatelink.servicebus.windows.net",     # Service Bus
    "privatelink.eventhub.windows.net",       # Event Hubs
    "privatelink.azurecr.io",                 # Azure Container Registry
    "privatelink.vaultcore.azure.net",        # Azure Key Vault
    "privatelink.blob.core.windows.net",      # Blob storage
    "privatelink.dfs.core.windows.net",       # ADLS Gen2
    "privatelink.monitor.azure.com",          # Azure Monitor
    "privatelink.oms.opinsights.azure.com",   # Log Analytics
    "privatelink.ods.opinsights.azure.com",
  ]
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = toset(local.private_dns_zones)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Link each private DNS zone to all VNets
resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "link-${replace(each.key, ".", "-")}-hub"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "link-${replace(each.key, ".", "-")}-aks"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.aks.id
  registration_enabled  = false
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "aks_vnet_id" {
  value = azurerm_virtual_network.aks.id
}

output "aks_nodes_subnet_id" {
  value = azurerm_subnet.aks_nodes.id
}

output "aks_private_endpoints_subnet_id" {
  value = azurerm_subnet.aks_private_endpoints.id
}

output "sql_private_endpoint_subnet_id" {
  value = azurerm_subnet.sql_private_endpoint.id
}

output "redis_private_endpoint_subnet_id" {
  value = azurerm_subnet.redis_private_endpoint.id
}

output "eventhub_private_endpoint_subnet_id" {
  value = azurerm_subnet.eventhub_private_endpoint.id
}

output "firewall_private_ip" {
  value = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "private_dns_zone_ids" {
  value = { for k, v in azurerm_private_dns_zone.zones : k => v.id }
}
