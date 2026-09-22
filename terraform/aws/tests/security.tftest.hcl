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
    error_message = "Egress to the internet should be limited to HTTPS and HTTP."
  }
}

# The assertion above once read "Egress should be limited to HTTPS and
# HTTP", and was true, and was the bug: the ingress rules admitted peers
# on 8200 and 8201, egress let no node send to one, and on the first real
# apply the followers discovered the leader and never reached it. A
# cluster of one, three processes healthy.
#
# apply, not plan: the peer references are computed ids.
run "nodes_can_reach_each_other_and_nothing_else_on_cluster_ports" {
  command = apply

  assert {
    condition = alltrue([
      aws_vpc_security_group_egress_rule.vault_api_to_peers.from_port == 8200,
      aws_vpc_security_group_egress_rule.vault_api_to_peers.to_port == 8200,
      aws_vpc_security_group_egress_rule.vault_cluster_to_peers.from_port == 8201,
      aws_vpc_security_group_egress_rule.vault_cluster_to_peers.to_port == 8201,
    ])
    error_message = "Nodes must be able to open connections to peers on 8200 (Raft join, forwarding) and 8201 (Raft)."
  }

  assert {
    condition = alltrue([
      aws_vpc_security_group_egress_rule.vault_api_to_peers.referenced_security_group_id == aws_security_group.vault.id,
      aws_vpc_security_group_egress_rule.vault_cluster_to_peers.referenced_security_group_id == aws_security_group.vault.id,
    ])
    error_message = "Cluster-port egress must go to the node group itself, not to another group."
  }

  # Paired with the reference above: a CIDR alongside it would widen the
  # rule to the network while the reference assertion still passed.
  assert {
    condition = alltrue([
      aws_vpc_security_group_egress_rule.vault_api_to_peers.cidr_ipv4 == null,
      aws_vpc_security_group_egress_rule.vault_cluster_to_peers.cidr_ipv4 == null,
    ])
    error_message = "Cluster-port egress must be peer-only, never a CIDR."
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

run "the_seal_key_and_the_volume_key_are_separate" {
  command = plan

  assert {
    condition     = aws_launch_template.vault.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "The root volume holding Raft data must be encrypted."
  }

  # Asserted on configuration, not on arns.
  #
  # The mock gives every aws_kms_key the same arn, so comparing
  # kms_key_id against a key's arn either fails for both or passes for
  # both and proves nothing either way. tests/README.md says exactly this
  # about mocked values, and the first version of this block ignored it.
  # The arns are compared in tests/cloud-apply-emulated, where they are
  # real and distinct.
  #
  # What is checked here is that two keys are configured, with the
  # lifecycles that make the split worth having.
  #
  # They used to be one key. `terraform destroy` then scheduled the seal
  # key along with the volumes it also encrypted, so tearing down a test
  # cluster put every snapshot ever taken with it on a deletion timer --
  # including snapshots from clusters that no longer existed. storage.tf
  # warned the key had to survive a teardown; the code deleted it.
  assert {
    condition     = aws_kms_key.vault_autounseal.deletion_window_in_days >= 30
    error_message = "The seal key needs a long deletion window; seven days is a short time to notice a mistaken teardown."
  }

  assert {
    condition     = aws_kms_key.vault_data.deletion_window_in_days <= 7
    error_message = "The node volume key is not durable and does not need a long window."
  }

  assert {
    condition     = aws_kms_key.vault_data.description != aws_kms_key.vault_autounseal.description
    error_message = "The two keys must be distinct resources, not one key referenced twice."
  }

  assert {
    condition     = aws_kms_key.vault_data.enable_key_rotation
    error_message = "Both keys should rotate."
  }
}

# The first real apply launched twelve instances and kept none: the
# autoscaling group's service-linked role could not use the volume key,
# because the key had the default policy and that role's IAM cannot be
# changed. See the comment on aws_kms_key.vault_data.
#
# These read the policy the configuration writes, never a mocked data
# source's output -- the account id in it is the mock's, and says nothing.
run "autoscaling_can_encrypt_node_volumes" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.vault_data.policy).Statement :
      endswith(try(s.Condition.StringEquals["aws:PrincipalArn"], ""),
      ":role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling")
      && contains(flatten([s.Action]), "kms:GenerateDataKey*")
      && s.Effect == "Allow"
    ])
    error_message = "The autoscaling service-linked role must be allowed to generate data keys, or no instance survives launch."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.vault_data.policy).Statement :
      endswith(try(s.Condition.StringEquals["aws:PrincipalArn"], ""),
      ":role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling")
      && contains(flatten([s.Action]), "kms:CreateGrant")
      && try(s.Condition.Bool["kms:GrantIsForAWSResource"], "") == "true"
    ])
    error_message = "The role must be able to grant the key to EC2, and only to an AWS resource."
  }

  # Named by condition, never as the principal: on a new account the role
  # does not exist until the group does, and KMS refuses a policy naming
  # a principal that does not exist. Paired with the two positives above,
  # which pin that the role is still admitted.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_kms_key.vault_data.policy).Statement :
      strcontains(jsonencode(s.Principal), "AWSServiceRoleForAutoScaling")
    ])
    error_message = "Match the service-linked role by condition; naming it as a principal fails on an account that has never had an autoscaling group."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.vault_data.policy).Statement :
      endswith(try(s.Principal.AWS, ""), ":root") && s.Action == "kms:*" && s.Effect == "Allow"
    ])
    error_message = "Keep the account's administration statement, or nothing can manage the key."
  }
}

