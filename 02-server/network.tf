# ==============================================================================
# VPC
# ==============================================================================
#
# One public subnet is enough for a single web server. The instance needs
# outbound internet for apt, snap and the ACM ACME endpoint, and inbound 443
# for the site.
# ==============================================================================

resource "aws_vpc" "acme_vpc" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "acme-vpc"
  }
}

resource "aws_internet_gateway" "acme_igw" {
  vpc_id = aws_vpc.acme_vpc.id

  tags = {
    Name = "acme-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.acme_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.acme_igw.id
  }

  tags = {
    Name = "acme-public-rt"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.acme_vpc.id
  cidr_block        = "10.0.0.0/26"
  availability_zone = "us-east-1a"

  # The instance needs outbound access while it boots, before the Elastic
  # IP is attached.
  map_public_ip_on_launch = true

  tags = {
    Name = "acme-public-subnet"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ==============================================================================
# SECURITY GROUP
# ==============================================================================
#
# Only 443 is open. Port 80 stays closed because the ACME endpoint approves
# the domain in advance and sends no HTTP-01 challenge. There is no SSH;
# administration goes through SSM Session Manager.
# ==============================================================================

resource "aws_security_group" "web" {
  name        = "acme-web-sg"
  description = "HTTPS to NGINX"
  vpc_id      = aws_vpc.acme_vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "acme-web-sg"
  }
}
