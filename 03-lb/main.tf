# ==============================================================================
# PROVIDER
# ==============================================================================
#
# 03-lb stands on its own: it reads nothing from 01-acme or 02-server and
# has its own VPC. It shows the two other ways to run HTTPS behind a load
# balancer, next to option 1's certbot-on-the-instance:
#
#   option 2: the load balancer ends TLS with an ACM certificate and talks
#             plain HTTP to the instance (the plain backend).
#   option 3: the load balancer ends TLS with an ACM certificate and opens a
#             new TLS connection to the instance, which serves a long-lived
#             self-signed certificate (the ten-year backend).
#
# Both an ALB and an NLB front the same backends, plus a broken backend
# (a test, not an option) that shows neither kind of load balancer
# validates the certificate a target presents.
# ==============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ==============================================================================
# INPUTS
# ==============================================================================

variable "zone_name" {
  description = "Existing public Route 53 hosted zone (same as 01-acme). Set in lab.env (TF_VAR_zone_name)."
  type        = string
}

variable "alb_host_name" {
  description = "Host label for the ALB inside the zone"
  type        = string
  default     = "alb-lab"
}

variable "nlb_host_name" {
  description = "Host label for the NLB inside the zone"
  type        = string
  default     = "nlb-lab"
}

variable "backend_cert_mode" {
  description = <<-EOT
    Self-signed certificate on the broken backend (a test, not an option).
      expired  - expired in 2025 and named nobody-checks-this.invalid, to
                 prove the load balancers never check it.
      valid10y - a sane ten-year self-signed certificate.
  EOT
  type        = string
  default     = "expired"

  validation {
    condition     = contains(["expired", "valid10y"], var.backend_cert_mode)
    error_message = "backend_cert_mode must be \"expired\" or \"valid10y\"."
  }
}

variable "allowed_cidr" {
  description = "Who may reach the load balancers. Narrow it to your own /32 if you like."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Instance size for both backends"
  type        = string
  default     = "t3.micro"
}

locals {
  alb_fqdn = "${var.alb_host_name}.${var.zone_name}"
  nlb_fqdn = "${var.nlb_host_name}.${var.zone_name}"
}

# The zone already exists. It is looked up, never managed, so destroy leaves
# it and its other records alone.
data "aws_route53_zone" "zone" {
  name         = var.zone_name
  private_zone = false
}
