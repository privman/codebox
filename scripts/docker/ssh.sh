#!/usr/bin/env bash
# Open a shell in the box (the container equivalent of ssh). Extra arguments are run
# as a command instead of starting an interactive shell.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
[ -n "$state" ] || codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
codebox_container_up "$state"

# Only ask for a TTY when we have one, so `codebox ssh some-command < file` and use
# from scripts still work.
tty_args=(-i)
[ -t 0 ] && [ -t 1 ] && tty_args=(-it)

if [ "$#" -gt 0 ]; then
  exec docker exec "${tty_args[@]}" -u "$CODEBOX_DOCKER_USER" "$CODEBOX_INSTANCE" "$@"
fi
exec docker exec "${tty_args[@]}" -u "$CODEBOX_DOCKER_USER" "$CODEBOX_INSTANCE" bash -l
