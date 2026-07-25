#!/usr/bin/env bash
# Installed on the VM as ~/.local/bin/git-credential-codebox, and wired to
# github.com only (see vm/bootstrap.sh). Hands git a short-lived GitHub App
# installation token so `git push` works with no stored password anywhere.
set -uo pipefail

# Git writes the credential request on stdin. We don't need it — the helper is
# scoped to one host — but draining it keeps git from seeing a broken pipe.
cat >/dev/null

# Only `get` is meaningful: tokens are minted on demand, so there is nothing to
# store and nothing to erase.
[ "${1:-}" = "get" ] || exit 0

if ! token="$("$(dirname "$0")/codebox-gh-token")"; then
  exit 1   # codebox-gh-token already explained itself on stderr
fi

printf 'username=x-access-token\npassword=%s\n' "$token"
