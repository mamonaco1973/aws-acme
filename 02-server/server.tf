# ==============================================================================
# WEB SERVER
# ==============================================================================
#
# Ubuntu 24.04 with NGINX on 443 in front of Apache on 127.0.0.1:8080.
# The user data script installs both, gets the certificate from the ACM
# ACME endpoint with certbot, and only then enables the NGINX HTTPS site.
# ==============================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.web.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/scripts/userdata.sh.tpl", {
    fqdn               = local.fqdn
    acme_directory_url = local.acme_directory_url
    eab_arn            = local.eab_arn
  })

  tags = {
    Name = "acme-web"
  }

  # The role must be able to read the EAB before the script asks for it.
  depends_on = [aws_iam_role_policy.eab_credentials]
}

# ==============================================================================
# ELASTIC IP AND DNS
# ==============================================================================

resource "aws_eip" "web" {
  domain   = "vpc"
  instance = aws_instance.web.id

  tags = {
    Name = "acme-web-eip"
  }

  depends_on = [aws_internet_gateway.acme_igw]
}

resource "aws_route53_record" "web" {
  zone_id = local.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 60
  records = [aws_eip.web.public_ip]
}

# ==============================================================================
# OUTPUTS
# ==============================================================================

output "instance_id" {
  value = aws_instance.web.id
}

output "public_ip" {
  value = aws_eip.web.public_ip
}

output "site_url" {
  value = "https://${local.fqdn}"
}
