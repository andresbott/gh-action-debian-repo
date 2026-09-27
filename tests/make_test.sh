#!/usr/bin/env bash
# End to end through the Makefile, run from an instance directory the way a
# repository maintainer uses it: key -> add -> register -> publish -> verify ->
# preview, plus the key-rotation guard, the example instance and an instance
# Makefile that includes the engine's.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need make dpkg-deb apt-ftparchive gpg gpgv jq
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
unset INSTANCE SITE GNUPGHOME THEME
m(){ make --no-print-directory -f "$ROOT/Makefile" -C "$inst" KEY_EMAIL=test@example.org "$@"; }

inst="$tmp/acme-debs"; mkdir -p "$inst"
printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64"\n' > "$tmp/d.conf"
mkdir -p "$inst/conf"; cp "$tmp/d.conf" "$inst/conf/dists.conf"

m build >/dev/null 2>&1 && bad "build without a key must fail" || ok "build refuses without a key"
m key >/dev/null 2>&1 && [ -d "$inst/.gnupg-repo" ] && ok "make key -> instance-local keyring" || bad "make key failed"
m key >/dev/null 2>&1 && bad "second 'make key' must refuse" || ok "second 'make key' refuses"

m add DEB="$(make_deb "$tmp/b" widget 1.0 amd64 w)" >/dev/null && [ -f "$inst/debs/widget_1.0_w_amd64.deb" ] \
  && ok "make add -> debs/" || bad "make add"
m add DEB="$(make_deb "$tmp/b" gadget 2.0 amd64 g)" RELEASE=trixie >/dev/null && [ -f "$inst/debs/trixie/gadget_2.0_g_amd64.deb" ] \
  && ok "make add RELEASE= -> debs/<release>/" || bad "make add RELEASE="
m add DEB="$tmp/b/gadget_2.0_g_amd64.deb" RELEASE=bogus >/dev/null 2>&1 && bad "make add accepted an unknown RELEASE" || ok "make add rejects an unknown RELEASE"

make_deb "$tmp/dist" tool 0.1 amd64 t >/dev/null
( cd "$inst" && m register NAME=tool REPO=acme/tool TAG=v0.1 DIST="$tmp/dist" >/dev/null ) \
  && jq -e '.name=="tool"' "$inst/packages/tool.json" >/dev/null && ok "make register -> packages/tool.json" || bad "make register"
rm -f "$inst/packages/tool.json"   # its URL is not downloadable here

if m publish >/dev/null 2>&1; then ok "make publish"; else bad "make publish: $(m publish 2>&1 | tail -3)"; fi
[ -f "$inst/_site/acme-debs-archive-keyring.gpg" ] && [ -f "$inst/_site/acme-debs.sources" ] \
  && ok "identity derived from the instance directory" || bad "keyring/sources not named after the instance"
out="$(m verify 2>&1)" && ok "make verify" || bad "make verify: $out"
printf '%s' "$out" | grep -q 'stable signature OK' || bad "verify must cover the alias suites"

# a tampered Release must fail verify
cp "$inst/_site/dists/trixie/InRelease" "$tmp/ir"; sed -i 's/^Suite: trixie/Suite: evil/' "$inst/_site/dists/trixie/InRelease"
m verify >/dev/null 2>&1 && bad "verify accepted a tampered InRelease" || ok "verify rejects a tampered InRelease"
cp "$tmp/ir" "$inst/_site/dists/trixie/InRelease"

# rotation: a second key signs alongside the first and both are published
m key ROTATE=1 KEY_EMAIL=new@example.org >/dev/null 2>&1 && m build >/dev/null 2>&1 && m verify >/dev/null 2>&1 \
  && [ "$(gpg --show-keys --with-colons "$inst/_site/acme-debs-archive-keyring.gpg" 2>/dev/null | grep -c '^pub')" = 2 ] \
  && ok "key rotation: two keys sign and are published" || bad "key rotation"

# preview: the built site when it has packages, a demo page otherwise
m preview THEME=teal >/dev/null 2>&1 && grep -q -- '--accent:#33D6B5' "$inst/_site/index.html" && ok "preview re-renders the built site" || bad "preview of the built site"
m clean >/dev/null; [ ! -d "$inst/_site" ] && ok "make clean" || bad "make clean"
m preview >/dev/null 2>&1 && grep -q 'Demo preview' "$inst/.cache/preview/index.html" \
  && ok "preview of an empty repo renders the demo" || bad "demo preview"

# the engine checkout builds its bundled example instance
[ "$(make --no-print-directory -C "$ROOT" help 2>/dev/null | sed -n 2p)" = "instance: $ROOT/example" ] \
  && ok "engine checkout defaults to example/" || bad "engine checkout instance"
# an instance's own Makefile can include the engine's
inc="$tmp/inc"; mkdir -p "$inc"; printf 'include %s/Makefile\n' "$ROOT" > "$inc/Makefile"
[ "$(make --no-print-directory -C "$inc" help 2>/dev/null | sed -n 1,2p | tr '\n' '|')" = "engine:   $ROOT|instance: $inc|" ] \
  && make --no-print-directory -C "$inc" validate >/dev/null 2>&1 \
  && ok "include <engine>/Makefile from an instance" || bad "include of the engine Makefile"
exa="$tmp/example"; cp -r "$ROOT/example" "$exa"; rm -rf "$exa/debs" "$exa/_site"
if make --no-print-directory -C "$ROOT" INSTANCE="$exa" GNUPGHOME="$tmp/exg" KEY_EMAIL=t@example.org \
        EXAMPLE_DEBS="$exa/debs" key example-debs >/dev/null 2>&1 \
   && make --no-print-directory -C "$ROOT" INSTANCE="$exa" GNUPGHOME="$tmp/exg" publish verify >/dev/null 2>&1; then
  ok "example instance: example-debs + publish + verify"
else bad "example instance build"; fi

[ "$fail" = 0 ] && echo "PASS make_test" || { echo "FAIL make_test"; exit 1; }
