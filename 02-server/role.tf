# ==============================================================================
# INSTANCE ROLE
# ==============================================================================
#
# Two jobs:
#   - SSM Session Manager and Run Command (renew.sh and destroy.sh use it).
#   - Reading the EAB key ID and MAC key for this one binding at boot, so the
#     secret is fetched by the server itself instead of passing through user
#     data or Terraform state.
# ==============================================================================

resource "aws_iam_role" "web" {
  name = "acme-web-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "eab_credentials" {
  name = "read-eab-credentials"
  role = aws_iam_role.web.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "acm:GetAcmeExternalAccountBindingCredentials"
      Resource = local.eab_arn
    }]
  })
}

resource "aws_iam_instance_profile" "web" {
  name = "acme-web-profile"
  role = aws_iam_role.web.name
}
