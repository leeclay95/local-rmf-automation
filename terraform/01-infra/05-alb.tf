###############################################################################
# Application Load Balancers.
#
# In the original lab the AWS Load Balancer Controller ran inside each cluster
# and created these from the Ingress annotations. That needs the controller pod
# to hold IRSA credentials and call the ELBv2 API, which is several moving parts
# deep for an emulator; so here Terraform creates the same resources directly
# and the Kubernetes Services in ../02-workloads are NodePort instead of
# ClusterIP + Ingress. The resulting AWS objects are the same shape.
#
# Floci's ELBv2 is a real proxy, not just a control plane: HTTPS listeners
# terminate TLS with the ACM certificate, pick the load balancer by SNI, and
# forward to the registered targets. Both ALBs share host port 443, which is why
# each needs its own certificate hostname.
#
# Targets are target_type = "ip" pointing at the k3s container's address on the
# lab Docker network, on the Service's NodePort. target_type = "instance" does
# not work: Floci's data plane hands the instance ID straight to DNS.
###############################################################################
locals {
  alb_subnet_ids = [for s in aws_subnet.private : s.id]

  albs = {
    keycloak = {
      host      = var.keycloak_host
      node_port = var.keycloak_node_port
      node_ip   = one(data.aws_instances.keycloak_node.private_ips)
      vpc_id    = aws_vpc.lab.id
      # Keycloak answers / with a 302 to /admin, which the default 200-only
      # matcher reads as unhealthy. This is the same fix the original lab had to
      # apply by hand in the Target Groups console (README step 8).
      health_matcher = "200,301,302"
      health_path    = "/"
    }
    stigman = {
      host           = var.stigman_host
      node_port      = var.stigman_node_port
      node_ip        = one(data.aws_instances.stigman_node.private_ips)
      vpc_id         = aws_vpc.lab.id
      health_matcher = "200,301,302"
      health_path    = "/"
    }
  }
}

resource "aws_security_group" "alb" {
  for_each = local.albs

  name        = "${each.key}-alb"
  description = "Ingress to the ${each.key} ALB"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "HTTP (redirected to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${each.key}-alb" }
}

resource "aws_lb" "app" {
  for_each = local.albs

  name               = "${each.key}-alb"
  load_balancer_type = "application"
  internal           = true
  subnets            = local.alb_subnet_ids
  security_groups    = [aws_security_group.alb[each.key].id]

  # Keycloak builds absolute URLs (and its OIDC issuer) from the Host header, so
  # the client's Host must survive the proxy hop unchanged. Without this the ALB
  # rewrites it to the target's ip:port and Keycloak issues tokens for an issuer
  # the browser never used.
  preserve_host_header = true

  tags = { Name = "${each.key}-alb" }
}

resource "aws_lb_target_group" "app" {
  for_each = local.albs

  name        = "${each.key}-tg"
  port        = each.value.node_port
  protocol    = "HTTP"
  vpc_id      = each.value.vpc_id
  target_type = "ip"

  health_check {
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = each.value.health_matcher
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${each.key}-tg" }
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = local.albs

  target_group_arn  = aws_lb_target_group.app[each.key].arn
  target_id         = each.value.node_ip
  port              = each.value.node_port
  availability_zone = "all"
}

resource "aws_lb_listener" "https" {
  for_each = local.albs

  load_balancer_arn = aws_lb.app[each.key].arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.leaf[each.key].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }
}

# Published on host port 8080 rather than 80, because apache2 already holds
# port 80 on this host. See the README if you would rather have :80.
resource "aws_lb_listener" "http_redirect" {
  for_each = local.albs

  load_balancer_arn = aws_lb.app[each.key].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}
