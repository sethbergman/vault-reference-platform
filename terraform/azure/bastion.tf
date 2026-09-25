# Reaching the nodes.
#
# The nodes sit in a private subnet with no public IP and no inbound 22,
# which is the posture network.tf argues for and this file does not
# change. What it adds is a way in that is not a hole: Azure Bastion
# terminates the session in a managed service, and `az network bastion
# tunnel` carries an ordinary SSH connection down it. Nothing here gets a
# public address, and there is no jump host to patch.
#
# WHY THIS EXISTS AT ALL
#
# Until 2026-09-25 this profile had no way to reach a node. The inventory
# resolved ansible_host to a private address with nothing routing to it,
# so `ansible-playbook` could not connect from anywhere outside the VNet:
# snapshots, audit devices, PKI and hardening were all unreachable, and so
# was any diagnosis of a node that failed to start. The AWS profile solved
# the same problem with Session Manager, which is why its inventory
# carries a ProxyCommand; this is the Azure counterpart.
#
# WHY STANDARD, AND WHY IT IS ON BY DEFAULT
#
# Tunnelling is a Standard SKU feature. Basic offers browser sessions
# only, which no automation can drive -- a Bastion that cannot tunnel
# leaves this profile exactly as unreachable as it was, while costing
# money, so the SKU is pinned rather than defaulted.
#
# It defaults to on because the alternative is the failure terraform/aws
# spent a session learning: an apply that succeeds and produces a cluster
# nobody can configure. That profile ships `ssh_key_name` empty, the first
# real apply produced instances nobody could log into, and the pre-flight
# now fails on it. Paying for reachability by default is the cheaper
# mistake. Set bastion_enabled = false when you have another route into
# the VNet -- a VPN, ExpressRoute, a jump host of your own -- and know
# that the playbook cannot run without one.
#
# COST
#
# Standard is about $0.19/hour for the host plus outbound data, so roughly
# $140/month if left running, and well under a dollar for the length of a
# verification session. It is the second-largest line in this profile
# after the NAT gateway. Destroy it with the cluster.

resource "azurerm_subnet" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  # The name is not a choice. Azure rejects a Bastion host whose subnet is
  # called anything else, and it must be at least a /26 -- the third /24
  # carved out of the VNet is comfortably larger.
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.vault.name
  virtual_network_name = azurerm_virtual_network.vault.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 2)]
}

# Standard SKU, static allocation: Bastion accepts nothing else, and a
# dynamic address would change under a running tunnel.
resource "azurerm_public_ip" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  name                = "${var.cluster_name}-bastion"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_bastion_host" "vault" {
  count = var.bastion_enabled ? 1 : 0

  name                = "${var.cluster_name}-bastion"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  # Standard for tunneling_enabled; see the header. scale_units is Standard's
  # floor of 2, stated rather than defaulted so a reader can see what is
  # being paid for.
  sku                    = "Standard"
  tunneling_enabled      = true
  scale_units            = 2
  ip_connect_enabled     = false
  shareable_link_enabled = false

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }

  tags = module.vault_cluster.cluster_tags
}

# The node NSG denies everything inbound at 4096. Bastion reaches a target
# from its own subnet, so 22 is opened from that prefix and from nowhere
# else -- not from the VNet, which would let any compromised workload in
# the address space reach sshd on a Vault node.
resource "azurerm_network_security_rule" "bastion_ssh" {
  count = var.bastion_enabled ? 1 : 0

  name                        = "allow-bastion-ssh"
  resource_group_name         = azurerm_resource_group.vault.name
  network_security_group_name = azurerm_network_security_group.vault.name
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = cidrsubnet(var.vnet_cidr, 8, 2)
  destination_address_prefix  = cidrsubnet(var.vnet_cidr, 8, 0)
}
