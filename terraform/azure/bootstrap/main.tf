# The storage account that holds the state for terraform/azure.
#
# WHY THIS IS A SEPARATE ROOT MODULE
#
# The same ordering problem as terraform/aws/bootstrap, and the same
# answer: a backend cannot store state in a container that does not exist
# yet, and the container must not live in the state it holds, or
# `terraform destroy` of the cluster deletes the state of the destroy
# that is running. The full argument is in that file and in
# docs/terraform-state.md; it is not repeated here.
#
# APPLY THIS ONCE PER SUBSCRIPTION AND REGION. Its own state is local,
# deliberately, for the reasons given there.
#
# WHERE AZURE DIFFERS, AND IT IS NOT COSMETIC
#
#   - Locking needs nothing. The azurerm backend takes a blob lease, so
#     there is no second resource to create and no Terraform version
#     floor -- where the S3 backend needs `use_lockfile` and Terraform
#     1.10. Two mechanisms, and only the AWS one can be got wrong by
#     omission.
#   - Authentication is Entra ID, not a key. shared_access_key_enabled
#     is false, so the backend needs `use_azuread_auth = true` and the
#     principal running Terraform needs a role assignment -- which this
#     module creates for whoever applies it. Anyone else has to be
#     granted it explicitly, which is the point.
#   - The network default is Allow, and on the snapshot account in
#     ../storage.tf it is Deny. That is not an oversight; see the
#     network_rules block below.

terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # Storage account names are globally unique across all of Azure, the
    # same constraint the snapshot account has in ../storage.tf.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # The account below sets shared_access_key_enabled = false, and the
  # provider's own data-plane calls default to a key: the Blob Service
  # availability poll that finishes creating the account, and creating the
  # container inside it. Without this they are refused by the very control
  # this module exists to set:
  #
  #   403 Key based authentication is not permitted on this storage account
  #     with KeyBasedAuthenticationNotPermitted
  #
  # The comments below say twice that the *backend* needs
  # use_azuread_auth, and outputs.tf emits it. Nothing said the same thing
  # to the provider running this module, so the first real apply of it
  # failed partway: resource group and storage account created, container
  # and role assignment not.
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Lowercase alphanumeric only, 24 characters maximum -- the same
  # constraint that forces the substr on the snapshot account.
  account_name = coalesce(
    var.state_storage_account_name,
    substr("${replace(lower(var.name_prefix), "/[^a-z0-9]/", "")}tfstate${random_id.suffix.hex}", 0, 24),
  )
}

resource "azurerm_resource_group" "tfstate" {
  name     = "${var.name_prefix}-tfstate-rg"
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                = local.account_name
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_tier = "Standard"
  # Zone-redundant, matching the snapshot account. State is small and
  # rewritten constantly; what matters is that losing a zone does not
  # take with it the ability to manage the cluster in the other two.
  account_replication_type = "ZRS"

  infrastructure_encryption_enabled = true

  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  # No account keys. A storage account key is a bearer credential that
  # grants full access to every state file in the account, and it is the
  # credential most likely to end up in a CI variable and stay there
  # after the person who put it there has left. Access is via Entra ID
  # and the role assignment below instead, which is revocable per
  # principal.
  #
  # This is why the backend needs `use_azuread_auth = true`. Without it
  # the backend looks for a key, finds none, and fails at init.
  shared_access_key_enabled = false

  allow_nested_items_to_be_public = false

  blob_properties {
    # The Azure half of the property S3 versioning gives the other
    # profile: a state blob overwritten by a bad apply is still
    # recoverable from the version before it.
    versioning_enabled = true

    delete_retention_policy {
      days = var.state_version_retention_days
    }

    container_delete_retention_policy {
      days = var.state_version_retention_days
    }
  }

  # Allow by default, where the snapshot account in ../storage.tf denies.
  #
  # The difference is who reaches it. Snapshots are written by the nodes,
  # from inside the VNet, over a service endpoint -- so denying
  # everything else costs nothing. State is read and written by whoever
  # runs `terraform apply`: a laptop, a CI runner, an on-call engineer on
  # a different continent. There is no subnet to allow, and an account
  # that denies by default with no ip_rules is an account nobody can plan
  # against, including the person who created it.
  #
  # Set allowed_ip_ranges and this becomes Deny with those ranges
  # permitted. Worth doing where the set of places Terraform runs from is
  # known and stable; a foot-gun where it is not, because being locked
  # out of the state of a running Vault cluster is the failure this whole
  # module exists to prevent.
  #
  # The control that is not optional either way is above:
  # shared_access_key_enabled = false, so reaching the account is not the
  # same as being able to read it.
  # Declared only when there is something to declare. A network_rules
  # block with default_action = "Allow" and no addresses says exactly what
  # a storage account already does by default -- Azure stores
  # defaultAction Allow and bypass AzureServices either way -- but the
  # provider does not match its own empty block against what comes back,
  # so every subsequent plan wanted to add it again. Applying it changed
  # nothing and the next plan wanted it again.
  #
  # A plan that never reads clean is worse than the noise: it teaches
  # whoever runs it that one pending change is normal here, and real
  # drift arrives looking exactly like that.
  dynamic "network_rules" {
    for_each = length(var.allowed_ip_ranges) > 0 ? [1] : []

    content {
      default_action = "Deny"
      ip_rules       = var.allowed_ip_ranges
      bypass         = ["AzureServices"]
    }
  }

  # The Azure half of the AWS bucket's prevent_destroy. `terraform
  # destroy` in this directory is a plausible thing to run while tidying
  # up a subscription, and it would take the state of every running
  # cluster in the account with it. Making that an edit rather than a
  # command is the whole guard.
  #
  # There is no force_destroy counterpart to pair it with: azurerm has no
  # such argument, and destroying an account with blobs in it does not
  # fail the way an S3 bucket does. So on this side the lifecycle block
  # is not defence in depth — it is the only thing standing there.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# Microsoft-managed keys, not the cluster's Key Vault key.
#
# The snapshot account uses the auto-unseal key deliberately, so that one
# key has to survive a teardown rather than two. That reasoning inverts
# here: the auto-unseal key lives in terraform/azure's *state*, so
# encrypting the state under it would mean needing the state in order to
# read the state. A key created in this module instead would work, at the
# cost of a second Key Vault whose purge protection outlives every
# cluster -- not worth it for an account that already refuses key-based
# auth.

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"

  # Owner is a control-plane role and carries no data-plane access at all.
  # Creating a container in an account that refuses keys goes through the
  # data plane, so it needs the Blob Data Contributor assignment below --
  # and nothing in the references between these two resources says so, so
  # Terraform is free to create them in either order or at the same time.
  #
  # An Azure role assignment is not effective the instant it returns.
  # If this fails with a 403 on AuthorizationPermissionMismatch, that is
  # propagation rather than configuration: re-run the apply.
  depends_on = [azurerm_role_assignment.tfstate_operator]
}

# Granted to whoever applied this module, so that the next command they
# run -- `terraform init` against the backend -- works. Everyone else is
# granted explicitly.
#
# Data Contributor rather than Owner: enough to read, write and lease the
# state blobs, and not enough to change who else can.
resource "azurerm_role_assignment" "tfstate_operator" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
