#!/bin/bash
# ==============================================================================
# validate.sh — prove the site works and show where its certificate came from
#
#   1. The page loads over HTTPS with normal certificate checking, and the
#      body says Apache served it through NGINX.
#   2. The certificate NGINX presents: issuer, serial, validity.
#   3. The same certificate in ACM, with key pair origin ACME.
#   4. Options 2 and 3 behind the ALB and the NLB: each of the six load
#      balancer paths returns 200, and the page shows which backend answered
#      and what it received. The broken backend (a test, not an option) has
#      an expired, wrong-name certificate, and both load balancers use it
#      anyway. The ten-year backend (option 3) is the pattern to copy.
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

# ==============================================================================
# OPTIONS 2 AND 3: LOAD BALANCERS (plus the broken-backend test)
# ==============================================================================

alb_fqdn=$(terraform -chdir=03-lb output -raw alb_fqdn)
nlb_fqdn=$(terraform -chdir=03-lb output -raw nlb_fqdn)
alb_dns=$(terraform -chdir=03-lb output -raw alb_dns_name)
nlb_dns=$(terraform -chdir=03-lb output -raw nlb_dns_name)

failed=0

# Read one value back from the diagnostic page by its id.
page_field() {
  sed -n "s/.*<td id=\"$1\">\(.*\)<\/td>.*/\1/p" <<<"${page}" | head -n 1
}

# ------------------------------------------------------------------------------
# check_endpoint LABEL HOST LB_DNS PORT PATH EXPECTED_BACKEND
# ------------------------------------------------------------------------------
# Like the option 1 check, --resolve pins the lab name to one of the load
# balancer's own addresses, so a fresh alias record that has not reached the
# local resolver cannot fail the check. Certificate checking stays normal:
# the client must trust the front certificate for the lab name.
# ------------------------------------------------------------------------------

check_endpoint() {
  local label=$1 host=$2 lb_dns=$3 port=$4 path=$5 expected=$6
  local url="https://${host}${path}"
  [[ "${port}" != "443" ]] && url="https://${host}:${port}${path}"

  local code="000" ip=""
  page=""
  for i in $(seq 1 30); do
    ip=$(dig +short "${lb_dns}" | grep -E '^[0-9.]+$' | head -n 1 || true)
    if [[ -n "${ip}" ]]; then
      page=$(curl -sS --max-time 10 -w '\n%{http_code}' \
        --resolve "${host}:${port}:${ip}" "${url}" 2>/dev/null || true)
      code=$(tail -n 1 <<<"${page}")
      [[ "${code}" == "200" ]] && break
    fi
    sleep 10
  done

  echo "${label}"
  printf "NOTE: %-18s %s\n" "URL:" "${url}"

  if [[ "${code}" != "200" ]]; then
    echo "ERROR: ${url} returned HTTP ${code:-none} after 5 minutes."
    echo ""
    failed=$((failed + 1))
    return
  fi

  local backend front_issuer
  backend=$(sed -n 's/.*data-backend="\([^"]*\)".*/\1/p' <<<"${page}" | head -n 1)
  front_issuer=$(openssl s_client -connect "${ip}:${port}" -servername "${host}" \
    </dev/null 2>/dev/null | openssl x509 -noout -issuer | cut -d= -f2-)

  printf "NOTE: %-18s %s\n" "HTTP status:" "${code}"
  printf "NOTE: %-18s %s\n" "Backend:" "${backend}"
  printf "NOTE: %-18s %s\n" "Scheme at backend:" "$(page_field scheme)"
  printf "NOTE: %-18s %s\n" "Front cert issuer:" "${front_issuer}"
  printf "NOTE: %-18s %s\n" "NGINX saw client:" "$(page_field client)"
  printf "NOTE: %-18s %s\n" "X-Forwarded-For:" "$(page_field xff)"

  if [[ "${backend}" != "${expected}" ]]; then
    echo "ERROR: Expected backend ${expected}, got ${backend:-nothing}."
    failed=$((failed + 1))
  fi

  if [[ "${backend}" == self-signed* ]]; then
    local subject san status
    subject=$(page_field cert_subject)
    san=$(page_field cert_san)
    status=$(page_field cert_status)

    printf "NOTE: %-18s %s\n" "Backend cert:" "${subject}"
    printf "NOTE: %-18s %s\n" "Backend not after:" "$(page_field cert_not_after)"

    if [[ "${san}" != *"${host}"* && "${status}" == "EXPIRED" ]]; then
      echo "NOTE: Backend cert is EXPIRED and wrong-name; the load balancer accepted it anyway."
    elif [[ "${status}" != "EXPIRED" ]]; then
      echo "NOTE: Backend cert is self-signed and in date; nothing has to renew it for years."
    fi
  fi
  echo ""
}

echo "============================================================================"
echo "ALB - ACM certificate on the load balancer"
echo "============================================================================"
echo ""

check_endpoint "ALB /http/    -> HTTP:80 -> plain backend (option 2)" \
  "${alb_fqdn}" "${alb_dns}" 443 "/http/" "plain"
check_endpoint "ALB /tls/     -> HTTPS:443 -> broken backend (test)" \
  "${alb_fqdn}" "${alb_dns}" 443 "/tls/" "self-signed"
check_endpoint "ALB /tls10y/  -> HTTPS:443 -> ten-year backend (option 3)" \
  "${alb_fqdn}" "${alb_dns}" 443 "/tls10y/" "self-signed-10y"

echo "============================================================================"
echo "NLB - ACM certificate on the load balancer"
echo "============================================================================"
echo ""

check_endpoint "NLB :443      -> TCP:80 -> plain backend (option 2)" \
  "${nlb_fqdn}" "${nlb_dns}" 443 "/" "plain"
check_endpoint "NLB :8443     -> TLS:443 -> broken backend (test)" \
  "${nlb_fqdn}" "${nlb_dns}" 8443 "/" "self-signed"
check_endpoint "NLB :9443     -> TLS:443 -> ten-year backend (option 3)" \
  "${nlb_fqdn}" "${nlb_dns}" 9443 "/" "self-signed-10y"

if [[ ${failed} -gt 0 ]]; then
  echo "ERROR: ${failed} load balancer check(s) failed."
  exit 1
fi
