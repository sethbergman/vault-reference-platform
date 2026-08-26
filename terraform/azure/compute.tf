# Vault nodes as a VM scale set, mirroring the AWS autoscaling group.
#
# As on AWS, this exists for self-healing rather than elasticity: Raft
# membership is consensus-based, so instances cannot be added and removed
# freely to track load. The instance count is pinned to node_count and
# there is no autoscale rule — what the scale set buys is that a failed
# instance is replaced and rejoins on its own via auto_join.

resource "azurerm_user_assigned_identity" "vault" {
  name                = "${var.cluster_name}-vault"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  tags = module.vault_cluster.cluster_tags
}

# Auto-unseal. This is the access policy that main.tf previously pointed
# at a placeholder null-GUID because there was no identity to grant it to.
resource "azurerm_key_vault_access_policy" "vault_nodes" {
  key_vault_id = azurerm_key_vault.vault_autounseal.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.vault.principal_id

  # Wrap and unwrap only — enough to seal and unseal, and not enough to
  # read the key material itself.
  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

# Raft auto-join enumerates the scale set's network interfaces through
# the Azure API. Reader on the resource group is the smallest built-in
# role that covers the required
# Microsoft.Compute/virtualMachineScaleSets/*/read.
resource "azurerm_role_assignment" "vault_autojoin" {
  scope                = azurerm_resource_group.vault.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.vault.principal_id
}

# Snapshots. Data-plane access to blobs, deliberately Contributor on the
# container rather than an account-key credential — and note the storage
# account has shared_access_key_enabled = false, so this identity is the
# only way in.
resource "azurerm_role_assignment" "vault_snapshots" {
  scope                = azurerm_storage_container.snapshots.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.vault.principal_id
}

# The scale set name is referenced from inside the scale set's own
# cloud-init (Raft discovery filters on it), which would be a self-
# reference. A local breaks the cycle and keeps the two in step — see
# the retry_join note in templates/cloud-init.sh.tftpl.
locals {
  vault_scale_set_name = "${var.cluster_name}-vault"
}

resource "azurerm_linux_virtual_machine_scale_set" "vault" {
  name                = local.vault_scale_set_name
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  sku       = var.vm_size
  instances = var.node_count

  # Spread across zones so losing one costs at most ceil(node_count/zones)
  # nodes. "1" means strict zone balance — Azure will fail the deployment
  # rather than quietly placing everything in one zone.
  zones                       = var.availability_zones
  zone_balance                = true
  platform_fault_domain_count = 1
  upgrade_mode                = "Manual"

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.vault.id]
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
    disk_size_gb         = var.os_disk_size_gb
  }

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    vault_version   = var.vault_version
    cluster_name    = var.cluster_name
    key_vault_name  = azurerm_key_vault.vault_autounseal.name
    key_name        = azurerm_key_vault_key.vault_autounseal.name
    tenant_id       = data.azurerm_client_config.current.tenant_id
    subscription_id = data.azurerm_client_config.current.subscription_id
    resource_group  = azurerm_resource_group.vault.name
    vm_scale_set    = local.vault_scale_set_name
  }))

  network_interface {
    name    = "${var.cluster_name}-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.vault.id

      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.vault.id,
      ]
    }
  }

  # Replace an instance whose Vault process is unhealthy, not merely one
  # whose VM has stopped — the same reasoning as using ELB health checks
  # on AWS. A node that is running but sealed is useless.
  health_probe_id = azurerm_lb_probe.vault.id

  automatic_instance_repair {
    enabled = true
    # Long enough for a replacement to install Vault, auto-unseal and join
    # Raft before the platform decides it is unhealthy and starts again.
    grace_period = "PT30M"
  }

  boot_diagnostics {}

  tags = merge(module.vault_cluster.cluster_tags, {
    # What ansible/inventory/azure.yml filters on. NOT what retry_join
    # matches: go-discover's azure provider rejects a mix of tag and
    # scale-set selectors, so the cloud-init template enumerates the
    # scale set instead and never looks at tags.
    #
    # Which means this tag and Raft discovery fail independently here,
    # unlike the AWS profile where one tag drives both. Changing it
    # empties the inventory and leaves the cluster fine.
    VaultCluster = var.cluster_name
  })

  depends_on = [
    # Without the access policy in place first, the first boot cannot
    # unseal and the node sits sealed until something retries.
    azurerm_key_vault_access_policy.vault_nodes,
    azurerm_subnet_nat_gateway_association.vault,
  ]
}
