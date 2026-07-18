#!/usr/bin/env bash
# Runs as root from a systemd timer. Suspends the VM after a sustained idle period
# instead of stopping it: RAM is frozen to disk, so running processes (dev servers,
# Claude Code, …) are restored intact on the next resume. Suspend is triggered by
# calling the Compute API on this instance itself, authenticated with the metadata
# service-account token (requires the compute scope + compute.instances.suspend).
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
if [ "$elapsed_min" -lt "$IDLE_TIMEOUT_MIN" ]; then
  exit 0
fi

logger -t codebox-idle "idle for ${elapsed_min} min (>= ${IDLE_TIMEOUT_MIN}); requesting self-suspend"

# Reset the countdown BEFORE suspending. On resume this file is gone, so the idle
# timer starts a fresh 30-min count instead of immediately re-suspending; and if the
# suspend call fails, the next attempt is a clean cycle rather than a tight retry loop.
rm -f "$STATE"

md="http://metadata.google.internal/computeMetadata/v1"
hdr="Metadata-Flavor: Google"
token="$(curl -s -H "$hdr" "$md/instance/service-accounts/default/token" \
           | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)"
project="$(curl -s -H "$hdr" "$md/project/project-id" 2>/dev/null || true)"
zone="$(curl -s -H "$hdr" "$md/instance/zone" 2>/dev/null | awk -F/ '{print $NF}')"
name="$(curl -s -H "$hdr" "$md/instance/name" 2>/dev/null || true)"

if [ -z "$token" ] || [ -z "$project" ] || [ -z "$zone" ] || [ -z "$name" ]; then
  logger -t codebox-idle "could not read metadata/token; not suspending (will retry next cycle)"
  exit 0
fi

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $token" \
          "https://compute.googleapis.com/compute/v1/projects/${project}/zones/${zone}/instances/${name}/suspend" || true)"
if [ "$code" = "200" ]; then
  logger -t codebox-idle "self-suspend request accepted (HTTP 200)"
else
  logger -t codebox-idle "self-suspend request failed (HTTP ${code:-none}); staying up, will retry"
fi
