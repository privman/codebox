#!/usr/bin/env bash
# Provider-agnostic configuration and helpers. Sourced by each provider's lib.sh
# (scripts/<provider>/lib.sh), which adds its own defaults and helpers on top.
#
# Nothing here may assume a particular provider: settings that only one of them
# understands belong in that provider's lib.sh.
set -euo pipefail

# Repo root is one level up: scripts/ -> repo root.
CODEBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- load config ---------------------------------------------------------
# Where the file is (and why a missing CODEBOX_ENV is fatal) lives in env-file.sh, which
# bin/codebox shares so the dispatcher resolves the same config these scripts will.
# shellcheck source=env-file.sh
. "$(dirname "${BASH_SOURCE[0]}")/env-file.sh"

_codebox_load_env() {
  local candidate
  # Non-zero here means CODEBOX_ENV named a file that is not there; env-file.sh has
  # already explained it, so just stop.
  candidate="$(codebox_env_file_path "$CODEBOX_ROOT")" || exit 1
  [ -n "$candidate" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$candidate"
  set +a
  CODEBOX_ENV_FILE="$candidate"
}
_codebox_load_env

codebox_die()  { printf 'codebox: %s\n' "$*" >&2; exit 1; }
codebox_info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
codebox_warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

# --- per-box overrides ---------------------------------------------------
# One codebox.env can describe several boxes. File-level CODEBOX_<KEY> settings are the
# shared defaults; CODEBOX_BOX_<name>_<KEY> overrides one of them for the box selected with
# `--box <name>`:
#
#   CODEBOX_PROJECT=my-project            # both boxes
#   CODEBOX_BOX_work_LOCAL_PORT=8080      # only `--box work`
#   CODEBOX_BOX_play_LOCAL_PORT=8081      # only `--box play`
#
# The CODEBOX_BOX_ prefix is reserved rather than namespacing on the box name directly
# (CODEBOX_<name>_<KEY>), because that form collides with real settings the moment someone
# names a box `github` or `docker`, and would keep colliding as new settings are added.
# Sections would have been the other option, but this file is *sourced* as bash — people
# put $HOME and command substitutions in it — and `[section]` headers would mean parsing it
# ourselves and losing that.
_codebox_apply_box() {
  [ -n "${CODEBOX_BOX:-}" ] || return 0

  # The name becomes part of a shell variable name, so it has to be an identifier fragment.
  case "$CODEBOX_BOX" in
    [A-Za-z_]*) ;;
    *) codebox_die "--box name must start with a letter or underscore; got '$CODEBOX_BOX'" ;;
  esac
  case "$CODEBOX_BOX" in
    *[!A-Za-z0-9_]*) codebox_die "--box name may only contain letters, digits and underscores; got '$CODEBOX_BOX'" ;;
  esac

  local prefix="CODEBOX_BOX_${CODEBOX_BOX}_" var key matched=0 named_instance=0
  for var in $(compgen -v "$prefix" 2>/dev/null); do
    key="CODEBOX_${var#"$prefix"}"
    # Assignment context, so the value is not re-split or re-parsed.
    eval "$key=\${$var}"
    export "${key?}"
    matched=1
    [ "$key" = CODEBOX_INSTANCE ] && named_instance=1
  done

  # The instance name is the one setting that must differ between boxes — sharing it would
  # point two boxes at the same VM or container. So a named box gets its own by default and
  # a file-level CODEBOX_INSTANCE does not apply to it; an explicit
  # CODEBOX_BOX_<name>_INSTANCE still wins.
  [ "$named_instance" = 1 ] || CODEBOX_INSTANCE="codebox-${CODEBOX_BOX}"
  export CODEBOX_INSTANCE

  [ "$matched" = 1 ] || codebox_warn "no CODEBOX_BOX_${CODEBOX_BOX}_* settings found; using the file-level values with instance '$CODEBOX_INSTANCE'."
}

_codebox_apply_box

# --- defaults shared by every provider -----------------------------------
: "${CODEBOX_INSTANCE:=codebox}"
: "${CODEBOX_LOCAL_PORT:=8080}"
: "${CODEBOX_REMOTE_PORT:=8080}"
: "${CODEBOX_ADDITIONAL_PORTS:=}"
: "${CODEBOX_IDLE_TIMEOUT_MIN:=30}"
: "${CODEBOX_REPO:=}"
: "${CODEBOX_GITHUB_APP_ID:=}"
: "${CODEBOX_GITHUB_APP_INSTALLATION_ID:=}"
: "${CODEBOX_GITHUB_APP_KEY:=}"
: "${CODEBOX_GITHUB_BOT_NAME:=}"
: "${CODEBOX_GITHUB_BOT_USER_ID:=}"
: "${CODEBOX_GITHUB_TOKEN_FILE:=}"
: "${CODEBOX_GITHUB_WRITE_REPOS:=}"
: "${CODEBOX_AGENT_USER:=}"
: "${CODEBOX_AGENT_UID:=}"
: "${CODEBOX_CLAUDE_TOKEN_FILE:=}"
: "${CODEBOX_SSH_KEY_FILE:=}"
: "${CODEBOX_CLAUDE_MARKETPLACES:=}"
: "${CODEBOX_CLAUDE_PLUGINS:=}"
: "${CODEBOX_CODE_EXTENSIONS:=}"
: "${CODEBOX_AGENT_PERMISSION_MODE:=}"
: "${CODEBOX_AGENT_DENY_TOOLS:=}"
: "${CODEBOX_AGENT_ALLOW_TOOLS:=}"
: "${CODEBOX_GIT_AGENT_NAME:=}"
: "${CODEBOX_GIT_AGENT_EMAIL:=}"

