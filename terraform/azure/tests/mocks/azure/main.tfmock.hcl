# Shared provider mocks, referenced by every test file via
#   mock_provider "azurerm" { source = "./tests/mocks/azure" }
#
# Same purpose as terraform/aws/tests/mocks/aws: the generated mock values
# are random strings, and the provider validates the *shape* of several
# attributes, so anything read back as a resource ID needs a realistic
# stand-in.
#
# The subscription GUID is the all-zeros placeholder.

mock_data "azurerm_client_config" {
  defaults = {
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    object_id       = "00000000-0000-0000-0000-000000000000"
    client_id       = "00000000-0000-0000-0000-000000000000"
  }
}

mock_resource "azurerm_resource_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg"
  }
}

mock_resource "azurerm_key_vault" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.KeyVault/vaults/mock-kv"
  }
}

mock_resource "azurerm_storage_account" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Storage/storageAccounts/mockstorage"
    # The system-assigned identity the customer-managed key policy is
    # granted to. The provider validates this is a real UUID.
    identity = [{
      type         = "SystemAssigned"
      principal_id = "22222222-2222-2222-2222-222222222222"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
    }]
  }
}

mock_resource "azurerm_storage_container" {
  defaults = {
    resource_manager_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Storage/storageAccounts/mockstorage/blobServices/default/containers/snapshots"
  }
}

mock_resource "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/virtualNetworks/mock-vnet"
  }
}

mock_resource "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/mock-subnet"
  }
}

mock_resource "azurerm_network_security_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/networkSecurityGroups/mock-nsg"
  }
}

mock_resource "azurerm_lb" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/loadBalancers/mock-lb"
  }
}

mock_resource "azurerm_lb_backend_address_pool" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/loadBalancers/mock-lb/backendAddressPools/mock-pool"
  }
}

mock_resource "azurerm_lb_probe" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/loadBalancers/mock-lb/probes/mock-probe"
  }
}

mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-identity"
    principal_id = "11111111-1111-1111-1111-111111111111"
  }
}

mock_resource "azurerm_nat_gateway" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/natGateways/mock-nat"
  }
}

mock_resource "azurerm_public_ip" {
  defaults = {
    id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.Network/publicIPAddresses/mock-ip"
    ip_address = "203.0.113.10"
  }
}
