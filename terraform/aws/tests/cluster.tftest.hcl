# Cluster shape and quorum behaviour.
#
# Raft correctness is arithmetic: an even node count buys no extra fault
# tolerance, and a rolling replacement that takes down too many nodes at
# once loses quorum and the cluster stops serving writes. Both are easy to
# break with a one-character edit and neither shows up in a plan diff as
# anything alarming.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {}

run "asg_is_pinned_and_does_not_autoscale" {
  command = plan

  # min == max == desired is deliberate. Raft membership is
  # consensus-based, so a scaling policy that added a node would change
  # the quorum arithmetic underneath a running cluster.
  assert {
    condition = (
      aws_autoscaling_group.vault.min_size == var.node_count &&
      aws_autoscaling_group.vault.max_size == var.node_count &&
      aws_autoscaling_group.vault.desired_capacity == var.node_count
    )
    error_message = "ASG min/max/desired must all equal node_count — this group is for self-healing, not scaling."
  }
}

run "rolling_refresh_preserves_quorum" {
  command = plan

  # With 3 nodes, 67% keeps 2 up throughout — a majority. At 50% the ASG
  # could take down 2 of 3 and the cluster would lose quorum mid-upgrade.
  assert {
    condition     = aws_autoscaling_group.vault.instance_refresh[0].preferences[0].min_healthy_percentage > 50
    error_message = "Instance refresh must keep more than half the nodes healthy or a rolling replacement breaks Raft quorum."
  }
}

run "health_check_defaults_to_ec2_so_a_bare_apply_terminates" {
  command = plan

  # This assertion looks backwards and is not.
  #
  # ELB health is the better check once the cluster serves, because a node
  # that is up but sealed or wedged is useless and only the load balancer
  # can see that. But this profile does not issue TLS certificates —
  # user-data says so and defers to Ansible — so until Ansible has run,
  # Vault never starts and the load balancer's check can never pass.
  #
  # With ELB health that is not a delay, it is a loop: every instance is
  # marked unhealthy at the end of the grace period, terminated, replaced,
  # and the replacement repeats it. A bare `terraform apply` never
  # converges and bills the whole time.
  #
  # EC2 is therefore the only default under which the apply terminates.
  assert {
    condition     = aws_autoscaling_group.vault.health_check_type == "EC2"
    error_message = "Default must be EC2; ELB cannot pass before Ansible has issued certificates, so the group would replace instances forever."
  }

  # A new node installs Vault, auto-unseals and joins Raft before it can
  # report healthy. Too short a grace period and the ASG kills nodes
  # mid-bootstrap, in a loop.
  assert {
    condition     = aws_autoscaling_group.vault.health_check_grace_period >= 300
    error_message = "Health check grace period is too short for a node to bootstrap and join Raft."
  }
}

run "health_check_can_be_promoted_to_elb_once_the_cluster_serves" {
  command = plan

  variables {
    health_check_type = "ELB"
  }

  # The other half. The default protects the first apply; it must not trap
  # the profile there, because a cluster running on EC2 health forever has
  # no way to notice a node that is up and sealed.
  assert {
    condition     = aws_autoscaling_group.vault.health_check_type == "ELB"
    error_message = "health_check_type must accept ELB, or there is no way to promote the check after Ansible has run."
  }

  # The target group is what ELB health reads, so the promotion is only
  # meaningful while it still accepts a standby's 429.
  assert {
    condition     = aws_lb_target_group.vault.health_check[0].matcher == "200,429"
    error_message = "Promoting to ELB health is pointless if the target group ejects healthy standbys."
  }
}

run "target_group_keeps_standby_nodes_in_the_pool" {
  command = plan

  # Vault returns 200 on the active node and 429 on standbys. Accepting
  # only 200 would route all traffic at the leader and idle the standbys;
  # a plain TCP check would keep *sealed* nodes in rotation.
  assert {
    condition     = strcontains(aws_lb_target_group.vault.health_check[0].matcher, "429")
    error_message = "Health check must accept 429 so unsealed standby nodes stay in the pool."
  }

  assert {
    condition     = strcontains(aws_lb_target_group.vault.health_check[0].matcher, "200")
    error_message = "Health check must accept 200 for the active node."
  }

  # An HTTPS check against sys/health is what distinguishes a sealed node
  # from a healthy one; a TCP check cannot.
  assert {
    condition     = aws_lb_target_group.vault.health_check[0].protocol == "HTTPS"
    error_message = "Health check must speak HTTPS to sys/health, not raw TCP."
  }

  assert {
    condition     = strcontains(aws_lb_target_group.vault.health_check[0].path, "/v1/sys/health")
    error_message = "Health check path must be Vault's sys/health endpoint."
  }
}

run "tls_terminates_at_vault_not_the_load_balancer" {
  command = plan

  # docs/security.md commits to this. An ALB would terminate the client's
  # TLS and re-encrypt to the backend, so plaintext would exist inside the
  # load balancer.
  assert {
    condition     = aws_lb.vault.load_balancer_type == "network"
    error_message = "Must be a network load balancer — an ALB terminates TLS, which docs/security.md forbids."
  }

  assert {
    condition     = aws_lb_listener.vault.protocol == "TCP"
    error_message = "Listener must be TCP passthrough so Vault terminates TLS itself."
  }
}

run "nodes_are_spread_across_the_private_subnets" {
  # apply, not plan: this compares against resource IDs that are
  # computed. Mocked providers make apply inert.
  command = apply

  assert {
    condition     = length(aws_autoscaling_group.vault.vpc_zone_identifier) == var.az_count
    error_message = "The ASG must be able to place nodes in every private subnet."
  }
}

run "cluster_tag_matches_what_raft_auto_join_searches_for" {
  command = plan

  # retry_join's auto_join filters on tag_key=VaultCluster. If the launch
  # template stops applying that tag, new nodes come up healthy at the
  # instance level and never join the cluster — the failure is silent.
  assert {
    condition     = aws_launch_template.vault.tag_specifications[0].tags["VaultCluster"] == var.cluster_name
    error_message = "Instances must carry the VaultCluster tag that Raft auto-join discovers peers by."
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

  # 4 nodes tolerate the same single failure as 3 while costing more and
  # making elections slower.
  expect_failures = [var.node_count]
}

run "single_node_is_rejected" {
  command = plan

  variables {
    node_count = 1
  }

  expect_failures = [var.node_count]
}

run "five_nodes_are_accepted" {
  command = plan

  variables {
    node_count = 5
  }

  assert {
    condition     = aws_autoscaling_group.vault.desired_capacity == 5
    error_message = "Five nodes should be a valid cluster size."
  }
}