# --- helpers -------------------------------------------------------------

# Echo the ports in CODEBOX_ADDITIONAL_PORTS, one per line, rejecting anything that is
# not a bare port number — these end up in command lines on both providers, and a typo
# should be a clear error rather than a mangled forward.
#
# Call it with a plain assignment (`ports="$(codebox_additional_ports)"`), never with
# `local ports=...`: `local` would mask the exit status and swallow the rejection.
# Namerefs would be tidier but need bash 4.3, and macOS ships 3.2.
codebox_additional_ports() {
  local port IFS=','
  [ -n "${CODEBOX_ADDITIONAL_PORTS:-}" ] || return 0
  for port in $CODEBOX_ADDITIONAL_PORTS; do
    port="${port//[[:space:]]/}"
    [ -n "$port" ] || continue
    case "$port" in
      *[!0-9]*) codebox_die "CODEBOX_ADDITIONAL_PORTS has a non-numeric port: '$port'" ;;
    esac
    printf '%s\n' "$port"
  done
}

# CODEBOX_AGENT_USER becomes a unix account inside the box, so reject anything useradd
# would refuse before we are halfway through a bootstrap. codebox-git is ours.
codebox_validate_agent_user() {
  # A pinned uid without an agent to give it to is a config that does nothing; say so
  # rather than let someone believe the split is on.
  if [ -n "${CODEBOX_AGENT_UID:-}" ] && [ -z "${CODEBOX_AGENT_USER:-}" ]; then
    codebox_die "CODEBOX_AGENT_UID is set but CODEBOX_AGENT_USER is empty; there is no agent account to pin."
  fi
  if [ -n "${CODEBOX_AGENT_UID:-}" ]; then
    case "$CODEBOX_AGENT_UID" in
      *[!0-9]*|"") codebox_die "CODEBOX_AGENT_UID must be a number; got '$CODEBOX_AGENT_UID'." ;;
    esac
    # Below 1000 is the system range on Debian, where it would collide with a packaged
    # account; 0 would be root.
    [ "$CODEBOX_AGENT_UID" -ge 1000 ] 2>/dev/null || \
      codebox_die "CODEBOX_AGENT_UID must be 1000 or above (it is a login account); got '$CODEBOX_AGENT_UID'."
  fi

  [ -n "${CODEBOX_AGENT_USER:-}" ] || return 0
  case "$CODEBOX_AGENT_USER" in
    codebox-git|root) codebox_die "CODEBOX_AGENT_USER cannot be '$CODEBOX_AGENT_USER'; it is reserved." ;;
    [a-z_]*) ;;
    *) codebox_die "CODEBOX_AGENT_USER must start with a letter or underscore; got '$CODEBOX_AGENT_USER'." ;;
  esac
  case "$CODEBOX_AGENT_USER" in
    *[!a-z0-9_-]*) codebox_die "CODEBOX_AGENT_USER must be a lowercase unix username; got '$CODEBOX_AGENT_USER'." ;;
  esac
}

