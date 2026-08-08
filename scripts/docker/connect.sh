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

# Bind mounts are baked in at create time for the same reason, so a CODEBOX_DOCKER_MOUNT
# that was added or repointed afterwards silently does nothing until the box is recreated.
want_mount="$(codebox_mount_source)"
[ -n "$want_mount" ] || want_mount="$(codebox_shared_dir_source)"
if [ -n "$want_mount" ]; then
  have_mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \
                 "$CODEBOX_INSTANCE" 2>/dev/null || true)"
  if ! printf '%s\n' "$have_mounts" | grep -qxF "$want_mount"; then
    codebox_warn "a project directory at $want_mount is configured, but the container does not mount it."
    codebox_warn "Mounts are fixed when the container is created. To apply the change:"
    codebox_warn "  codebox destroy && codebox create"
  fi
fi

codebox_info "Waiting for code-server ..."
codebox_wait_for_editor || \
  codebox_die "code-server did not come up in the box. Check 'docker logs $CODEBOX_INSTANCE'."

# Read as root: with the uid split on this file belongs to the agent, and the login user
# has no business reading into that home.
password="$(docker exec -u root "$CODEBOX_INSTANCE" \
  awk '/^password:/{print $2; exit}' \
  "$CODEBOX_BOX_HOME/.config/code-server/config.yaml" 2>/dev/null || true)"

cat >&2 <<EOF

  ┌─ codebox (docker) ───────────────────────────────────────
  │  Editor:    http://localhost:${CODEBOX_LOCAL_PORT}/
  │  Password:  ${password:-<run: codebox ssh, then cat ~/.config/code-server/config.yaml>}
  │
  │  The box keeps running in the background — no terminal to hold open.
  │  Stop it with 'codebox --provider docker stop'.
  └──────────────────────────────────────────────────────────

EOF
