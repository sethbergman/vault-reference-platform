# Network layout, mirroring terraform/aws/network.tf: Vault nodes sit in a
# private subnet with no public IPs, and only the load balancer is
# reachable — and even that is internal by default.
#
# The Azure shape differs from AWS in two ways worth knowing:
#
#   - Subnets are not per-availability-zone. One subnet spans the region,
#     and zone spread is a property of the scale set, not the subnet. So
#     there is a single Vault subnet here rather than one per zone.
#   - Outbound access needs an explicit NAT gateway. Azure's default
#     outbound access for new deployments is being retired, and relying
#     on it means nodes lose internet access on a date outside your
#     control.

resource "azurerm_virtual_network" "vault" {
  name                = "${var.cluster_name}-vnet"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  address_space       = [var.vnet_cidr]

  tags = module.vault_cluster.cluster_tags
}

# Nodes. Service endpoints let the subnet reach Key Vault and Storage over
# the Azure backbone rather than via the NAT gateway and the public
# internet — which also makes the Key Vault network ACL able to name this
# subnet rather than an IP range.
resource "azurerm_subnet" "vault" {
  name                 = "${var.cluster_name}-nodes"
  resource_group_name  = azurerm_resource_group.vault.name
  virtual_network_name = azurerm_virtual_network.vault.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 0)]

  service_endpoints = [
    "Microsoft.KeyVault",
    "Microsoft.Storage",
  ]
}

# The load balancer's frontend lives here when it is internet-facing. Kept
# separate from the node subnet so the two never share a security group by
# accident.
resource "azurerm_subnet" "lb" {
  name                 = "${var.cluster_name}-lb"
  resource_group_name  = azurerm_resource_group.vault.name
  virtual_network_name = azurerm_virtual_network.vault.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)]
}

# ---------------------------------------------------------------------------
# Outbound
# ---------------------------------------------------------------------------
# Explicit NAT gateway rather than Azure's implicit default outbound,
# which is deprecated and will stop working for new deployments. Nodes
# need it to install packages at boot; Key Vault and Storage go over
# service endpoints instead.
resource "azurerm_public_ip" "nat" {
  name                = "${var.cluster_name}-nat"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_nat_gateway" "vault" {
  name                    = "${var.cluster_name}-nat"
  resource_group_name     = azurerm_resource_group.vault.name
  location                = azurerm_resource_group.vault.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_nat_gateway_public_ip_association" "vault" {
  nat_gateway_id       = azurerm_nat_gateway.vault.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "vault" {
  subnet_id      = azurerm_subnet.vault.id
  nat_gateway_id = azurerm_nat_gateway.vault.id
}

# ---------------------------------------------------------------------------
# Network security group
# ---------------------------------------------------------------------------
# Azure NSGs are ordered rules with an explicit priority, unlike AWS
# security groups where every rule is an independent allow. That means the
# deny at the end is doing real work: without it the platform's default
# rules would still permit intra-VNet traffic on any port.
resource "azurerm_network_security_group" "vault" {
  name                = "${var.cluster_name}-nodes"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_network_security_rule" "vault_api" {
  name                        = "AllowVaultAPI"
  resource_group_name         = azurerm_resource_group.vault.name
  network_security_group_name = azurerm_network_security_group.vault.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8200"
  source_address_prefixes     = var.allowed_cidr_blocks
  destination_address_prefix  = "*"
  description                 = "Vault API from allowed networks, via the load balancer"
}

# Raft replication and leader election. Scoped to the node subnet itself
# rather than the whole VNet, so anything else in the network cannot reach
# the cluster port.
resource "azurerm_network_security_rule" "vault_cluster" {
  name                        = "AllowRaftCluster"
  resource_group_name         = azurerm_resource_group.vault.name
  network_security_group_name = azurerm_network_security_group.vault.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8201"
  source_address_prefix       = cidrsubnet(var.vnet_cidr, 8, 0)
  destination_address_prefix  = "*"
  description                 = "Raft cluster traffic between nodes only"
}

# Health probes come from a platform-owned address, not from the VNet.
# Without this the load balancer marks every node unhealthy and the
# cluster looks down while being perfectly fine.
resource "azurerm_network_security_rule" "health_probe" {
  name                        = "AllowAzureLoadBalancerProbe"
  resource_group_name         = azurerm_resource_group.vault.name
  network_security_group_name = azurerm_network_security_group.vault.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8200"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  description                 = "Load balancer health probes"
}

resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "DenyAllInbound"
  resource_group_name         = azurerm_resource_group.vault.name
  network_security_group_name = azurerm_network_security_group.vault.name
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  description                 = "Everything not explicitly allowed above"
}

resource "azurerm_subnet_network_security_group_association" "vault" {
  subnet_id                 = azurerm_subnet.vault.id
  network_security_group_id = azurerm_network_security_group.vault.id
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------
# The Azure equivalent of the VPC flow logs in terraform/aws. Vault's audit
# device records requests it served; these record the attempts it never
# saw.
resource "azurerm_network_watcher" "vault" {
  name                = "${var.cluster_name}-watcher"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_network_watcher_flow_log" "vault" {
  name                 = "${var.cluster_name}-flow-log"
  network_watcher_name = azurerm_network_watcher.vault.name
  resource_group_name  = azurerm_resource_group.vault.name
  location             = azurerm_resource_group.vault.location

  network_security_group_id = azurerm_network_security_group.vault.id
  storage_account_id        = azurerm_storage_account.vault.id
  enabled                   = true

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }
}
