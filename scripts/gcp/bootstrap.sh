#!/usr/bin/env bash
# Copy the VM setup files to the instance and run the on-VM bootstrap.
# Safe to re-run (installs are idempotent).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
[ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$status" != "RUNNING" ]; then
  codebox_info "Instance status is $status; starting it ..."
  codebox_gcloud compute instances start "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE"
fi

codebox_info "Waiting for SSH (via IAP) ..."
codebox_wait_for_ssh || codebox_die "timed out waiting for SSH. Check IAM roles and firewall, then retry 'codebox bootstrap'."

codebox_info "Copying VM setup files ..."
codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  --command="rm -rf ~/vm"
codebox_gcloud compute scp --recurse "$CODEBOX_ROOT/vm" "$CODEBOX_INSTANCE:~/vm" \
  --zone "$CODEBOX_ZONE" --tunnel-through-iap

codebox_info "Running on-VM bootstrap (code-server, Claude Code, idle-shutdown) ..."
codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  --command="CODEBOX_REMOTE_PORT='${CODEBOX_REMOTE_PORT}' CODEBOX_IDLE_TIMEOUT_MIN='${CODEBOX_IDLE_TIMEOUT_MIN}' bash ~/vm/bootstrap.sh"

codebox_info "Done. Run 'codebox connect' to open the editor."
