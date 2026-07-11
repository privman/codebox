#!/usr/bin/env bash
# Stop the VM (halts compute billing; disk is retained).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
case "$status" in
  "")           codebox_die "instance '$CODEBOX_INSTANCE' not found." ;;
  TERMINATED)   codebox_info "Instance is already stopped." ;;
  *)            codebox_info "Stopping instance (status was $status) ..."
                codebox_gcloud compute instances stop "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" ;;
esac
