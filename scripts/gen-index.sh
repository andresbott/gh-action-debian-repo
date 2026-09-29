#!/usr/bin/env bash
# Generate and GPG-sign the APT index for <site>, for every codename in the
# instance's dists.conf (from its hydrated per-codename pool, scripts/hydrate.sh)
# plus a signed tree for every rolling-suite alias, then publish the files a
# client needs next to it — the public keyring (exported from the very keys
# that signed) and a ready-made .sources file — and render the landing page.
# Usage: gen-index.sh <site>
# Env: INSTANCE, DISTS_CONF, SITE_CONF (see instance-lib.sh); GNUPGHOME holding
# the signing key(s). Every usable secret key in GNUPGHOME signs, so a key
# rotation publishes old+new side by side; SIGNING_KEYS="<id>..." narrows that.
set -euo pipefail

SITE="${1:?site dir}"
. "$(dirname "$0")/instance-lib.sh"; instance_init
. "$(dirname "$0")/dists-lib.sh"; dists_load "$DISTS_CONF"
site_load

# fingerprints of the usable (not expired/revoked/disabled/invalid) secret keys
signing_keys() {
  gpg --batch --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '$1=="sec"{want=($2!~/^[erdni]$/); next} want&&$1=="fpr"{print $10; want=0}'
}
# shellcheck disable=SC2206
if [ -n "${SIGNING_KEYS:-}" ]; then KEYS=($SIGNING_KEYS); else mapfile -t KEYS < <(signing_keys); fi
[ ${#KEYS[@]} -gt 0 ] || { echo "❌ no usable signing key in ${GNUPGHOME:-~/.gnupg} (make key, or import one)" >&2; exit 1; }
SIGNERS=(); for k in "${KEYS[@]}"; do SIGNERS+=(--local-user "$k"); done
echo ">> signing with ${#KEYS[@]} key(s): ${KEYS[*]}"

sign_dist() { # <dist-dir>
  gpg --batch --yes "${SIGNERS[@]}" --clearsign -o "$1/InRelease"   "$1/Release"
  gpg --batch --yes "${SIGNERS[@]}" -abs        -o "$1/Release.gpg" "$1/Release"
}

release_file() { # <dist-dir> <suite> <codename>
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="$APT_ORIGIN" \
    -o APT::FTPArchive::Release::Label="$APT_LABEL" \
    -o APT::FTPArchive::Release::Description="$APT_DESCRIPTION" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Suite="$2" \
    -o APT::FTPArchive::Release::Codename="$3" \
    -o APT::FTPArchive::Release::Architectures="$ARCHES" \
    release "$1" > "$1/Release"
}

mkdir -p "$SITE"; rm -rf "$SITE/dists"
(
  cd "$SITE"
  for cn in $DISTS; do
    mkdir -p "pool/$cn/main"
    for arch in $ARCHES; do
      mkdir -p "dists/$cn/main/binary-$arch"
      echo ">> indexing $cn/$arch"
      apt-ftparchive --arch "$arch" packages "pool/$cn/main" > "dists/$cn/main/binary-$arch/Packages"
      gzip -9 -kf "dists/$cn/main/binary-$arch/Packages"
    done
    echo ">> Release + sign: $cn"
    release_file "dists/$cn" "$cn" "$cn"
    sign_dist "dists/$cn"
  done
  while read -r al target; do
    [ -n "$al" ] || continue
    echo ">> alias $al -> $target"
    rm -rf "dists/$al"; mkdir -p "dists/$al/main"
    cp -r "dists/$target/main/binary-"* "dists/$al/main/"
    release_file "dists/$al" "$al" "$target"
    sign_dist "dists/$al"
  done < <(alias_pairs)
)

# static files served from the site root: the public keyring (binary for
# Signed-By, armored for humans) exported from the signing keys themselves, and
# the .sources file the landing page's snippets write
gpg --batch --export "${KEYS[@]}" > "$SITE/$KEYRING_FILE"
gpg --batch --export --armor "${KEYS[@]}" > "$SITE/${KEYRING_FILE%.gpg}.asc"
cat > "$SITE/$SOURCES_FILE" <<EOF
Types: deb
URIs: $REPO_URL
Suites: $SOURCES_SUITE
Components: main
Architectures: $ARCHES
Signed-By: /etc/apt/keyrings/$KEYRING_FILE
EOF
# landing page, with the package listing injected into the "Packages" tab
"$(dirname "$0")/render-index.sh" "$SITE"
touch "$SITE/.nojekyll"

echo "✅ built + signed $SITE/"
