#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
make_instance "$tmp/instance"
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64 arm64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" test@example.org

DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" "$ROOT/scripts/gen-index.sh" "$site"

fail=0
for s in bookworm trixie stable; do
  [ -f "$site/dists/$s/InRelease" ] || { echo "❌ $s/InRelease missing"; fail=1; continue; }
  GNUPGHOME="$GNUPGHOME" gpg --verify "$site/dists/$s/InRelease" >/dev/null 2>&1 || { echo "❌ $s signature bad"; fail=1; }
done
grep -q '^Suite: stable$'    "$site/dists/stable/Release" || { echo "❌ alias Suite wrong"; fail=1; }
grep -q '^Codename: bookworm$' "$site/dists/stable/Release" || { echo "❌ alias Codename wrong"; fail=1; }

# empty-suite: a configured codename that nothing targets must still get a signed Release
confE="$tmp/distsE.conf"; printf 'DISTS="bookworm sid"\nALIASES=""\nARCHES="amd64"\n' > "$confE"
siteE="$tmp/_siteE"; debsE="$tmp/debsE"
make_deb "$debsE/bookworm" widget 1.0 amd64 bk >/dev/null   # bookworm only => sid stays empty
DISTS_CONF="$confE" "$ROOT/scripts/hydrate.sh"   "$siteE" "$debsE"
DISTS_CONF="$confE" "$ROOT/scripts/gen-index.sh" "$siteE"
if [ -f "$siteE/dists/sid/InRelease" ] && gpg --verify "$siteE/dists/sid/InRelease" >/dev/null 2>&1; then
  echo "✅ empty suite sid signed"
else
  echo "❌ empty suite sid must have a verifying InRelease"; fail=1
fi
[ -f "$siteE/dists/sid/main/binary-amd64/Packages" ] || { echo "❌ empty suite sid missing Packages index"; fail=1; }
grep -q '^Suite: sid$' "$siteE/dists/sid/Release" && grep -q '^Codename: sid$' "$siteE/dists/sid/Release" || { echo "❌ sid Release Suite/Codename wrong"; fail=1; }

# --arch filename footgun: a SOURCE .deb whose filename is NOT arch-trailing must still
# be indexed. apt-ftparchive --arch selects debs by filename (*_<arch>.deb / *_all.deb),
# ignoring the control Architecture field, so a source name like widget_9.9_amd64_EXTRA.deb
# (arch not last) would be silently dropped — unless hydrate canonicalizes the pooled
# filename to <Package>_<Version>_<Architecture>.deb (which it does). RED before that fix.
confF="$tmp/distsF.conf"; printf 'DISTS="bookworm"\nALIASES=""\nARCHES="amd64"\n' > "$confF"
siteF="$tmp/_siteF"; debsF="$tmp/debsF"; mkdir -p "$debsF/bookworm"
srcF=$(make_deb "$tmp/buildF" widget 9.9 amd64 EXTRA)          # control Architecture: amd64
mv "$srcF" "$debsF/bookworm/widget_9.9_amd64_EXTRA.deb"        # SOURCE name: arch NOT trailing
DISTS_CONF="$confF" "$ROOT/scripts/hydrate.sh"   "$siteF" "$debsF"
DISTS_CONF="$confF" "$ROOT/scripts/gen-index.sh" "$siteF"
if grep -q '^Package: widget' "$siteF/dists/bookworm/main/binary-amd64/Packages"; then
  echo "✅ non-arch-trailing source name still indexed (pool filename canonicalized)"
else
  echo "❌ non-arch-trailing source name dropped from Packages index"; fail=1
fi

