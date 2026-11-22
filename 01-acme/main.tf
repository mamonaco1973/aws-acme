# ==============================================================================
# PROVIDERS
# ==============================================================================
#
# The hashicorp/aws provider has no ACME resources yet, so the ACM ACME
# endpoint, domain validation and external account binding come from the
# Cloud Control based awscc provider. Everything else uses aws.
# ==============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    time = {
      source = "hashicorp/time"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.110.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "awscc" {
  region = "us-east-1"
}

# ==============================================================================
# INPUTS
# ==============================================================================

variable "zone_name" {
  description = "Existing public Route 53 hosted zone. Set in lab.env (TF_VAR_zone_name)."
  type        = string
}

variable "host_name" {
  description = "Host label for the demo site inside the zone"
  type        = string
  default     = "acme-lab"
}

locals {
  fqdn = "${var.host_name}.${var.zone_name}"
}

# The zone already exists (Route 53 Registrar created it). It is looked up,
# never managed, so destroy leaves it and its other records alone.
data "aws_route53_zone" "zone" {
  name         = var.zone_name
  private_zone = false
}