# The same mistake on the seal key, and the error that actually ended the
# first real apply: the flow log group is encrypted with it, the key had
# the default policy, and CloudWatch Logs was denied CreateLogGroup.
run "cloudwatch_logs_can_encrypt_flow_logs" {
  command = plan

  # Pinned to the group the configuration creates, by comparing with that
  # resource's own name -- so renaming the group without the policy fails
  # here, not at CreateLogGroup.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.vault_autounseal.policy).Statement :
      try(s.Principal.Service, "") == "logs.${var.aws_region}.amazonaws.com"
      && contains(flatten([s.Action]), "kms:GenerateDataKey*")
      && endswith(try(s.Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"], ""),
      ":log-group:${aws_cloudwatch_log_group.vpc_flow_logs.name}")
    ])
    error_message = "CloudWatch Logs must be able to use the seal key for the flow log group, and that group only."
  }

  # The seal key is the one everything durable depends on. Losing the
  # account statement would cut off the instance role's IAM grant, which
  # is how Vault unseals.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.vault_autounseal.policy).Statement :
      endswith(try(s.Principal.AWS, ""), ":root") && s.Action == "kms:*" && s.Effect == "Allow"
    ])
    error_message = "Keep the account's administration statement on the seal key, or Vault loses its IAM route to unseal."
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

# A replacement node reads the bootstrap CA from SSM and signs its own
# leaf (tls.tf, scripts/issue-bootstrap-cert.sh). The first real apply
# watched a replacement sit with no certificate until a person noticed.
#
# Asserted on the resources' own arguments and on named locals, never on
# the policy JSON: that comes from a data source, which is mocked here.
run "a_new_node_can_read_the_bootstrap_ca_and_nothing_more" {
  command = apply

  # Every aws_kms_key gets the same ARN from the shared mock, so without
  # the overrides below the key_id assertion compares a value with itself
  # and passes whichever key the parameter names. It did: encrypting the
  # CA key under the seal key passed.
  #
  # And the overrides alone were not enough, because runs in one file
  # share state. Earlier apply runs had already created both keys with the
  # shared ARN; this run saw nothing to change, kept them, and still
  # passed with the seal key. state_key gives it state of its own, so the
  # keys are created here, with the ARNs below.
  state_key = "bootstrap_ca"
  override_resource {
    target = aws_kms_key.vault_data
    values = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000da7a"
      key_id = "00000000-0000-0000-0000-00000000da7a"
    }
  }

  override_resource {
    target = aws_kms_key.vault_autounseal
    values = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000053a1"
      key_id = "00000000-0000-0000-0000-0000000053a1"
    }
  }

  assert {
    condition     = aws_ssm_parameter.bootstrap_ca_key.type == "SecureString"
    error_message = "The CA key must be a SecureString."
  }

  # The cluster's own volume key: not the seal key, which should do nothing
  # it does not have to, and not the account's aws/ssm key, which the node
  # role would then need decrypt on -- admitting every SecureString in the
  # account.
  assert {
    condition     = aws_ssm_parameter.bootstrap_ca_key.key_id == aws_kms_key.vault_data.arn
    error_message = "The CA key must be encrypted under the node volume key."
  }

  # Terraform writes a placeholder and never the key; the boot script reads
  # that placeholder as "first apply". tests/bootstrap-cert holds the value
  # to the script's.
  #
  # Only the certificate's is readable here. The key's is written with
  # value_wo, which is null in plan and state by design -- which is the
  # point of it. Whether the published key then stays out of state is a
  # question about the real provider's refresh, which a mock cannot
  # answer; tests/cloud-apply-emulated publishes one and re-applies.
  assert {
    condition     = aws_ssm_parameter.bootstrap_ca_cert.value == local.bootstrap_ca_placeholder
    error_message = "The certificate parameter must start as the placeholder the boot script recognises."
  }

  assert {
    condition     = local.bootstrap_ca_ssm_actions == ["ssm:GetParameter"]
    error_message = "The node role may read the CA parameters, and do nothing else in SSM."
  }

  assert {
    condition = toset(local.bootstrap_ca_parameter_arns) == toset([
      aws_ssm_parameter.bootstrap_ca_cert.arn,
      aws_ssm_parameter.bootstrap_ca_key.arn,
    ]) && length(local.bootstrap_ca_parameter_arns) == 2
    error_message = "The read grant must name exactly the two CA parameters."
  }

  assert {
    condition     = local.bootstrap_ca_kms_actions == ["kms:Decrypt"]
    error_message = "The node role needs Decrypt on the volume key through SSM, and nothing more."
  }
}
