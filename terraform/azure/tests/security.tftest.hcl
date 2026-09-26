# Security posture, mirroring terraform/aws/tests/security.tftest.hcl.
#
# Each of these encodes a decision that is easy to reverse accidentally
# and hard to notice afterwards, because nothing breaks when you do.

mock_provider "azurerm" {
  source = "./tests/mocks/azure"
}

mock_provider "random" {}

# The azurerm provider reads the subnet NAME out of the subnet id and
# rejects a Bastion host whose subnet is called anything but
# AzureBastionSubnet -- at plan time, before any API call. Mocked ids are
# random strings, so without this every run that plans the configuration
# fails on a rule the configuration actually satisfies.
#
# Only the id is overridden. The assertion that the subnet is named
# correctly (security.tftest.hcl) reads the resource's own name argument,
# which this does not touch.
override_resource {
  target = azurerm_subnet.bastion[0]
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.Network/virtualNetworks/mock/subnets/AzureBastionSubnet"
  }
}


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

# ---------------------------------------------------------------------------
# Reaching the nodes, without opening them
# ---------------------------------------------------------------------------

run "bastion_can_tunnel_or_it_is_only_a_browser_session" {
  command = plan

  # Tunnelling is a Standard SKU feature and the only reason this host is
  # here: Basic gives a browser session, which no playbook can drive. A
  # Bastion that cannot tunnel leaves the profile exactly as unreachable as
  # it was before, while billing about $0.19/hour -- the most expensive way
  # possible to change nothing.
  assert {
    condition = (
      azurerm_bastion_host.vault[0].sku == "Standard" &&
      azurerm_bastion_host.vault[0].tunneling_enabled == true
    )
    error_message = "Bastion must be Standard with tunneling_enabled: Basic cannot tunnel, so ansible cannot reach a node through it."
  }

  # Azure rejects the host outright if its subnet is named anything else.
  # Worth pinning because the error arrives at apply time, after the VNet
  # and the NAT gateway are already billing.
  assert {
    condition     = azurerm_subnet.bastion[0].name == "AzureBastionSubnet"
    error_message = "The Bastion subnet must be named AzureBastionSubnet; Azure refuses any other name."
  }
}

run "bastion_reaches_the_nodes_and_nothing_else_does" {
  command = plan

  # 22 comes from the Bastion subnet, not from the VNet. The difference is
  # every other workload in the address space: with a VirtualNetwork source
  # a compromised container three subnets away can reach sshd on a Vault
  # node, and the rule still reads as "SSH is locked down".
  assert {
    condition = (
      azurerm_network_security_rule.bastion_ssh[0].source_address_prefix == cidrsubnet(var.vnet_cidr, 8, 2) &&
      azurerm_network_security_rule.bastion_ssh[0].destination_port_range == "22" &&
      azurerm_network_security_rule.bastion_ssh[0].access == "Allow"
    )
    error_message = "SSH must be allowed from the Bastion subnet prefix alone, not from the VNet or anywhere wider."
  }

  # The deny-all rule still has to sit below it, or the allow is decoration.
  assert {
    condition = (
      azurerm_network_security_rule.bastion_ssh[0].priority < azurerm_network_security_rule.deny_all_inbound.priority
    )
    error_message = "The Bastion SSH rule must have a lower priority number than deny_all_inbound, or it never applies."
  }
}

run "turning_the_bastion_off_removes_all_of_it" {
  command = plan

  variables {
    bastion_enabled = false
  }

  # Off means off: no host, no public address, and no SSH rule left behind
  # pointing at a subnet that no longer exists. A stranded allow-rule is the
  # kind of leftover that reads as harmless and is not.
  assert {
    condition = (
      length(azurerm_bastion_host.vault) == 0 &&
      length(azurerm_public_ip.bastion) == 0 &&
      length(azurerm_subnet.bastion) == 0 &&
      length(azurerm_network_security_rule.bastion_ssh) == 0
    )
    error_message = "bastion_enabled = false must remove the host, its subnet, its public IP and the SSH rule together."
  }
}

