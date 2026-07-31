#!/usr/bin/env bash
# Runs INSIDE the box as the *agent* user — the account code-server, Claude Code and every
# editor terminal run as. Everything here lives under that user's home.
#
# Split out of bootstrap.sh so this half can run as a different, unprivileged uid when
# CODEBOX_AGENT_USER is set: the agent must not be able to read the GitHub App key, only to
# ask the minter behind it for a token scoped by policy it cannot edit. With the split off
# this runs as the login user and the box is exactly as it was.
set -euo pipefail

REMOTE_PORT="${CODEBOX_REMOTE_PORT:-8080}"
REPO="${CODEBOX_REPO:-}"
GH_APP_ID="${CODEBOX_GITHUB_APP_ID:-}"
GH_APP_INSTALL_ID="${CODEBOX_GITHUB_APP_INSTALLATION_ID:-}"
GH_BOT_NAME="${CODEBOX_GITHUB_BOT_NAME:-}"
GH_BOT_USER_ID="${CODEBOX_GITHUB_BOT_USER_ID:-}"
GH_WRITE_REPOS="${CODEBOX_GITHUB_WRITE_REPOS:-}"
SPLIT="${CODEBOX_AGENT_SPLIT:-0}"
PERMISSION_MODE="${CODEBOX_AGENT_PERMISSION_MODE:-}"
DENY_TOOLS="${CODEBOX_AGENT_DENY_TOOLS:-}"
ALLOW_TOOLS="${CODEBOX_AGENT_ALLOW_TOOLS:-}"
# Pre-rendered JSON arrays, built by the caller where jq and the config live together.
DENY_TOOLS_JSON="${CODEBOX_AGENT_DENY_TOOLS_JSON:-}"
ALLOW_TOOLS_JSON="${CODEBOX_AGENT_ALLOW_TOOLS_JSON:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[codebox]\033[0m %s\n' "$*"; }

if [ -f /.dockerenv ] || [ -n "${CODEBOX_CONTAINER:-}" ]; then
  IN_CONTAINER=1
else
  IN_CONTAINER=0
fi
in_container() { [ "$IN_CONTAINER" = 1 ]; }

# Add a line to the shell startup files if it is not there already. Both files, on purpose:
# Debian's ~/.bashrc returns early when the shell is not interactive, so an export only
# there is invisible to `bash -lc` and to anything headless, while ~/.profile alone misses
# the interactive non-login shells that code-server terminals actually are.
add_shell_line() {
  local line="$1" marker="$2" f
  for f in "$HOME/.profile" "$HOME/.bashrc"; do
    [ -e "$f" ] || : > "$f"
    grep -qsF "$marker" "$f" || printf '%s\n' "$line" >> "$f"
  done
}

# --- Claude Code ---------------------------------------------------------
# Native installer: a self-contained binary in ~/.local/bin that auto-updates
# with no language-runtime dependency. Installed as the user (never sudo).
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  log "Installing Claude Code (native installer) ..."
  curl -fsSL https://claude.ai/install.sh | bash
else
  log "Claude Code already installed (it auto-updates in the background)."
fi
# Make sure ~/.local/bin is on PATH for login shells and code-server terminals. Debian's
# skeleton ~/.profile already adds it for login shells; this covers the rest.
add_shell_line 'export PATH="$HOME/.local/bin:$PATH"' '.local/bin'
export PATH="$HOME/.local/bin:$PATH"

# In a container, code-server has to listen on all interfaces or Docker's published
# port cannot reach it. That is not an exposure: `codebox create` publishes the port to
# the host's loopback only, and the password still applies.
if in_container; then BIND_ADDR="0.0.0.0"; else BIND_ADDR="127.0.0.1"; fi
log "Configuring code-server (${BIND_ADDR}:${REMOTE_PORT}) ..."
mkdir -p "$HOME/.config/code-server"
config="$HOME/.config/code-server/config.yaml"
if [ ! -f "$config" ]; then
  password="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  cat > "$config" <<EOF
