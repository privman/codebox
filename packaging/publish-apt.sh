#!/usr/bin/env bash
# Publish the apt repository that lives on the gh-pages branch.
#
# Adds dist/codebox_<version>_all.deb to the pool, regenerates the index, and signs
# it so `apt-get update` accepts it. Old versions stay in the pool, so a pin to an
# earlier release keeps resolving.
#
# Usage: packaging/publish-apt.sh <version>
# Environment:
#   GPG_KEY             armored private key used to sign the repo (required)
#   GPG_PASSPHRASE      passphrase for that key, if it has one
#   CODEBOX_APT_REMOTE  git remote to pull gh-pages from and push back to. Unset
#                       (the default) builds the repo in dist/apt and pushes nothing,
#                       which is how you test this locally.
#   CODEBOX_APT_DIR     where to build the tree. Default: dist/apt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

die() { printf 'publish-apt: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }

version="${1:-}"
[ -n "$version" ] || die "usage: packaging/publish-apt.sh <version>"

SUITE="stable"
COMPONENT="main"
# The .deb is Architecture: all, but apt only looks in binary-<arch> directories for
# the architectures it is configured for, so publish the index under each of them.
ARCHES="all amd64 arm64"

deb="$ROOT/dist/codebox_${version}_all.deb"
[ -f "$deb" ] || die "missing $deb — run packaging/build.sh $version first"

[ -n "${GPG_KEY:-}" ] || die "GPG_KEY is empty; an unsigned apt repo is useless to clients"
for tool in dpkg-scanpackages apt-ftparchive gpg; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found (apt-get install dpkg-dev apt-utils gnupg)"
done

repo_slug="${GITHUB_REPOSITORY:-privman/codebox}"
pages_url="https://${repo_slug%%/*}.github.io/${repo_slug##*/}"

# --- import the signing key into a throwaway keyring ---------------------
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s\n' "$GPG_KEY" | gpg --batch --quiet --import
keyid="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
[ -n "$keyid" ] || die "GPG_KEY did not contain a secret key"
log "Signing as $keyid"

gpg_sign() {
  gpg --batch --yes --pinentry-mode loopback \
      --passphrase "${GPG_PASSPHRASE:-}" --local-user "$keyid" "$@"
}

# --- get the current repo state ------------------------------------------
work="${CODEBOX_APT_DIR:-$ROOT/dist/apt}"
remote="${CODEBOX_APT_REMOTE:-}"
rm -rf "$work"
if [ -n "$remote" ]; then
  if git clone --quiet --depth 1 --branch gh-pages --single-branch "$remote" "$work" 2>/dev/null; then
    log "Cloned the existing gh-pages branch."
  else
    log "No gh-pages branch yet — creating one."
    git init --quiet "$work"
    git -C "$work" checkout --quiet -b gh-pages
    git -C "$work" remote add origin "$remote"
  fi
else
  log "No CODEBOX_APT_REMOTE set — building the tree in $work without publishing."
  mkdir -p "$work"
fi

# --- rebuild the index ----------------------------------------------------
mkdir -p "$work/pool/$COMPONENT"
cp "$deb" "$work/pool/$COMPONENT/"

cd "$work"
rm -rf "dists"
mkdir -p "dists/$SUITE/$COMPONENT"

# --multiversion keeps every .deb in the pool listed, not just the newest.
dpkg-scanpackages --multiversion "pool/$COMPONENT" > "$work/Packages.tmp"
for arch in $ARCHES; do
  mkdir -p "dists/$SUITE/$COMPONENT/binary-$arch"
  cp "$work/Packages.tmp" "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
  gzip -9nc "$work/Packages.tmp" > "dists/$SUITE/$COMPONENT/binary-$arch/Packages.gz"
done
rm -f "$work/Packages.tmp"

# Write Release outside the tree first: apt-ftparchive hashes everything it finds
# under dists/, and a half-written Release must not be one of those files.
apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=codebox" \
  -o "APT::FTPArchive::Release::Label=codebox" \
  -o "APT::FTPArchive::Release::Suite=$SUITE" \
  -o "APT::FTPArchive::Release::Codename=$SUITE" \
  -o "APT::FTPArchive::Release::Architectures=$ARCHES" \
  -o "APT::FTPArchive::Release::Components=$COMPONENT" \
  -o "APT::FTPArchive::Release::Description=codebox releases" \
  release "dists/$SUITE" > "$work/Release.tmp"
mv "$work/Release.tmp" "dists/$SUITE/Release"

gpg_sign --armor --detach-sign --output "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
gpg_sign --clearsign --output "dists/$SUITE/InRelease" "dists/$SUITE/Release"

# Dearmored, so it can be dropped straight into /usr/share/keyrings.
gpg --export "$keyid" > codebox.gpg

# GitHub Pages runs Jekyll otherwise, which would swallow parts of the tree.
touch .nojekyll
cat > index.html <<EOF
<!doctype html>
<meta charset="utf-8">
<title>codebox apt repository</title>
<h1>codebox apt repository</h1>
<p>Packages for <a href="https://github.com/$repo_slug">$repo_slug</a>. Latest: <code>$version</code>.</p>
<pre>
curl -fsSL $pages_url/codebox.gpg | sudo tee /usr/share/keyrings/codebox.gpg &gt;/dev/null
echo "deb [signed-by=/usr/share/keyrings/codebox.gpg] $pages_url $SUITE $COMPONENT" \\
  | sudo tee /etc/apt/sources.list.d/codebox.list
sudo apt-get update
sudo apt-get install codebox
</pre>
EOF

log "apt repo built at $work (suite $SUITE, component $COMPONENT)"

# --- publish --------------------------------------------------------------
if [ -n "$remote" ]; then
  git add -A
  if git diff --cached --quiet; then
    log "Nothing changed; not pushing."
  else
    git -c user.name="codebox-release[bot]" \
        -c user.email="codebox@users.noreply.github.com" \
        commit --quiet -m "apt: codebox $version"
    git push --quiet origin gh-pages
    log "Pushed to gh-pages. Repo URL: $pages_url"
  fi
fi
