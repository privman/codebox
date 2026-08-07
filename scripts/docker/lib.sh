#!/usr/bin/env bash
# Docker-specific configuration and helpers.
# Sourced by every script in this directory; the provider-agnostic half lives in
# ../common.sh.
#
# The model mirrors the GCP provider as closely as the substrate allows: one long-lived
# box named CODEBOX_INSTANCE, bootstrapped by the same vm/bootstrap.sh, reached on
# localhost. What differs is that there is no tunnel — the editor port is published
# straight to the host's loopback — and no idle auto-suspend, because a local container
# costs nothing to leave running.
set -euo pipefail

CODEBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
. "$CODEBOX_SCRIPT_DIR/../common.sh"

# --- Docker-only defaults ------------------------------------------------
: "${CODEBOX_DOCKER_IMAGE:=codebox:local}"
: "${CODEBOX_DOCKER_USER:=coder}"
# Host interface the editor port is published on. Loopback by default, matching the
# GCP provider's rule that nothing is reachable from outside the machine.
: "${CODEBOX_DOCKER_BIND:=127.0.0.1}"
# A host directory to bind-mount as the box's project folder, instead of cloning
# CODEBOX_REPO into it. Empty means clone, which is the GCP provider's only option.
: "${CODEBOX_DOCKER_MOUNT:=}"
# The uid the box user is built with. Matching the host's is what makes a bind mount
# usable from both sides: a mismatch leaves every file the box writes owned by a
# stranger on the host, and vice versa. Root on the host falls back to the old fixed
# 1000, because uid 0 already exists in the image.
if [ -z "${CODEBOX_DOCKER_UID:-}" ]; then
  CODEBOX_DOCKER_UID="$(id -u)"
  [ "$CODEBOX_DOCKER_UID" = 0 ] && CODEBOX_DOCKER_UID=1000
fi

CODEBOX_DOCKER_HOME="/home/${CODEBOX_DOCKER_USER}"
# Whose home the editor's config lives in: the agent's when the uid split is on, otherwise
# the single box user's.
CODEBOX_BOX_USER="${CODEBOX_AGENT_USER:-$CODEBOX_DOCKER_USER}"
CODEBOX_BOX_HOME="/home/${CODEBOX_BOX_USER}"

codebox_check_docker() {
  command -v docker >/dev/null 2>&1 || \
    codebox_die "docker not found. Install Docker: https://docs.docker.com/get-docker/"
  docker info >/dev/null 2>&1 || \
    codebox_die "cannot reach the Docker daemon. Is it running, and is your user allowed to use it?"
}

# Echo the container's state (running/exited/paused/created), or empty if there is no
# such container. Non-zero only when the *query* failed, so a daemon problem is never
# misreported as "no container" — the same distinction codebox_instance_status makes on
# GCP, and for the same reason: the wrong answer here sends you to `codebox create`.
codebox_container_state() {
  local out
  if out="$(docker ps -a --filter "name=^${CODEBOX_INSTANCE}$" --format '{{.State}}' 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  codebox_warn "could not query Docker for container '$CODEBOX_INSTANCE'."
  codebox_warn "This is usually the daemon being unreachable, not a missing container."
  codebox_warn "Fix that and retry — do NOT run 'codebox create', which would try to make a second box."
  return 1
}

# Run a command inside the box as the box user.
codebox_docker_exec() {
  docker exec -u "$CODEBOX_DOCKER_USER" "$CODEBOX_INSTANCE" "$@"
}

# Bring the container up from whatever state it is in. Paused unpauses (processes are
# restored), anything else starts.
codebox_container_up() {
  case "$1" in
    running) return 0 ;;
    paused)
      codebox_info "Container is paused; unpausing (running processes are restored) ..."
      docker unpause "$CODEBOX_INSTANCE" >/dev/null ;;
    *)
      codebox_info "Container is ${1:-absent}; starting ..."
      docker start "$CODEBOX_INSTANCE" >/dev/null ;;
  esac
}

# Wait for code-server to accept connections inside the box. Checked from inside rather
# than on the published port so this reports on the editor itself, not on Docker's
# port binding, which answers as soon as the container exists.
codebox_wait_for_editor() {
  local i
  for i in $(seq 1 60); do
    if codebox_docker_exec bash -c "exec 3<>/dev/tcp/127.0.0.1/${CODEBOX_REMOTE_PORT}" \
         >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- the mounted project directory ---------------------------------------
# Absolute host path of CODEBOX_DOCKER_MOUNT, or nothing when it is not set. Docker needs
# an absolute path: given a relative one it silently creates a *named volume* instead,
# which shows up as an empty project folder rather than as an error.
codebox_mount_source() {
  local path="${CODEBOX_DOCKER_MOUNT:-}"
  [ -n "$path" ] || return 0
  case "$path" in
    "~")   path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
  esac
  [ -d "$path" ] || codebox_die "CODEBOX_DOCKER_MOUNT is not a directory: $CODEBOX_DOCKER_MOUNT"
  path="$(cd "$path" && pwd)"          # absolute, and symlinks resolved
  [ "$path" != / ] || codebox_die "CODEBOX_DOCKER_MOUNT cannot be '/'; point it at a project directory."
  printf '%s' "$path"
}

# Where that directory lands inside the box: the same <home>/<name> shape a clone would
# take, so code-server opens the project the same way whichever way it got there.
codebox_mount_target() {
  local src
  src="$(codebox_mount_source)" || return 1
  [ -n "$src" ] || return 0
  printf '%s/%s' "$CODEBOX_BOX_HOME" "$(basename "$src")"
}

# The uid split and a bind mount do not currently fit together: the mount arrives owned by
# CODEBOX_DOCKER_UID (the login user's), while the agent is a separate account created
# inside the box with a uid of its own, so it cannot write to its own project directory.
# Warn rather than fail — a read-only look at the code is still useful, and the box is fine
# in every other respect.
codebox_check_mount_agent_split() {
  [ -n "${CODEBOX_DOCKER_MOUNT:-}" ] || return 0
  [ -n "${CODEBOX_AGENT_USER:-}" ] || return 0
  codebox_warn "CODEBOX_DOCKER_MOUNT with CODEBOX_AGENT_USER: the mount belongs to uid $CODEBOX_DOCKER_UID"
  codebox_warn "(the login user), but the agent runs as '$CODEBOX_AGENT_USER' with a different uid, so it"
  codebox_warn "will not be able to write to the mounted project. Drop CODEBOX_AGENT_USER for a box you"
  codebox_warn "want the agent to edit a mounted directory in."
}

# The -p arguments for the editor port plus CODEBOX_ADDITIONAL_PORTS, one per line.
# Extra ports use the same number on the host and in the box, matching the tunnel's
# behaviour on GCP.
codebox_publish_args() {
  local port ports
  printf '%s\n' "${CODEBOX_DOCKER_BIND}:${CODEBOX_LOCAL_PORT}:${CODEBOX_REMOTE_PORT}"
  ports="$(codebox_additional_ports)"
  for port in $ports; do
    printf '%s\n' "${CODEBOX_DOCKER_BIND}:${port}:${port}"
  done
}
