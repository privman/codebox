#!/usr/bin/env bash
# Runs INSIDE the box — a GCP VM or a local Docker container — as the login user, which
# has passwordless sudo on GCP images and in the codebox image.
# Does the privileged half: packages, the code-server install, the uid split, and the
# systemd units. Everything that lives in the agent's home is bootstrap-user.sh, which this
# runs as the agent user.
# Idempotent: safe to re-run.
set -euo pipefail

REMOTE_PORT="${CODEBOX_REMOTE_PORT:-8080}"
IDLE_TIMEOUT_MIN="${CODEBOX_IDLE_TIMEOUT_MIN:-30}"
REPO="${CODEBOX_REPO:-}"
GH_APP_ID="${CODEBOX_GITHUB_APP_ID:-}"
GH_APP_INSTALL_ID="${CODEBOX_GITHUB_APP_INSTALLATION_ID:-}"
GH_BOT_NAME="${CODEBOX_GITHUB_BOT_NAME:-}"
GH_BOT_USER_ID="${CODEBOX_GITHUB_BOT_USER_ID:-}"
GH_WRITE_REPOS="${CODEBOX_GITHUB_WRITE_REPOS:-}"
# Empty means one uid for everything, as codebox has always worked. A username here turns
# on privilege separation: see the agent / key separation section below.
AGENT_USER="${CODEBOX_AGENT_USER:-}"
SPLIT=0
[ -z "$AGENT_USER" ] || SPLIT=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[codebox]\033[0m %s\n' "$*"; }

# The same script bootstraps a GCP VM and a local Docker container. The container has no
# systemd (code-server is run by the image's entrypoint instead) and nothing to suspend,
# so the pieces built on those are skipped there rather than failing halfway.
if [ -f /.dockerenv ] || [ -n "${CODEBOX_CONTAINER:-}" ]; then
  IN_CONTAINER=1
else
  IN_CONTAINER=0
fi
in_container() { [ "$IN_CONTAINER" = 1 ]; }
# --- base packages -------------------------------------------------------
log "Updating apt and installing base packages ..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git build-essential ca-certificates gnupg ripgrep jq tmux

# --- GitHub CLI ----------------------------------------------------------
# From GitHub's own apt repo; the Debian package lags badly. Checked by path, not by
# `command -v`, because in GitHub App mode we install a shim named `gh` on PATH.
if [ ! -x /usr/bin/gh ]; then
  log "Installing GitHub CLI ..."
  gh_ok=1
  {
    sudo mkdir -p -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
  } || gh_ok=0
  # Not fatal: the box is still perfectly usable without `gh`, you just can't open PRs
  # from it. Anything that needs gh warns for itself further down.
  [ "$gh_ok" = 1 ] || log "warning: GitHub CLI install failed; 'gh' (and PR creation) will be unavailable."
fi
# --- code-server ---------------------------------------------------------
if ! command -v code-server >/dev/null 2>&1; then
  log "Installing code-server ..."
  curl -fsSL https://code-server.dev/install.sh | sh
fi
# --- agent / key separation ----------------------------------------------
# With CODEBOX_AGENT_USER set, the box runs three uids instead of one:
#
#   the login user  you, over ssh — sudo, admin, no agent processes
#   $AGENT_USER     code-server, Claude Code, every editor terminal — no sudo
#   codebox-git     owns the GitHub App key and mints tokens — reachable only through one
#                   sudoers rule, and only to run the minter
#
# That is what turns CODEBOX_GITHUB_WRITE_REPOS from a promise into a boundary: the agent
# can ask for a scoped token but cannot read the key, so it cannot mint a broader one.
conf_dir="$HOME/.config/codebox"

if [ -n "$AGENT_USER" ]; then
  log "Setting up privilege separation (agent: $AGENT_USER, key holder: codebox-git) ..."
  id -u "$AGENT_USER" >/dev/null 2>&1 || \
    sudo useradd --create-home --shell /bin/bash "$AGENT_USER"
  id -u codebox-git >/dev/null 2>&1 || \
    sudo useradd --system --create-home --home-dir /var/lib/codebox-git \
                 --shell /usr/sbin/nologin codebox-git

  # Make sure the agent never sits in a group that is root-equivalent, including on a box
  # that was bootstrapped before this and had the agent added to something.
  for group in sudo adm docker google-sudoers; do
    sudo gpasswd -d "$AGENT_USER" "$group" >/dev/null 2>&1 || true
  done

  AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  [ -n "$AGENT_HOME" ] || { log "error: could not resolve $AGENT_USER's home"; exit 1; }

  if [ -f "$conf_dir/gh-app.pem" ]; then
    log "Moving the app key behind codebox-git ..."
    sudo install -d -m 0700 -o codebox-git -g codebox-git /var/lib/codebox-git
    sudo install -m 0600 -o codebox-git -g codebox-git \
      "$conf_dir/gh-app.pem" /var/lib/codebox-git/gh-app.pem
    # The login user only ever held it in order to hand it over. Leaving a copy in a
    # home directory would make the whole arrangement decorative.
    rm -f "$conf_dir/gh-app.pem"
  fi

  # Root-owned so the agent cannot rewrite its own policy. World-readable on purpose: it
  # holds ids and a repository list, no secrets, and codebox-git must be able to read it.
  sudo install -d -m 0755 /etc/codebox
  sudo tee /etc/codebox/gh-app.env >/dev/null <<EOF
# Written by codebox bootstrap. Read by /usr/local/bin/codebox-gh-token, running as
# codebox-git. The agent can read this file but not change it, and not read PEM.
APP_ID=${GH_APP_ID}
INSTALLATION_ID=${GH_APP_INSTALL_ID}
PEM=/var/lib/codebox-git/gh-app.pem
WRITE_REPOS=${GH_WRITE_REPOS}
EOF
  sudo chmod 0644 /etc/codebox/gh-app.env
  sudo install -m 0755 "$HERE/gh-app-token.sh" /usr/local/bin/codebox-gh-token

  # The only privilege the agent gets. One fixed command, no wildcards: the minter reads
  # its policy from the root-owned file above, so nothing in the arguments can widen the
  # scope it hands back.
  printf '%s ALL=(codebox-git) NOPASSWD: /usr/local/bin/codebox-gh-token\n' "$AGENT_USER" \
    | sudo tee /etc/sudoers.d/codebox-agent >/dev/null
  sudo chmod 0440 /etc/sudoers.d/codebox-agent
  if ! sudo visudo -cf /etc/sudoers.d/codebox-agent >/dev/null; then
    sudo rm -f /etc/sudoers.d/codebox-agent
    log "error: the sudoers rule was rejected and has been removed; not continuing"
    exit 1
  fi
fi

# --- the agent's half ----------------------------------------------------
# Claude Code, the editor config, the GitHub helpers and the clone all live in the agent's
# home, so they are installed by bootstrap-user.sh running as that user. Without the split
# it is the same script run inline as the login user, and the box is unchanged.
user_env=(
  "CODEBOX_REMOTE_PORT=$REMOTE_PORT"
  "CODEBOX_REPO=$REPO"
  "CODEBOX_GITHUB_APP_ID=$GH_APP_ID"
  "CODEBOX_GITHUB_APP_INSTALLATION_ID=$GH_APP_INSTALL_ID"
  "CODEBOX_GITHUB_BOT_NAME=$GH_BOT_NAME"
  "CODEBOX_GITHUB_BOT_USER_ID=$GH_BOT_USER_ID"
  "CODEBOX_GITHUB_WRITE_REPOS=$GH_WRITE_REPOS"
  "CODEBOX_GIT_AGENT_NAME=${CODEBOX_GIT_AGENT_NAME:-}"
  "CODEBOX_GIT_AGENT_EMAIL=${CODEBOX_GIT_AGENT_EMAIL:-}"
  "CODEBOX_CONTAINER=${CODEBOX_CONTAINER:-}"
  "CODEBOX_AGENT_SPLIT=$SPLIT"
)

if [ -n "$AGENT_USER" ]; then
  # The scripts are in the login user's home, which the agent has no business reading.
  # Stage them somewhere world-readable instead.
  stage=/usr/local/lib/codebox
  sudo rm -rf "$stage"
  sudo install -d -m 0755 "$stage"
  sudo install -m 0755 "$HERE"/*.sh "$stage/"
  sudo -u "$AGENT_USER" -H env "${user_env[@]}" bash "$stage/bootstrap-user.sh"
else
  env "${user_env[@]}" bash "$HERE/bootstrap-user.sh"
fi
if in_container; then
  # The image's entrypoint runs code-server and picks it up within a few seconds of
  # this install finishing, so there is no unit to enable.
  log "Container: code-server is started by the entrypoint."
else
  # The unit runs as the agent user when the split is on: code-server is the agent's
  # process, and every terminal it opens inherits that uid.
  cs_user="${AGENT_USER:-$USER}"
  log "Enabling code-server service (as $cs_user) ..."
  sudo systemctl enable --now "code-server@${cs_user}"
fi

# --- suspend notice ------------------------------------------------------
# Installed even when the idle timer is off: `codebox suspend` uses it too, so a
# manual suspend also gets to warn connected clients.
if in_container; then
  # `codebox suspend` on Docker is `docker pause`, which freezes the container without
  # touching the published port — there is no tunnel to warn anyone about.
  log "Container: skipping the pre-suspend client notice (nothing to disconnect)."
else
  log "Installing the pre-suspend client notice ..."
  sudo install -m 0755 "$HERE/pre-suspend.sh" /usr/local/bin/codebox-pre-suspend
fi

# --- idle shutdown -------------------------------------------------------
if in_container; then
  # Idle auto-suspend is a cloud-billing feature: a stopped container costs nothing and
  # the timer needs systemd anyway. Local boxes stay up until you stop them.
  log "Container: idle auto-suspend does not apply; use 'codebox stop' when you are done."
elif [ "$IDLE_TIMEOUT_MIN" -gt 0 ]; then
  log "Installing idle-shutdown timer (timeout ${IDLE_TIMEOUT_MIN} min) ..."
  sudo install -m 0755 "$HERE/idle-shutdown.sh" /usr/local/bin/codebox-idle-shutdown
  sudo tee /etc/codebox-idle.conf >/dev/null <<EOF
# codebox idle-shutdown configuration
IDLE_TIMEOUT_MIN=${IDLE_TIMEOUT_MIN}
REMOTE_PORT=${REMOTE_PORT}
LOAD_THRESHOLD=0.4
# Traffic below this rate counts as idle. A parked code-server tab heartbeats at
# roughly 11 KB/min, so this sits well above the noise and below real interaction.
TRAFFIC_KB_PER_MIN=50
# Seconds to wait after warning connected clients, so they can close their tunnels
# before RAM freezes. Capped hard — a client that has gone away must not delay a suspend.
SUSPEND_GRACE_SEC=5
EOF
  sudo cp "$HERE/systemd/codebox-idle-shutdown.service" /etc/systemd/system/
  sudo cp "$HERE/systemd/codebox-idle-shutdown.timer"   /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now codebox-idle-shutdown.timer
else
  log "Idle shutdown disabled (CODEBOX_IDLE_TIMEOUT_MIN=0). Removing any existing timer ..."
  sudo systemctl disable --now codebox-idle-shutdown.timer 2>/dev/null || true
fi

log "Bootstrap complete."