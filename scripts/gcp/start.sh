#!/usr/bin/env bash
# Start a stopped VM (or resume it if suspended).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
[ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$status" = "RUNNING" ]; then
  codebox_info "Instance is already running."
else
  codebox_start_or_resume "$status"
fi
