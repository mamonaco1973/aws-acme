#!/bin/bash
# ==============================================================================
# validate.sh — prove the site works and show where its certificate came from
#
#   1. The page loads over HTTPS with normal certificate checking, and the
#      body says Apache served it through NGINX.
#   2. The certificate NGINX presents: issuer, serial, validity.
#   3. The same certificate in ACM, with key pair origin ACME.
# ==============================================================================

set -euo pipefail

cd "$(dirname "$0")"

export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"

fqdn=$(terraform -chdir=01-acme output -raw fqdn)
endpoint_arn=$(terraform -chdir=01-acme output -raw acme_endpoint_arn)
public_ip=$(terraform -chdir=02-server output -raw public_ip)

echo ""
echo "============================================================================"
echo "ACM ACME Lab - Validation Output"
echo "============================================================================"
echo ""

# ------------------------------------------------------------------------------
# HTTPS check
# ------------------------------------------------------------------------------
# --resolve pins the name to the Elastic IP so a new A record that has not
# reached the local resolver yet cannot fail the check. TLS verification is
# still the normal one against the host name.
# ------------------------------------------------------------------------------

page=""
for i in $(seq 1 30); do
  if page=$(curl -sS --fail --max-time 10 \
      --resolve "${fqdn}:443:${public_ip}" "https://${fqdn}/" 2>/dev/null); then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: https://${fqdn}/ did not answer after 5 minutes."
    exit 1
  fi
  sleep 10
done

if grep -q "Served by Apache through NGINX" <<<"${page}"; then
  printf "NOTE: %-18s %s\n" "Site URL:" "https://${fqdn}"
  printf "NOTE: %-18s %s\n" "Response:" "Served by Apache through NGINX"
else
  echo "ERROR: The page did not come from Apache through NGINX."
  exit 1
fi

# ------------------------------------------------------------------------------
# Certificate NGINX is serving
# ------------------------------------------------------------------------------

cert=$(openssl s_client -connect "${public_ip}:443" -servername "${fqdn}" \
  </dev/null 2>/dev/null | openssl x509)

field() { openssl x509 -noout "$@" <<<"${cert}" | cut -d= -f2-; }

printf "NOTE: %-18s %s\n" "Issuer:" "$(field -issuer)"
printf "NOTE: %-18s %s\n" "Serial:" "$(field -serial)"
printf "NOTE: %-18s %s\n" "Not after:" "$(field -enddate)"

# ------------------------------------------------------------------------------
# The same certificate in ACM
# ------------------------------------------------------------------------------
# ACME certificates are left out of list-certificates unless asked for by
# key pair origin. Pick the one issued through this lab's endpoint.
# ------------------------------------------------------------------------------

cert_arn=$(aws acm search-certificates \
  --filter-statement "{\"Filter\":{\"AcmCertificateMetadataFilter\":{\"AcmeEndpointArn\":\"${endpoint_arn}\"}}}" \
  --query "Results[0].CertificateArn" --output text 2>/dev/null || true)

if [[ -n "${cert_arn}" && "${cert_arn}" != "None" ]]; then
  origin=$(aws acm describe-certificate --certificate-arn "${cert_arn}" \
    --query "Certificate.CertificateKeyPairOrigin" --output text)
  printf "NOTE: %-18s %s\n" "ACM certificate:" "${cert_arn}"
  printf "NOTE: %-18s %s\n" "Key pair origin:" "${origin}"
else
  echo "WARN: No ACM certificate found for this endpoint."
fi
echo ""
