#!/usr/bin/env bash
# Build the codebox image, create the container, and install the tooling into it.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker
codebox_validate_repo
codebox_validate_github
codebox_validate_agent_user
codebox_check_mount_agent_split

state="$(codebox_container_state)"
if [ -n "$state" ]; then
  codebox_die "container '$CODEBOX_INSTANCE' already exists (state: $state). Use 'codebox bootstrap' to reinstall the tooling, or 'codebox destroy' first."
fi

dockerfile="$CODEBOX_ROOT/docker/Dockerfile"
[ -f "$dockerfile" ] || codebox_die "missing $dockerfile — is the codebox install complete?"

codebox_info "Building image $CODEBOX_DOCKER_IMAGE ..."
docker build \
  --build-arg "CODEBOX_USER=$CODEBOX_DOCKER_USER" \
  --build-arg "CODEBOX_UID=$CODEBOX_DOCKER_UID" \
  -t "$CODEBOX_DOCKER_IMAGE" \
  -f "$dockerfile" \
  "$CODEBOX_ROOT"

# Ports are fixed when the container is created — Docker cannot add a published port to
# a running container — so changing CODEBOX_ADDITIONAL_PORTS later means recreating the
# box. `codebox connect` notices the mismatch and says so.
publish_args=()
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  publish_args+=(-p "$spec")
done <<< "$(codebox_publish_args)"

# A bind mount is fixed at create time for the same reason ports are, so `connect` checks
# it against the config too and says when they have drifted.
mount_args=()
mount_src="$(codebox_mount_source)"
if [ -n "$mount_src" ]; then
  mount_target="$(codebox_mount_target)"
  codebox_info "Mounting $mount_src at $mount_target ..."
  mount_args=(-v "$mount_src:$mount_target")
fi

codebox_info "Creating container '$CODEBOX_INSTANCE' ..."
# The agent user reaches the entrypoint through the container's environment, so it is still
# there after a `docker start` — the entrypoint is what restarts the editor.
docker run -d \
  --name "$CODEBOX_INSTANCE" \
  --hostname codebox \
  -e "CODEBOX_AGENT_USER=$CODEBOX_AGENT_USER" \
  "${publish_args[@]}" \
  ${mount_args[@]+"${mount_args[@]}"} \
  "$CODEBOX_DOCKER_IMAGE" >/dev/null

codebox_info "Container created. Installing the tooling (a few minutes) ..."
exec bash "$CODEBOX_SCRIPT_DIR/bootstrap.sh"
