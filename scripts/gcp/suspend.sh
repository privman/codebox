#!/usr/bin/env bash
# Suspend the VM: freeze RAM to disk so running processes (dev servers, Claude Code,
# etc.) are restored intact on the next resume. Cheaper than running, preserves state.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
case "$status" in
  "")          codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first." ;;
  SUSPENDED)   codebox_info "Instance is already suspended." ;;
  RUNNING)     codebox_info "Suspending instance (running processes are preserved) ..."
               codebox_gcloud compute instances suspend "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" ;;
  *)           codebox_die "cannot suspend an instance in state '$status' — only a RUNNING instance can be suspended." ;;
esac