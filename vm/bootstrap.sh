#!/usr/bin/env bash
# Runs ON the VM (as the login user, which has passwordless sudo on GCP images).
# Installs Claude Code, code-server, and the idle-shutdown timer.
# Idempotent: safe to re-run.
set -euo pipefail

REMOTE_PORT="${CODEBOX_REMOTE_PORT:-8080}"
IDLE_TIMEOUT_MIN="${CODEBOX_IDLE_TIMEOUT_MIN:-30}"
REPO="${CODEBOX_REPO:-}"
GH_APP_ID="${CODEBOX_GITHUB_APP_ID:-}"
GH_APP_INSTALL_ID="${CODEBOX_GITHUB_APP_INSTALLATION_ID:-}"
GH_BOT_NAME="${CODEBOX_GITHUB_BOT_NAME:-}"
GH_BOT_USER_ID="${CODEBOX_GITHUB_BOT_USER_ID:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[codebox]\033[0m %s\n' "$*"; }

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
# Seed our defaults, but never clobber a value the user has already chosen (keeps
# re-running bootstrap non-destructive) — `$defaults * .` merges with the existing
# file winning on every key it defines.
#   window.autoDetectColorScheme — follow the browser/OS light/dark preference.
#   window.title — project name first. VS Code's default leads with the file name,
#     which in a browser tab truncates to something you can't tell apart from the
#     other codebox tabs; the ${...} placeholders are VS Code's, not the shell's.
codebox_settings='{
  "window.autoDetectColorScheme": true,
  "window.title": "${rootName}${separator}${dirty}${activeEditorShort}${separator}${appName}"
}'
tmp="$(mktemp)"
if jq --argjson defaults "$codebox_settings" '$defaults * .' \
     "$settings" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$settings"
else
  rm -f "$tmp"
  log "warning: could not parse $settings; leaving it untouched."
fi

# --- GitHub access -------------------------------------------------------
# Two mutually exclusive modes, chosen by what the laptop side copied over:
#   App mode  — ~/.config/codebox/gh-app.pem plus the app/installation ids. Tokens are
#               minted per use and expire in an hour; git and gh both act as the app's bot.
#   PAT mode  — ~/.config/codebox/gh-token, a fine-grained token stored via `gh auth login`.
# This runs *before* the clone below so a private CODEBOX_REPO authenticates first time.
conf_dir="$HOME/.config/codebox"
bin_dir="$HOME/.local/bin"
agent_name=""
agent_email=""

# The agent lives on branches, so let a first push create the upstream by itself.
git config --global push.autoSetupRemote true

if [ -n "$GH_APP_ID" ] && [ -n "$GH_APP_INSTALL_ID" ] && [ -f "$conf_dir/gh-app.pem" ]; then
  log "Configuring GitHub App access ..."
  cat > "$conf_dir/gh-app.env" <<EOF
# Written by codebox bootstrap; read by ~/.local/bin/codebox-gh-token.
APP_ID=${GH_APP_ID}
INSTALLATION_ID=${GH_APP_INSTALL_ID}
PEM=${conf_dir}/gh-app.pem
EOF
  chmod 600 "$conf_dir/gh-app.env"

  install -m 0755 -D "$HERE/gh-app-token.sh" "$bin_dir/codebox-gh-token"
  install -m 0755 -D "$HERE/git-credential-codebox.sh" "$bin_dir/git-credential-codebox"
  if [ -x /usr/bin/gh ]; then
    install -m 0755 -D "$HERE/gh-shim.sh" "$bin_dir/gh"
  else
    log "warning: skipping the gh shim — /usr/bin/gh is missing, so 'gh pr create' won't work."
  fi

  # Absolute path on purpose: git must find the helper even when invoked from a context
  # that never sourced .bashrc (and so has no ~/.local/bin on PATH).
  git config --global --unset-all "credential.https://github.com.helper" 2>/dev/null || true
  git config --global "credential.https://github.com.helper" "$bin_dir/git-credential-codebox"

  # Resolve the bot's login and numeric user id. The id is what makes GitHub render the
  # commit as the bot — avatar and `bot` badge — instead of an unlinked name. It is the
  # *bot user's* id, not the app id; mixing those up silently yields an unlinked commit.
  if [ -z "$GH_BOT_NAME" ]; then
    slug="$(curl -sf -H "Authorization: Bearer $("$bin_dir/codebox-gh-token" --jwt)" \
              -H "Accept: application/vnd.github+json" \
              https://api.github.com/app | jq -r '.slug // empty')" || slug=""
    [ -z "$slug" ] || GH_BOT_NAME="${slug}[bot]"
  fi
  if [ -n "$GH_BOT_NAME" ] && [ -z "$GH_BOT_USER_ID" ]; then
    GH_BOT_USER_ID="$(curl -sf -H "Accept: application/vnd.github+json" \
      "https://api.github.com/users/${GH_BOT_NAME%\[bot\]}%5Bbot%5D" \
      | jq -r '.id // empty')" || GH_BOT_USER_ID=""
  fi
  if [ -n "$GH_BOT_NAME" ] && [ -n "$GH_BOT_USER_ID" ]; then
    agent_name="$GH_BOT_NAME"
    agent_email="${GH_BOT_USER_ID}+${GH_BOT_NAME}@users.noreply.github.com"
    log "Agent identity: $agent_name <$agent_email>"
  else
    log "warning: could not look up the app's bot identity from api.github.com. Set"
    log "         CODEBOX_GITHUB_BOT_NAME and CODEBOX_GITHUB_BOT_USER_ID in codebox.env"
    log "         (id: 'gh api /users/<app-slug>%5Bbot%5D --jq .id') and re-run bootstrap."
  fi

