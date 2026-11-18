# ==============================================================================
# ACM ACME ENDPOINT
# ==============================================================================
#
# A managed ACME server. Its directory URL is what certbot uses as --server.
#
# PRE_APPROVED means ACM checks the domain validation below instead of
# sending the client an HTTP-01 or DNS-01 challenge, so the web server never
# has to open port 80 and certbot never touches DNS.
# ==============================================================================

resource "awscc_certificatemanager_acme_endpoint" "lab" {
  authorization_behavior = "PRE_APPROVED"
  contact                = "NOT_REQUIRED"

  certificate_authority = {
    public_certificate_authority = {
      allowed_key_algorithms = ["EC_prime256v1", "RSA_2048"]
    }
  }

  tags = [{
    key   = "Name"
    value = "acme-lab-endpoint"
  }]
}

# ==============================================================================
# DOMAIN VALIDATION
# ==============================================================================
#
# Approves the endpoint to issue for the one demo host name only: no apex,
# no other subdomains, no wildcards. With hosted_zone_id set, ACM writes the
# validation CNAME into Route 53 itself. apply.sh waits for status VALID
# before the server is built.
# ==============================================================================

resource "awscc_certificatemanager_acme_domain_validation" "lab" {
  acme_endpoint_arn = awscc_certificatemanager_acme_endpoint.lab.acme_endpoint_arn
  domain_name       = local.fqdn

  prevalidation_options = {
    dns_prevalidation = {
      hosted_zone_id = data.aws_route53_zone.zone.zone_id
      domain_scope = {
        exact_domain = "ENABLED"
        subdomains   = "DISABLED"
        wildcards    = "DISABLED"
      }
    }
  }
}

# ==============================================================================
# EXTERNAL ACCOUNT BINDING
# ==============================================================================
#
# Gives certbot a key ID and MAC key to register an ACME account. The server
# reads them from ACM at boot with its own instance role, so the secret never
# appears in user data or Terraform outputs.
#
# The binding only matters for that first registration; the ACME account it
# creates keeps working (renewals included) after the binding expires.
# ==============================================================================

resource "awscc_certificatemanager_acme_external_account_binding" "lab" {
  acme_endpoint_arn = awscc_certificatemanager_acme_endpoint.lab.acme_endpoint_arn
  role_arn          = aws_iam_role.acme_issuer.arn

  expiration = {
    value = 1
    type  = "DAYS"
  }

  # ACM assumes the role when the binding is created to check it, so the
  # policy has to be attached and visible to IAM first.
  depends_on = [time_sleep.issuer_role_propagation]
}

# ==============================================================================
# OUTPUTS
# ==============================================================================

output "fqdn" {
  value = local.fqdn
}

output "zone_id" {
  value = data.aws_route53_zone.zone.zone_id
}

output "acme_endpoint_arn" {
  value = awscc_certificatemanager_acme_endpoint.lab.acme_endpoint_arn
}

output "acme_directory_url" {
  value = awscc_certificatemanager_acme_endpoint.lab.endpoint_url
}

output "domain_validation_arn" {
  value = awscc_certificatemanager_acme_domain_validation.lab.arn
}

output "eab_arn" {
  value = awscc_certificatemanager_acme_external_account_binding.lab.acme_external_account_binding_arn
}
