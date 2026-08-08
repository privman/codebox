#!/usr/bin/env bash
# Announce changes in the download directory so connected clients know to pull.
#
# The client already holds a `tail -F` on /run/codebox/notices over the SSH connection
# it uses for the tunnel (scripts/gcp/connect.sh), so appending a line reaches it without
# the VM needing a route back to the laptop — the same channel vm/pre-suspend.sh uses to
# warn about a suspend.
#
# inotify rather than a poll, and this is the whole reason: idle detection on the VM
# measures traffic on port 22, so a channel that said something every few seconds would
# keep the box awake and billing. Watching costs nothing while nothing changes.
#
# Run as root from codebox-sync-watch.service.
# Usage: codebox-sync-watch <download-dir>
set -euo pipefail

DIR="${1:-}"
[ -n "$DIR" ] || { printf 'codebox-sync-watch: usage: %s <download-dir>\n' "$0" >&2; exit 1; }

NOTICE_DIR=/run/codebox
NOTICE="$NOTICE_DIR/notices"
# Coalesce a burst — an editor writing a file produces several events, and a build
# dropping a tree produces thousands. One line per quiet period is all the client needs;
# it re-syncs the whole directory either way.
QUIET_SEC="${CODEBOX_SYNC_QUIET_SEC:-2}"

mkdir -p "$NOTICE_DIR"

announce() {
  printf 'CODEBOX-SYNC-DOWNLOAD %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$NOTICE"
  chmod 0644 "$NOTICE" 2>/dev/null || true
}

# The directory may not exist yet on a box bootstrapped before sync was configured, and
# inotifywait exits rather than waiting for it. Sit still until it turns up.
while [ ! -d "$DIR" ]; do
  sleep 30
done

# -m keeps watching after the first event; -r covers subdirectories. Events are read one
# per line and then drained for QUIET_SEC, so a burst becomes a single announcement.
inotifywait -m -r -q -e close_write -e moved_to -e moved_from -e create -e delete \
            --format '%e' "$DIR" 2>/dev/null | while IFS= read -r _event; do
  # Drain whatever else arrived while we were being told about this one.
  while IFS= read -r -t "$QUIET_SEC" _more; do :; done
  announce
done