# --- identity + signing ---
# The published keyring and .sources file are generated from the instance
# identity and the keys in GNUPGHOME — nothing is committed. Two usable keys (a
# rotation in progress) both sign and are both published; an expired key in the
# same keyring is skipped instead of breaking the build.
confK="$tmp/distsK.conf"; printf 'DISTS="bookworm"\nALIASES="stable:bookworm"\nARCHES="amd64"\n' > "$confK"
make_instance "$tmp/acme"
printf 'REPO_NAME=acme\nSITE_TITLE="Acme debs"\nREPO_URL=https://apt.example.org/\n' > "$tmp/acme/conf/site.conf"
export GNUPGHOME="$tmp/gnupgK"
make_test_key "$GNUPGHOME" old@example.org; make_test_key "$GNUPGHOME" new@example.org
make_expired_key "$GNUPGHOME" expired@example.org
siteK="$tmp/_siteK"; debsK="$tmp/debsK"; make_deb "$debsK" widget 1.0 amd64 any >/dev/null
DISTS_CONF="$confK" "$ROOT/scripts/hydrate.sh" "$siteK" "$debsK" >/dev/null
if DISTS_CONF="$confK" "$ROOT/scripts/gen-index.sh" "$siteK" >/dev/null 2>&1; then
  echo "✅ build with an expired key present"
else echo "❌ an expired key in GNUPGHOME must be skipped, not fail the build"; fail=1; fi
kr="$siteK/acme-archive-keyring.gpg"
[ -f "$kr" ] && [ -f "$siteK/acme-archive-keyring.asc" ] || { echo "❌ keyring not published under the instance name"; fail=1; }
[ "$(gpg --show-keys --with-colons "$kr" 2>/dev/null | grep -c '^pub')" = 2 ] \
  || { echo "❌ published keyring must hold exactly the 2 usable keys"; fail=1; }
good=$(gpgv --status-fd 1 --keyring "$kr" "$siteK/dists/stable/InRelease" 2>/dev/null | grep -c GOODSIG)
[ "$good" = 2 ] || { echo "❌ InRelease must carry 2 good signatures, got $good"; fail=1; }
gpgv --keyring "$kr" "$siteK/dists/bookworm/Release.gpg" "$siteK/dists/bookworm/Release" >/dev/null 2>&1 \
  || { echo "❌ detached Release.gpg does not verify"; fail=1; }
for f in 'Origin: acme' 'Label: acme' 'Description: Acme debs APT repository' 'Components: main'; do
  grep -qx "$f" "$siteK/dists/bookworm/Release" || { echo "❌ Release lacks '$f'"; fail=1; }
done
src="$siteK/acme.sources"
[ -f "$src" ] && grep -qx 'URIs: https://apt.example.org' "$src" && grep -qx 'Suites: stable' "$src" \
  && grep -qx 'Signed-By: /etc/apt/keyrings/acme-archive-keyring.gpg' "$src" \
  || { echo "❌ acme.sources wrong: $(cat "$src" 2>/dev/null)"; fail=1; }
grep -rqi autobott "$siteK" && { echo "❌ the built site still mentions autobott"; fail=1; }
# SIGNING_KEYS narrows the signers (and the published keyring) to the given keys
SIGNING_KEYS=new@example.org DISTS_CONF="$confK" "$ROOT/scripts/gen-index.sh" "$siteK" >/dev/null 2>&1
good=$(gpgv --status-fd 1 --keyring "$kr" "$siteK/dists/stable/InRelease" 2>/dev/null | grep -c GOODSIG)
[ "$good" = 1 ] || { echo "❌ SIGNING_KEYS=new must sign once, got $good"; fail=1; }
# no usable key: fail loudly, never publish an unsigned repository
export GNUPGHOME="$tmp/gnupgNone"; install -d -m 700 "$GNUPGHOME"; make_expired_key "$GNUPGHOME" x@example.org
if err=$(DISTS_CONF="$confK" "$ROOT/scripts/gen-index.sh" "$siteK" 2>&1); then
  echo "❌ gen-index must fail without a usable key"; fail=1
else
  printf '%s' "$err" | grep -q 'no usable signing key' || { echo "❌ no-key message, got: $err"; fail=1; }
fi

[ "$fail" = 0 ] && echo "PASS gen_index_test" || { echo "FAIL gen_index_test"; exit 1; }
