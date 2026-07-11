#!/usr/bin/env bash
# Show the instance status.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
if [ -z "$status" ]; then
  codebox_info "instance '$CODEBOX_INSTANCE' does not exist in $CODEBOX_ZONE (project $CODEBOX_PROJECT)."
  exit 0
fi

codebox_info "instance '$CODEBOX_INSTANCE' in $CODEBOX_ZONE: $status"
codebox_gcloud compute instances describe "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" \
  --format='table(name, status, machineType.basename(), lastStartTimestamp)'
