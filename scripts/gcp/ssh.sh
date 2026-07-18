#!/usr/bin/env bash
# Open an interactive SSH shell on the VM over IAP. Extra args are passed to gcloud ssh.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
[ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$status" != "RUNNING" ]; then
  codebox_start_or_resume "$status"
  codebox_wait_for_ssh || codebox_die "timed out waiting for SSH."
fi

codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap "$@"