bind-addr: ${BIND_ADDR}:${REMOTE_PORT}
auth: password
password: ${password}
cert: false
EOF
  chmod 600 "$config"
  log "Generated a code-server password (stored in $config)."
else
  # Keep the existing password; just make sure the bind address is right.
  sed -i "s|^bind-addr:.*|bind-addr: ${BIND_ADDR}:${REMOTE_PORT}|" "$config"
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

# App mode is configured even when the key is not in this user's home: with the split on
# it lives behind another uid entirely.
if [ -n "$GH_APP_ID" ] && [ -n "$GH_APP_INSTALL_ID" ] && \
   { [ -f "$conf_dir/gh-app.pem" ] || [ "$SPLIT" = 1 ]; }; then
  log "Configuring GitHub App access ..."
  if [ "$SPLIT" = 1 ]; then
    # The key and the real minter belong to another uid; all this user gets is the right to
    # ask for a token. -H so the minter's cache lands in codebox-git's home where this user
    # cannot read it, and -n so a missing sudoers rule fails loudly instead of hanging on a
    # password prompt nobody is there to answer.
    install -d -m 0755 "$bin_dir"
    cat > "$bin_dir/codebox-gh-token" <<'WRAPPER'
#!/bin/sh
# Written by codebox bootstrap. The real minter runs as codebox-git and holds the app key;
# this side cannot read it, only ask for a scoped token. See vm/gh-app-token.sh.
exec sudo -n -H -u codebox-git /usr/local/bin/codebox-gh-token "$@"
WRAPPER
    chmod 0755 "$bin_dir/codebox-gh-token"
  else
    cat > "$conf_dir/gh-app.env" <<EOF
# Written by codebox bootstrap; read by ~/.local/bin/codebox-gh-token.
APP_ID=${GH_APP_ID}
INSTALLATION_ID=${GH_APP_INSTALL_ID}
PEM=${conf_dir}/gh-app.pem
# Repositories the agent may write to. Everything else the app can see is minted
# read-only. Empty means no policy: tokens are as broad as the installation.
WRITE_REPOS=${GH_WRITE_REPOS}
EOF
    chmod 600 "$conf_dir/gh-app.env"
    install -m 0755 -D "$HERE/gh-app-token.sh" "$bin_dir/codebox-gh-token"
  fi
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
  # Without this git sends only the host, so the helper cannot tell which repository it is
  # being asked about and every call would get the same scope.
  git config --global "credential.https://github.com.useHttpPath" true

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

# --- Claude Code credential ----------------------------------------------
# A token from `claude setup-token` on your laptop, copied in by the provider. It bills to
# your subscription and can only make model requests: it cannot reach claude.ai connectors,
# which is the point — a connector you cannot scope is better absent than denied. Without
# it the box is unauthenticated and you run `claude` once to log in, as before.
if [ -f "$conf_dir/claude-token" ]; then
  chmod 600 "$conf_dir/claude-token"
  # Exported by reference, never inlined: the secret stays in one 0600 file instead of being
  # copied into a world-readable shell profile.
  add_shell_line \
    'export CLAUDE_CODE_OAUTH_TOKEN="$(cat ~/.config/codebox/claude-token 2>/dev/null)"' \
    'CLAUDE_CODE_OAUTH_TOKEN'
  log "Claude Code will authenticate from $conf_dir/claude-token."
else
  log "No Claude Code credential configured; run 'claude' in the box once to log in."
fi


