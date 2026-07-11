#!/usr/bin/env bash
# Runs ON the VM (as the login user, which has passwordless sudo on GCP images).
# Installs Node.js, Claude Code, code-server, and the idle-shutdown timer.
# Idempotent: safe to re-run.
set -euo pipefail

NODE_VERSION="${CODEBOX_NODE_VERSION:-20}"
REMOTE_PORT="${CODEBOX_REMOTE_PORT:-8080}"
IDLE_TIMEOUT_MIN="${CODEBOX_IDLE_TIMEOUT_MIN:-30}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[codebox]\033[0m %s\n' "$*"; }

# --- base packages -------------------------------------------------------
log "Updating apt and installing base packages ..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git build-essential ca-certificates gnupg ripgrep jq tmux

# --- Node.js -------------------------------------------------------------
need_node=1
if command -v node >/dev/null 2>&1; then
  cur="$(node -v | sed 's/^v//' | cut -d. -f1)"
  [ "$cur" -ge "$NODE_VERSION" ] && need_node=0
fi
if [ "$need_node" -eq 1 ]; then
  log "Installing Node.js ${NODE_VERSION} ..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash -
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi
log "Enabling corepack (pnpm/yarn) ..."
sudo corepack enable || true

# --- Claude Code ---------------------------------------------------------
log "Installing/updating Claude Code ..."
sudo npm install -g @anthropic-ai/claude-code

# --- code-server ---------------------------------------------------------
if ! command -v code-server >/dev/null 2>&1; then
  log "Installing code-server ..."
  curl -fsSL https://code-server.dev/install.sh | sh
fi

log "Configuring code-server (127.0.0.1:${REMOTE_PORT}) ..."
mkdir -p "$HOME/.config/code-server"
config="$HOME/.config/code-server/config.yaml"
if [ ! -f "$config" ]; then
  password="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  cat > "$config" <<EOF
bind-addr: 127.0.0.1:${REMOTE_PORT}
auth: password
password: ${password}
cert: false
EOF
  chmod 600 "$config"
  log "Generated a code-server password (stored in $config)."
else
  # Keep the existing password; just make sure the bind address is right.
  sed -i "s|^bind-addr:.*|bind-addr: 127.0.0.1:${REMOTE_PORT}|" "$config"
  log "Kept existing code-server config."
fi

log "Enabling code-server service ..."
sudo systemctl enable --now "code-server@${USER}"

# --- idle shutdown -------------------------------------------------------
if [ "$IDLE_TIMEOUT_MIN" -gt 0 ]; then
  log "Installing idle-shutdown timer (timeout ${IDLE_TIMEOUT_MIN} min) ..."
  sudo install -m 0755 "$HERE/idle-shutdown.sh" /usr/local/bin/codebox-idle-shutdown
  sudo tee /etc/codebox-idle.conf >/dev/null <<EOF
# codebox idle-shutdown configuration
IDLE_TIMEOUT_MIN=${IDLE_TIMEOUT_MIN}
REMOTE_PORT=${REMOTE_PORT}
LOAD_THRESHOLD=0.4
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
log "Node:        $(node -v 2>/dev/null || echo missing)"
log "Claude Code: $(claude --version 2>/dev/null || echo 'installed (run \"claude\" to sign in)')"
log "code-server: $(code-server --version 2>/dev/null | head -1 || echo missing)"
