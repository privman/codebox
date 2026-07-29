#!/usr/bin/env bash
# Installed on the box as ~/.local/bin/codebox-gh-token.
#
# Prints a GitHub App *installation* token on stdout and nothing else — it is consumed by
# the git credential helper and the `gh` shim, so any stray output would corrupt their
# protocol. Tokens are valid for one hour; we cache for 45 minutes so a burst of git
# operations doesn't mint one per call.
#
# Usage:
#   codebox-gh-token                  a token for whatever scope the caller has not named
#   codebox-gh-token --repo owner/name  a token scoped to that one repository
#   codebox-gh-token --jwt            the app JWT, for endpoints that must be called as the
#                                     app itself rather than as the installation (GET /app)
#
# Scoping. With WRITE_REPOS set, one installation serves two access levels: the listed
# repositories get the installation's full permissions but only on themselves, and
# everything else gets a read-only token across all installed repositories. GitHub enforces
# both narrowings — `repositories` and `permissions` on the token request can only ever
# reduce what the installation already grants, never extend it.
#
# The repository argument is therefore untrusted input and safe to treat as such: a caller
# that names a repo it should not write to gets a read-only token for it, and a caller that
# lies about which repo it is pushing to gets a token that only works on the repo it named.
# There is no argument that yields write access to something outside WRITE_REPOS.
set -euo pipefail

die() { echo "codebox-gh-token: $*" >&2; exit 1; }

# CODEBOX_GH_APP_ENV lets a test point this at another config. It is deliberately ignored
# when running as another user (the privilege-separated setup, where the caller is the
# agent and must not be able to redirect us at a key or app of its choosing).
conf="$HOME/.config/codebox/gh-app.env"
if [ -n "${CODEBOX_GH_APP_ENV:-}" ]; then
  [ -z "${SUDO_USER:-}" ] || die "CODEBOX_GH_APP_ENV is not honoured under sudo"
  conf="$CODEBOX_GH_APP_ENV"
fi
[ -f "$conf" ] || die "$conf not found; re-run 'codebox bootstrap'"
# shellcheck disable=SC1090
. "$conf"   # APP_ID, INSTALLATION_ID, PEM, WRITE_REPOS
: "${PEM:=$HOME/.config/codebox/gh-app.pem}"
: "${WRITE_REPOS:=}"
[ -f "$PEM" ] || die "private key $PEM not found"

# --- what was asked for --------------------------------------------------
mode="token"
repo=""
case "${1:-}" in
  "")      ;;
  --jwt)   mode="jwt" ;;
  --repo)  repo="${2:-}"; [ -n "$repo" ] || die "--repo needs an owner/name argument" ;;
  # Anything else is a typo, and guessing would hand back the wrong credential.
  *)       die "unknown option '$1' (expected --repo owner/name, --jwt, or no argument)" ;;
esac
if [ -n "$repo" ]; then
  case "$repo" in
    */*/*|/*|*/) die "--repo must be owner/name; got '$repo'" ;;
    *[!A-Za-z0-9._/-]*) die "--repo has characters that are not valid in a repository name: '$repo'" ;;
    */*) ;;
    *) die "--repo must be owner/name; got '$repo'" ;;
  esac
fi

# --- decide the scope ----------------------------------------------------
# scope is both the policy decision and the cache key.
lower() { tr '[:upper:]' '[:lower:]'; }
if [ -z "$WRITE_REPOS" ]; then
  # No policy configured: behave as codebox always has, and hand out a token as broad as
  # the installation itself.
  scope="installation"
elif [ -n "$repo" ] && printf ',%s,' "$(printf '%s' "$WRITE_REPOS" | lower | tr -d '[:space:]')" \
       | grep -qF ",$(printf '%s' "$repo" | lower),"; then
  scope="write:$repo"
else
  scope="read"
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/codebox"
mkdir -p "$cache_dir"
chmod 700 "$cache_dir"
# One cache file per scope: a single file cannot hold tokens of differing reach, and
# serving the wrong one is exactly the bug this design has to avoid.
cache="$cache_dir/token-$(printf '%s' "$scope" | tr -c 'A-Za-z0-9._-' '_')"

# Reuse a cached token while it still has comfortable life left. Delete the cache files to
# force fresh ones (e.g. after revoking the installation).
#
# Installation tokens only. A JWT is signed locally in a millisecond and lives nine
# minutes, so there is nothing worth caching — and answering --jwt from this cache would
# return an installation token to a caller that asked for a JWT, which GitHub rejects with
# a 401 on the endpoints that need one.
if [ "$mode" = "token" ] && [ -s "$cache" ]; then
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

if [ "$mode" = "jwt" ]; then
  printf '%s\n' "$jwt"
  exit 0
fi

# --- mint ----------------------------------------------------------------
# The request body is what does the narrowing:
#   write:<repo>  only `repositories`, so the token keeps the installation's permissions
#                 but reaches one repo. Not naming permissions is deliberate — it avoids
#                 having to mirror the app's grant set here, and asking for a permission
#                 the installation lacks is a 422.
#   read          only `permissions`, so the token reaches every installed repository but
#                 can only read.
case "$scope" in
  installation) body='{}' ;;
  write:*)      body="$(jq -nc --arg r "${scope#write:}" '{repositories: [$r | split("/") | .[1]]}')" ;;
  read)         body='{"permissions":{"contents":"read","metadata":"read"}}' ;;
esac

response="$(curl -sf -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -d "$body" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")" || true
token="$(printf '%s' "$response" | jq -r '.token // empty' 2>/dev/null || true)"

if [ -z "$token" ]; then
  echo "codebox-gh-token: could not mint an installation token (scope: $scope)." >&2
  echo "  Check CODEBOX_GITHUB_APP_ID / CODEBOX_GITHUB_APP_INSTALLATION_ID and that the" >&2
  echo "  private key belongs to that app and the app is still installed on the repo." >&2
  case "$scope" in
    write:*) echo "  For a scoped token the app must also be installed on ${scope#write:} itself." >&2 ;;
    read)    echo "  A read-only token needs the app to grant Contents: Read (or Read & write)." >&2 ;;
  esac
  exit 1
fi

umask 077
printf '%s\n' "$token" > "$cache"
printf '%s\n' "$token"