# --- ssh access to git hosts ---------------------------------------------
# A passphrase-less key, copied in by the provider. It exists for the one case the
# credential helper cannot serve: Claude Code's background marketplace refresh disables
# credential helpers for its `git pull`, so a private marketplace over https cannot
# authenticate and falls back to re-cloning the whole repo. An ssh remote authenticates on
# every pull, so a private skill marketplace stays in sync without that fallback.
#
# The supported shape is a read-only *deploy key* on the repository it needs to reach:
# per-repo and read-only, so it cannot write anywhere and cannot be used to go around
# CODEBOX_GITHUB_WRITE_REPOS. A personal ssh key here would do both, and is not the
# intended use.
if [ -f "$conf_dir/ssh-key" ]; then
  log "Installing the ssh key ..."
  install -d -m 0700 "$HOME/.ssh"
  install -m 0600 "$conf_dir/ssh-key" "$HOME/.ssh/id_codebox"
  # One copy, in the place ssh looks. The staged copy has done its job.
  rm -f "$conf_dir/ssh-key"

  # Host keys from GitHub's own metadata endpoint over TLS, rather than ssh-keyscan, which
  # trusts whatever answers on port 22. Without them a non-interactive pull fails on an
  # unknown host, which is exactly the situation this key exists for.
  known="$HOME/.ssh/known_hosts"
  touch "$known"
  chmod 0600 "$known"
  if hostkeys="$(curl -fsS https://api.github.com/meta 2>/dev/null | jq -r '.ssh_keys[]?' 2>/dev/null)" \
     && [ -n "$hostkeys" ]; then
    while IFS= read -r hostkey; do
      [ -n "$hostkey" ] || continue
      grep -qsF "$hostkey" "$known" || printf 'github.com %s\n' "$hostkey" >> "$known"
    done <<< "$hostkeys"
    log "  pinned github.com host keys from api.github.com/meta"
  else
    log "  warning: could not fetch GitHub's host keys; ssh pulls will fail until"
    log "           ~/.ssh/known_hosts has an entry for github.com"
  fi

  # IdentitiesOnly so ssh offers this key rather than everything it can find, which on a
  # box with several keys is what produces "too many authentication failures".
  ssh_cfg="$HOME/.ssh/config"
  touch "$ssh_cfg"
  chmod 0600 "$ssh_cfg"
  if ! grep -qs "id_codebox" "$ssh_cfg"; then
    cat >> "$ssh_cfg" <<'SSHCFG'

Host github.com
  User git
  IdentityFile ~/.ssh/id_codebox
  IdentitiesOnly yes
SSHCFG
  fi
  log "  ssh configured for github.com (key: ~/.ssh/id_codebox)"
fi

# --- Claude Code tool policy ---------------------------------------------
# Permission rules for the agent, from codebox.env. The point of these is that they survive
# --dangerously-skip-permissions: Claude Code evaluates deny rules in every mode, so this is
# how a box can run without approval prompts and still not be able to call a destructive
# tool. codebox owns the three keys it is given; anything else in the file is left alone.
if [ -n "$PERMISSION_MODE" ] || [ -n "$DENY_TOOLS" ] || [ -n "$ALLOW_TOOLS" ]; then
  log "Applying the agent's tool policy ..."
  claude_settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$claude_settings" ] || echo '{}' > "$claude_settings"
  deny_json="${DENY_TOOLS_JSON:-}"
  allow_json="${ALLOW_TOOLS_JSON:-}"
  tmp="$(mktemp)"
  if jq --arg mode "$PERMISSION_MODE" \
        --argjson deny "${deny_json:-null}" \
        --argjson allow "${allow_json:-null}" '
        .permissions = ((.permissions // {})
          | if $mode  == "" then . else .defaultMode = $mode end
          | if $deny  == null then . else .deny  = $deny  end
          | if $allow == null then . else .allow = $allow end)
      ' "$claude_settings" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$claude_settings"
    [ -z "$PERMISSION_MODE" ] || log "  mode: $PERMISSION_MODE"
    [ -z "$DENY_TOOLS" ]      || log "  deny: $DENY_TOOLS"
    [ -z "$ALLOW_TOOLS" ]     || log "  allow: $ALLOW_TOOLS"
  else
    rm -f "$tmp"
    log "warning: could not update $claude_settings; set permissions there by hand."
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

log "Agent-side setup complete (user: $(id -un))."
log "Claude Code: $(claude --version 2>/dev/null || echo 'installed (run \"claude\" to sign in)')"
# --version writes a default config when none exists, so only ask once ours is in place.
log "code-server: $(code-server --version 2>/dev/null | head -1 || echo missing)"