# ---------------------------------------------------------------------------
# The bootstrap CA a replacement node signs from
# ---------------------------------------------------------------------------

run "a_node_can_read_the_bootstrap_ca_and_nothing_more" {
  command = plan

  # Get, and nothing else. With Set a compromised node could replace the CA
  # every later node will trust -- which is a cluster-wide trust decision
  # taken by whichever box was unlucky. With List it could enumerate what
  # else the vault holds. Publishing is a human's job, with human
  # credentials (scripts/publish-bootstrap-ca.sh).
  assert {
    condition = (
      length(azurerm_key_vault_access_policy.vault_nodes.secret_permissions) == 1 &&
      contains(azurerm_key_vault_access_policy.vault_nodes.secret_permissions, "Get")
    )
    error_message = "The node identity must have Get on secrets and nothing else: Set would let a node replace the CA its peers trust, List would let it enumerate the vault."
  }

  # Reading a secret must not imply unwrapping the seal key. Keys and
  # secrets are separate permission surfaces in an access policy, and that
  # separation is the whole reason the CA can live in the same vault as the
  # seal key rather than needing one of its own -- a second Key Vault would
  # mean a second 90-day soft-delete window on every teardown.
  assert {
    condition = alltrue([
      contains(azurerm_key_vault_access_policy.vault_nodes.key_permissions, "UnwrapKey"),
      !contains(azurerm_key_vault_access_policy.vault_nodes.secret_permissions, "Set"),
      !contains(azurerm_key_vault_access_policy.vault_nodes.secret_permissions, "List"),
      !contains(azurerm_key_vault_access_policy.vault_nodes.secret_permissions, "Delete"),
    ])
    error_message = "Seal unwrap and CA read must stay separate grants, and the secret grant must be read-only."
  }
}

run "the_boot_script_reaches_the_node_and_fits" {
  # apply, not plan: custom_data embeds the load balancer's address, which
  # is computed. During plan the whole rendered template is unknown and a
  # condition on it errors whether the configuration is right or wrong --
  # the trap that made an assertion in the AWS suite fail in every state
  # until a mutation pass caught it.
  command = apply

  # The script travels inside custom_data rather than being fetched, so a
  # node needs nothing reachable but Key Vault to issue its certificate,
  # and the version that runs is the version this commit tested.
  # Anchored to the start of a line, because strcontains matches a
  # commented-out invocation exactly as well as a real one -- which it did,
  # until a mutation pass commented the command out and nothing failed.
  assert {
    condition = alltrue([
      length(regexall("(?m)^/usr/local/sbin/vault-bootstrap-cert", base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data))) > 0,
      strcontains(base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data), "--cloud azure"),
      strcontains(base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data), "--key-vault"),
    ])
    error_message = "cloud-init must invoke the bootstrap-cert script, not merely contain it: an invocation that is commented out still matches a substring search."
  }

  # Azure caps custom_data at 64 KB. The comment lines are stripped for
  # this reason, and an assertion is cheaper than finding the ceiling at
  # apply time, after the VNet is already billing -- which is how the AWS
  # profile found its own 16 KB limit.
  assert {
    condition     = length(base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data)) < 49152
    error_message = "Rendered cloud-init is within 16 KB of Azure's 64 KB custom_data ceiling; strip prose rather than raising this."
  }

  # Two shebangs: cloud-init's own and the embedded script's. Searching for
  # one found cloud-init's whether or not the stripping had eaten the
  # script's, which is how this assertion passed while a regex that removes
  # every comment line -- shebang included -- was in place.
  assert {
    condition     = length(regexall("(?m)^#!/usr/bin/env bash", base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data))) >= 2
    error_message = "The embedded script lost its shebang to the comment stripping: the regex must spare #! lines."
  }
}
