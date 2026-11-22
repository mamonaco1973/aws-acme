# ==============================================================================
# BACKEND ROLE
# ==============================================================================
#
# SSM Session Manager and Run Command only: apply.sh uses Run Command to
# wait for the bootstrap to finish. The backends need nothing else from AWS.
# ==============================================================================

resource "aws_iam_role" "backend" {
  name = "acme-lb-backend-role"

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
  role       = aws_iam_role.backend.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "backend" {
  name = "acme-lb-backend-profile"
  role = aws_iam_role.backend.name
}

# ==============================================================================
# BACKENDS
# ==============================================================================
#
# Three Ubuntu 24.04 instances running NGINX alone, in the private subnets
# with no public IP, all serving the same diagnostic page at any path:
#
#   A "plain"           - port 80, plain HTTP                        (option a)
#   B "self-signed"     - port 443, certificate per backend_cert_mode (option b)
#   C "self-signed-10y" - port 443, ten-year self-signed certificate  (option b)
#
# B shows that nothing checks the certificate; C is the pattern to copy.
#
# Each target group holds one instance, so a request that lands in the
# other Availability Zone has to cross zones; nlb.tf turns that on for the
# NLB (an ALB always does it).
# ==============================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "plain" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.backend.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  metadata_options {
    http_tokens = "required"
  }

  # A change to the user data (backend_cert_mode included) rebuilds the
  # instance, since cloud-init only runs it on first boot.
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/scripts/backend.sh.tpl", {
    backend   = "plain"
    label     = "A"
    cert_mode = "none"
  })

  tags = {
    Name = "acme-lb-plain"
  }

  # User data needs the NAT route for apt as soon as the instance boots.
  depends_on = [aws_route_table_association.private_a]
}

resource "aws_instance" "self_signed" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_b.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.backend.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  metadata_options {
    http_tokens = "required"
  }

  # A change to the user data (backend_cert_mode included) rebuilds the
  # instance, since cloud-init only runs it on first boot.
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/scripts/backend.sh.tpl", {
    backend   = "self-signed"
    label     = "B"
    cert_mode = var.backend_cert_mode
  })

  tags = {
    Name = "acme-lb-self-signed"
  }

  depends_on = [aws_route_table_association.private_b]
}

# The recommended version of option b: a self-signed certificate that stays
# valid for ten years, so nothing on the instance ever has to renew it.
resource "aws_instance" "self_signed_10y" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.backend.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  metadata_options {
    http_tokens = "required"
  }

  # A change to the user data (backend_cert_mode included) rebuilds the
  # instance, since cloud-init only runs it on first boot.
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/scripts/backend.sh.tpl", {
    backend   = "self-signed-10y"
    label     = "C"
    cert_mode = "valid10y"
  })

  tags = {
    Name = "acme-lb-self-signed-10y"
  }

  depends_on = [aws_route_table_association.private_a]
}
