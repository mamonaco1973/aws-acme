# ==============================================================================
# NETWORK LOAD BALANCER (scenario 3)
# ==============================================================================
#
# Three TLS listeners with the ACM certificate, one per backend:
#
#   TLS:443   ->  TCP:80   ->  instance A   (option a: plain to the target)
#   TLS:8443  ->  TLS:443  ->  instance B   (option b: re-encrypt)
#   TLS:9443  ->  TLS:443  ->  instance C   (option b, ten-year cert)
#
# An NLB passes bytes, not HTTP, so it adds no X-Forwarded-For. With
# instance targets it keeps the client's own IP as the source address, so
# NGINX sees the real client directly.
#
# The security group has to be attached when the NLB is created; an NLB
# created without one can never have one added.
# ==============================================================================

resource "aws_lb" "nlb" {
  name               = "acme-lb-nlb"
  load_balancer_type = "network"
  internal           = false
  security_groups    = [aws_security_group.nlb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  # Each target group has a single instance in one zone; without this, the
  # NLB node in the other zone would have no target to send to.
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "acme-lb-nlb"
  }
}

resource "aws_lb_target_group" "nlb_tcp" {
  name               = "acme-nlb-tcp"
  port               = 80
  protocol           = "TCP"
  target_type        = "instance"
  vpc_id             = aws_vpc.lb_vpc.id
  preserve_client_ip = "true"

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# TLS to the target. Like the ALB, the NLB encrypts to the target without
# checking the certificate it gets back.
resource "aws_lb_target_group" "nlb_tls" {
  name               = "acme-nlb-tls"
  port               = 443
  protocol           = "TLS"
  target_type        = "instance"
  vpc_id             = aws_vpc.lb_vpc.id
  preserve_client_ip = "true"

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "nlb_tls10y" {
  name               = "acme-nlb-tls10y"
  port               = 443
  protocol           = "TLS"
  target_type        = "instance"
  vpc_id             = aws_vpc.lb_vpc.id
  preserve_client_ip = "true"

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "nlb_tcp" {
  target_group_arn = aws_lb_target_group.nlb_tcp.arn
  target_id        = aws_instance.plain.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "nlb_tls" {
  target_group_arn = aws_lb_target_group.nlb_tls.arn
  target_id        = aws_instance.self_signed.id
  port             = 443
}

resource "aws_lb_target_group_attachment" "nlb_tls10y" {
  target_group_arn = aws_lb_target_group.nlb_tls10y.arn
  target_id        = aws_instance.self_signed_10y.id
  port             = 443
}

resource "aws_lb_listener" "nlb_plain" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tcp.arn
  }
}

resource "aws_lb_listener" "nlb_tls" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 8443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tls.arn
  }
}

resource "aws_lb_listener" "nlb_tls10y" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 9443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tls10y.arn
  }
}

resource "aws_route53_record" "nlb" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = local.nlb_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.nlb.dns_name
    zone_id                = aws_lb.nlb.zone_id
    evaluate_target_health = false
  }
}

# ==============================================================================
# OUTPUTS
# ==============================================================================

output "plain_instance_id" {
  value = aws_instance.plain.id
}

output "self_signed_instance_id" {
  value = aws_instance.self_signed.id
}

output "self_signed_10y_instance_id" {
  value = aws_instance.self_signed_10y.id
}

output "alb_fqdn" {
  value = local.alb_fqdn
}

output "nlb_fqdn" {
  value = local.nlb_fqdn
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "nlb_dns_name" {
  value = aws_lb.nlb.dns_name
}

output "backend_cert_mode" {
  value = var.backend_cert_mode
}

output "target_group_arns" {
  value = [
    aws_lb_target_group.alb_http.arn,
    aws_lb_target_group.alb_tls.arn,
    aws_lb_target_group.nlb_tcp.arn,
    aws_lb_target_group.alb_tls10y.arn,
    aws_lb_target_group.nlb_tls.arn,
    aws_lb_target_group.nlb_tls10y.arn,
  ]
}
