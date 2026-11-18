# ==============================================================================
# ACME ISSUER ROLE
# ==============================================================================
#
# ACM assumes this role whenever an ACME account registered through the
# binding issues or revokes a certificate. It is the same permission check
# as calling acm:RequestCertificate directly, so the acm:DomainNames
# condition limits it to the demo host name even if the endpoint's domain
# validations were widened later.
# ==============================================================================

resource "aws_iam_role" "acme_issuer" {
  name = "acme-lab-issuer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "acm-acme.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        StringLikeIfExists = { "sts:SourceIdentity" = "acm-acme-*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "acme_issuer" {
  name = "issue-and-revoke"
  role = aws_iam_role.acme_issuer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "acm:RequestCertificate"
        Resource = "*"
        Condition = {
          "ForAllValues:StringEquals" = { "acm:DomainNames" = [local.fqdn] }
        }
      },
      {
        Effect   = "Allow"
        Action   = "acm:RevokeCertificate"
        Resource = "*"
      }
    ]
  })
}

# New IAM roles take a few seconds to become assumable everywhere.
resource "time_sleep" "issuer_role_propagation" {
  create_duration = "15s"
  depends_on      = [aws_iam_role_policy.acme_issuer]
}
