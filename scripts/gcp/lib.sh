#!/usr/bin/env bash
# Shared configuration and helpers for the codebox scripts.
# Sourced by every script in this directory.
set -euo pipefail

CODEBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root is two levels up: scripts/gcp/ -> scripts/ -> repo root.
CODEBOX_ROOT="$(cd "${CODEBOX_SCRIPT_DIR}/../.." && pwd)"

# --- load config ---------------------------------------------------------
# Priority: $CODEBOX_ENV, ./codebox.env, <repo>/codebox.env
_codebox_load_env() {
  local candidate
  for candidate in "${CODEBOX_ENV:-}" "$PWD/codebox.env" "$CODEBOX_ROOT/codebox.env"; do
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

# --- defaults ------------------------------------------------------------
: "${CODEBOX_ZONE:=us-central1-a}"
: "${CODEBOX_INSTANCE:=codebox}"
: "${CODEBOX_MACHINE_TYPE:=e2-standard-4}"
: "${CODEBOX_DISK_SIZE:=50}"
: "${CODEBOX_IMAGE_FAMILY:=debian-12}"
: "${CODEBOX_IMAGE_PROJECT:=debian-cloud}"
: "${CODEBOX_NETWORK_TAG:=codebox}"
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
: "${CODEBOX_GIT_AGENT_NAME:=}"
: "${CODEBOX_GIT_AGENT_EMAIL:=}"
: "${CODEBOX_ALLOW_FIREWALL_RULE:=codebox-allow-iap-ssh}"
: "${CODEBOX_DENY_FIREWALL_RULE:=codebox-deny-ssh}"

# IAP's TCP-forwarding source range. Fixed by Google.
CODEBOX_IAP_RANGE="35.235.240.0/20"

# --- helpers -------------------------------------------------------------
codebox_die()  { printf 'codebox: %s\n' "$*" >&2; exit 1; }
codebox_info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
codebox_warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

# Sanity-check CODEBOX_REPO before we spend minutes creating a VM. The actual URI
# handling (and the clone) happens on the VM in vm/bootstrap.sh; here we only reject
# shapes git wouldn't accept and characters that would break the quoting of the
# remote bootstrap command (and are never valid in a git URI anyway).
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
# git and gh differently on the VM, and quietly preferring one would be a nasty surprise.
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

  # These reach the VM inside a single-quoted remote command, so reject quoting breakers.
  for v in "$CODEBOX_GITHUB_BOT_NAME" "$CODEBOX_GIT_AGENT_NAME" "$CODEBOX_GIT_AGENT_EMAIL"; do
    case "$v" in
      *[\'\"\`\$\\]*) codebox_die "quotes, backslashes and \$ are not allowed in the GitHub identity settings; got '$v'." ;;
    esac
  done
}

codebox_check_gcloud() {
  command -v gcloud >/dev/null 2>&1 || \
    codebox_die "gcloud CLI not found. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
}

codebox_require_project() {
  if [ -z "${CODEBOX_PROJECT:-}" ]; then
    CODEBOX_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  [ -n "${CODEBOX_PROJECT:-}" ] || \
    codebox_die "CODEBOX_PROJECT is not set. Edit codebox.env or run 'gcloud config set project <id>'."
}

# gcloud, always scoped to the configured project.
codebox_gcloud() {
  gcloud --project "$CODEBOX_PROJECT" "$@"
}

# Echo the instance status (RUNNING/TERMINATED/...), or empty if the instance does not
# exist. Returns non-zero (after an explanatory message) when the *lookup itself* fails —
# e.g. no network or expired credentials — so a transient error is never misreported as
# "instance not found". We use `list` rather than `describe` on purpose: `list` exits 0
# with empty output for an absent instance and non-zero only on real errors, whereas
# `describe` exits non-zero for both, making the two indistinguishable.
codebox_instance_status() {
  local out
  if out="$(codebox_gcloud compute instances list \
        --zones "$CODEBOX_ZONE" \
        --filter="name=${CODEBOX_INSTANCE}" \
        --format='value(status)')"; then
    printf '%s' "$out"
    return 0
  fi
  codebox_warn "could not query GCP for instance '$CODEBOX_INSTANCE' (project '$CODEBOX_PROJECT', zone '$CODEBOX_ZONE')."
  codebox_warn "This is usually a connectivity or credentials problem, not a missing VM (see the gcloud error above)."
  codebox_warn "Fix that and retry — do NOT run 'codebox create', which would try to make a second instance."
  return 1
}

# Bring the instance up to RUNNING from whatever state it's in: resume if it's
# SUSPENDED (restoring running processes), otherwise start. No-op if already RUNNING.
codebox_start_or_resume() {
  case "$1" in
    RUNNING)   return 0 ;;
    SUSPENDED)
      codebox_info "Instance is suspended; resuming (running processes are restored) ..."
      codebox_gcloud compute instances resume "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" ;;
    *)
      codebox_info "Instance status is $1; starting ..."
      codebox_gcloud compute instances start "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" ;;
  esac
}

# Wait until SSH-over-IAP succeeds (bootstrap after boot can take a moment).
codebox_wait_for_ssh() {
  local i
  for i in $(seq 1 30); do
    if codebox_gcloud compute ssh "$CODEBOX_INSTANCE" \
         --zone "$CODEBOX_ZONE" --tunnel-through-iap \
         --command="true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}
