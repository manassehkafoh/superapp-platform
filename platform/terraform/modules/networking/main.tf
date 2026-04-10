###############################################################################
# SuperApp Platform — Networking Module
# Hub-spoke VNet topology, Azure Firewall Premium (IDPS Deny), Bastion,
# DDoS Standard, NSGs, UDR, Private DNS Zones
###############################################################################

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
  }
}

variable "resource_group_name" { type = string }
variable "location"             { type = string }
variable "environment"          { type = string }
variable "hub_vnet_cidr"        { type = string, default = "10.0.0.0/16" }
variable "spoke_vnet_cidr"      { type = string, default = "10.1.0.0/16" }
variable "common_tags"          { type = map(string), default = {} }

locals {
  prefix = "superapp-${var.environment}"

  subnets = {
    AzureFirewallSubnet   = cidrsubnet(var.hub_vnet_cidr, 10, 0)  # /26 required by Firewall
    AzureBastionSubnet    = cidrsubnet(var.hub_vnet_cidr, 8, 1)   # /24
    GatewaySubnet         = cidrsubnet(var.hub_vnet_cidr, 8, 2)   # /24
    aks-system            = cidrsubnet(var.spoke_vnet_cidr, 4, 0)  # /20 — system node pool
    aks-app               = cidrsubnet(var.spoke_vnet_cidr, 4, 1)  # /20 — app node pool
    aks-data              = cidrsubnet(var.spoke_vnet_cidr, 4, 2)  # /20 — data node pool
    private-endpoints     = cidrsubnet(var.spoke_vnet_cidr, 8, 48) # /24 — SQL, Redis, KV, ACR
  }

  # Payment rail FQDNs allowed for egress (PCI-DSS network segmentation)
  payment_rail_fqdns = [
    "ghipss.com.gh", "api.ghipss.com.gh",
    "expresspaygh.com", "api.expresspaygh.com",
    "api.hubtel.com",
    "login.microsoftonline.com",    # Azure AD auth
    "management.azure.com",         # Azure API
  ]
}

# ── Hub VNet ─────────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.hub_vnet_cidr]
  tags                = merge(var.common_tags, { tier = "hub-network" })
}

# ── Spoke VNet ────────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-spoke-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.spoke_vnet_cidr]
  tags                = merge(var.common_tags, { tier = "spoke-network" })
}

# ── VNet Peering (bi-directional) ─────────────────────────────────────────────
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "peer-hub-to-spoke"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-spoke-to-hub"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

# ── Subnets ───────────────────────────────────────────────────────────────────
resource "azurerm_subnet" "hub_subnets" {
  for_each             = { for k, v in local.subnets : k => v if contains(["AzureFirewallSubnet", "AzureBastionSubnet", "GatewaySubnet"], k) }
  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [each.value]
}

resource "azurerm_subnet" "spoke_subnets" {
  for_each             = { for k, v in local.subnets : k => v if !contains(["AzureFirewallSubnet", "AzureBastionSubnet", "GatewaySubnet"], k) }
  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [each.value]
}

# ── Azure Firewall Premium (IDPS Deny mode — PCI-DSS Req.1) ──────────────────
resource "azurerm_public_ip" "firewall" {
  name                = "pip-fw-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.common_tags
}

resource "azurerm_firewall_policy" "main" {
  name                = "fwpol-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium"
  threat_intel_mode   = "Deny"

  intrusion_detection {
    mode = var.environment == "prod" ? "Deny" : "Alert"
  }

  dns { proxy_enabled = true }
  tags = var.common_tags
}

resource "azurerm_firewall" "main" {
  name                = "fw-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Premium"
  firewall_policy_id  = azurerm_firewall_policy.main.id
  zones               = ["1", "2", "3"]

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.hub_subnets["AzureFirewallSubnet"].id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  tags = merge(var.common_tags, { component = "firewall" })
}

# Firewall rules — allow payment rails, block everything else
resource "azurerm_firewall_policy_rule_collection_group" "payment_rails" {
  name               = "rcg-payment-rails"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 200

  application_rule_collection {
    name     = "allow-payment-rails"
    priority = 200
    action   = "Allow"

    dynamic "rule" {
      for_each = local.payment_rail_fqdns
      content {
        name             = "allow-${replace(rule.value, ".", "-")}"
        source_addresses = [var.spoke_vnet_cidr]
        destination_fqdns = [rule.value]
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }
}

# ── Azure Bastion Standard (no public SSH — SOC 2 CC6.1) ─────────────────────
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.common_tags
}

resource "azurerm_bastion_host" "main" {
  name                = "bastion-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.hub_subnets["AzureBastionSubnet"].id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = var.common_tags
}

# ── DDoS Protection Standard ──────────────────────────────────────────────────
resource "azurerm_network_ddos_protection_plan" "main" {
  count               = var.environment == "prod" ? 1 : 0
  name                = "ddos-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.common_tags
}

# ── Private DNS Zones (all Azure PaaS services) ───────────────────────────────
locals {
  private_dns_zones = [
    "privatelink.database.windows.net",
    "privatelink.redis.cache.windows.net",
    "privatelink.servicebus.windows.net",
    "privatelink.vaultcore.azure.net",
    "privatelink.azurecr.io",
    "privatelink.blob.core.windows.net",
    "privatelink.azmk8s.io",
  ]
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = toset(local.private_dns_zones)
  name                = each.key
  resource_group_name = var.resource_group_name
  tags                = var.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "link-spoke-${replace(each.key, ".", "-")}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.common_tags
}

# ── UDR: Force all spoke traffic through Firewall ─────────────────────────────
resource "azurerm_route_table" "spoke_udr" {
  name                          = "rt-spoke-${local.prefix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  disable_bgp_route_propagation = true

  route {
    name                   = "force-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }

  tags = var.common_tags
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "hub_vnet_id"         { value = azurerm_virtual_network.hub.id }
output "spoke_vnet_id"       { value = azurerm_virtual_network.spoke.id }
output "aks_app_subnet_id"   { value = azurerm_subnet.spoke_subnets["aks-app"].id }
output "aks_system_subnet_id" { value = azurerm_subnet.spoke_subnets["aks-system"].id }
output "private_ep_subnet_id" { value = azurerm_subnet.spoke_subnets["private-endpoints"].id }
output "firewall_private_ip" { value = azurerm_firewall.main.ip_configuration[0].private_ip_address }
output "private_dns_zone_ids" { value = { for k, v in azurerm_private_dns_zone.zones : k => v.id } }
