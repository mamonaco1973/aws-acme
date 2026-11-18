#!/bin/bash
# ==============================================================================
# apply.sh — build the ACM ACME lab
#
# Phase 1 (01-acme):   ACM ACME endpoint, domain validation for the demo
#                      host name, issuer role and external account binding.
# Phase 2 (02-server): VPC, NGINX + Apache server, Elastic IP and A record.
#                      The server gets its certificate with certbot at boot.
#
# The script then waits for the server to finish and runs validate.sh.
# ==============================================================================

set -euo pipefail

cd "$(dirname "$0")"

export AWS_DEFAULT_REGION="us-east-1"
# AWS_REGION, if set in the caller's shell, overrides AWS_DEFAULT_REGION.
export AWS_REGION="us-east-1"

./check_env.sh

# ==============================================================================
# PHASE 1: ACM ACME ENDPOINT
# ==============================================================================

echo "NOTE: Creating the ACM ACME endpoint."

cd 01-acme
terraform init
terraform apply -auto-approve

validation_arn=$(terraform output -raw domain_validation_arn)
cd ..

# Terraform normally returns once the domain validation is VALID; this
# makes sure, since certbot cannot get a certificate before then.
echo "NOTE: Waiting for the ACME domain validation to be VALID."

for i in $(seq 1 60); do
  status=$(aws acm describe-acme-domain-validation \
    --acme-domain-validation-arn "${validation_arn}" \
    --query "AcmeDomainValidation.Status" --output text)

  case "${status}" in
    VALID)   echo "NOTE: Domain validation is VALID."; break ;;
    INVALID) echo "ERROR: Domain validation is INVALID."; exit 1 ;;
  esac

  if [[ $i -eq 60 ]]; then
    echo "ERROR: Domain validation still ${status} after 10 minutes."
    exit 1
  fi
  sleep 10
done

# ==============================================================================
# PHASE 2: WEB SERVER
# ==============================================================================

echo "NOTE: Building the NGINX + Apache server."

cd 02-server
terraform init
terraform apply -auto-approve

instance_id=$(terraform output -raw instance_id)
cd ..

# ==============================================================================
# WAIT FOR THE SERVER BOOTSTRAP
# ==============================================================================
#
# User data installs packages, gets the certificate and starts NGINX, then
# writes /var/lib/acme-lab/ready. SSM Run Command checks for that file; it
# also needs the SSM agent to have registered first.
# ==============================================================================

echo "NOTE: Waiting for the server to get its certificate and start NGINX."

for i in $(seq 1 60); do
  cmd_id=$(aws ssm send-command \
    --instance-ids "${instance_id}" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["test -f /var/lib/acme-lab/ready && echo READY || (tail -n 1 /var/log/acme-lab-bootstrap.log; false)"]' \
    --query "Command.CommandId" --output text 2>/dev/null || true)

  if [[ -n "${cmd_id}" ]]; then
    sleep 5
    result=$(aws ssm get-command-invocation \
      --command-id "${cmd_id}" --instance-id "${instance_id}" \
      --query "StandardOutputContent" --output text 2>/dev/null || true)

    if [[ "${result}" == READY* ]]; then
      echo "NOTE: Server is ready."
      break
    fi
  fi

  if [[ $i -eq 60 ]]; then
    echo "ERROR: Server not ready after 15 minutes."
    echo "       Check /var/log/acme-lab-bootstrap.log through Session Manager."
    exit 1
  fi
  sleep 10
done

# ==============================================================================
# VALIDATE
# ==============================================================================

./validate.sh
