#!/usr/bin/env bash
# Start the VM if needed, then open an IAP SSH tunnel that forwards the local
# editor port to code-server on the VM. Blocks until you Ctrl-C.
#
# The tunnel is supervised rather than just exec'd:
#   - when it drops — the VM auto-suspends when idle, or the network hiccups — you
#     are asked whether to reconnect instead of being dumped back at the shell;
#   - editing the config file while connected restarts the tunnel, which is how a
#     CODEBOX_ADDITIONAL_PORTS change takes effect without a manual reconnect.
set -euo pipefail

# Which CODEBOX_* settings came from the environment rather than from the config file.
# A reload re-execs this script with everything *else* unset, so deleting a line from
# the file really drops it instead of leaving the exported value behind. This has to
# run before lib.sh, which exports everything it sources.
: "${CODEBOX_INHERITED_VARS:=$(env | sed -n 's/^\(CODEBOX_[A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')}"
export CODEBOX_INHERITED_VARS

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CODEBOX_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# How often to look at the config file while the tunnel is up. Polling keeps this
# dependency-free; inotify/fswatch would mean a different tool per platform.
WATCH_INTERVAL=2

TUNNEL_PID=""
TUNNEL_PGID=""
TUNNEL_ENDED_BY=""   # config-changed | dropped | suspending
OWN_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"

# The VM announces an imminent suspend by appending to a notice file (vm/pre-suspend.sh).
# Rather than poll for it, the tunnel's own SSH session tails that file, so the warning
# arrives on the connection we already hold and costs nothing while nothing happens —
# which matters, because idle detection on the VM now measures traffic and a chatty
# channel would keep the box awake. `-F` waits for a file that does not exist yet, so
# this is silently harmless against a VM whose bootstrap predates the notice.
NOTICE_MARKER="CODEBOX-SUSPENDING"
NOTICE_COMMAND="tail -n 0 -F /run/codebox/notices 2>/dev/null"
NOTICE_OUT="$(mktemp "${TMPDIR:-/tmp}/codebox-notice.XXXXXX")"

codebox_check_gcloud
codebox_require_project

# --- tunnel process -------------------------------------------------------
codebox_kill_tunnel() {
  [ -n "$TUNNEL_PID$TUNNEL_PGID" ] || return 0
  if [ -n "$TUNNEL_PGID" ]; then
    # Signal the whole group rather than just gcloud: an ssh child left in it would
    # keep the local port bound and the next tunnel would fail to bind. A process
    # group outlives its leader while members remain, so this also cleans up after a
    # tunnel whose gcloud has already exited.
    kill -TERM "-$TUNNEL_PGID" 2>/dev/null || :
  else
    kill -TERM "$TUNNEL_PID" 2>/dev/null || :
  fi
  [ -n "$TUNNEL_PID" ] && { wait "$TUNNEL_PID" 2>/dev/null || :; }
  TUNNEL_PID=""
  TUNNEL_PGID=""
}

trap 'codebox_kill_tunnel; rm -f "$NOTICE_OUT"' EXIT
trap 'codebox_kill_tunnel; codebox_info "Disconnected."; exit 0' INT TERM

# Did the VM tell us it is about to suspend?
codebox_suspend_announced() {
  grep -q "$NOTICE_MARKER" "$NOTICE_OUT" 2>/dev/null
}

codebox_start_tunnel() {
  local pgid
  : > "$NOTICE_OUT"
  # `set -m` puts the job in a process group of its own; turning it back off keeps
  # bash from printing asynchronous "Terminated" job notices when we stop it.
  set -m
  codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
    --command="$NOTICE_COMMAND" \
    -- "${forward_args[@]}" </dev/null >"$NOTICE_OUT" &
  TUNNEL_PID=$!
  set +m

  # Only treat it as a group if it really got its own — group-killing our own group
  # would take this script down with it.
  TUNNEL_PGID=""
  pgid="$(ps -o pgid= -p "$TUNNEL_PID" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$pgid" ] && [ "$pgid" = "$TUNNEL_PID" ] && [ "$pgid" != "$OWN_PGID" ]; then
    TUNNEL_PGID="$pgid"
  fi
}

