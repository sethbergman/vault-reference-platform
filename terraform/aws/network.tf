# Network layout: Vault nodes sit in private subnets with no public IPs.
# Only the load balancer lives in public subnets, and even that defaults to
# internal (var.internal_lb). Nodes reach the internet outbound-only,
# through NAT, to install packages and call KMS.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve /24s out of the VPC CIDR: public subnets first, then private.
  # With the default 10.0.0.0/16 and 3 AZs that's 10.0.0-2.0/24 public and
  # 10.0.10-12.0/24 private, leaving room between them to grow.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

resource "aws_vpc" "vault" {
  cidr_block = var.vpc_cidr

  # Both required for the VPC endpoint below to resolve.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

resource "aws_internet_gateway" "vault" {
  vpc_id = aws_vpc.vault.id

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# ---------------------------------------------------------------------------
# Public subnets — load balancer and NAT only
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.vault.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vault.id
  }

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-public"
  })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# NAT — one per AZ
# ---------------------------------------------------------------------------
# One NAT gateway per AZ so a single AZ failure can't cut outbound access
# for the others. This is the main running cost of the whole stack
# (roughly $32/month each, plus data processing) — collapsing to a single
# shared NAT is a reasonable trade for non-production, at the price of a
# cross-AZ dependency.
resource "aws_eip" "nat" {
  count = var.az_count

  domain = "vpc"

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-nat-${local.azs[count.index]}"
  })
}

resource "aws_nat_gateway" "vault" {
  count = var.az_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-nat-${local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.vault]
}

# ---------------------------------------------------------------------------
# Private subnets — the Vault nodes
# ---------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.vault.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# A route table per AZ, because each points at that AZ's own NAT gateway.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.vault.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.vault[count.index].id
  }

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-private-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint
# ---------------------------------------------------------------------------
# Snapshot uploads would otherwise leave via NAT, paying per-GB processing
# on every snapshot. A gateway endpoint keeps that traffic on the AWS
# network and costs nothing.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.vault.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-s3"
  })
}
