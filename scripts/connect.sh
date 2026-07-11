#!/usr/bin/env bash
# Start the VM if needed, then open an IAP SSH tunnel that forwards the local
# editor port to code-server on the VM. Blocks until you Ctrl-C.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

status="$(codebox_instance_status)"
[ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$status" != "RUNNING" ]; then
  codebox_info "Instance status is $status; starting it ..."
  codebox_gcloud compute instances start "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE"
  codebox_wait_for_ssh || codebox_die "timed out waiting for SSH."
fi

codebox_info "Fetching code-server password ..."
password="$(codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  --command="awk '/^password:/{print \$2; exit}' ~/.config/code-server/config.yaml" 2>/dev/null || true)"

cat >&2 <<EOF

  ┌─ codebox ────────────────────────────────────────────────
  │  Editor:    http://localhost:${CODEBOX_LOCAL_PORT}/
  │  Password:  ${password:-<run: cat ~/.config/code-server/config.yaml on the VM>}
  │
  │  Keep this terminal open to hold the tunnel. Ctrl-C to disconnect.
  └──────────────────────────────────────────────────────────

EOF

codebox_info "Opening IAP tunnel (localhost:${CODEBOX_LOCAL_PORT} -> VM 127.0.0.1:${CODEBOX_REMOTE_PORT}) ..."
codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  -- -N -L "${CODEBOX_LOCAL_PORT}:localhost:${CODEBOX_REMOTE_PORT}"