# --- config watching ------------------------------------------------------
# Fingerprint of the config file lib.sh actually loaded. Empty when there is no
# config file (all settings from the environment), which disables watching.
codebox_config_fingerprint() {
  [ -n "${CODEBOX_ENV_FILE:-}" ] || return 0
  # A missing file is reported as no change: editors that save by rename make the
  # file briefly absent, and reloading a config that is not there would just strand
  # us on the defaults.
  [ -f "$CODEBOX_ENV_FILE" ] || return 0
  cksum < "$CODEBOX_ENV_FILE"
}

# Re-exec with the config file as the only source of CODEBOX_* settings, apart from
# the ones the user had in their environment when this started.
codebox_reload() {
  local var unset_args=()
  while IFS= read -r var; do
    [ "$var" = CODEBOX_ENV ] && continue
    case " $CODEBOX_INHERITED_VARS " in
      *" $var "*) continue ;;   # came from the user's shell — leave it alone
    esac
    unset_args+=(-u "$var")
  done < <(env | sed -n 's/^\(CODEBOX_[A-Za-z0-9_]*\)=.*/\1/p')

  codebox_kill_tunnel
  trap - EXIT
  exec env ${unset_args[@]+"${unset_args[@]}"} \
    CODEBOX_ENV="$CODEBOX_ENV_FILE" bash "$CODEBOX_SELF" "$@"
}

# Watch the tunnel until it ends, and record why. Runs in this shell (not a
# subshell) so the traps above and TUNNEL_PID stay in scope.
codebox_supervise() {
  local fingerprint="$1"
  while :; do
    # Checked first, and again after a drop: the notice and the connection dying can
    # land in the same poll window, and the notice is the more informative of the two.
    if codebox_suspend_announced; then
      TUNNEL_ENDED_BY="suspending"
      codebox_kill_tunnel
      return 0
    fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
      codebox_suspend_announced && TUNNEL_ENDED_BY="suspending" || TUNNEL_ENDED_BY="dropped"
      return 0
    fi
    if [ "$(codebox_config_fingerprint)" != "$fingerprint" ]; then
      TUNNEL_ENDED_BY="config-changed"
      codebox_kill_tunnel
      return 0
    fi
    sleep "$WATCH_INTERVAL" || :
  done
}

