#!/usr/bin/env bash
# PID 1 in a codebox container.
#
# Runs code-server in the foreground once it exists, and keeps the container alive
# before that: `codebox create` starts the container first and installs code-server into
# it afterwards, so on the very first boot there is nothing to run yet. Also covers
# `docker start` after a stop, where the editor has to come back by itself.
set -uo pipefail

CHILD=""

# Forward shutdown to code-server so `docker stop` is a clean exit rather than a ten
# second wait for SIGKILL.
shutdown() {
  trap - TERM INT
  [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
  [ -n "$CHILD" ] && wait "$CHILD" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

export PATH="$HOME/.local/bin:$PATH"
echo "[codebox] entrypoint started; waiting for code-server ..."

while :; do
  if command -v code-server >/dev/null 2>&1; then
    # Configuration (bind address, password) comes from ~/.config/code-server/config.yaml,
    # which bootstrap.sh writes.
    code-server &
    CHILD=$!
    wait "$CHILD" || true
    CHILD=""
    # Only reached if code-server exited on its own: a crash, or someone restarting it
    # from inside the box. Pause so a broken install cannot spin the CPU.
    echo "[codebox] code-server exited; restarting in 2s"
    sleep 2
  else
    sleep 5
  fi
done