# The Claude Code credential and the tool policy that ride into the box together: one says
# what the agent may spend, the other what it may call.
codebox_validate_agent_policy() {
  if [ -n "${CODEBOX_CLAUDE_TOKEN_FILE:-}" ]; then
    [ -f "$CODEBOX_CLAUDE_TOKEN_FILE" ] || codebox_die "Claude token file not found: $CODEBOX_CLAUDE_TOKEN_FILE"
    [ -s "$CODEBOX_CLAUDE_TOKEN_FILE" ] || codebox_die "Claude token file is empty: $CODEBOX_CLAUDE_TOKEN_FILE"
  fi
  if [ -n "${CODEBOX_SSH_KEY_FILE:-}" ]; then
    [ -f "$CODEBOX_SSH_KEY_FILE" ] || codebox_die "SSH key not found: $CODEBOX_SSH_KEY_FILE"
    [ -s "$CODEBOX_SSH_KEY_FILE" ] || codebox_die "SSH key is empty: $CODEBOX_SSH_KEY_FILE"
    # A public key here is a common slip and would fail silently inside the box.
    case "$CODEBOX_SSH_KEY_FILE" in
      *.pub) codebox_die "CODEBOX_SSH_KEY_FILE must be the private key, not $CODEBOX_SSH_KEY_FILE" ;;
    esac
    grep -qs -- "-----BEGIN .*PRIVATE KEY-----" "$CODEBOX_SSH_KEY_FILE" || \
      codebox_die "CODEBOX_SSH_KEY_FILE does not look like a private key: $CODEBOX_SSH_KEY_FILE"
    # An encrypted key cannot be used unattended: a background pull has nowhere to ask for
    # the passphrase. Test by trying to derive the public key with an empty one — grepping
    # for "ENCRYPTED" only catches the old PEM format, not the OpenSSH format every current
    # ssh-keygen writes, where the encryption is inside the base64 blob.
    if command -v ssh-keygen >/dev/null 2>&1 &&
       ! ssh-keygen -y -P "" -f "$CODEBOX_SSH_KEY_FILE" >/dev/null 2>&1; then
      codebox_die "CODEBOX_SSH_KEY_FILE is passphrase-protected (or not a usable private key); a background git pull in the box has nowhere to ask for the passphrase. Use a dedicated passphrase-less deploy key."
    fi
  fi

  # These reach a VM inside a single-quoted remote command; a quote would break the command
  # rather than the value. Whitespace inside an entry is always a mistake here.
  local item
  for item in "${CODEBOX_CLAUDE_MARKETPLACES:-}" "${CODEBOX_CLAUDE_PLUGINS:-}" \
              "${CODEBOX_CODE_EXTENSIONS:-}"; do
    case "$item" in
      *[\'\"\\]*) codebox_die "CODEBOX_CLAUDE_MARKETPLACES / _PLUGINS / CODEBOX_CODE_EXTENSIONS cannot contain quotes or backslashes; got '$item'." ;;
    esac
  done

  # An ssh marketplace with no key is the misconfiguration that produces a box whose skills
  # silently never sync, which is exactly what this feature exists to avoid.
  case "${CODEBOX_CLAUDE_MARKETPLACES:-}" in
    *git@*|*ssh://*)
      [ -n "${CODEBOX_SSH_KEY_FILE:-}" ] || \
        codebox_die "CODEBOX_CLAUDE_MARKETPLACES has an ssh source but CODEBOX_SSH_KEY_FILE is empty; the box would have no key to clone it with." ;;
  esac

  case "${CODEBOX_AGENT_PERMISSION_MODE:-}" in
    ""|default|acceptEdits|plan|auto|dontAsk|bypassPermissions) ;;
    *) codebox_die "CODEBOX_AGENT_PERMISSION_MODE must be one of default, acceptEdits, plan, auto, dontAsk, bypassPermissions; got '$CODEBOX_AGENT_PERMISSION_MODE'." ;;
  esac
  # These reach a VM inside a single-quoted remote command, so a quote or backslash in a
  # rule would break the command rather than the rule. Permission patterns hardly ever need
  # them; rejecting is far better than shipping a mangled policy.
  local list
  for list in "${CODEBOX_AGENT_DENY_TOOLS:-}" "${CODEBOX_AGENT_ALLOW_TOOLS:-}"; do
    case "$list" in
      *[\'\"\\]*) codebox_die "CODEBOX_AGENT_DENY_TOOLS / _ALLOW_TOOLS cannot contain quotes or backslashes; got '$list'." ;;
    esac
  done

  # dontAsk denies anything not explicitly allowed, so shipping it with an empty allow list
  # produces a box where the agent cannot run a single tool.
  if [ "${CODEBOX_AGENT_PERMISSION_MODE:-}" = dontAsk ] && [ -z "${CODEBOX_AGENT_ALLOW_TOOLS:-}" ]; then
    codebox_die "CODEBOX_AGENT_PERMISSION_MODE=dontAsk needs CODEBOX_AGENT_ALLOW_TOOLS; it denies everything else."
  fi
}

