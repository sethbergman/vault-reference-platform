# Shared provider mocks are declared per-file in Terraform's test
# framework, so each .tftest.hcl repeats this block. Kept identical
# across files on purpose — if one drifts, tests start disagreeing about
# what the world looks like.
#
# These tests run `command = plan` against mocked providers, so they need
# no AWS credentials and create nothing. That means they check the
# *configuration's* logic — that a flag routes to the right subnets, that
# a health check accepts standby nodes — not that AWS accepts the result.
# Only a real apply proves that.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {}

# Guards the defaults themselves. Every other test overrides variables to
# probe a specific behaviour, so without this the shipped defaults could
# drift without anything noticing.
run "defaults_produce_a_three_node_private_cluster" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "Default az_count should produce three private subnets."
  }

  assert {
    condition     = aws_autoscaling_group.vault.desired_capacity == 3
    error_message = "Default node_count should be three."
  }

  assert {
    condition     = aws_lb.vault.internal == true
    error_message = "The load balancer must default to internal — an internet-facing Vault should be an explicit choice."
  }
}
