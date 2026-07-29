#!/usr/bin/env bash
# Installed on the box as ~/.local/bin/gh, ahead of the real gh on PATH.
#
# Runs the real gh with a freshly minted GitHub App token, so `gh pr create` acts
# as the app's bot account and no long-lived credential is ever stored in
# ~/.config/gh. Tokens expire hourly, which a stored `gh auth login` would not.
set -euo pipefail

real_gh=/usr/bin/gh
[ -x "$real_gh" ] || { echo "gh: real gh not found at $real_gh" >&2; exit 127; }

# Which repository is this command about? gh itself answers that from -R/--repo or, failing
# that, the checkout you are standing in — so we resolve it the same way and pass it to the
# minter, which decides read-only or write from its own allowlist. Guessing wrong is safe:
# an unrecognised repo simply yields a read-only token.
repo=""
prev=""
for arg in "$@"; do
  case "$arg" in
    --repo=*) repo="${arg#--repo=}" ;;
  esac
  # Separate case, not an && chain: under `set -e` a failed test in the loop body would
  # take the whole shim down.
  case "$prev" in
    -R|--repo) repo="$arg" ;;
  esac
  prev="$arg"
done
if [ -z "$repo" ]; then
  remote="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$remote" in
    *github.com[:/]*) repo="${remote##*github.com}"; repo="${repo#[:/]}"; repo="${repo%.git}" ;;
  esac
fi

if [ -n "$repo" ]; then
  token="$("$(dirname "$0")/codebox-gh-token" --repo "$repo")"
else
  token="$("$(dirname "$0")/codebox-gh-token")"
fi
exec env GH_TOKEN="$token" "$real_gh" "$@"
