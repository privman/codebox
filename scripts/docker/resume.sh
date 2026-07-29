#!/usr/bin/env bash
# Resume a suspended box, restoring the processes frozen by 'codebox suspend'.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
case "$state" in
  "")        codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first." ;;
  running)   codebox_info "Box is already running." ;;
  paused)    codebox_container_up paused
             codebox_info "Resumed." ;;
  *)         codebox_info "Box is $state, not suspended; starting it instead ..."
             codebox_container_up "$state" ;;
esac
