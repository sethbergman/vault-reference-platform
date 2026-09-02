# Security posture, mirroring terraform/aws/tests/security.tftest.hcl.
#
# Each of these encodes a decision that is easy to reverse accidentally
# and hard to notice afterwards, because nothing breaks when you do.

mock_provider "azurerm" {
  source = "./tests/mocks/azure"
}

mock_provider "random" {}

variables {
  # See the note in cluster.tftest.hcl — a throwaway key, since the
  # provider parses this field.
  ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDW8ADLwKrTa2b7TIHS8rVEt+IuZ5uT6uLDJKWXmyhr5yXXi6ZkPzIz492Q/bUccmRvl5UM1318WHYrb7kAFuru/7V0an6EyxmBEeuMNr4g6VpiJf47b/0P0dz55fP9QcGlFinnflCP6TXqT10TywpINfAU1DOTSpqxbkDUChJ47O+TbgaLWXQk18kpiTP18H2wpINuQusCBtSVviDgSVHFpOdo/n9RU8EJnYNZ6LuqWW6OWWD8cNmTv4kyh8TqejilCgLtZUn/iDALykrTj98adT2f0fBCbKxOZs0WdiWhJurCPYlgUsf+6mvGpiXPCq2jCcfTzCCBOeLQUSyZkxiX terraform-test-fixture"
}

run "the_autounseal_key_cannot_be_purged" {
  command = plan

  # The single most consequential setting in this module. Every Raft
  # snapshot is encrypted under this key, so purging it does not merely
  # break unsealing — it makes every existing backup permanently
  # undecryptable. Purge protection cannot be disabled once enabled,
  # which is the point.
  assert {
    condition     = azurerm_key_vault.vault_autounseal.purge_protection_enabled == true
    error_message = "Purge protection must be enabled — without it the key, and therefore every snapshot, can be destroyed."
  }

  # 30, not the 7 the module's floor comment might suggest: the azurerm
  # provider already refuses anything below 7 ("expected
  # soft_delete_retention_days to be in the range (7 - 90)"), so an
  # assertion at 7 cannot fail and proves nothing. This one sits above
  # the floor, where a contributor shortening 90 days to the minimum
  # breaks it.
  assert {
    condition     = azurerm_key_vault.vault_autounseal.soft_delete_retention_days >= 30
    error_message = "Soft delete retention is too short to recover from an accidental deletion noticed weeks later."
  }
}

run "the_key_vault_denies_by_default" {
  command = plan

  assert {
    condition     = azurerm_key_vault.vault_autounseal.network_acls[0].default_action == "Deny"
    error_message = "The Key Vault holding the unseal key must deny network access by default."
  }
}

run "the_key_vault_name_fits_azures_limit" {
  command = plan

  variables {
    # Longer than the budget on purpose. With the default 15-character
    # cluster name the prefix is 15 characters however main.tf truncates
    # it, so a name at the cap is the only input that can distinguish a
    # correct budget from a widened one.
    cluster_name = "vault-reference-platform-azure"
  }

  # Key Vault names are capped at 24 characters and are globally unique.
  # "${cluster_name}-autounseal" was 26 at the default cluster name and
  # would have failed at apply — `terraform validate` cannot see this,
  # because it constrains the value rather than the schema.
  #
  # Asserted on local.key_vault_name_prefix rather than the resolved
  # name: the name includes random_id.hex, which is unknown at plan time,
  # so reading the attribute yields "unknown condition value".
  #
  # It has to read that local rather than recompute it. The version this
  # replaced re-derived the same substr() in the test file, which made it
  # a tautology — substr(s, 0, 15) is at most 15 characters, so
  # 15 + 1 + 8 <= 24 held no matter what main.tf did. Widening the
  # module's budget to 20 left it green.
  assert {
    condition     = length(local.key_vault_name_prefix) + 1 + 8 <= 24
    error_message = "Key Vault name would exceed Azure's 24-character limit: 15-char prefix + dash + 8 hex is the budget."
  }

  # The storage account name is truncated to 24 by construction, so this
  # guards the substr bound rather than the arithmetic.
  assert {
    condition     = length(replace(lower(var.cluster_name), "/[^a-z0-9]/", "")) >= 1
    error_message = "cluster_name must contain at least one alphanumeric character to build a storage account name from."
  }
}

