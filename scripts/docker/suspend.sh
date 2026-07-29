#!/usr/bin/env bash
# Suspend the box: freeze its processes in place with `docker pause`, the local
# equivalent of a VM suspend. Nothing is billed either way locally — this is here for
# parity, and because freezing a busy box beats stopping it.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
case "$state" in
  "")        codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first." ;;
  paused)    codebox_info "Box is already suspended." ;;
  running)   codebox_info "Suspending the box (running processes are frozen in place) ..."
             docker pause "$CODEBOX_INSTANCE" >/dev/null
             codebox_info "Suspended. The editor will not respond until you resume." ;;
  *)         codebox_die "cannot suspend a box in state '$state' — only a running box can be suspended." ;;
esac
