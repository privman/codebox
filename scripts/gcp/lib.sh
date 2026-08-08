#!/usr/bin/env bash
# GCP-specific configuration and helpers.
# Sourced by every script in this directory; the provider-agnostic half lives in
# ../common.sh.
set -euo pipefail

CODEBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
. "$CODEBOX_SCRIPT_DIR/../common.sh"

# --- GCP-only defaults ---------------------------------------------------
: "${CODEBOX_ZONE:=us-central1-a}"
: "${CODEBOX_MACHINE_TYPE:=e2-standard-4}"
: "${CODEBOX_DISK_SIZE:=50}"
: "${CODEBOX_IMAGE_FAMILY:=debian-12}"
: "${CODEBOX_IMAGE_PROJECT:=debian-cloud}"
: "${CODEBOX_NETWORK_TAG:=codebox}"
: "${CODEBOX_ALLOW_FIREWALL_RULE:=codebox-allow-iap-ssh}"
: "${CODEBOX_DENY_FIREWALL_RULE:=codebox-deny-ssh}"

# IAP's TCP-forwarding source range. Fixed by Google.
CODEBOX_IAP_RANGE="35.235.240.0/20"

# --- moving files between the box and here -------------------------------
# Two one-way directories rather than one shared one. Over a network link a directory
# written from both ends needs conflict resolution, and one-way-each has none to have:
# the agent writes download/ and it lands here, you write upload/ and it lands there.
# Directions are named from this machine's point of view, on both sides.
: "${CODEBOX_SYNC_REMOTE_DIR:=}"

# Where the pair lives in the box. The agent's home when the uid split is on, because the
# agent is the only thing in there that reads or writes them.
codebox_sync_remote_dir() {
  [ -n "${CODEBOX_SYNC_DIR:-}" ] || return 0
  if [ -n "${CODEBOX_SYNC_REMOTE_DIR:-}" ]; then
    printf '%s' "$CODEBOX_SYNC_REMOTE_DIR"
  elif [ -n "${CODEBOX_AGENT_USER:-}" ]; then
    printf '/home/%s/codebox-sync' "$CODEBOX_AGENT_USER"
  else
    printf '~/codebox-sync'
  fi
}

# Absolute path of the local half, created if missing.
codebox_sync_local_dir() {
  local path="${CODEBOX_SYNC_DIR:-}"
  [ -n "$path" ] || return 0
  case "$path" in
    "~")   path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *)  path="$PWD/$path" ;;
  esac
  mkdir -p "$path/download" "$path/upload" || \
    codebox_die "could not create the sync directories under $path"
  printf '%s' "$path"
}

# rsync's transport. `start-iap-tunnel --listen-on-stdin` is built to be a ProxyCommand,
# which is what lets plain ssh — and so rsync — reach a VM that has no public address.
# A fresh tunnel per invocation costs a second or two; the alternative is holding a
# ControlMaster open, which would put a second long-lived connection on port 22 and
# muddy the traffic measurement the idle timer depends on.
codebox_sync_rsh() {
  printf 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ProxyCommand=%s' \
    "'gcloud compute start-iap-tunnel $CODEBOX_INSTANCE %p --listen-on-stdin --project=$CODEBOX_PROJECT --zone=$CODEBOX_ZONE'"
}

# The login name gcloud uses on the VM. `gcloud compute ssh` derives it from the active
# account; asking it directly avoids guessing wrong for a service account.
codebox_sync_remote_user() {
  local account
  account="$(gcloud config get-value account 2>/dev/null || true)"
  [ -n "$account" ] || { printf '%s' "${USER:-}"; return 0; }
  # Same transformation gcloud applies: local part, non-alphanumerics to underscores.
  printf '%s' "${account%%@*}" | tr -c 'a-zA-Z0-9_-' '_'
}

# Pull the box's download/ into ours. --delete so a file removed in the box goes away
# here too; without it the directory only ever grows and stops reflecting the box.
codebox_sync_pull() {
  local local_dir remote_dir
  local_dir="$(codebox_sync_local_dir)" || return 1
  [ -n "$local_dir" ] || return 0
  remote_dir="$(codebox_sync_remote_dir)"
  rsync -rlptz --delete -e "$(codebox_sync_rsh)" \
    "$(codebox_sync_remote_user)@$CODEBOX_INSTANCE:$remote_dir/download/" \
    "$local_dir/download/"
}

# Push our upload/ into the box's.
codebox_sync_push() {
  local local_dir remote_dir
  local_dir="$(codebox_sync_local_dir)" || return 1
  [ -n "$local_dir" ] || return 0
  remote_dir="$(codebox_sync_remote_dir)"
  rsync -rlptz --delete -e "$(codebox_sync_rsh)" \
    "$local_dir/upload/" \
    "$(codebox_sync_remote_user)@$CODEBOX_INSTANCE:$remote_dir/upload/"
}

# Cheap local fingerprint of the upload directory, so `connect` can notice you dropped
# something in without going near the network.
codebox_sync_upload_fingerprint() {
  local local_dir
  local_dir="$(codebox_sync_local_dir)" || return 0
  [ -n "$local_dir" ] || return 0
  find "$local_dir/upload" -type f -exec ls -ld {} + 2>/dev/null | cksum
}

codebox_check_rsync() {
  [ -n "${CODEBOX_SYNC_DIR:-}" ] || return 0
  command -v rsync >/dev/null 2>&1 || \
    codebox_die "CODEBOX_SYNC_DIR is set but rsync is not installed; the file-transfer directories need it."
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

# Poll until the instance leaves a transitional state, so the next API call doesn't race
# it — resuming an instance that is still SUSPENDING is rejected. Echoes the settled
# status; returns non-zero (with the last status seen) if it never settles.
codebox_wait_for_settled() {
  local i status=""
  for i in $(seq 1 60); do   # ~5 minutes at 5s a go
    status="$(codebox_instance_status || true)"
    case "$status" in
      PROVISIONING|STAGING|STOPPING|SUSPENDING|REPAIRING) sleep 5 ;;
      *) printf '%s' "$status"; return 0 ;;
    esac
  done
  printf '%s' "$status"
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
