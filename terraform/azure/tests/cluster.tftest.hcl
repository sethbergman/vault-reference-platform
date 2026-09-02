# Cluster shape, quorum, and the load balancer.
#
# Deliberately mirrors terraform/aws/tests/cluster.tftest.hcl. Where the
# two clouds need different mechanisms to reach the same behaviour, the
# assertion says so — the point of a reference platform is that both
# profiles behave the same, not that they read the same.

mock_provider "azurerm" {
  source = "./tests/mocks/azure"
}

mock_provider "random" {}

variables {
  # A throwaway keypair generated for these tests and discarded — the
  # provider parses this field, so a placeholder string fails with
  # "decoding admin_ssh_key.0.public_key". Public keys are not secrets,
  # and the matching private key does not exist anywhere.
  ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDW8ADLwKrTa2b7TIHS8rVEt+IuZ5uT6uLDJKWXmyhr5yXXi6ZkPzIz492Q/bUccmRvl5UM1318WHYrb7kAFuru/7V0an6EyxmBEeuMNr4g6VpiJf47b/0P0dz55fP9QcGlFinnflCP6TXqT10TywpINfAU1DOTSpqxbkDUChJ47O+TbgaLWXQk18kpiTP18H2wpINuQusCBtSVviDgSVHFpOdo/n9RU8EJnYNZ6LuqWW6OWWD8cNmTv4kyh8TqejilCgLtZUn/iDALykrTj98adT2f0fBCbKxOZs0WdiWhJurCPYlgUsf+6mvGpiXPCq2jCcfTzCCBOeLQUSyZkxiX terraform-test-fixture"
}

run "scale_set_is_pinned_and_does_not_autoscale" {
  command = plan

  # Same reasoning as the AWS ASG: Raft membership is consensus-based, so
  # an autoscale rule that added an instance would change the quorum
  # arithmetic underneath a running cluster. There is deliberately no
  # azurerm_monitor_autoscale_setting anywhere in this module.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.instances == var.node_count
    error_message = "Scale set instance count must equal node_count — this scale set is for self-healing, not scaling."
  }
}

run "nodes_are_spread_across_availability_zones" {
  command = plan

  # zone_balance makes Azure fail the deployment rather than quietly
  # placing every instance in one zone, which would leave a cluster that
  # looks HA and is not.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.zone_balance == true
    error_message = "Zone balance must be enforced or Azure may place all nodes in one zone."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine_scale_set.vault.zones) >= 2
    error_message = "Nodes must span at least two availability zones."
  }
}

run "unhealthy_nodes_are_repaired_not_just_stopped_ones" {
  command = plan

  # These two are the substance: repair enabled, and a grace period long
  # enough for a replacement to install Vault, auto-unseal and join Raft
  # before Azure decides it is unhealthy and starts again. Too short and
  # nodes are destroyed mid-bootstrap, in a loop.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.automatic_instance_repair[0].enabled == true
    error_message = "Automatic instance repair must be enabled for the scale set to self-heal."
  }

  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.automatic_instance_repair[0].grace_period == "PT30M"
    error_message = "Repair grace period is too short for a node to bootstrap and join Raft."
  }

  # The probe wiring is asserted separately, below — it needs apply mode.
}

run "repair_watches_vault_rather_than_the_vm" {
  # apply, not plan: health_probe_id resolves to the probe's computed ID.
  # An earlier comment here said the module could not survive apply under
  # mocks; fixing the storage account's identity mock for the discovery
  # runs settled that, and this is the assertion it unblocks.
  command = apply

  # Both sides of this comparison are mocked IDs, so it proves the
  # reference points at the probe resource and nothing about the probe
  # itself — which is exactly the gap. Repair with no probe attached
  # falls back to watching whether the VM is running, and a node that is
  # up and sealed is the failure this whole block exists to catch.
  # Deleting the health_probe_id line left every other run green.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.health_probe_id == azurerm_lb_probe.vault.id
    error_message = "Repair must watch the Vault health probe; without it Azure only notices a stopped VM."
  }
}

run "health_probe_keeps_standby_nodes_in_the_pool" {
  command = plan

  # Azure probes accept 200-299 only — there is no status-code matcher
  # like AWS's. Vault answers 429 on a standby, which Azure would treat
  # as unhealthy and eject, leaving just the leader serving. standbyok
  # makes Vault answer 200 for a healthy standby instead. Dropping this
  # query string silently halves the cluster's serving capacity.
  # The "?" matters: "perfstandbyok=true" contains "standbyok=true" as a
  # substring, so the looser check passed even with the real parameter
  # deleted. Found by deleting it and watching the test stay green.
  assert {
    condition     = strcontains(azurerm_lb_probe.vault.request_path, "?standbyok=true")
    error_message = "Probe must pass standbyok=true or Azure ejects every standby node."
  }

  assert {
    condition     = strcontains(azurerm_lb_probe.vault.request_path, "/v1/sys/health")
    error_message = "Probe must target Vault's sys/health endpoint."
  }

  # An HTTPS probe distinguishes a sealed node from a healthy one; a TCP
  # probe cannot.
  assert {
    condition     = azurerm_lb_probe.vault.protocol == "Https"
    error_message = "Probe must speak HTTPS to sys/health, not raw TCP."
  }
}