elif [ -f "$conf_dir/gh-token" ]; then
  log "Configuring GitHub access from a personal access token ..."
  rm -f "$bin_dir/gh"   # a leftover App-mode shim would shadow the real gh
  git config --global --unset-all "credential.https://github.com.helper" 2>/dev/null || true
  if [ ! -x /usr/bin/gh ]; then
    log "warning: /usr/bin/gh is missing, so the token can't be installed. Fix the gh install and re-run."
  elif /usr/bin/gh auth login --with-token < "$conf_dir/gh-token"; then
    # `setup-git` points git's credential helper at gh, so this one token covers both
    # pushes and PR creation.
    /usr/bin/gh auth setup-git
    agent_name="codebox-agent"
    agent_email="codebox-agent@users.noreply.github.com"
    log "Agent identity: $agent_name <$agent_email> (unlinked — PRs will be attributed to the token's owner)"
  else
    log "warning: 'gh auth login' rejected the token in $conf_dir/gh-token."
  fi

else
  log "No GitHub credentials configured; skipping (set CODEBOX_GITHUB_* in codebox.env)."
fi

# An explicit identity in codebox.env always wins over what we derived above.
[ -z "${CODEBOX_GIT_AGENT_NAME:-}" ]  || agent_name="$CODEBOX_GIT_AGENT_NAME"
[ -z "${CODEBOX_GIT_AGENT_EMAIL:-}" ] || agent_email="$CODEBOX_GIT_AGENT_EMAIL"

if [ -n "$agent_name" ] && [ -n "$agent_email" ]; then
  log "Labelling Claude Code's commits as $agent_name ..."
  claude_settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$claude_settings" ] || echo '{}' > "$claude_settings"
  # Claude Code applies `env` to the subprocesses it spawns, so this identity attaches to
  # the commits *Claude* makes and leaves your own terminal commits on the VM's
  # ~/.gitconfig identity — the two share a unix user, so env is what separates them.
  # `attribution` is only seeded when unset, so a footer you chose yourself survives.
  tmp="$(mktemp)"
  if jq --arg n "$agent_name" --arg e "$agent_email" '
        .env = ((.env // {}) + {
          GIT_AUTHOR_NAME: $n,    GIT_AUTHOR_EMAIL: $e,
          GIT_COMMITTER_NAME: $n, GIT_COMMITTER_EMAIL: $e
        })
      | if (.attribution | type) == "object" and (.attribution | has("commit"))
        then .
        else .attribution = ((.attribution // {}) + {commit: "🤖 committed by \($n) on codebox"})
        end' "$claude_settings" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$claude_settings"
  else
    rm -f "$tmp"
    log "warning: could not update $claude_settings; set the git identity there by hand."
  fi
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

# --- suspend notice ------------------------------------------------------
# Installed even when the idle timer is off: `codebox suspend` uses it too, so a
# manual suspend also gets to warn connected clients.
log "Installing the pre-suspend client notice ..."
sudo install -m 0755 "$HERE/pre-suspend.sh" /usr/local/bin/codebox-pre-suspend

# --- idle shutdown -------------------------------------------------------
if [ "$IDLE_TIMEOUT_MIN" -gt 0 ]; then
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
log "Claude Code: $(claude --version 2>/dev/null || echo 'installed (run \"claude\" to sign in)')"
log "code-server: $(code-server --version 2>/dev/null | head -1 || echo missing)"
