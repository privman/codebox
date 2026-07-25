#!/usr/bin/env bash
# Installed on the VM as ~/.local/bin/gh, ahead of the real gh on PATH.
#
# Runs the real gh with a freshly minted GitHub App token, so `gh pr create` acts
# as the app's bot account and no long-lived credential is ever stored in
# ~/.config/gh. Tokens expire hourly, which a stored `gh auth login` would not.
set -euo pipefail

real_gh=/usr/bin/gh
[ -x "$real_gh" ] || { echo "gh: real gh not found at $real_gh" >&2; exit 127; }

token="$("$(dirname "$0")/codebox-gh-token")"
exec env GH_TOKEN="$token" "$real_gh" "$@"
