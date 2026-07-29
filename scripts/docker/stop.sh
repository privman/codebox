#!/usr/bin/env bash
# Stop the box. The filesystem persists, so 'codebox start' brings it back with your
# work intact — but processes are gone, unlike suspend.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
[ -n "$state" ] || codebox_die "container '$CODEBOX_INSTANCE' not found."
case "$state" in
  exited|created) codebox_info "Box is already stopped." ;;
  paused)         codebox_info "Box is paused; unpausing so it can shut down cleanly ..."
                  docker unpause "$CODEBOX_INSTANCE" >/dev/null
                  docker stop "$CODEBOX_INSTANCE" >/dev/null
                  codebox_info "Box stopped." ;;
  *)              codebox_info "Stopping the box ..."
                  docker stop "$CODEBOX_INSTANCE" >/dev/null
                  codebox_info "Box stopped." ;;
esac