run "vault_api_is_not_reachable_from_the_whole_internet" {
  command = plan

  assert {
    condition     = !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "allowed_cidr_blocks must not default to the entire internet."
  }

  # The variable's default is not the only way in. Asserting on it alone
  # left the rule itself unguarded: replacing source_address_prefixes
  # with source_address_prefix = "Internet" opens the API to everyone
  # while the default stays RFC1918, and nothing here noticed.
  assert {
    condition     = azurerm_network_security_rule.vault_api.source_address_prefixes == toset(var.allowed_cidr_blocks)
    error_message = "The Vault API rule must take its sources from allowed_cidr_blocks, not from a prefix set alongside it."
  }

  assert {
    condition     = azurerm_network_security_rule.vault_api.source_address_prefix == null
    error_message = "A singular source_address_prefix on the API rule bypasses allowed_cidr_blocks entirely."
  }

  # Asserted on the count rather than the frontend's public_ip_address_id,
  # which is unknown at plan time. This is the stronger claim anyway: no
  # public IP resource exists at all, rather than one existing unattached.
  assert {
    condition     = length(azurerm_public_ip.lb) == 0
    error_message = "No public IP should be created when internal_lb is true."
  }
}

run "a_public_frontend_requires_asking_for_one" {
  command = plan

  variables {
    internal_lb = false
  }

  # The mirror of the above: flipping the flag is what creates the public
  # IP, so the two together prove the conditional works in both
  # directions rather than the resource simply never being created.
  assert {
    condition     = length(azurerm_public_ip.lb) == 1
    error_message = "internal_lb = false should create a public IP for the frontend."
  }
}

run "raft_traffic_is_confined_to_the_node_subnet" {
  command = plan

  # Scoped to the node subnet rather than the whole VNet, so anything
  # else on the network cannot reach the cluster port.
  assert {
    condition     = azurerm_network_security_rule.vault_cluster.source_address_prefix == cidrsubnet(var.vnet_cidr, 8, 0)
    error_message = "Raft cluster traffic must be restricted to the node subnet."
  }

  assert {
    condition     = azurerm_network_security_rule.vault_cluster.destination_port_range == "8201"
    error_message = "Raft cluster port should be 8201."
  }
}

run "the_security_group_denies_what_it_does_not_allow" {
  command = plan

  # Azure NSGs are ordered rules, not independent allows. Without an
  # explicit deny at the bottom, the platform's default rules still
  # permit intra-VNet traffic on any port.
  assert {
    condition     = azurerm_network_security_rule.deny_all_inbound.access == "Deny"
    error_message = "There must be a catch-all deny rule below the explicit allows."
  }

  # Below *every* allow, not just the first one. Comparing against
  # vault_api alone let a deny at priority 105 through: the API stayed
  # reachable, so nothing looked wrong, while Raft (110) and the health
  # probe (120) were both denied — a cluster that never forms and a load
  # balancer that ejects every node. Azure's floor is 100 and vault_api
  # holds it, so 105 is the realistic version of this mistake.
  assert {
    condition = alltrue([
      for allow in [
        azurerm_network_security_rule.vault_api,
        azurerm_network_security_rule.vault_cluster,
        azurerm_network_security_rule.health_probe,
      ] : azurerm_network_security_rule.deny_all_inbound.priority > allow.priority
    ])
    error_message = "The deny rule must sit below every allow rule or it blocks what they permit."
  }
}

run "snapshots_are_not_reachable_with_a_shared_key" {
  command = plan

  # Account keys grant full access to every backup and cannot be scoped.
  # Disabling them means the nodes' managed identity is the only way in.
  assert {
    condition     = azurerm_storage_account.vault.shared_access_key_enabled == false
    error_message = "Shared key access must be disabled — it is an unscopeable credential for every snapshot."
  }

  assert {
    condition     = azurerm_storage_account.vault.network_rules[0].default_action == "Deny"
    error_message = "The snapshot storage account must deny network access by default."
  }

  assert {
    condition     = azurerm_storage_container.snapshots.container_access_type == "private"
    error_message = "The snapshot container must not be publicly readable."
  }
}

run "snapshots_survive_an_overwrite" {
  command = plan

  # Versioning is what makes a snapshot overwritten by a corrupt one
  # still recoverable.
  assert {
    condition     = azurerm_storage_account.vault.blob_properties[0].versioning_enabled == true
    error_message = "Blob versioning must be enabled so a corrupt overwrite is recoverable."
  }
}

run "storage_requires_modern_tls" {
  command = plan

  assert {
    condition     = azurerm_storage_account.vault.min_tls_version == "TLS1_2"
    error_message = "Storage must require TLS 1.2 or better."
  }

  assert {
    condition     = azurerm_storage_account.vault.https_traffic_only_enabled == true
    error_message = "Storage must refuse unencrypted transfer."
  }
}

run "flow_logs_are_enabled" {
  command = plan

  # Vault's audit device records requests it served; these record the
  # attempts it never saw.
  assert {
    condition     = azurerm_network_watcher_flow_log.vault.enabled == true
    error_message = "NSG flow logs must be enabled."
  }

  assert {
    condition     = azurerm_network_watcher_flow_log.vault.retention_policy[0].enabled == true
    error_message = "Flow log retention must be enabled or logs are discarded immediately."
  }
}
