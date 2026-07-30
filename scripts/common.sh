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
# Priority: $CODEBOX_ENV, ./codebox.env, <repo>/codebox.env, ~/.config/codebox/codebox.env.
# The last one is the fallback for installs from Homebrew or apt, where CODEBOX_ROOT is a
# read-only system directory and there is no checkout to keep a config in.
_codebox_load_env() {
  local candidate
  for candidate in "${CODEBOX_ENV:-}" "$PWD/codebox.env" "$CODEBOX_ROOT/codebox.env" \
                   "${XDG_CONFIG_HOME:-$HOME/.config}/codebox/codebox.env"; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate" ]; then
      set -a
      # shellcheck disable=SC1090
      . "$candidate"
      set +a
      CODEBOX_ENV_FILE="$candidate"
      return 0
    fi
  done
  return 0
}
_codebox_load_env

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
: "${CODEBOX_CLAUDE_TOKEN_FILE:=}"
: "${CODEBOX_AGENT_PERMISSION_MODE:=}"
: "${CODEBOX_AGENT_DENY_TOOLS:=}"
: "${CODEBOX_AGENT_ALLOW_TOOLS:=}"
: "${CODEBOX_GIT_AGENT_NAME:=}"
: "${CODEBOX_GIT_AGENT_EMAIL:=}"

# --- helpers -------------------------------------------------------------
codebox_die()  { printf 'codebox: %s\n' "$*" >&2; exit 1; }
codebox_info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
codebox_warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

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
