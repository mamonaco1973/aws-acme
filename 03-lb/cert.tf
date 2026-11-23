# ==============================================================================
# ACM CERTIFICATE FOR THE LOAD BALANCERS
# ==============================================================================
#
# A regular ACM public certificate, validated through DNS. It cannot be an
# ACME certificate from 01-acme: AWS never holds an ACME certificate's
# private key, so those cannot be attached to ELB, CloudFront or API
# Gateway. ACM renews this one by itself, however short public certificate
# lifetimes get, as long as the validation records stay in place.
#
# One certificate covers both load balancer names.
# ==============================================================================

resource "aws_acm_certificate" "lb" {
  domain_name               = local.alb_fqdn
  subject_alternative_names = [local.nlb_fqdn]
  validation_method         = "DNS"

  tags = {
    Name = "acme-lb-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.lb.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.zone.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

# Waits until ACM reports the certificate ISSUED; the listeners need that.
resource "aws_acm_certificate_validation" "lb" {
  certificate_arn         = aws_acm_certificate.lb.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