run "tls_terminates_at_vault_not_the_load_balancer" {
  command = plan

  # docs/security.md commits to this. An Application Gateway would
  # terminate the client's TLS and re-encrypt to the backend, so
  # plaintext would exist inside the load balancer. A Standard LB rule
  # forwards TCP untouched.
  assert {
    condition     = azurerm_lb_rule.vault.protocol == "Tcp"
    error_message = "Load balancer rule must be TCP passthrough so Vault terminates TLS itself."
  }

  assert {
    condition     = azurerm_lb.vault.sku == "Standard"
    error_message = "Must be a Standard load balancer — Basic has no zone support and is retiring."
  }
}

run "cluster_tag_matches_what_raft_auto_join_searches_for" {
  command = plan

  # auto_join filters on tag_name=VaultCluster. If the scale set stops
  # applying that tag, instances come up healthy and never join — the
  # failure is silent, which is the worst kind.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.tags["VaultCluster"] == var.cluster_name
    error_message = "Instances must carry the VaultCluster tag that Raft auto-join discovers peers by."
  }
}

run "nodes_authenticate_with_a_managed_identity_not_a_password" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.disable_password_authentication == true
    error_message = "Password authentication must be disabled on the nodes."
  }

  # No credential on the node: Key Vault, the Azure API and blob storage
  # are all reached through this identity.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.identity[0].type == "UserAssigned"
    error_message = "Nodes must use a managed identity rather than embedded credentials."
  }
}

# ---------------------------------------------------------------------------
# Variable validation
# ---------------------------------------------------------------------------
run "even_node_counts_are_rejected" {
  command = plan

  variables {
    node_count = 4
  }

  expect_failures = [var.node_count]
}

run "single_node_is_rejected" {
  command = plan

  variables {
    node_count = 1
  }

  expect_failures = [var.node_count]
}

run "a_single_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zones = ["1"]
  }

  expect_failures = [var.availability_zones]
}

run "five_nodes_are_accepted" {
  command = plan

  variables {
    node_count = 5
  }

  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.instances == 5
    error_message = "Five nodes should be a valid cluster size."
  }
}

# ---------------------------------------------------------------------------
# Raft discovery
# ---------------------------------------------------------------------------
# These assert on the *rendered* cloud-init rather than on the template
# file, so they cover the values Terraform substitutes in as well as the
# literal text. custom_data is computed by templatefile() from this
# module's own configuration, not supplied by the mock provider, so it is
# real evidence.

run "raft_discovery_uses_scale_set_mode_not_tags" {
  # apply, not plan: custom_data is rendered from a key name the mock
  # provider only supplies at apply time, so at plan it is unknown and
  # every assertion below would error rather than evaluate. The mock
  # contributes the key name; the auto_join line these assert on comes
  # from this module's own template and variables.
  command = apply

  # go-discover's azure provider accepts (tag_name + tag_value) OR
  # (resource_group + vm_scale_set) and rejects any config carrying both
  # with "unclear configuration: use (tag name and value) or
  # (resouce_group and vm_scale_set)".
  #
  # This module shipped both. Vault would have started on every node,
  # reported healthy, and never formed a cluster — the failure is a line
  # in a node's log, not anything the infrastructure surfaces.
  #
  # Tag mode would be wrong here anyway: it matches tags on network
  # interfaces, and the tags this module sets land on the scale set.
  assert {
    condition = !strcontains(
      base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data),
      "tag_name="
    )
    error_message = "Azure auto_join must not mix a tag selector with scale-set mode; go-discover rejects the combination outright."
  }

  assert {
    condition = strcontains(
      base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data),
      "vm_scale_set=${local.vault_scale_set_name}"
    )
    error_message = "Azure auto_join must name the scale set it should enumerate."
  }

  # Scale-set mode has no managed-identity fallback for the subscription:
  # omit it and discovery fails with "subscription_id not provided".
  assert {
    condition = strcontains(
      base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data),
      "subscription_id="
    )
    error_message = "Azure auto_join requires subscription_id explicitly."
  }

  # Scale-set mode is (resource_group AND vm_scale_set), not either one.
  # Dropping the resource group leaves a line that still reads like
  # scale-set discovery and that go-discover rejects the same way as the
  # mixed selector above — asserting on vm_scale_set alone missed it.
  assert {
    condition = strcontains(
      base64decode(azurerm_linux_virtual_machine_scale_set.vault.custom_data),
      "resource_group="
    )
    error_message = "Azure auto_join needs resource_group alongside vm_scale_set; either alone is not a valid selector."
  }
}

run "the_scale_set_name_matches_what_discovery_looks_for" {
  command = apply

  # The name is referenced from inside the scale set's own cloud-init, so
  # it comes from a local rather than from the resource. If the resource
  # name were ever changed independently, discovery would enumerate a
  # scale set that does not exist and quietly find no peers.
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.vault.name == local.vault_scale_set_name
    error_message = "The scale set must be named by the same local that cloud-init filters on."
  }
}
