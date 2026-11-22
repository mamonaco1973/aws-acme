# ==============================================================================
# VPC
# ==============================================================================
#
# Two public and two private subnets across two Availability Zones (an ALB
# needs at least two):
#
#   public  - the ALB, the NLB and the NAT gateway; the only internet-facing
#             pieces.
#   private - the three backends, with no public IP. The load balancers are
#             the only way in; the NAT gateway is their only way out (apt and
#             SSM).
#
# One NAT gateway, in us-east-1a, keeps the cost down. Production would run
# one per Availability Zone.
# ==============================================================================

resource "aws_vpc" "lb_vpc" {
  cidr_block           = "10.0.1.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "acme-lb-vpc"
  }
}

resource "aws_internet_gateway" "lb_igw" {
  vpc_id = aws_vpc.lb_vpc.id

  tags = {
    Name = "acme-lb-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lb_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lb_igw.id
  }

  tags = {
    Name = "acme-lb-public-rt"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.lb_vpc.id
  cidr_block              = "10.0.1.0/26"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "acme-lb-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.lb_vpc.id
  cidr_block              = "10.0.1.64/26"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "acme-lb-public-b"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "acme-lb-nat-eip"
  }

  depends_on = [aws_internet_gateway.lb_igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "acme-lb-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lb_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "acme-lb-private-rt"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.lb_vpc.id
  cidr_block        = "10.0.1.128/26"
  availability_zone = "us-east-1a"

  tags = {
    Name = "acme-lb-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.lb_vpc.id
  cidr_block        = "10.0.1.192/26"
  availability_zone = "us-east-1b"

  tags = {
    Name = "acme-lb-private-b"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# SECURITY GROUPS
# ==============================================================================
#
# The ALB takes 443, the NLB takes 443, 8443 and 9443. The backends accept 80 and
# 443 only from those two security groups (and have no public IP anyway).
# That holds for the NLB too, even
# though it preserves the client's IP: a target rule that references the
# NLB's security group matches traffic the NLB forwards, whatever its source
# address. There is no SSH; administration goes through SSM.
# ==============================================================================

resource "aws_security_group" "alb" {
  name        = "acme-lb-alb-sg"
  description = "HTTPS to the ALB"
  vpc_id      = aws_vpc.lb_vpc.id

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
    Name = "acme-lb-alb-sg"
  }
}

resource "aws_security_group" "nlb" {
  name        = "acme-lb-nlb-sg"
  description = "TLS to the NLB"
  vpc_id      = aws_vpc.lb_vpc.id

  ingress {
    description = "TLS to plain backend"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "TLS to expired-cert backend"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "TLS to ten-year-cert backend"
    from_port   = 9443
    to_port     = 9443
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
    Name = "acme-lb-nlb-sg"
  }
}

resource "aws_security_group" "backend" {
  name        = "acme-lb-backend-sg"
  description = "HTTP and HTTPS from the load balancers only"
  vpc_id      = aws_vpc.lb_vpc.id

  ingress {
    description     = "HTTP from the load balancers"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id, aws_security_group.nlb.id]
  }

  ingress {
    description     = "HTTPS from the load balancers"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id, aws_security_group.nlb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "acme-lb-backend-sg"
  }
}
