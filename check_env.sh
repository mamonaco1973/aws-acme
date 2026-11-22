#!/bin/bash
# ==============================================================================
# check_env.sh — confirm tools, AWS login and DNS delegation
#
# The DNS check matters for a freshly registered domain: the hosted zone is
# only authoritative once the registrar's name servers match the zone's
# delegation set. ACM validation and the public site both depend on it.
# ==============================================================================

source "$(dirname "$0")/lab.env"

echo "NOTE: Validating that required commands are found in your PATH."
commands=("aws" "terraform" "jq" "openssl" "curl" "dig")

all_found=true
for cmd in "${commands[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd is not found in the current PATH."
    all_found=false
  else
    echo "NOTE: $cmd is found in the current PATH."
  fi
done

if [ "$all_found" = true ]; then
  echo "NOTE: All required commands are available."
else
  echo "ERROR: One or more commands are missing."
  exit 1
fi

echo "NOTE: Checking AWS cli connection."

if ! aws sts get-caller-identity --query "Account" --output text > /dev/null; then
  echo "ERROR: Failed to connect to AWS. Please check your credentials and environment variables."
  exit 1
fi
echo "NOTE: Successfully logged into AWS."

# ------------------------------------------------------------------------------
# Hosted zone and delegation
# ------------------------------------------------------------------------------

echo "NOTE: Checking Route 53 hosted zone ${ZONE_NAME}."

zone_id=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ZONE_NAME}" \
  --query "HostedZones[?Name=='${ZONE_NAME}.' && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text)

if [[ -z "${zone_id}" || "${zone_id}" == "None" ]]; then
  echo "ERROR: No public hosted zone named ${ZONE_NAME} in this account."
  exit 1
fi

zone_ns=$(aws route53 get-hosted-zone --id "${zone_id}" \
  --query "DelegationSet.NameServers" --output text | tr '\t' '\n' | sort)
public_ns=$(dig +short NS "${ZONE_NAME}" | sed 's/\.$//' | sort)

if [[ "${zone_ns}" != "${public_ns}" ]]; then
  echo "ERROR: ${ZONE_NAME} is not delegated to this hosted zone yet."
  echo "       Route 53 zone: $(echo ${zone_ns})"
  echo "       Public DNS:    $(echo ${public_ns})"
  exit 1
fi
echo "NOTE: ${ZONE_NAME} is delegated to hosted zone ${zone_id#/hostedzone/}."
