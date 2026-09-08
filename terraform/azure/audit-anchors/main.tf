# The storage account that holds audit chain anchors, and cannot let go
# of them.
#
# The Azure half of terraform/aws/audit-anchors. Same argument for being
# a separate root module — a `terraform destroy` of the cluster must not
# be able to delete the record of what that cluster did — and the same
# argument for belonging in a different subscription if you can manage
# one. Neither is repeated here; read that file first.
#
# WHERE AZURE DIFFERS, AND IT IS NOT COSMETIC
#
# S3 object lock protects an object *version*. Azure's immutability
# policy protects everything in its scope for a period measured from each
# blob's creation, and the scope here is the whole account. That is a
# better fit than it sounds: this account holds anchors and nothing else,
# so account-wide is exactly the intended blast radius, and it removes
# the per-object retention flag that scripts/ship-anchors.sh has to get
# right on the S3 side.
#
# The lock states are named differently and mean the same thing:
#
#   Azure Unlocked  ~  S3 GOVERNANCE   an admin can shorten or remove it
#   Azure Locked    ~  S3 COMPLIANCE   nobody can, including the owner
#
# Locked is the default here for the reason COMPLIANCE is the default
# there: the threat model is somebody who reached privileged
# credentials, so a policy those credentials can lift protects nothing.
#
# WHAT LOCKING COSTS, AND IT IS IRREVERSIBLE
#
# A locked policy cannot be unlocked, shortened or deleted by anyone,
# including the subscription owner. Its period can only be extended.
# While it holds, blobs cannot be deleted or overwritten, the container
# cannot be deleted, and the storage account cannot be deleted — so a
# `terraform destroy` of this module fails, and no teardown script fixes
# it. That is the property being bought, and it is a decision with a tail
# as long as var.anchor_retention_days.
#
# Set anchor_immutability_state = "Unlocked" while trying this out. It is
# the weaker guarantee and says so.
#
# NOTHING HERE HAS BEEN APPLIED
#
# There is no Azure emulator — moto implements an AWS API — so unlike the
# AWS module, which tests/audit-anchor-worm applies and then attacks,
# this has only ever been parsed and validated. It is configuration with
# reasoning attached, not a demonstrated guarantee. See docs/roadmap.md,
# which says the same about every other Azure resource here.

terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # Storage account names are globally unique across all of Azure, the
    # same constraint the state account has in ../bootstrap/main.tf.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Lowercase alphanumeric only, 24 characters maximum — the same
  # constraint that forces the substr on the state and snapshot accounts.
  account_name = coalesce(
    var.anchor_storage_account_name,
    substr("${replace(lower(var.name_prefix), "/[^a-z0-9]/", "")}anchors${random_id.suffix.hex}", 0, 24),
  )
}

resource "azurerm_resource_group" "anchors" {
  name     = "${var.name_prefix}-audit-anchors-rg"
  location = var.location

  tags = var.tags
}

resource "azurerm_storage_account" "anchors" {
  name                = local.account_name
  resource_group_name = azurerm_resource_group.anchors.name
  location            = azurerm_resource_group.anchors.location

  account_tier = "Standard"
  # Zone-redundant rather than geo-redundant, matching the snapshot
  # account. Anchors are evidence about one cluster in one region;
  # surviving the loss of a zone is the property that matters, and
  # geo-redundancy would be a second copy in a paired region with no
  # corresponding reason to read it.
  account_replication_type = "ZRS"

  infrastructure_encryption_enabled = true

  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  # No account keys, for the reason ../bootstrap/main.tf gives at length:
  # an account key is a bearer credential granting full access to
  # everything in the account, and it is the credential most likely to
  # outlive the person who created it.
  #
  # It matters more here than there. The whole point of this account is
  # that reaching the Vault host does not reach the evidence, and a
  # shared key stored anywhere near that host would undo it.
  shared_access_key_enabled = false

  allow_nested_items_to_be_public = false

  # Versioning is what makes an overwrite recoverable rather than
  # destructive, the same role S3 versioning plays for the anchor bucket.
  # The immutability policy already refuses the overwrite; this is what
  # makes the refusal recoverable if the policy is ever set to Unlocked.
  blob_properties {
    versioning_enabled = true
  }

  # The account-level equivalent of S3 COMPLIANCE object lock.
  #
  # allow_protected_append_writes stays false. Anchors are written once
  # and never appended to — ship-anchors.sh writes one immutable object
  # per sequence number precisely so that appending is never needed — and
  # an append is a write to an existing blob, which is the operation this
  # policy exists to refuse.
  immutability_policy {
    allow_protected_append_writes = false
    state                         = var.anchor_immutability_state
    period_since_creation_in_days = var.anchor_retention_days
  }

  # Allow by default, and Deny the moment anyone says what to allow —
  # the same shape, and mostly the same argument, as
  # ../bootstrap/main.tf.
  #
  # The twist here is which direction the traffic goes. Writes have a
  # network to come from: whatever ships anchors runs beside the audit
  # collector, inside the VNet, so a rule could name it. Reads do not.
  # Fetching anchors is what you do during an incident, from a machine
  # that is deliberately not the compromised one — a laptop, an on-call
  # engineer somewhere else — and an account that denies by default with
  # no ip_rules is an account nobody can read at exactly the moment it
  # exists to be read. Evidence nobody can reach is not evidence.
  #
  # Azure also rejects 0.0.0.0/0 in ip_rules, so "deny by default and
  # allow everything explicitly" is not available as an escape hatch.
  #
  # The control that is not optional either way is above:
  # shared_access_key_enabled = false. Reaching the account is not the
  # same as being able to read it, because there is no account key and
  # access needs an Entra principal holding a role.
  #
  # Set allowed_ip_ranges once the set of places that fetch anchors is
  # known and stable, and this becomes Deny.
  network_rules {
    default_action = length(var.allowed_ip_ranges) > 0 ? "Deny" : "Allow"
    ip_rules       = var.allowed_ip_ranges
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

resource "azurerm_storage_container" "anchors" {
  name                  = var.anchor_container_name
  storage_account_name  = azurerm_storage_account.anchors.name
  container_access_type = "private"
}

# The credential that ships anchors cannot remove them.
#
# Azure has no built-in role for this. Storage Blob Data Contributor is
# the obvious choice and it grants delete, which is the one action that
# must not be granted — so the role is defined here instead, by listing
# the data actions rather than inheriting a set that happens to include
# the wrong one.
#
# This is defence in depth, not the guarantee: a Locked immutability
# policy already refuses the delete. What it adds is that the delete is
# refused at the point of the call, by authorization, so a policy left
# Unlocked does not silently become a deletable trail.
resource "azurerm_role_definition" "ship_anchors" {
  name        = "${var.name_prefix}-ship-audit-anchors"
  scope       = azurerm_storage_account.anchors.id
  description = "Write audit chain anchors and read them back; never remove one"

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
    ]

    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]

    # Explicit rather than merely absent, matching the NeverDelete
    # statement in the AWS module: an unstated action is denied until
    # some future assignment allows it, and a listed one cannot be
    # granted around.
    not_data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/deleteBlobVersion/action",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/permanentDelete/action",
    ]
  }

  assignable_scopes = [azurerm_storage_account.anchors.id]
}
