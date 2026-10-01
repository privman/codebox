#!/usr/bin/env bash
# Find out where a box could actually land right now.
#
# GCP publishes no capacity or stockout API, so the only honest way to learn whether a zone
# can give you a machine type is to ask it for one. This creates a throwaway VM of each
# candidate shape, records whether the create succeeded, and deletes it again — which is a
# real answer about this minute, not a prediction. Capacity episodes last hours, so repeated
# sampling over an afternoon says little more than one sweep does; the use for this is "my
# box will not start, where should I go instead", not forecasting.
#
# What it CANNOT tell you: whether a suspended box will resume. A resume is pinned to that
# box's exact machine type in its exact zone, because the saved RAM image can only be
# restored onto the same hardware. A green row elsewhere is a migration target, not a fix.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_gcloud
codebox_require_project

# Candidates, newest generation first. Each is tried in each zone below.
# e2 is included last as the control: it is the cheapest family and gcloud's own default, so
# it absorbs more bulk demand than anything else and is the likeliest pool to be dry.
: "${CODEBOX_CAPACITY_CANDIDATES:=c4-standard-4 c4d-standard-4 n4-standard-4 n2-standard-4 e2-standard-4}"
: "${CODEBOX_CAPACITY_ZONES:=$CODEBOX_ZONE}"

PROBE_PREFIX="codebox-capacity-probe"
PROBE_LABEL="purpose=codebox-capacity-probe"

# C4, C4D, N4 and M4 take Hyperdisk only — they reject Persistent Disk outright — so the
# boot disk type is a function of the machine type, not a free choice. Getting this wrong
# fails the create for the wrong reason and would read as a stockout.
disk_type_for() {
  case "${1%%-*}" in
    c4|c4d|c4a|n4|n4a|n4d|m4) printf 'hyperdisk-balanced' ;;
    *)                        printf 'pd-balanced' ;;
  esac
}

# Delete anything a previous run left behind. An abandoned probe bills by the hour, so this
# runs before and after the sweep rather than trusting the happy path.
reap() {
  local listing name zone
  listing="$(codebox_gcloud compute instances list \
               --filter="labels.purpose=codebox-capacity-probe" \
               --format='value(name,zone)' 2>/dev/null || true)"
  [ -n "$listing" ] || return 0
  while read -r name zone; do
    [ -n "$name" ] || continue
    codebox_info "Removing leftover probe $name in $zone ..."
    codebox_gcloud compute instances delete "$name" --zone "$zone" --quiet >/dev/null 2>&1 || true
  done <<< "$listing"
}

# probe() reports through these rather than through stdout, because a command substitution
# would run it in a subshell and lose the record of what it created — which is exactly the
# record the teardown depends on.
VERDICT=""
ROW_PROBES=""

probe() {
  local zone="$1" mtype="$2" name disk out rc
  disk="$(disk_type_for "$mtype")"
  name="${PROBE_PREFIX}-$$-${RANDOM}"

  rc=0
  out="$(codebox_gcloud compute instances create "$name" \
           --zone "$zone" --machine-type "$mtype" \
           --boot-disk-type "$disk" --boot-disk-size 10GB \
           --image-family "$CODEBOX_IMAGE_FAMILY" \
           --image-project "$CODEBOX_IMAGE_PROJECT" \
           --labels "$PROBE_LABEL" --no-address 2>&1)" || rc=$?

  # Recorded even when the create reported failure: a rejected create can still leave an
  # instance behind, and a name that was never used costs nothing to try to delete.
  ROW_PROBES="$ROW_PROBES $name"

  if [ "$rc" -eq 0 ]; then
    VERDICT="available"
    return 0
  fi

  case "$out" in
    *ZONE_RESOURCE_POOL_EXHAUSTED*)  VERDICT="EXHAUSTED" ;;
    *QUOTA*|*quota*)                 VERDICT="quota" ;;
    *"not found"*|*"Invalid value"*|*UNSUPPORTED_OPERATION*)
                                     VERDICT="unsupported" ;;
    *)                               VERDICT="error" ;;
  esac
  return 0
}

# Tear down the row's probes in one call. `gcloud compute instances delete` takes a list but
# has no --async, and one call per probe would cost minutes each, so a row goes together.
# Failures are reported rather than swallowed: a teardown that quietly does not happen is
# how a probe becomes a running VM nobody knows about.
teardown_row() {
  local zone="$1" names="$ROW_PROBES"
  ROW_PROBES=""
  # shellcheck disable=SC2086  # deliberate word splitting: a list of instance names
  set -- $names
  [ "$#" -gt 0 ] || return 0
  if ! codebox_gcloud compute instances delete "$@" --zone "$zone" --quiet >/dev/null 2>&1; then
    codebox_warn "could not delete every probe in $zone. Check for leftovers with:"
    codebox_warn "  gcloud compute instances list --project $CODEBOX_PROJECT --filter='labels.purpose=codebox-capacity-probe'"
  fi
}

codebox_info "Probing live capacity by creating and deleting one VM per cell."
codebox_info "Each probe is a real 4-vCPU VM for a minute or two; the cost is pennies."
reap

printf '\n%-18s' "zone"
for mtype in $CODEBOX_CAPACITY_CANDIDATES; do
  printf '%16s' "${mtype%-standard-4}"
done
printf '\n'

for zone in $CODEBOX_CAPACITY_ZONES; do
  printf '%-18s' "$zone"
  for mtype in $CODEBOX_CAPACITY_CANDIDATES; do
    probe "$zone" "$mtype"
    printf '%16s' "$VERDICT"
  done
  printf '\n'
  teardown_row "$zone"
done

printf '\n'
reap
codebox_info "'available' means a VM of that shape could be created in that zone just now."
codebox_info "Moving zone means recreating the box: a disk cannot leave the zone it is in"
codebox_info "except through a snapshot, so treat a move as a migration, not a setting change."
