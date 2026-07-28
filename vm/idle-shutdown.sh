#!/usr/bin/env bash
# Runs as root from a systemd timer. Suspends the VM after a sustained idle period
# instead of stopping it: RAM is frozen to disk, so running processes (dev servers,
# Claude Code, …) are restored intact on the next resume. Suspend is triggered by
# calling the Compute API on this instance itself, authenticated with the metadata
# service-account token (requires the compute scope + compute.instances.suspend).
#
# Before suspending it runs codebox-pre-suspend, which gives any connected client a
# few seconds to close its tunnel cleanly (see vm/pre-suspend.sh).
#
# "Idle" means, for IDLE_TIMEOUT_MIN consecutive minutes, BOTH of:
#   - SSH + code-server connections moving less than TRAFFIC_KB_PER_MIN,
#   - 1-minute load average below LOAD_THRESHOLD (protects running builds/tasks).
#
# Note what is deliberately NOT a signal: the mere existence of a connection. An open
# tunnel is what you leave behind when you walk away from the laptop, and a parked
# browser tab on code-server keeps a websocket alive indefinitely — measured at about
# 11 KB/min of pure heartbeat with nobody touching it. Counting either as "in use"
# meant the box never suspended while a terminal or tab was left open, which is
# exactly the case it exists to catch. So we look at the traffic *rate* instead.
set -euo pipefail

CONF=/etc/codebox-idle.conf
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-30}"
REMOTE_PORT="${REMOTE_PORT:-8080}"
LOAD_THRESHOLD="${LOAD_THRESHOLD:-0.4}"
# ~4.5x the measured idle-heartbeat rate: high enough that a parked tab reads as idle,
# low enough that any real interaction (a keystroke, a save, a scroll) reads as busy.
TRAFFIC_KB_PER_MIN="${TRAFFIC_KB_PER_MIN:-50}"

STATE_DIR=/var/lib/codebox
STATE="$STATE_DIR/idle-since"
SAMPLE="$STATE_DIR/net-sample"
mkdir -p "$STATE_DIR"

now="$(date +%s)"
active=0

# How much are the SSH / code-server connections actually moving? `ss -i` reports
# per-socket byte counters; we compare the total against the previous run to get a rate.
sockets="$(ss -Htni state established \
  "( sport = :22 or dport = :22 or sport = :${REMOTE_PORT} or dport = :${REMOTE_PORT} )" \
  2>/dev/null || true)"

if [ -z "$sockets" ]; then
  # Nothing connected at all: unambiguously idle, and the old sample is meaningless.
  rm -f "$SAMPLE"
else
  bytes="$(printf '%s\n' "$sockets" | grep -oE 'bytes_(sent|received):[0-9]+' \
             | cut -d: -f2 | awk '{ s += $1 } END { print s + 0 }')"
  prev_time=""
  prev_bytes=""
  [ ! -f "$SAMPLE" ] || read -r prev_time prev_bytes < "$SAMPLE" || true
  printf '%s %s\n' "$now" "$bytes" > "$SAMPLE"

  if [ -z "$prev_time" ] || [ -z "$prev_bytes" ]; then
    # First sample since boot/resume — no rate to judge yet, so assume in use.
    active=1
  else
    secs=$(( now - prev_time ))
    delta=$(( bytes - prev_bytes ))
    if [ "$secs" -le 0 ] || [ "$delta" -lt 0 ]; then
      # Clock jump, or sockets closed and reopened between runs: don't guess, stay up.
      active=1
    elif [ $(( delta * 60 / secs )) -ge $(( TRAFFIC_KB_PER_MIN * 1024 )) ]; then
      active=1
    fi
  fi
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

# Metadata is good and we are definitely suspending: tell any connected clients first
# so they can close their tunnels, instead of having the connection cut from under them
# when RAM freezes. Best-effort — never let this stop the suspend.
if [ -x /usr/local/bin/codebox-pre-suspend ]; then
  /usr/local/bin/codebox-pre-suspend "${SUSPEND_GRACE_SEC:-5}" || \
    logger -t codebox-idle "pre-suspend notice failed; suspending anyway"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $token" \
          "https://compute.googleapis.com/compute/v1/projects/${project}/zones/${zone}/instances/${name}/suspend" || true)"
if [ "$code" = "200" ]; then
  logger -t codebox-idle "self-suspend request accepted (HTTP 200)"
else
  logger -t codebox-idle "self-suspend request failed (HTTP ${code:-none}); staying up, will retry"
fi
