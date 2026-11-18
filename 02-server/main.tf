# ==============================================================================
# PROVIDER AND PHASE 1 OUTPUTS
# ==============================================================================
#
# Phase 1 (01-acme) owns the ACME endpoint, the domain validation and the
# external account binding. This phase reads their identifiers from its
# local state file rather than looking them up by tag.
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

data "terraform_remote_state" "acme" {
  backend = "local"
  config = {
    path = "../01-acme/terraform.tfstate"
  }
}

locals {
  fqdn               = data.terraform_remote_state.acme.outputs.fqdn
  zone_id            = data.terraform_remote_state.acme.outputs.zone_id
  acme_directory_url = data.terraform_remote_state.acme.outputs.acme_directory_url
  eab_arn            = data.terraform_remote_state.acme.outputs.eab_arn
}

# ==============================================================================
# INPUTS
# ==============================================================================

variable "allowed_cidr" {
  description = "Who may reach the site on 443. Narrow it to your own /32 if you like."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Instance size for the NGINX + Apache server"
  type        = string
  default     = "t3.micro"
}