# Echo a comma-separated tool list as a JSON array, for the permissions block in the box's
# ~/.claude/settings.json. Empty input yields nothing, so callers can tell "not configured"
# from "configured empty".
codebox_tools_json() {
  [ -n "${1:-}" ] || return 0
  printf '%s' "$1" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# Sanity-check CODEBOX_REPO before we spend minutes building a box. The actual URI
# handling (and the clone) happens inside the box in vm/bootstrap.sh; here we only reject
# shapes git wouldn't accept and characters that would break the quoting of the
# bootstrap command (and are never valid in a git URI anyway).
codebox_validate_repo() {
  [ -n "${CODEBOX_REPO:-}" ] || return 0
  case "$CODEBOX_REPO" in
    *[[:space:]\'\"\`\$\\\;\&\|\<\>\(\)]*)
      codebox_die "CODEBOX_REPO contains characters that aren't valid in a git URI: $CODEBOX_REPO" ;;
  esac
  case "$CODEBOX_REPO" in
    https://*/*|http://*/*|ssh://*/*|*@*:*) return 0 ;;
    *) codebox_die "CODEBOX_REPO must be an https or ssh git URI (e.g. 'https://github.com/owner/repo' or 'git@github.com:owner/repo'); got: $CODEBOX_REPO" ;;
  esac
}

# Check the GitHub-access config before we start copying secrets around. The two options
# (a GitHub App, or a fine-grained PAT in a file) are mutually exclusive: each configures
# git and gh differently inside the box, and quietly preferring one would be a nasty surprise.
codebox_validate_github() {
  local v
  if [ -n "$CODEBOX_GITHUB_APP_KEY" ] && [ -n "$CODEBOX_GITHUB_TOKEN_FILE" ]; then
    codebox_die "set either the CODEBOX_GITHUB_APP_* variables or CODEBOX_GITHUB_TOKEN_FILE, not both."
  fi

  if [ -n "$CODEBOX_GITHUB_APP_ID$CODEBOX_GITHUB_APP_INSTALLATION_ID$CODEBOX_GITHUB_APP_KEY" ]; then
    [ -n "$CODEBOX_GITHUB_APP_ID" ] || codebox_die "CODEBOX_GITHUB_APP_ID is required for GitHub App access."
    [ -n "$CODEBOX_GITHUB_APP_INSTALLATION_ID" ] || codebox_die "CODEBOX_GITHUB_APP_INSTALLATION_ID is required for GitHub App access (find it in the app's install URL)."
    [ -n "$CODEBOX_GITHUB_APP_KEY" ] || codebox_die "CODEBOX_GITHUB_APP_KEY must point at the app's private-key .pem file on this machine."
    for v in "$CODEBOX_GITHUB_APP_ID" "$CODEBOX_GITHUB_APP_INSTALLATION_ID"; do
      case "$v" in
        *[!0-9]*) codebox_die "CODEBOX_GITHUB_APP_ID and CODEBOX_GITHUB_APP_INSTALLATION_ID must be numeric; got '$v'." ;;
      esac
    done
    [ -f "$CODEBOX_GITHUB_APP_KEY" ] || codebox_die "GitHub App key not found: $CODEBOX_GITHUB_APP_KEY"
  fi

  if [ -n "$CODEBOX_GITHUB_TOKEN_FILE" ]; then
    [ -f "$CODEBOX_GITHUB_TOKEN_FILE" ] || codebox_die "GitHub token file not found: $CODEBOX_GITHUB_TOKEN_FILE"
    [ -s "$CODEBOX_GITHUB_TOKEN_FILE" ] || codebox_die "GitHub token file is empty: $CODEBOX_GITHUB_TOKEN_FILE"
  fi

  if [ -n "$CODEBOX_GITHUB_BOT_USER_ID" ]; then
    case "$CODEBOX_GITHUB_BOT_USER_ID" in
      *[!0-9]*) codebox_die "CODEBOX_GITHUB_BOT_USER_ID must be the bot's numeric user id (not the app id); got '$CODEBOX_GITHUB_BOT_USER_ID'." ;;
    esac
  fi

  # Each entry has to be owner/name: it is matched against what git and gh report, and a
  # near-miss would silently downgrade the agent to read-only on the repo it needs to push.
  if [ -n "$CODEBOX_GITHUB_WRITE_REPOS" ]; then
    local IFS=','   # restored when this function returns
    for v in $CODEBOX_GITHUB_WRITE_REPOS; do
      v="${v//[[:space:]]/}"
      [ -n "$v" ] || continue
      case "$v" in
        *[!A-Za-z0-9._/-]*) codebox_die "CODEBOX_GITHUB_WRITE_REPOS has characters that are not valid in a repository: '$v'" ;;
        */*/*|/*|*/)        codebox_die "CODEBOX_GITHUB_WRITE_REPOS entries must be owner/name; got '$v'" ;;
        */*)                ;;
        *)                  codebox_die "CODEBOX_GITHUB_WRITE_REPOS entries must be owner/name; got '$v'" ;;
      esac
    done
  fi

  # These reach the box inside a single-quoted command, so reject quoting breakers.
  for v in "$CODEBOX_GITHUB_BOT_NAME" "$CODEBOX_GIT_AGENT_NAME" "$CODEBOX_GIT_AGENT_EMAIL"; do
    case "$v" in
      *[\'\"\`\$\\]*) codebox_die "quotes, backslashes and \$ are not allowed in the GitHub identity settings; got '$v'." ;;
    esac
  done
}
