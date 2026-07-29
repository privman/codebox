#!/usr/bin/env bash
# Start the container if needed and print how to reach the editor.
#
# Unlike the GCP provider there is nothing to hold open: the editor port is published
# straight to the host's loopback, so it stays reachable for as long as the container
# runs and this command has no reason to block. Stop the box with `codebox stop`.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
[ -n "$state" ] || codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
codebox_container_up "$state"

# Published ports are baked in at create time, so a CODEBOX_ADDITIONAL_PORTS edit does
# not reach a container that already exists. Say so rather than leaving someone to
# wonder why their dev server is unreachable.
want="$(codebox_publish_args | sort)"
have="$(docker port "$CODEBOX_INSTANCE" 2>/dev/null \
        | sed -n 's|^\([0-9]*\)/tcp -> \(.*\):\([0-9]*\)$|\2:\3:\1|p' | sort)"
if [ -n "$have" ] && [ "$want" != "$have" ]; then
  codebox_warn "the published ports do not match your config:"
  codebox_warn "  configured: $(printf '%s' "$want" | tr '\n' ' ')"
  codebox_warn "  container:  $(printf '%s' "$have" | tr '\n' ' ')"
  codebox_warn "Docker fixes ports when the container is created. To apply the change:"
  codebox_warn "  codebox --provider docker destroy && codebox --provider docker create"
fi

codebox_info "Waiting for code-server ..."
codebox_wait_for_editor || \
  codebox_die "code-server did not come up in the box. Check 'docker logs $CODEBOX_INSTANCE'."

password="$(codebox_docker_exec awk '/^password:/{print $2; exit}' \
  "$CODEBOX_DOCKER_HOME/.config/code-server/config.yaml" 2>/dev/null || true)"

cat >&2 <<EOF

  ┌─ codebox (docker) ───────────────────────────────────────
  │  Editor:    http://localhost:${CODEBOX_LOCAL_PORT}/
  │  Password:  ${password:-<run: codebox ssh, then cat ~/.config/code-server/config.yaml>}
  │
  │  The box keeps running in the background — no terminal to hold open.
  │  Stop it with 'codebox --provider docker stop'.
  └──────────────────────────────────────────────────────────

EOF
