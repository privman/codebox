#!/usr/bin/env bash
# Build the release artifacts into dist/:
#
#   codebox                    self-extracting bundle (chmod +x and run; no install)
#   codebox-<version>.tar.gz   plain source tree (what the Homebrew formula fetches)
#   codebox_<version>_all.deb  Debian package (/usr/lib/codebox + /usr/bin symlink)
#   SHA256SUMS                 checksums for all of the above
#
# The release workflow runs this, but it is a normal script: run it locally to check
# a release before tagging one. Usage: packaging/build.sh [version]
# With no argument the version comes from the VERSION file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

die() { printf 'build: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }

version="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version must look like MAJOR.MINOR.PATCH; got '$version'" ;;
esac

# What ships. Everything a codebox install needs at runtime, and nothing that only
# matters to someone hacking on the repo (CLAUDE.md, packaging/, .github/).
PAYLOAD_PATHS=(bin scripts vm docker .dockerignore VERSION codebox.env.example README.md)

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
tree="$stage/codebox-$version"
mkdir -p "$tree"

for path in "${PAYLOAD_PATHS[@]}"; do
  [ -e "$ROOT/$path" ] || die "missing from the working tree: $path"
  cp -R "$ROOT/$path" "$tree/"
done
# The version argument wins over the file, so a test build is self-consistent.
printf '%s\n' "$version" > "$tree/VERSION"
chmod 755 "$tree/bin/codebox"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1  # macOS
  fi
}

# --- source tarball ------------------------------------------------------
log "Building codebox-$version.tar.gz ..."
tar -czf "$DIST/codebox-$version.tar.gz" -C "$stage" "codebox-$version"

# --- self-extracting bundle ----------------------------------------------
log "Building the standalone bundle ..."
# Payload holds the tree's *contents*, so it unpacks straight into the cache dir.
tar -czf "$stage/payload.tgz" -C "$tree" .
bundle_id="$version-$(sha256 "$stage/payload.tgz" | cut -c1-12)"

sed -e "s/@VERSION@/$version/g" -e "s/@BUNDLE_ID@/$bundle_id/g" \
  "$HERE/bundle-header.sh" > "$DIST/codebox"
cat "$stage/payload.tgz" >> "$DIST/codebox"
chmod 755 "$DIST/codebox"

# A bundle that cannot report its own version is broken; catch that here rather
# than in someone's terminal.
built_version="$(CODEBOX_CACHE_DIR="$stage/cache" "$DIST/codebox" version)"
[ "$built_version" = "codebox $version" ] || \
  die "bundle self-test failed: 'codebox version' said '$built_version'"

# --- debian package ------------------------------------------------------
if command -v dpkg-deb >/dev/null 2>&1; then
  log "Building codebox_${version}_all.deb ..."
  deb="$stage/deb"
  mkdir -p "$deb/DEBIAN" "$deb/usr/lib/codebox" "$deb/usr/bin" "$deb/usr/share/doc/codebox"
  cp -R "$tree/." "$deb/usr/lib/codebox/"
  mv "$deb/usr/lib/codebox/README.md" "$deb/usr/share/doc/codebox/README.md"
  # Relative link: resolves to /usr/lib/codebox/bin/codebox, and bin/codebox walks
  # back through it to find its own tree.
  ln -s ../lib/codebox/bin/codebox "$deb/usr/bin/codebox"

  cat > "$deb/DEBIAN/control" <<EOF
Package: codebox
Version: $version
Section: utils
Priority: optional
Architecture: all
Depends: bash (>= 4.0), coreutils, openssh-client
Maintainer: codebox maintainers <codebox@users.noreply.github.com>
Homepage: https://github.com/privman/codebox
Description: Manage a cloud dev VM for Claude Code and code-server
 codebox provisions and drives a single cloud VM running code-server (VS Code in
 the browser) and Claude Code, reached from your laptop over an IAP tunnel.
 .
 The Google Cloud SDK (gcloud) must be installed separately; it is not packaged
 in Debian or Ubuntu.
EOF

  # --root-owner-group avoids needing fakeroot to get root-owned files.
  dpkg-deb --root-owner-group --build "$deb" "$DIST/codebox_${version}_all.deb" >/dev/null
else
  log "dpkg-deb not found; skipping the .deb (it is built in CI)."
fi

# --- checksums -----------------------------------------------------------
(
  cd "$DIST"
  for f in *; do
    [ "$f" = SHA256SUMS ] && continue
    printf '%s  %s\n' "$(sha256 "$f")" "$f"
  done > SHA256SUMS
)

log "Artifacts in dist/:"
ls -1sh "$DIST" >&2
