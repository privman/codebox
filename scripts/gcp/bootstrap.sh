#!/usr/bin/env bash
# Copy the VM setup files to the instance and run the on-VM bootstrap.
# Safe to re-run (installs are idempotent).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project
codebox_validate_repo
codebox_validate_github
codebox_validate_agent_user
codebox_validate_agent_policy

status="$(codebox_instance_status)"
[ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
if [ "$status" != "RUNNING" ]; then
  codebox_start_or_resume "$status"
fi

codebox_info "Waiting for SSH (via IAP) ..."
codebox_wait_for_ssh || codebox_die "timed out waiting for SSH. Check IAM roles and firewall, then retry 'codebox bootstrap'."

codebox_info "Copying VM setup files ..."
codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  --command="rm -rf ~/vm"
codebox_gcloud compute scp --recurse "$CODEBOX_ROOT/vm" "$CODEBOX_INSTANCE:~/vm" \
  --zone "$CODEBOX_ZONE" --tunnel-through-iap

# --- GitHub credentials --------------------------------------------------
# Copy the app key / token to the VM before the bootstrap runs, so its clone of a
# private CODEBOX_REPO can authenticate on the first attempt. Both land in a 0700
# directory and are chmod'ed to 0600 (scp does not preserve modes).
codebox_copy_secret() {
  local src="$1" dest="$2"
  codebox_info "Copying $(basename "$dest") to the VM ..."
  codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
    --command="mkdir -p ~/.config/codebox && chmod 700 ~/.config/codebox"
  codebox_gcloud compute scp "$src" "$CODEBOX_INSTANCE:~/.config/codebox/$dest" \
    --zone "$CODEBOX_ZONE" --tunnel-through-iap
  codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
    --command="chmod 600 ~/.config/codebox/$dest"
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

codebox_info "Running on-VM bootstrap (code-server, Claude Code, GitHub access, idle-shutdown) ..."
codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
  --command="CODEBOX_REMOTE_PORT='${CODEBOX_REMOTE_PORT}' \
CODEBOX_IDLE_TIMEOUT_MIN='${CODEBOX_IDLE_TIMEOUT_MIN}' \
CODEBOX_REPO='${CODEBOX_REPO}' \
CODEBOX_GITHUB_APP_ID='${CODEBOX_GITHUB_APP_ID}' \
CODEBOX_GITHUB_APP_INSTALLATION_ID='${CODEBOX_GITHUB_APP_INSTALLATION_ID}' \
CODEBOX_GITHUB_BOT_NAME='${CODEBOX_GITHUB_BOT_NAME}' \
CODEBOX_GITHUB_WRITE_REPOS='${CODEBOX_GITHUB_WRITE_REPOS}' \
CODEBOX_AGENT_USER='${CODEBOX_AGENT_USER}' \
CODEBOX_AGENT_PERMISSION_MODE='${CODEBOX_AGENT_PERMISSION_MODE}' \
CODEBOX_AGENT_DENY_TOOLS='${CODEBOX_AGENT_DENY_TOOLS}' \
CODEBOX_AGENT_ALLOW_TOOLS='${CODEBOX_AGENT_ALLOW_TOOLS}' \
CODEBOX_GITHUB_BOT_USER_ID='${CODEBOX_GITHUB_BOT_USER_ID}' \
CODEBOX_GIT_AGENT_NAME='${CODEBOX_GIT_AGENT_NAME}' \
CODEBOX_GIT_AGENT_EMAIL='${CODEBOX_GIT_AGENT_EMAIL}' \
bash ~/vm/bootstrap.sh"

codebox_info "Done. Run 'codebox connect' to open the editor."
