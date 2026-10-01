#!/usr/bin/env bash
# Resume a suspended VM, restoring its running processes. Falls back to a fresh
# start if the instance is stopped rather than suspended.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
case "$status" in
  "")          codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first." ;;
  RUNNING)     codebox_info "Instance is already running." ;;
  SUSPENDED)   codebox_info "Resuming instance (restoring running processes) ..."
               codebox_power_on resume ;;
  *)           codebox_info "Instance is '$status', not suspended; starting it fresh ..."
               codebox_power_on start ;;
esac