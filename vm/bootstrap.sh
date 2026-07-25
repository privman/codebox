#!/usr/bin/env bash
# Runs ON the VM (as the login user, which has passwordless sudo on GCP images).
# Installs Claude Code, code-server, and the idle-shutdown timer.
# Idempotent: safe to re-run.
set -euo pipefail

REMOTE_PORT="${CODEBOX_REMOTE_PORT:-8080}"
IDLE_TIMEOUT_MIN="${CODEBOX_IDLE_TIMEOUT_MIN:-30}"
REPO="${CODEBOX_REPO:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[codebox]\033[0m %s\n' "$*"; }

# --- base packages -------------------------------------------------------
log "Updating apt and installing base packages ..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git build-essential ca-certificates gnupg ripgrep jq tmux

# --- Claude Code ---------------------------------------------------------
# Native installer: a self-contained binary in ~/.local/bin that auto-updates
# with no language-runtime dependency. Installed as the user (never sudo).
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  log "Installing Claude Code (native installer) ..."
  curl -fsSL https://claude.ai/install.sh | bash
else
  log "Claude Code already installed (it auto-updates in the background)."
fi
# Make sure ~/.local/bin is on PATH for login shells and code-server terminals.
if ! grep -qs '\.local/bin' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

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

log "Applying default editor settings ..."
user_data_dir="$HOME/.local/share/code-server"
settings_dir="$user_data_dir/User"
settings="$settings_dir/settings.json"
mkdir -p "$settings_dir"
[ -s "$settings" ] || echo '{}' > "$settings"
# Set window.autoDetectColorScheme on by default, but don't clobber a value the
# user has already chosen (keeps re-running bootstrap non-destructive).
tmp="$(mktemp)"
if jq 'if has("window.autoDetectColorScheme") then . else . + {"window.autoDetectColorScheme": true} end' \
     "$settings" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$settings"
else
  rm -f "$tmp"
  log "warning: could not parse $settings; leaving it untouched."
fi

# --- project repo --------------------------------------------------------
# Clone CODEBOX_REPO into the home directory and make its root the folder
# code-server opens. Idempotent: an existing checkout is left alone.
if [ -n "$REPO" ]; then
  # Derive the checkout directory from the URI's last path segment. Handles
  # https://host/owner/repo, ssh://[user@]host/owner/repo and scp-style
  # git@host:owner/repo; the `.git` suffix is optional.
  repo_path="$REPO"
  case "$repo_path" in
    *://*) repo_path="${repo_path#*://}" ;;  # strip the scheme; [user@]host is dropped below
    *@*:*) repo_path="${repo_path#*:}" ;;    # scp-style: keep what follows the colon
  esac
  repo_path="${repo_path%/}"                 # tolerate a trailing slash
  repo_name="${repo_path##*/}"
  repo_name="${repo_name%.git}"              # `.git` suffix is optional

  repo_dir=""
  if [ -z "$repo_name" ]; then
    log "warning: could not derive a directory name from CODEBOX_REPO='$REPO'; skipping clone."
  elif [ -d "$HOME/$repo_name/.git" ]; then
    repo_dir="$HOME/$repo_name"
    log "Repo already cloned at $repo_dir; leaving it as is."
  elif [ -e "$HOME/$repo_name" ]; then
    log "warning: $HOME/$repo_name exists but is not a git checkout; skipping clone."
  else
    log "Cloning $REPO into $HOME/$repo_name ..."
    # Never block on a credential prompt — bootstrap runs non-interactively, so a
    # private repo must fail fast rather than hang waiting on stdin.
    if GIT_TERMINAL_PROMPT=0 \
       GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
       git clone "$REPO" "$HOME/$repo_name"; then
      repo_dir="$HOME/$repo_name"
    else
      log "warning: clone failed. If the repo is private, put credentials on the VM (an SSH"
      log "         key in ~/.ssh, or a git credential helper) and re-run 'codebox bootstrap'."
    fi
  fi

  if [ -n "$repo_dir" ]; then
    # code-server remembers the last folder you opened in coder.json and prefers it
    # over anything else, so seeding that entry makes the repo the default folder.
    # Only seed it when nothing is recorded yet — otherwise we'd yank the user out of
    # whatever they last had open every time bootstrap is re-run.
    coder_json="$user_data_dir/coder.json"
    if [ -s "$coder_json" ] && jq -e '.query.folder // .query.workspace' "$coder_json" >/dev/null 2>&1; then
      log "code-server already has a last-opened folder; leaving it as is."
    else
      [ -s "$coder_json" ] && jq -e . "$coder_json" >/dev/null 2>&1 || echo '{}' > "$coder_json"
      tmp="$(mktemp)"
      if jq --arg folder "$repo_dir" '.query = ((.query // {}) + {folder: $folder})' \
           "$coder_json" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$coder_json"
        log "code-server will open $repo_dir by default."
      else
        rm -f "$tmp"
        log "warning: could not update $coder_json; code-server will open its usual default view."
      fi
    fi
  fi
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
log "Claude Code: $(claude --version 2>/dev/null || echo 'installed (run \"claude\" to sign in)')"
log "code-server: $(code-server --version 2>/dev/null | head -1 || echo missing)"
