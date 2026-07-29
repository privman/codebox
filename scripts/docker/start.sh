#!/usr/bin/env bash
# Start a stopped box (or unpause it if suspended).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
[ -n "$state" ] || codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$state" = running ]; then
  codebox_info "Box is already running."
else
  codebox_container_up "$state"
fi
