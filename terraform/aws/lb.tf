# A network load balancer, not an application load balancer.
#
# docs/security.md commits to TLS terminating at the Vault process rather
# than being offloaded at the load balancer. An ALB cannot do that — it
# terminates client TLS and opens a second connection to the backend, so
# the plaintext exists inside the load balancer. An NLB forwards TCP
# untouched, which keeps the client's TLS session end-to-end with Vault
# and means the load balancer never holds a certificate or sees a token.

resource "aws_lb" "vault" {
  name_prefix = "vault-"
  # An internet-facing Vault should be a deliberate decision; the default
  # is internal.
  internal           = var.internal_lb
  load_balancer_type = "network"
  security_groups    = [aws_security_group.lb.id]
  subnets            = var.internal_lb ? aws_subnet.private[*].id : aws_subnet.public[*].id

  enable_cross_zone_load_balancing = true

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-vault"
  })
}

resource "aws_lb_target_group" "vault" {
  name_prefix = "vault-"
  port        = 8200
  protocol    = "TCP"
  vpc_id      = aws_vpc.vault.id
  target_type = "instance"

  # The health check is the part that makes this cluster-aware. Vault's
  # /sys/health returns 200 only on the active node and 429 on standbys.
  # Accepting both keeps every unsealed node in the pool, so reads can be
  # served anywhere and writes get forwarded to the leader. Checking TCP
  # alone would keep sealed nodes in rotation; accepting only 200 would
  # route everything to the leader and waste the standbys.
  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true"
    matcher             = "200,429"
    interval            = 10
    timeout             = 6
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Give a node being replaced time to finish in-flight requests, but not
  # so long that a rolling refresh crawls.
  deregistration_delay = 60

  stickiness {
    enabled = false
    type    = "source_ip"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.vault.arn
  port              = 8200
  # TCP, not TLS: the listener passes bytes through without decrypting.
  protocol = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}
