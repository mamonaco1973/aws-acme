# ==============================================================================
# APPLICATION LOAD BALANCER (scenario 2)
# ==============================================================================
#
# HTTPS on 443 with the ACM certificate. The path picks the backend:
#
#   /http/*    ->  HTTP:80   ->  instance A   (option a: plain to the target)
#   /tls/*     ->  HTTPS:443 ->  instance B   (option b: re-encrypt)
#   /tls10y/*  ->  HTTPS:443 ->  instance C   (option b, ten-year cert)
#
# Anything else gets a fixed 404. The ALB adds X-Forwarded-For and
# X-Forwarded-Proto, and the backends see the ALB's own address as the
# client.
# ==============================================================================

resource "aws_lb" "alb" {
  name               = "acme-lb-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "acme-lb-alb"
  }
}

resource "aws_lb_target_group" "alb_http" {
  name     = "acme-alb-http"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lb_vpc.id

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# HTTPS to the target. The ALB encrypts but does not check the target's
# certificate at all: not the issuer, not the name, not the dates.
resource "aws_lb_target_group" "alb_tls" {
  name     = "acme-alb-tls"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = aws_vpc.lb_vpc.id

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "alb_tls10y" {
  name     = "acme-alb-tls10y"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = aws_vpc.lb_vpc.id

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "alb_http" {
  target_group_arn = aws_lb_target_group.alb_http.arn
  target_id        = aws_instance.plain.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "alb_tls" {
  target_group_arn = aws_lb_target_group.alb_tls.arn
  target_id        = aws_instance.self_signed.id
  port             = 443
}

resource "aws_lb_target_group_attachment" "alb_tls10y" {
  target_group_arn = aws_lb_target_group.alb_tls10y.arn
  target_id        = aws_instance.self_signed_10y.id
  port             = 443
}

resource "aws_lb_listener" "alb_https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "No route. Try /http/, /tls/ or /tls10y/.\n"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "alb_http" {
  listener_arn = aws_lb_listener.alb_https.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/http", "/http/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_http.arn
  }
}

resource "aws_lb_listener_rule" "alb_tls" {
  listener_arn = aws_lb_listener.alb_https.arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/tls", "/tls/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tls.arn
  }
}

resource "aws_lb_listener_rule" "alb_tls10y" {
  listener_arn = aws_lb_listener.alb_https.arn
  priority     = 30

  condition {
    path_pattern {
      values = ["/tls10y", "/tls10y/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tls10y.arn
  }
}

resource "aws_route53_record" "alb" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = local.alb_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = false
  }
}
