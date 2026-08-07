#!/usr/bin/env bash
# Which codebox.env applies.
#
# This is split out of common.sh because bin/codebox needs it *first*: the provider can be
# set in the config, and the dispatcher has to know the provider before it can source a
# provider's lib.sh — which is what pulls common.sh in. Both callers share this one copy so
# the dispatcher can never end up reading a different config than the scripts it execs.

# Echo the config file that applies, or nothing when there is none.
# $1 is the codebox root (the tree holding bin/ and scripts/).
#
# Priority: $CODEBOX_ENV, ./codebox.env, <root>/codebox.env, ~/.config/codebox/codebox.env.
# The last one is the fallback for installs from Homebrew or apt, where the root is a
# read-only system directory and there is no checkout to keep a config in.
#
# Returns 2 when CODEBOX_ENV names a file that is not there. A config named explicitly but
# not present is always a mistake — a typo, or a file that was moved or deleted. Falling
# through to the next candidate would quietly operate on a *different* box than the one
# asked for, which is the worst possible way to be wrong. It returns rather than exits
# because callers run this in a command substitution, where exit would only leave the
# subshell and the caller would carry on with an empty path.
codebox_env_file_path() {
  local root="${1:-}" candidate
  if [ -n "${CODEBOX_ENV:-}" ] && [ ! -f "${CODEBOX_ENV}" ]; then
    printf 'codebox: CODEBOX_ENV names a file that does not exist: %s\n' "$CODEBOX_ENV" >&2
    printf 'codebox: refusing to fall back to another config — fix the path or unset CODEBOX_ENV.\n' >&2
    return 2
  fi
  for candidate in "${CODEBOX_ENV:-}" "$PWD/codebox.env" "${root:+$root/codebox.env}" \
                   "${XDG_CONFIG_HOME:-$HOME/.config}/codebox/codebox.env"; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 0
}
