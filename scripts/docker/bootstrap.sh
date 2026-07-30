#!/usr/bin/env bash
# Copy the box setup files into the container and run the shared bootstrap.
# Safe to re-run (installs are idempotent).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker
codebox_validate_repo
codebox_validate_github
codebox_validate_agent_user
codebox_validate_agent_policy

state="$(codebox_container_state)"
[ -n "$state" ] || codebox_die "container '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
codebox_container_up "$state"

codebox_info "Copying box setup files ..."
codebox_docker_exec rm -rf "$CODEBOX_DOCKER_HOME/vm"
docker cp "$CODEBOX_ROOT/vm" "$CODEBOX_INSTANCE:$CODEBOX_DOCKER_HOME/vm"
# docker cp lands as root regardless of the container's user.
docker exec -u root "$CODEBOX_INSTANCE" \
  chown -R "$CODEBOX_DOCKER_USER:$CODEBOX_DOCKER_USER" "$CODEBOX_DOCKER_HOME/vm"

# --- GitHub credentials --------------------------------------------------
# Same two modes as the GCP provider, copied in before the bootstrap runs so a clone of
# a private CODEBOX_REPO authenticates on the first attempt.
codebox_copy_secret() {
  local src="$1" dest="$2"
  codebox_info "Copying $(basename "$dest") into the box ..."
  codebox_docker_exec mkdir -p "$CODEBOX_DOCKER_HOME/.config/codebox"
  codebox_docker_exec chmod 700 "$CODEBOX_DOCKER_HOME/.config/codebox"
  docker cp "$src" "$CODEBOX_INSTANCE:$CODEBOX_DOCKER_HOME/.config/codebox/$dest"
  docker exec -u root "$CODEBOX_INSTANCE" \
    chown "$CODEBOX_DOCKER_USER:$CODEBOX_DOCKER_USER" "$CODEBOX_DOCKER_HOME/.config/codebox/$dest"
  codebox_docker_exec chmod 600 "$CODEBOX_DOCKER_HOME/.config/codebox/$dest"
}
if [ -n "$CODEBOX_GITHUB_APP_KEY" ]; then
  codebox_copy_secret "$CODEBOX_GITHUB_APP_KEY" gh-app.pem
fi
if [ -n "$CODEBOX_GITHUB_TOKEN_FILE" ]; then
  codebox_copy_secret "$CODEBOX_GITHUB_TOKEN_FILE" gh-token
fi
if [ -n "$CODEBOX_CLAUDE_TOKEN_FILE" ]; then
  codebox_copy_secret "$CODEBOX_CLAUDE_TOKEN_FILE" claude-token
fi

codebox_info "Running the bootstrap inside the box (code-server, Claude Code, GitHub access) ..."
# CODEBOX_IDLE_TIMEOUT_MIN is pinned to 0: idle auto-suspend is a cloud-billing feature
# and needs systemd, so it has no place in a local container. bootstrap.sh also detects
# the container for itself, but being explicit keeps the intent visible here.
docker exec -u "$CODEBOX_DOCKER_USER" \
  -e "CODEBOX_CONTAINER=1" \
  -e "CODEBOX_REMOTE_PORT=$CODEBOX_REMOTE_PORT" \
  -e "CODEBOX_IDLE_TIMEOUT_MIN=0" \
  -e "CODEBOX_REPO=$CODEBOX_REPO" \
  -e "CODEBOX_GITHUB_APP_ID=$CODEBOX_GITHUB_APP_ID" \
  -e "CODEBOX_GITHUB_APP_INSTALLATION_ID=$CODEBOX_GITHUB_APP_INSTALLATION_ID" \
  -e "CODEBOX_GITHUB_BOT_NAME=$CODEBOX_GITHUB_BOT_NAME" \
  -e "CODEBOX_GITHUB_WRITE_REPOS=$CODEBOX_GITHUB_WRITE_REPOS" \
  -e "CODEBOX_AGENT_USER=$CODEBOX_AGENT_USER" \
  -e "CODEBOX_AGENT_PERMISSION_MODE=$CODEBOX_AGENT_PERMISSION_MODE" \
  -e "CODEBOX_AGENT_DENY_TOOLS=$CODEBOX_AGENT_DENY_TOOLS" \
  -e "CODEBOX_AGENT_ALLOW_TOOLS=$CODEBOX_AGENT_ALLOW_TOOLS" \
  -e "CODEBOX_GITHUB_BOT_USER_ID=$CODEBOX_GITHUB_BOT_USER_ID" \
  -e "CODEBOX_GIT_AGENT_NAME=$CODEBOX_GIT_AGENT_NAME" \
  -e "CODEBOX_GIT_AGENT_EMAIL=$CODEBOX_GIT_AGENT_EMAIL" \
  "$CODEBOX_INSTANCE" bash "$CODEBOX_DOCKER_HOME/vm/bootstrap.sh"

codebox_info "Done. Run 'codebox --provider docker connect' to open the editor."