# --- reconnect prompt -----------------------------------------------------
# Returns 0 to reconnect, 1 to give up. $1 is the instance status, or empty if it
# could not be read.
codebox_ask_reconnect() {
  local status="$1" answer=""
  printf '\n' >&2
  case "$status" in
    ANNOUNCED)
      # The VM warned us before suspending, so we closed the tunnel ourselves rather
      # than having it cut mid-connection. Nothing went wrong here.
      codebox_info "The VM is suspending; the tunnel was closed cleanly at this end."
      codebox_info "Everything running on it is frozen and comes back on resume." ;;
    SUSPENDED)
      if [ "${CODEBOX_IDLE_TIMEOUT_MIN:-0}" != "0" ]; then
        codebox_warn "The VM suspended itself after ${CODEBOX_IDLE_TIMEOUT_MIN} idle minutes, which closed the tunnel."
      else
        codebox_warn "The VM is suspended, which closed the tunnel."
      fi
      codebox_info "Reconnecting resumes it, and anything that was running is still there." ;;
    TERMINATED)
      codebox_warn "The VM is stopped, which closed the tunnel."
      codebox_info "Reconnecting starts it again (processes from the last session are gone)." ;;
    RUNNING)
      codebox_warn "The tunnel closed, but the VM is still running — a network drop or an SSH timeout." ;;
    "")
      codebox_warn "The tunnel closed and the VM's status could not be read (see any error above)." ;;
    *)
      codebox_warn "The tunnel closed; the VM is now $status." ;;
  esac

  if [ ! -t 0 ]; then
    codebox_warn "Not running on a terminal, so not asking — run 'codebox connect' again to reconnect."
    return 1
  fi

  # EOF (Ctrl-D) reads as "no". Anything other than n/no reconnects, so leaning on
  # the return key does the expected thing.
  read -r -p "Reconnect? [Y/n] " answer || return 1
  case "$answer" in
    [Nn]|[Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

# --- main loop ------------------------------------------------------------
while :; do
  status="$(codebox_instance_status)"
  [ -n "$status" ] || codebox_die "instance '$CODEBOX_INSTANCE' not found. Run 'codebox create' first."
  case "$status" in
    # Reconnecting right after a suspend notice lands here: resuming an instance that
    # is still SUSPENDING is rejected, so let the transition finish first.
    PROVISIONING|STAGING|STOPPING|SUSPENDING|REPAIRING)
      codebox_info "Instance is $status; waiting for that to finish ..."
      status="$(codebox_wait_for_settled)" || codebox_die "instance is still $status; try again in a minute." ;;
  esac
  if [ "$status" != "RUNNING" ]; then
    codebox_start_or_resume "$status"
    codebox_wait_for_ssh || codebox_die "timed out waiting for SSH."
  fi

  codebox_info "Fetching code-server password ..."
  password="$(codebox_gcloud compute ssh "$CODEBOX_INSTANCE" --zone "$CODEBOX_ZONE" --tunnel-through-iap \
    --command="awk '/^password:/{print \$2; exit}' ~/.config/code-server/config.yaml" 2>/dev/null || true)"

  # Build the SSH port-forward flags: the editor port first, then any extra dev-server
  # ports from CODEBOX_ADDITIONAL_PORTS. Extras use the same port number both
  # locally and on the VM (unlike the editor's separate local/remote ports).
  # -T rather than -N: the session carries the suspend-notice tail, and -N would tell
  # ssh to ignore the remote command entirely.
  forward_args=(-T -L "${CODEBOX_LOCAL_PORT}:localhost:${CODEBOX_REMOTE_PORT}")
  extra_desc=""
  # Plain assignment, not `local`: a rejected port has to propagate out of the
  # substitution and stop us here (see codebox_additional_ports).
  extra_ports="$(codebox_additional_ports)"
  for _p in $extra_ports; do
    forward_args+=(-L "${_p}:localhost:${_p}")
    extra_desc="${extra_desc} ${_p}"
  done

  cat >&2 <<EOF

  ┌─ codebox ────────────────────────────────────────────────
  │  Editor:    http://localhost:${CODEBOX_LOCAL_PORT}/
  │  Password:  ${password:-<run: cat ~/.config/code-server/config.yaml on the VM>}
  │
  │  Keep this terminal open to hold the tunnel. Ctrl-C to disconnect.
EOF
  if [ -n "${CODEBOX_ENV_FILE:-}" ]; then
    printf '  │  Editing %s reopens the tunnel with the new settings.\n' \
      "$(basename "$CODEBOX_ENV_FILE")" >&2
  fi
  printf '  └──────────────────────────────────────────────────────────\n\n' >&2

  codebox_info "Opening IAP tunnel (localhost:${CODEBOX_LOCAL_PORT} -> VM 127.0.0.1:${CODEBOX_REMOTE_PORT}) ..."
  [ -n "$extra_desc" ] && codebox_info "Also forwarding port(s):${extra_desc} (same port locally and on the VM)."

  codebox_start_tunnel
  codebox_supervise "$(codebox_config_fingerprint)"

  case "$TUNNEL_ENDED_BY" in
    config-changed)
      codebox_info "$CODEBOX_ENV_FILE changed — reopening the tunnel with the new settings."
      codebox_reload "$@" ;;
    suspending)
      codebox_ask_reconnect ANNOUNCED || exit 0 ;;
    dropped)
      # The status query is what tells suspend/stop apart from a plain network drop.
      status="$(codebox_instance_status || true)"
      codebox_ask_reconnect "$status" || exit 0 ;;
  esac
done
