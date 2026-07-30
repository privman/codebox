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

# With the uid split on, code-server is the agent's process — it and every terminal it
# opens must not be this (sudo-capable) user. Passed in at `docker run` so it survives a
# restart, when this entrypoint is all that brings the editor back.
AGENT_USER="${CODEBOX_AGENT_USER:-}"
start_code_server() {
  if [ -n "$AGENT_USER" ] && [ "$AGENT_USER" != "$(id -un)" ]; then
    sudo -n -H -u "$AGENT_USER" code-server &
  else
    code-server &
  fi
}

echo "[codebox] entrypoint started; waiting for code-server ..."

# Where bootstrap-user.sh writes the editor config, as whichever user owns the editor.
# Resolved per iteration, not once: on a first boot this entrypoint is running before
# bootstrap has created the agent user, so the home directory cannot be looked up yet.
config_path() {
  local home=""
  if [ -n "$AGENT_USER" ]; then
    home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
    [ -n "$home" ] || return 1
  else
    home="$HOME"
  fi
  printf '%s/.config/code-server/config.yaml' "$home"
}

while :; do
  CONFIG="$(config_path || true)"
  # Wait for the config as well as the binary. Starting code-server first would have it
  # write its own default config, which bootstrap then treats as one to preserve — so the
  # box would come up with a password codebox never chose.
  if command -v code-server >/dev/null 2>&1 && [ -f "$CONFIG" ]; then
    # Configuration (bind address, password) comes from ~/.config/code-server/config.yaml,
    # which bootstrap.sh writes.
    start_code_server
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
