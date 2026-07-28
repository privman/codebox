#!/usr/bin/env bash
# Tell connected codebox clients that this VM is about to suspend, then give them a
# moment to get out of the way.
#
# Clients hold a `tail -F` on the notice file over the SSH connection they already
# have (see scripts/gcp/connect.sh), so appending a line reaches every one of them
# without the VM needing a route back to the laptop. Each client closes its own
# tunnel, which is what stops ssh from spraying errors when the freeze cuts the
# connection mid-flight.
#
# Run as root — from the idle timer, or over ssh with sudo by `codebox suspend`.
# Usage: codebox-pre-suspend [grace-seconds]
set -euo pipefail

GRACE="${1:-${SUSPEND_GRACE_SEC:-5}}"
NOTICE_DIR=/run/codebox
NOTICE="$NOTICE_DIR/notices"

# /run is tmpfs, so this is gone after a reboot and recreated here. Clients use
# `tail -F`, which waits for the file to appear and does not care that it is new.
mkdir -p "$NOTICE_DIR"
printf 'CODEBOX-SUSPENDING %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$NOTICE"
chmod 0644 "$NOTICE" 2>/dev/null || true

# Wait for the SSH sessions to end — a client closing its tunnel is the acknowledgement.
# Strictly bounded: a wedged or already-dead client must not be able to hold up the
# suspend. Note that when this is invoked over ssh (`codebox suspend`), the invoking
# session is itself one of these connections, so that path always waits out the grace.
i=0
while [ "$i" -lt "$GRACE" ]; do
  ss -Htn state established '( sport = :22 or dport = :22 )' 2>/dev/null | grep -q . || break
  sleep 1
  i=$((i + 1))
done
