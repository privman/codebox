#!/usr/bin/env bash
# Installed on the box as ~/.local/bin/git-credential-codebox, and wired to
# github.com only (see vm/bootstrap.sh). Hands git a short-lived GitHub App
# installation token so `git push` works with no stored password anywhere.
set -uo pipefail

# Git writes the credential request on stdin as key=value lines. We read it for `path`,
# which names the repository being reached — that is what lets codebox-gh-token decide
# whether this call gets a write-scoped or a read-only token. git only sends `path` when
# credential.useHttpPath is on, which bootstrap.sh sets for github.com; without it the
# request carries just the host and every repo would look alike.
repo=""
while IFS='=' read -r key value; do
  [ -n "$key" ] || continue
  if [ "$key" = "path" ]; then
    repo="${value%.git}"
  fi
done

# Only `get` is meaningful: tokens are minted on demand, so there is nothing to
# store and nothing to erase.
[ "${1:-}" = "get" ] || exit 0

minter="$(dirname "$0")/codebox-gh-token"
if [ -n "$repo" ]; then
  token="$("$minter" --repo "$repo")" || exit 1   # the minter explained itself on stderr
else
  token="$("$minter")" || exit 1
fi

printf 'username=x-access-token\npassword=%s\n' "$token"
