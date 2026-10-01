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
# Boot disk type. pd-balanced suits the older families; the current generations (C4, N4,
# M4) do not accept Persistent Disk at all and need hyperdisk-balanced, so the machine
# type and this have to be chosen together — a mismatch fails at create, not at boot.
: "${CODEBOX_DISK_TYPE:=pd-balanced}"
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

# Is the file-transfer pair switched on at all?
codebox_sync_enabled() {
  case "${CODEBOX_SYNC_DIR:-}" in
    ""|off|none|no) return 1 ;;
    *) return 0 ;;
  esac
}

# Where the pair lives in the box: inside the checkout, so it sits in the editor's file
# explorer beside the code. Falls back to the home directory when there is no repo to be
# inside of. The home is the agent's when the uid split is on, because the agent is the
# only thing in the box that reads or writes these.
codebox_sync_remote_dir() {
  local home repo
  codebox_sync_enabled || return 0
  if [ -n "${CODEBOX_SYNC_REMOTE_DIR:-}" ]; then
    printf '%s' "$CODEBOX_SYNC_REMOTE_DIR"
    return 0
  fi
  if [ -n "${CODEBOX_AGENT_USER:-}" ]; then
    home="/home/${CODEBOX_AGENT_USER}"
  else
    home="/home/$(codebox_sync_remote_user)"
  fi
  repo="$(codebox_repo_dir_name)"
  if [ -n "$repo" ]; then
    printf '%s/%s/.codebox/sync' "$home" "$repo"
  else
    printf '%s/.codebox/sync' "$home"
  fi
}

# Absolute path of the local half, created if missing.
codebox_sync_local_dir() {
  local path="${CODEBOX_SYNC_DIR:-}"
  codebox_sync_enabled || return 0
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
  # Resolved after creating it, so the default './.codebox/sync' reads as a real path in
  # the log lines rather than carrying a './' through the middle of it.
  (cd "$path" && pwd)
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
  codebox_sync_enabled || return 0
  local_dir="$(codebox_sync_local_dir)" || return 1
  remote_dir="$(codebox_sync_remote_dir)"
  rsync -rlptz --delete -e "$(codebox_sync_rsh)" \
    "$(codebox_sync_remote_user)@$CODEBOX_INSTANCE:$remote_dir/download/" \
    "$local_dir/download/"
}

# Push our upload/ into the box's.
codebox_sync_push() {
  local local_dir remote_dir
  codebox_sync_enabled || return 0
  local_dir="$(codebox_sync_local_dir)" || return 1
  remote_dir="$(codebox_sync_remote_dir)"
  rsync -rlptz --delete -e "$(codebox_sync_rsh)" \
    "$local_dir/upload/" \
    "$(codebox_sync_remote_user)@$CODEBOX_INSTANCE:$remote_dir/upload/"
}

# Cheap local fingerprint of the upload directory, so `connect` can notice you dropped
# something in without going near the network.
codebox_sync_upload_fingerprint() {
  local local_dir
  codebox_sync_enabled || return 0
  local_dir="$(codebox_sync_local_dir)" || return 0
  find "$local_dir/upload" -type f -exec ls -ld {} + 2>/dev/null | cksum
}

