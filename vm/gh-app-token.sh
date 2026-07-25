#!/usr/bin/env bash
# Installed on the VM as ~/.local/bin/codebox-gh-token.
#
# Prints a GitHub App *installation* token for this box on stdout and nothing else —
# it is consumed by the git credential helper and the `gh` shim, so any stray output
# would corrupt their protocol. Tokens are valid for one hour; we cache for 45 minutes
# so a burst of git operations doesn't mint one per call.
#
# With --jwt it prints the app JWT instead, for the few endpoints that must be called
# as the app itself rather than as the installation (e.g. GET /app).
set -euo pipefail

conf="${CODEBOX_GH_APP_ENV:-$HOME/.config/codebox/gh-app.env}"
[ -f "$conf" ] || { echo "codebox-gh-token: $conf not found; re-run 'codebox bootstrap'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$conf"   # APP_ID, INSTALLATION_ID, PEM
: "${PEM:=$HOME/.config/codebox/gh-app.pem}"
[ -f "$PEM" ] || { echo "codebox-gh-token: private key $PEM not found" >&2; exit 1; }

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/codebox"
cache="$cache_dir/gh-token"
mkdir -p "$cache_dir"
chmod 700 "$cache_dir"

# Reuse a cached token while it still has comfortable life left. Delete the cache file
# to force a fresh one (e.g. after revoking the installation).
if [ -s "$cache" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -lt 2700 ]; then
    cat "$cache"
    exit 0
  fi
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now="$(date +%s)"
# iat is backdated a minute to tolerate clock skew; GitHub rejects a JWT older than 10 min.
hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
pay="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
sig="$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$PEM" -binary | b64url)"
jwt="$hdr.$pay.$sig"

if [ "${1:-}" = "--jwt" ]; then
  printf '%s\n' "$jwt"
  exit 0
fi

token="$(curl -sf -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
  | jq -r '.token // empty')" || true

if [ -z "$token" ]; then
  echo "codebox-gh-token: could not mint an installation token." >&2
  echo "  Check CODEBOX_GITHUB_APP_ID / CODEBOX_GITHUB_APP_INSTALLATION_ID and that the" >&2
  echo "  private key belongs to that app and the app is still installed on the repo." >&2
  exit 1
fi

umask 077
printf '%s\n' "$token" > "$cache"
printf '%s\n' "$token"
