#!/usr/bin/env bash
# Provision the VM and IAP firewall rules, then install the tooling.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
if [ -n "$status" ]; then
  codebox_die "instance '$CODEBOX_INSTANCE' already exists in $CODEBOX_ZONE (status: $status). Use 'codebox start' or 'codebox destroy'."
fi

# --- firewall: SSH reachable only via IAP --------------------------------
# Allow SSH from the IAP range, and deny SSH from everywhere else, both scoped
# to our network tag. The deny has higher priority than the network's default
# allow-ssh rule, so port 22 is IAP-only even though the VM has an external IP.
codebox_info "Ensuring IAP SSH firewall rules ..."
if ! codebox_gcloud compute firewall-rules describe "$CODEBOX_ALLOW_FIREWALL_RULE" >/dev/null 2>&1; then
  codebox_gcloud compute firewall-rules create "$CODEBOX_ALLOW_FIREWALL_RULE" \
    --direction=INGRESS --action=ALLOW --rules=tcp:22 \
    --source-ranges="$CODEBOX_IAP_RANGE" \
    --target-tags="$CODEBOX_NETWORK_TAG" \
    --priority=1000 \
    --description="codebox: allow IAP-tunneled SSH"
fi
if ! codebox_gcloud compute firewall-rules describe "$CODEBOX_DENY_FIREWALL_RULE" >/dev/null 2>&1; then
  codebox_gcloud compute firewall-rules create "$CODEBOX_DENY_FIREWALL_RULE" \
    --direction=INGRESS --action=DENY --rules=tcp:22 \
    --source-ranges="0.0.0.0/0" \
    --target-tags="$CODEBOX_NETWORK_TAG" \
    --priority=1100 \
    --description="codebox: deny non-IAP SSH (IAP allow rule has higher priority)"
fi

# --- instance ------------------------------------------------------------
# The VM keeps an ephemeral external IP purely for outbound package installs.
# For a no-external-IP setup, add `--no-address` below and provision a Cloud NAT
# in the zone's region so apt/npm can still reach the internet, e.g.:
#   region="${CODEBOX_ZONE%-*}"
#   gcloud compute routers create codebox-router --network=default --region="$region"
#   gcloud compute routers nats create codebox-nat --router=codebox-router \
#       --region="$region" --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
codebox_info "Creating instance '$CODEBOX_INSTANCE' ($CODEBOX_MACHINE_TYPE, $CODEBOX_IMAGE_FAMILY) in $CODEBOX_ZONE ..."
codebox_gcloud compute instances create "$CODEBOX_INSTANCE" \
  --zone="$CODEBOX_ZONE" \
  --machine-type="$CODEBOX_MACHINE_TYPE" \
  --image-family="$CODEBOX_IMAGE_FAMILY" \
  --image-project="$CODEBOX_IMAGE_PROJECT" \
  --boot-disk-size="${CODEBOX_DISK_SIZE}GB" \
  --boot-disk-type=pd-balanced \
  --tags="$CODEBOX_NETWORK_TAG" \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring

codebox_info "Instance created. Installing tooling ..."
exec bash "$CODEBOX_SCRIPT_DIR/bootstrap.sh"