# Sync is on unless it was turned off, so a machine without rsync must not be stopped from
# connecting over it — say what is missing and carry on without the transfer directories.
codebox_check_rsync() {
  codebox_sync_enabled || return 0
  command -v rsync >/dev/null 2>&1 && return 0
  codebox_warn "rsync is not installed, so the download/ and upload/ directories are off."
  codebox_warn "Install rsync, or set CODEBOX_SYNC_DIR=\"off\" to stop mentioning it."
  CODEBOX_SYNC_DIR="off"
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

# ZONE_RESOURCE_POOL_EXHAUSTED is the zone momentarily having no host free for this
# machine type. gcloud answers it with "try a different zone", which is not advice a
# suspended box can take: a saved RAM image can only be restored onto the same machine
# type in the same zone, so while the state exists neither is changeable. Waiting is the
# only move that keeps it — and capacity churns on a scale of minutes — so retry quietly
# for a while before telling anybody there is a problem.
: "${CODEBOX_CAPACITY_RETRY_MIN:=10}"
: "${CODEBOX_CAPACITY_RETRY_INTERVAL_SEC:=20}"

# What to say once the waiting has not paid off. Every way out of an exhausted pool
# discards the suspended RAM state, so spell the choice out instead of leaving the raw
# "try a different zone" standing as if it were free: the boot disk survives all of them,
# the running processes survive none.
codebox_capacity_die() {
  local verb="$1"
  codebox_warn "Zone $CODEBOX_ZONE has no $CODEBOX_MACHINE_TYPE capacity (still exhausted after ${CODEBOX_CAPACITY_RETRY_MIN} min)."
  if [ "$verb" = resume ]; then
    codebox_warn "The box is suspended, so it can only resume onto this exact machine type in this exact"
    codebox_warn "zone. Either wait for the pool, or give up the saved RAM state — the disk is kept either way:"
    codebox_warn "  wait longer      codebox resume   (or CODEBOX_CAPACITY_RETRY_MIN=60 codebox resume)"
    codebox_warn "  another machine  codebox stop, then:"
    codebox_warn "                   gcloud compute instances set-machine-type $CODEBOX_INSTANCE --project $CODEBOX_PROJECT --zone $CODEBOX_ZONE --machine-type n2-standard-4"
    codebox_warn "                   codebox start   (families need different host platforms, so they run out separately;"
    codebox_warn "                                    e2 is the cheapest and most defaulted-to, so it goes first — but"
    codebox_warn "                                    nothing on-demand is guaranteed. Also set CODEBOX_MACHINE_TYPE,"
    codebox_warn "                                    which is only read at create time, so codebox.env would still say e2.)"
    codebox_warn "  another zone     codebox destroy, set CODEBOX_ZONE, codebox create (rebuilds from the repo)"
  else
    codebox_warn "Either retry, change to a machine type whose pool is not dry, or move CODEBOX_ZONE and"
    codebox_warn "recreate the box. Note that 'set-machine-type' can only reach families this box's boot"
    codebox_warn "disk suits: a pd-balanced disk rules out c4/n4/m4, which take Hyperdisk only, so those"
    codebox_warn "are a migration rather than a setting."
  fi
  codebox_warn "'codebox capacity' probes which machine types this zone can actually supply right now."
  codebox_die "could not $verb '$CODEBOX_INSTANCE' in $CODEBOX_ZONE."
}

# resume/start, retrying while the only thing wrong is the zone being out of capacity.
# Any other failure is reported and returned immediately — a wrong machine type or a
# revoked permission does not become true by being asked again.
codebox_power_on() {
  local verb="$1" out rc deadline
  deadline=$(( $(date +%s) + CODEBOX_CAPACITY_RETRY_MIN * 60 ))
  while :; do
    rc=0
    out="$(codebox_gcloud compute instances "$verb" "$CODEBOX_INSTANCE" \
             --zone "$CODEBOX_ZONE" 2>&1)" || rc=$?
    # Captured rather than streamed so the reason can be read; echoed either way, because
    # a progress line on success is what the caller has always seen. `&&` chains are out:
    # a false test under `set -e` would take the whole script down with it.
    if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fi
    if [ "$rc" -eq 0 ]; then return 0; fi
    case "$out" in
      *ZONE_RESOURCE_POOL_EXHAUSTED*) ;;
      *) return "$rc" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || codebox_capacity_die "$verb"
    codebox_info "Zone $CODEBOX_ZONE is out of $CODEBOX_MACHINE_TYPE capacity; retrying in ${CODEBOX_CAPACITY_RETRY_INTERVAL_SEC}s ..."
    sleep "$CODEBOX_CAPACITY_RETRY_INTERVAL_SEC"
  done
}

# Bring the instance up to RUNNING from whatever state it's in: resume if it's
# SUSPENDED (restoring running processes), otherwise start. No-op if already RUNNING.
codebox_start_or_resume() {
  case "$1" in
    RUNNING)   return 0 ;;
    SUSPENDED)
      codebox_info "Instance is suspended; resuming (running processes are restored) ..."
      codebox_power_on resume ;;
    *)
      codebox_info "Instance status is $1; starting ..."
      codebox_power_on start ;;
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
