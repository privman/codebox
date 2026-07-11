#!/usr/bin/env bash
# Delete the VM and, optionally, the firewall rules.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
if [ -n "$status" ]; then
  printf 'Delete instance "%s" in %s (status: %s)? Its boot disk will be lost. [y/N] ' \
    "$CODEBOX_INSTANCE" "$CODEBOX_ZONE" "$status" >&2
  read -r ans
  if [ "$ans" = y ] || [ "$ans" = Y ]; then
    codebox_gcloud compute instances delete "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --quiet
    codebox_info "Instance deleted."
  else
    codebox_info "Left the instance in place."
  fi
else
  codebox_info "Instance '$CODEBOX_INSTANCE' does not exist; nothing to delete."
fi

printf 'Also delete the firewall rules (%s, %s)? [y/N] ' \
  "$CODEBOX_ALLOW_FIREWALL_RULE" "$CODEBOX_DENY_FIREWALL_RULE" >&2
read -r ans2
if [ "$ans2" = y ] || [ "$ans2" = Y ]; then
  codebox_gcloud compute firewall-rules delete "$CODEBOX_ALLOW_FIREWALL_RULE" --quiet 2>/dev/null || true
  codebox_gcloud compute firewall-rules delete "$CODEBOX_DENY_FIREWALL_RULE" --quiet 2>/dev/null || true
  codebox_info "Firewall rules deleted."
else
  codebox_info "Left the firewall rules in place."
fi
