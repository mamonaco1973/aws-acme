#!/bin/bash
# ==============================================================================
# destroy.sh — tear down the ACM ACME lab
#
#   1. Revoke the certificate from the server, since its private key is
#      about to be destroyed with the instance.
#   2. Destroy the load balancer phase, the server phase, then the ACME
#      phase.
#   3. Clean up what Terraform does not own: the certificates ACM keeps in
#      its inventory, and the validation CNAME if ACM left it behind.
#
# The hosted zone itself and its other records are never touched.
# ==============================================================================

cd "$(dirname "$0")"

export AWS_DEFAULT_REGION="us-east-1"
# AWS_REGION, if set in the caller's shell, overrides AWS_DEFAULT_REGION.
export AWS_REGION="us-east-1"

# Same zone name apply.sh used.
source ./lab.env

# Read phase 1 outputs before that state is destroyed.
endpoint_arn=$(terraform -chdir=01-acme output -raw acme_endpoint_arn 2>/dev/null || true)
fqdn=$(terraform -chdir=01-acme output -raw fqdn 2>/dev/null || true)
zone_id=$(terraform -chdir=01-acme output -raw zone_id 2>/dev/null || true)
instance_id=$(terraform -chdir=02-server output -raw instance_id 2>/dev/null || true)

# ==============================================================================
# STEP 1: REVOKE THE CERTIFICATE
# ==============================================================================
#
# certbot revokes through the ACME endpoint (ACM's RevokeCertificate API does
# not apply to ACME certificates). Best effort: a failure here does not stop
# the teardown.
# ==============================================================================

if [[ -n "${instance_id}" ]]; then
  echo "NOTE: Revoking the certificate on ${instance_id}."

  cmd_id=$(aws ssm send-command \
    --instance-ids "${instance_id}" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["certbot revoke --cert-name acme-lab --reason cessationofoperation --non-interactive --no-delete-after-revoke"]' \
    --query "Command.CommandId" --output text 2>/dev/null || true)

  if [[ -n "${cmd_id}" ]]; then
    for i in $(seq 1 24); do
      sleep 5
      status=$(aws ssm get-command-invocation \
        --command-id "${cmd_id}" --instance-id "${instance_id}" \
        --query "Status" --output text 2>/dev/null || echo "Pending")
      [[ "${status}" =~ ^(Success|Failed|Cancelled|TimedOut)$ ]] && break
    done
    echo "NOTE: Revoke ${status}."
  else
    echo "WARN: Could not reach the server through SSM; skipping revoke."
  fi
fi

# ==============================================================================
# STEP 2: DESTROY THE LOAD BALANCERS (03-lb)
# ==============================================================================
#
# Terraform owns everything in this phase, including its ACM certificate and
# the certificate's DNS validation records, so destroy removes them all.
# ==============================================================================

echo "NOTE: Destroying the load balancers and their backends."

cd 03-lb
terraform init
terraform destroy -auto-approve
cd ..

# ==============================================================================
# STEP 3: DESTROY THE SERVER (02-server)
# ==============================================================================

echo "NOTE: Destroying the web server."

cd 02-server
terraform init
terraform destroy -auto-approve
cd ..

# ==============================================================================
# STEP 4: DESTROY THE ACME ENDPOINT (01-acme)
# ==============================================================================

echo "NOTE: Destroying the ACM ACME endpoint."

cd 01-acme
terraform init
terraform destroy -auto-approve
cd ..

# ==============================================================================
# STEP 5: ACM CERTIFICATE INVENTORY
# ==============================================================================
#
# Issued certificates stay in ACM after the endpoint is gone. ACM may refuse
# to delete one that has not expired yet; it removes ACME certificates by
# itself one year after they expire, and they cost nothing while they sit.
# ==============================================================================

if [[ -n "${endpoint_arn}" ]]; then
  for arn in $(aws acm search-certificates \
      --filter-statement "{\"Filter\":{\"AcmCertificateMetadataFilter\":{\"AcmeEndpointArn\":\"${endpoint_arn}\"}}}" \
      --query "Results[].CertificateArn" --output text 2>/dev/null); do

    if aws acm delete-certificate --certificate-arn "${arn}" 2>/dev/null; then
      echo "NOTE: Deleted ACM certificate ${arn}."
    else
      echo "NOTE: ACM kept ${arn} (deleted automatically a year after expiry)."
    fi
  done
fi

# ==============================================================================
# STEP 6: VALIDATION CNAME
# ==============================================================================
#
# ACM wrote the domain validation CNAME into the zone itself, so Terraform
# never owned it. Remove any validation record left under the lab host name.
# ==============================================================================

if [[ -n "${zone_id}" && -n "${fqdn}" ]]; then
  aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
    --query "ResourceRecordSets[?Type=='CNAME' && ends_with(Name, '.${fqdn}.') && starts_with(Name, '_')]" \
    --output json | jq -c '.[]' | while read -r record; do

    name=$(jq -r .Name <<<"${record}")
    echo "NOTE: Deleting leftover validation record ${name}"

    aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" \
      --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":${record}}]}" \
      > /dev/null
  done
fi

echo "NOTE: Teardown complete."
