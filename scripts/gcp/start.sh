#!/usr/bin/env bash
# Start a stopped VM.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
case "$status" in
  "")        codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first." ;;
  RUNNING)   codebox_info "Instance is already running." ;;
  *)         codebox_info "Starting instance (status was $status) ..."
             codebox_gcloud compute instances start "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" ;;
esac
