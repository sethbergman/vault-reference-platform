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

  # This block used to assert the node group took no CIDR ingress at all,
  # on the reasoning that the load balancer's security group was the only
  # way in. That reasoning was wrong, and the assertion was defending the
  # bug: with target_type = "instance" the load balancer preserves the
  # client address, so a security-group reference matches the health
  # checks and nothing else. Every target reported healthy and no client
  # could connect.
  #
  # The health-check path is still a reference, and still must be.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_api_from_lb.cidr_ipv4 == null
    error_message = "The load balancer health-check path must be a security group reference, not a CIDR."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.vault_api_from_lb.referenced_security_group_id == aws_security_group.lb.id
    error_message = "Vault API health checks must reference the load balancer security group."
  }

  # Client traffic arrives with the client's own address, so it needs a
  # CIDR rule. Without this the cluster is healthy and unreachable.
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.vault_api_from_clients) == length(var.allowed_cidr_blocks)
    error_message = "Every allowed CIDR needs node ingress; the load balancer's security group does not carry client traffic."
  }

  # The CIDR rule above is only correct while client IP preservation is
  # on, which is a property of the target type. Switching to "ip" without
  # revisiting the security group would leave the API open to those
  # ranges for no reason.
  assert {
    condition     = aws_lb_target_group.vault.target_type == "instance"
    error_message = "Client ingress on the node group assumes target_type = instance; revisit security.tf if this changes."
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

  # PutObject alone is not enough to store an object in a bucket with
  # SSE-KMS default encryption: S3 has the caller mint the data key, so a
  # node without this is denied by KMS while every S3 permission looks
  # right. Nothing was granting it, and no snapshot would ever have
  # landed.
  assert {
    condition     = contains(local.snapshot_kms_actions, "kms:GenerateDataKey")
    error_message = "Snapshot uploads need kms:GenerateDataKey; the bucket enforces SSE-KMS."
  }
}
