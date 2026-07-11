#!/usr/bin/env bash
# Runs as root from a systemd timer. Powers the machine off after a sustained
# idle period so a stopped GCP instance stops accruing compute charges.
#
# "Idle" means, for IDLE_TIMEOUT_MIN consecutive minutes, ALL of:
#   - no established SSH connection (no codebox tunnel open),
#   - no established connection on the code-server port,
#   - 1-minute load average below LOAD_THRESHOLD (protects running builds/tasks).
set -euo pipefail

CONF=/etc/codebox-idle.conf
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-30}"
REMOTE_PORT="${REMOTE_PORT:-8080}"
LOAD_THRESHOLD="${LOAD_THRESHOLD:-0.4}"

STATE_DIR=/var/lib/codebox
STATE="$STATE_DIR/idle-since"
mkdir -p "$STATE_DIR"

now="$(date +%s)"
active=0

# Established SSH or code-server connections?
if ss -Htn state established "( sport = :22 or dport = :22 or sport = :${REMOTE_PORT} or dport = :${REMOTE_PORT} )" \
     2>/dev/null | grep -q .; then
  active=1
fi

# Interactive logins?
if who 2>/dev/null | grep -q .; then
  active=1
fi

# Sustained CPU load => treat as active (protect long builds / Claude Code runs).
load1="$(cut -d' ' -f1 /proc/loadavg)"
if awk -v l="$load1" -v t="$LOAD_THRESHOLD" 'BEGIN { exit !(l >= t) }'; then
  active=1
fi

if [ "$active" -eq 1 ]; then
  rm -f "$STATE"
  exit 0
fi

# Idle: start or continue the countdown.
if [ ! -f "$STATE" ]; then
  echo "$now" > "$STATE"
  exit 0
fi

idle_since="$(cat "$STATE")"
elapsed_min=$(( (now - idle_since) / 60 ))
if [ "$elapsed_min" -ge "$IDLE_TIMEOUT_MIN" ]; then
  logger -t codebox-idle "idle for ${elapsed_min} min (>= ${IDLE_TIMEOUT_MIN}); shutting down"
  /sbin/shutdown -h now "codebox: idle shutdown"
fi
