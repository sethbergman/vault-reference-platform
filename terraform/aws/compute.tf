# Vault nodes, as an autoscaling group rather than fixed instances.
#
# The ASG is here for self-healing, not elasticity: Raft membership is
# consensus-based, so nodes cannot be added and removed freely to track
# load. desired/min/max are all pinned to node_count deliberately — a
# scaling policy that added a node would break quorum arithmetic. What the
# ASG buys is that a failed instance is replaced automatically, and the
# replacement rejoins on its own via auto_join.

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "vault" {
  name_prefix   = "${var.cluster_name}-vault-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  # Empty string would be an invalid key name; null omits the field.
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  iam_instance_profile {
    arn = aws_iam_instance_profile.vault.arn
  }

  vpc_security_group_ids = [aws_security_group.vault.id]

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    vault_version = var.vault_version
    cluster_name  = var.cluster_name
    aws_region    = var.aws_region
    kms_key_id    = aws_kms_key.vault_autounseal.key_id
  }))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size
      volume_type = "gp3"
      encrypted   = true
      # A dedicated key, not the seal key. Raft data does sit here, but a
      # root volume is not a backup -- it goes when the instance goes.
      # Sharing the seal key meant `terraform destroy` scheduled the one
      # key every archived snapshot depends on. See main.tf.
      kms_key_id            = aws_kms_key.vault_data.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only. IMDSv1's unauthenticated endpoint is reachable through
    # an SSRF bug in anything running on the node, which on a Vault node
    # would expose the instance role's credentials.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(module.vault_cluster.cluster_tags, {
      Name = "${var.cluster_name}-vault"
      # The tag retry_join's auto_join matches on. Changing this key or
      # value without updating the user-data template breaks cluster
      # formation.
      VaultCluster = var.cluster_name
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(module.vault_cluster.cluster_tags, {
      Name = "${var.cluster_name}-vault"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "vault" {
  name_prefix = "${var.cluster_name}-vault-"

  # All three pinned to node_count — see the note at the top of this file.
  min_size         = var.node_count
  max_size         = var.node_count
  desired_capacity = var.node_count

  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.vault.arn]

  # EC2 first, ELB once the cluster actually serves. The default is EC2,
  # and that is not timidity -- it is the only value under which a bare
  # `terraform apply` terminates.
  #
  # This profile deliberately does not issue TLS certificates; user-data
  # says so and defers to the Ansible layer. Vault will not start without
  # them, so the load balancer's health check cannot pass, so with
  # health_check_type = "ELB" the group marks every instance unhealthy at
  # the end of the grace period, terminates it, launches a replacement,
  # and repeats -- billing EC2, NAT and EBS the whole time while looking
  # like a slow bootstrap rather than a configuration gap.
  #
  # EC2 health only knows whether the instance is running, which is
  # exactly enough to survive the window before Ansible has run and no
  # more. Once the cluster is serving, switch to ELB: a node that is up
  # but sealed or wedged is useless, and only the load balancer can tell
  # the difference. docs/deployment.md sequences it.
  health_check_type = var.health_check_type
  # Generous, because a new node has to install Vault, auto-unseal, and
  # join Raft before it can report healthy. Too short and the ASG kills
  # nodes mid-bootstrap in a loop.
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.vault.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      # One at a time, keeping a majority up throughout. With 3 nodes this
      # means never dropping below 2, so Raft keeps quorum during a
      # rolling replacement.
      min_healthy_percentage = 67
      instance_warmup        = 600
    }
  }

  dynamic "tag" {
    for_each = merge(module.vault_cluster.cluster_tags, {
      Name         = "${var.cluster_name}-vault"
      VaultCluster = var.cluster_name
    })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
