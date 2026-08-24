# Security posture: the assertions that would otherwise only be caught by
# someone reading the diff carefully.
#
# Each of these encodes a decision that is easy to reverse accidentally —
# widening a CIDR while debugging, or relaxing IMDS to make a tool work —
# and hard to notice afterwards, because nothing breaks when you do.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {}

run "vault_api_is_not_reachable_from_the_whole_internet" {
  # apply, not plan: this compares against resource IDs that are
  # computed. Mocked providers make apply inert.
  command = apply

  # The node security group must never take an ingress CIDR rule at all:
  # the only ingress paths are references to the load balancer's group or
  # to itself. A cidr_ipv4 rule appearing here means someone opened the
  # API to a network range directly.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_api_from_lb.cidr_ipv4 == null
    error_message = "Vault API ingress must come from the load balancer's security group, not a CIDR."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_api_from_lb.referenced_security_group_id == aws_security_group.lb.id
    error_message = "Vault API ingress must reference the load balancer security group."
  }
}

run "default_exposure_is_private_networks_only" {
  command = plan

  # 0.0.0.0/0 on the load balancer is a deliberate act, not a default.
  assert {
    condition     = !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "allowed_cidr_blocks must not default to the entire internet."
  }
}

run "raft_and_forwarding_ports_are_peer_only" {
  # apply, not plan: this compares against resource IDs that are
  # computed. Mocked providers make apply inert.
  command = apply

  # 8201 is Raft. If this ever accepted a CIDR, cluster traffic would be
  # reachable from outside the cluster.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_cluster.referenced_security_group_id == aws_security_group.vault.id
    error_message = "Raft cluster traffic must be restricted to the node security group itself."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_cluster.from_port == 8201
    error_message = "Raft cluster port should be 8201."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_api_between_nodes.referenced_security_group_id == aws_security_group.vault.id
    error_message = "Request forwarding between nodes must be peer-only."
  }
}

run "egress_is_not_every_protocol_and_port" {
  command = plan

  # This started as a single ip_protocol = "-1" rule, which permits every
  # protocol on every port outbound. The destination is still 0.0.0.0/0
  # (accepted, with reasoning, in .trivyignore.yaml), but reverting to
  # "-1" would quietly restore the wider hole without changing the CIDR a
  # scanner looks at.
  assert {
    condition     = aws_vpc_security_group_egress_rule.vault_https.ip_protocol == "tcp"
    error_message = "Egress must be scoped to TCP, not every protocol."
  }

  assert {
    condition = alltrue([
      aws_vpc_security_group_egress_rule.vault_https.from_port == 443,
      aws_vpc_security_group_egress_rule.vault_http.from_port == 80,
    ])
    error_message = "Egress should be limited to HTTPS and HTTP."
  }
}

run "flow_logs_capture_rejected_traffic_too" {
  command = plan

  # ACCEPT-only would record what got through and nothing about what was
  # turned away, which is the half worth having when investigating.
  assert {
    condition     = aws_flow_log.vault.traffic_type == "ALL"
    error_message = "Flow logs must capture rejected traffic as well as accepted."
  }
}

run "imds_v2_is_required" {
  command = plan

  # IMDSv1's unauthenticated endpoint turns any SSRF bug on the node into
  # instance-role credential theft — and on a Vault node those credentials
  # unseal the cluster.
  assert {
    condition     = aws_launch_template.vault.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required (http_tokens = \"required\")."
  }

  assert {
    condition     = aws_launch_template.vault.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit should be 1 so containers on the host cannot reach instance credentials."
  }
}

run "root_volume_is_encrypted_with_the_cluster_key" {
  command = plan

  # Raft data lives on this volume, so it should be encrypted with the
  # same key that seals the cluster rather than the account default.
  assert {
    condition     = aws_launch_template.vault.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "The root volume holding Raft data must be encrypted."
  }
}

run "snapshot_bucket_is_not_public_and_is_versioned" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.snapshots.block_public_acls,
      aws_s3_bucket_public_access_block.snapshots.block_public_policy,
      aws_s3_bucket_public_access_block.snapshots.ignore_public_acls,
      aws_s3_bucket_public_access_block.snapshots.restrict_public_buckets,
    ])
    error_message = "The snapshot bucket must block all public access."
  }

  # Versioning is what makes a snapshot overwritten by a corrupt one still
  # recoverable.
  assert {
    condition     = aws_s3_bucket_versioning.snapshots.versioning_configuration[0].status == "Enabled"
    error_message = "The snapshot bucket must have versioning enabled."
  }
}

run "nodes_cannot_delete_snapshots" {
  command = plan

  # Deliberate: a node writes backups but must not be able to destroy
  # backup history. Expiry belongs to the bucket lifecycle rule. If
  # s3:DeleteObject ever appears here, a compromised node can erase the
  # backups as well as the cluster.
  #
  # Asserted against the local, not the rendered policy JSON. The JSON
  # comes from a data source, and data sources are mocked here — an
  # earlier version of this test read the rendered output and passed
  # happily with s3:DeleteObject injected into the real policy.
  assert {
    condition     = !contains(local.snapshot_object_actions, "s3:DeleteObject")
    error_message = "Nodes must not be granted s3:DeleteObject on the snapshot bucket."
  }

  # Guards the assertion above: if the list were renamed or emptied, the
  # check would pass trivially.
  assert {
    condition     = contains(local.snapshot_object_actions, "s3:PutObject")
    error_message = "Nodes must still be able to write snapshots."
  }
}
