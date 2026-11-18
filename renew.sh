#!/bin/bash
# ==============================================================================
# renew.sh — force one renewal and show the live certificate change
#
# certbot's own timer renews well before the 45-day certificate expires.
# This script forces a renewal now through SSM Run Command so the rotation
# can be watched: the serial NGINX serves changes, the page keeps loading,
# and the ACM certificate ARN stays the same.
#
# Each renewal is a new issuance and is billed like the first one.
# ==============================================================================

set -euo pipefail

cd "$(dirname "$0")"

export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"

fqdn=$(terraform -chdir=01-acme output -raw fqdn)
endpoint_arn=$(terraform -chdir=01-acme output -raw acme_endpoint_arn)
instance_id=$(terraform -chdir=02-server output -raw instance_id)
public_ip=$(terraform -chdir=02-server output -raw public_ip)

serial() {
  openssl s_client -connect "${public_ip}:443" -servername "${fqdn}" \
    </dev/null 2>/dev/null | openssl x509 -noout -serial | cut -d= -f2
}

acm_arn() {
  aws acm search-certificates \
    --filter-statement "{\"Filter\":{\"AcmCertificateMetadataFilter\":{\"AcmeEndpointArn\":\"${endpoint_arn}\"}}}" \
    --query "Results[0].CertificateArn" --output text
}

before_serial=$(serial)
before_arn=$(acm_arn)

echo ""
printf "NOTE: %-16s %s\n" "Serial before:" "${before_serial}"
printf "NOTE: %-16s %s\n" "ACM ARN before:" "${before_arn}"
echo ""

# ------------------------------------------------------------------------------
# Forced renewal on the server
# ------------------------------------------------------------------------------
# certbot reuses its registered ACME account, so no EAB is needed. The
# deploy hook reloads NGINX when the new certificate lands.
# ------------------------------------------------------------------------------

echo "NOTE: Forcing certbot renewal on ${instance_id}."

cmd_id=$(aws ssm send-command \
  --instance-ids "${instance_id}" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["certbot renew --force-renewal --cert-name acme-lab --issuance-timeout 120 --non-interactive"]' \
  --query "Command.CommandId" --output text)

for i in $(seq 1 36); do
  sleep 5
  status=$(aws ssm get-command-invocation \
    --command-id "${cmd_id}" --instance-id "${instance_id}" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  case "${status}" in
    Success) break ;;
    Failed|Cancelled|TimedOut)
      aws ssm get-command-invocation --command-id "${cmd_id}" \
        --instance-id "${instance_id}" \
        --query "[StandardOutputContent,StandardErrorContent]" --output text
      echo "ERROR: Renewal ${status}."
      exit 1 ;;
  esac
  if [[ $i -eq 36 ]]; then
    echo "ERROR: Renewal did not finish in 3 minutes."
    exit 1
  fi
done

echo "NOTE: certbot renewal succeeded."

after_serial=$(serial)
after_arn=$(acm_arn)

echo ""
printf "NOTE: %-16s %s\n" "Serial after:" "${after_serial}"
printf "NOTE: %-16s %s\n" "ACM ARN after:" "${after_arn}"
echo ""

if [[ "${after_serial}" == "${before_serial}" ]]; then
  echo "ERROR: NGINX is still serving the old certificate."
  exit 1
fi
echo "NOTE: NGINX is serving the renewed certificate."

if [[ "${after_arn}" == "${before_arn}" ]]; then
  echo "NOTE: ACM kept the same certificate ARN across the renewal."
fi

if curl -sS --fail --max-time 10 --resolve "${fqdn}:443:${public_ip}" \
    "https://${fqdn}/" | grep -q "Served by Apache through NGINX"; then
  echo "NOTE: The page still loads: Served by Apache through NGINX."
else
  echo "ERROR: The page did not load after the renewal."
  exit 1
fi
echo ""
