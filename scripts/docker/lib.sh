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
