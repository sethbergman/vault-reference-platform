# Networking: subnet maths, AZ spread, and where the load balancer lands.
#
# These are the things `terraform validate` cannot see. Validate is happy
# with a cidrsubnet() call that produces overlapping ranges, or a flag
# that silently routes a supposedly-internal load balancer into public
# subnets.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {}

run "public_and_private_subnets_do_not_overlap" {
  command = plan

  # The public and private ranges are both derived from vpc_cidr with
  # cidrsubnet(). An offset mistake would overlap them, which AWS rejects
  # at apply time — after everything else has already been created.
  assert {
    condition = length(setintersection(
      toset([for s in aws_subnet.public : s.cidr_block]),
      toset([for s in aws_subnet.private : s.cidr_block])
    )) == 0
    error_message = "Public and private subnet CIDRs overlap."
  }

  assert {
    condition     = length(toset([for s in aws_subnet.private : s.cidr_block])) == length(aws_subnet.private)
    error_message = "Private subnet CIDRs are not unique."
  }
}

run "subnets_spread_across_distinct_availability_zones" {
  command = plan

  # Putting every node in one AZ would still plan and apply cleanly while
  # quietly removing the AZ redundancy the whole design is for.
  assert {
    condition     = length(toset([for s in aws_subnet.private : s.availability_zone])) == 3
    error_message = "Private subnets must be in three distinct availability zones."
  }
}

run "each_private_subnet_routes_through_its_own_nat" {
  command = plan

  # One NAT per AZ is the point of the per-AZ route tables; a shared NAT
  # would reintroduce a cross-AZ dependency.
  assert {
    condition     = length(aws_nat_gateway.vault) == 3
    error_message = "Expected one NAT gateway per availability zone."
  }

  assert {
    condition     = length(aws_route_table.private) == length(aws_nat_gateway.vault)
    error_message = "Each private route table should pair with its own NAT gateway."
  }
}

run "az_count_scales_the_whole_network_together" {
  command = plan

  variables {
    az_count = 2
  }

  # Subnets, NAT gateways, route tables and EIPs are all counted from
  # az_count independently; they have to move together.
  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "Subnet counts should follow az_count."
  }

  assert {
    condition     = length(aws_nat_gateway.vault) == 2 && length(aws_eip.nat) == 2
    error_message = "NAT gateway and EIP counts should follow az_count."
  }

  assert {
    condition     = length(aws_route_table_association.private) == 2
    error_message = "Route table associations should follow az_count."
  }
}

run "internal_load_balancer_uses_private_subnets" {
  # apply, not plan: subnet IDs are computed, so the comparison below is
  # unknown at plan time. With mocked providers apply creates nothing —
  # it just resolves the mocked values.
  command = apply

  variables {
    internal_lb = true
  }

  # The subnet choice is a conditional on internal_lb. Getting it
  # backwards would put an "internal" load balancer in public subnets —
  # which still works, and is exactly the kind of thing nobody notices.
  assert {
    condition     = length(setintersection(toset(aws_lb.vault.subnets), toset(aws_subnet.private[*].id))) == length(aws_lb.vault.subnets)
    error_message = "An internal load balancer must live in the private subnets."
  }
}

run "public_load_balancer_uses_public_subnets" {
  command = apply

  variables {
    internal_lb = false
  }

  assert {
    condition     = aws_lb.vault.internal == false
    error_message = "internal_lb = false should produce an internet-facing load balancer."
  }

  assert {
    condition     = length(setintersection(toset(aws_lb.vault.subnets), toset(aws_subnet.public[*].id))) == length(aws_lb.vault.subnets)
    error_message = "An internet-facing load balancer must live in the public subnets."
  }
}

run "vpc_has_dns_enabled_for_endpoint_resolution" {
  command = plan

  # The S3 gateway endpoint silently fails to resolve without both.
  assert {
    condition     = aws_vpc.vault.enable_dns_support && aws_vpc.vault.enable_dns_hostnames
    error_message = "VPC DNS support and hostnames must both be enabled."
  }
}
