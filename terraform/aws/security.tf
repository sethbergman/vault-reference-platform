# Two security groups, deliberately separate: one for the load balancer,
# one for the nodes. The node group accepts API traffic only from the load
# balancer's group rather than from a CIDR, so the only way to reach the
# Vault API is through the load balancer even if something else lands in
# the same subnet.

resource "aws_security_group" "lb" {
  name        = "${var.cluster_name}-lb"
  description = "Vault load balancer"
  vpc_id      = aws_vpc.vault.id

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-lb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "lb_api" {
  count = length(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.lb.id
  description       = "Vault API from allowed networks"
  cidr_ipv4         = var.allowed_cidr_blocks[count.index]
  from_port         = 8200
  to_port           = 8200
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "lb_to_nodes" {
  security_group_id            = aws_security_group.lb.id
  description                  = "Health checks and forwarded traffic to Vault nodes"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = 8200
  to_port                      = 8200
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "vault" {
  name        = "${var.cluster_name}-nodes"
  description = "Vault cluster nodes"
  vpc_id      = aws_vpc.vault.id

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-nodes"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vault_api_from_lb" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Vault API from the load balancer only"
  referenced_security_group_id = aws_security_group.lb.id
  from_port                    = 8200
  to_port                      = 8200
  ip_protocol                  = "tcp"
}

# Raft replication and leader election between nodes. Self-referencing, so
# membership follows the security group rather than any IP list — which is
# what makes an autoscaling group workable here.
resource "aws_vpc_security_group_ingress_rule" "vault_cluster" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Raft cluster traffic between nodes"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = 8201
  to_port                      = 8201
  ip_protocol                  = "tcp"
}

# Nodes also call each other's API port — request forwarding sends writes
# received by a standby on to the active node.
resource "aws_vpc_security_group_ingress_rule" "vault_api_between_nodes" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Request forwarding between nodes"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = 8200
  to_port                      = 8200
  ip_protocol                  = "tcp"
}

# Outbound is unrestricted: nodes need package repositories, the KMS
# endpoint for auto-unseal, S3 for snapshots, and SSM. Narrowing this to
# specific endpoints is worthwhile hardening but needs interface endpoints
# for each service to avoid breaking auto-unseal on boot.
resource "aws_vpc_security_group_egress_rule" "vault_all" {
  security_group_id = aws_security_group.vault.id
  description       = "Outbound to package repos, KMS, S3 and SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
