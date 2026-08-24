# Azure Standard Load Balancer, layer 4.
#
# The same reasoning as the AWS side: docs/security.md commits to TLS
# terminating at the Vault process, so this must not be an Application
# Gateway. A Standard LB forwards TCP without decrypting, which keeps the
# client's TLS session end-to-end with Vault and means the load balancer
# never holds a certificate.
#
# Standard rather than Basic: Basic is retiring, does not support
# availability zones, and has no NSG integration.

resource "azurerm_public_ip" "lb" {
  # Only created when the load balancer is internet-facing. Vault normally
  # has no business having a public frontend.
  count = var.internal_lb ? 0 : 1

  name                = "${var.cluster_name}-lb"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_lb" "vault" {
  name                = "${var.cluster_name}-lb"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name = "vault-frontend"

    # Internal: a private address on the load balancer subnet.
    # Public: the IP above. Exactly one of these is set.
    subnet_id                     = var.internal_lb ? azurerm_subnet.lb.id : null
    private_ip_address_allocation = var.internal_lb ? "Dynamic" : null
    public_ip_address_id          = var.internal_lb ? null : azurerm_public_ip.lb[0].id
  }

  tags = module.vault_cluster.cluster_tags
}

resource "azurerm_lb_backend_address_pool" "vault" {
  name            = "vault-nodes"
  loadbalancer_id = azurerm_lb.vault.id
}

# The probe is what makes this cluster-aware.
#
# Azure probes have no equivalent of AWS's status-code matcher — they
# accept 200-299 and nothing else. Vault returns 429 on a standby, which
# Azure would treat as unhealthy and eject, leaving only the leader in the
# pool. standbyok=true makes Vault answer 200 for a healthy standby
# instead, which is how the same behaviour is achieved here.
resource "azurerm_lb_probe" "vault" {
  name            = "vault-health"
  loadbalancer_id = azurerm_lb.vault.id
  protocol        = "Https"
  port            = 8200
  request_path    = "/v1/sys/health?standbyok=true&perfstandbyok=true"

  interval_in_seconds = 10
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "vault" {
  name                           = "vault-api"
  loadbalancer_id                = azurerm_lb.vault.id
  protocol                       = "Tcp"
  frontend_port                  = 8200
  backend_port                   = 8200
  frontend_ip_configuration_name = azurerm_lb.vault.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.vault.id]
  probe_id                       = azurerm_lb_probe.vault.id

  # Vault's own request forwarding sends writes received by a standby on
  # to the leader, so client affinity buys nothing and would unbalance the
  # pool.
  load_distribution = "Default"

  # Without this an outbound flow can be silently dropped after idling,
  # which shows up as intermittent hangs rather than clean errors.
  enable_tcp_reset = true
}
