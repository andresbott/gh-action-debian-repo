#!/usr/bin/env bash
# End to end through the Makefile, run from an instance directory the way a
# repository maintainer uses it: key -> add -> register -> publish -> verify-site ->
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
git init --quiet "$inst"   # an instance is a git checkout: its private key must never show up as committable
m key >/dev/null 2>&1 && [ -d "$inst/.gnupg-repo" ] && ok "make key -> instance-local keyring" || bad "make key failed"
m key >/dev/null 2>&1 && bad "second 'make key' must refuse" || ok "second 'make key' refuses"
m backup-key >/dev/null 2>&1 && [ -s "$inst/.gnupg-repo/signing-key.secret.asc" ] \
  && ok "make backup-key -> inside the keyring directory" || bad "make backup-key: $(ls -A "$inst" "$inst/.gnupg-repo")"
leak="$(git -C "$inst" status --porcelain --untracked-files=all | grep -E '\.gnupg-repo/|\.secret\.asc$')"
[ -z "$leak" ] && ok "keyring and key backup are git-ignored" || bad "private key material committable: $leak"

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
out="$(m verify-site 2>&1)" && ok "make verify-site" || bad "make verify-site: $out"
printf '%s' "$out" | grep -q 'stable signature OK' || bad "verify-site must cover the alias suites"

# a tampered Release must fail verify-site
cp "$inst/_site/dists/trixie/InRelease" "$tmp/ir"; sed -i 's/^Suite: trixie/Suite: evil/' "$inst/_site/dists/trixie/InRelease"
m verify-site >/dev/null 2>&1 && bad "verify-site accepted a tampered InRelease" || ok "verify-site rejects a tampered InRelease"
cp "$tmp/ir" "$inst/_site/dists/trixie/InRelease"

# rotation: a second key signs alongside the first and both are published
m key ROTATE=1 KEY_EMAIL=new@example.org >/dev/null 2>&1 && m build >/dev/null 2>&1 && m verify-site >/dev/null 2>&1 \
  && [ "$(gpg --show-keys --with-colons "$inst/_site/acme-debs-archive-keyring.gpg" 2>/dev/null | grep -c '^pub')" = 2 ] \
  && ok "key rotation: two keys sign and are published" || bad "key rotation"

# preview: the built site when it has packages, a demo page otherwise
m preview THEME=teal >/dev/null 2>&1 && grep -q -- '--accent:#33D6B5' "$inst/_site/index.html" && ok "preview re-renders the built site" || bad "preview of the built site"
m clean >/dev/null; [ ! -d "$inst/_site" ] && ok "make clean" || bad "make clean"
m preview >/dev/null 2>&1 && grep -q 'Demo preview' "$inst/.cache/preview/index.html" \
  && ok "preview of an empty repo renders the demo" || bad "demo preview"

# validate: package files are read from PKG_DIR, as hydrate reads them; with no
# schema validator at all (scripts/jsonschema.sh exit 127) it warns and passes
val="$tmp/val"; mkdir -p "$val/conf" "$val/packages" "$tmp/pk"; cp "$tmp/d.conf" "$val/conf/dists.conf"
vm(){ make --no-print-directory -f "$ROOT/Makefile" -C "$val" "$@"; }
cp "$ROOT/tests/fixtures/invalid/bad-release.json" "$tmp/pk/"
out="$(PKG_DIR="$tmp/pk" vm validate 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q 'no package files'; then bad "validate ignores PKG_DIR: $out"
elif "$ROOT/scripts/jsonschema.sh" --version >/dev/null 2>&1 && [ "$rc" = 0 ]; then bad "validate accepted an invalid file in PKG_DIR: $out"
else ok "validate checks the package files in PKG_DIR"; fi
cp "$ROOT/tests/fixtures/valid/any-release.json" "$val/packages/"
nojs="$tmp/nojs"; mkdir -p "$nojs"   # a PATH without check-jsonschema, uvx or pipx
for c in bash sh make env dirname basename tr grep awk find cat; do ln -s "$(command -v "$c")" "$nojs/$c"; done
out="$(PATH="$nojs" vm validate 2>&1)" && printf '%s' "$out" | grep -q 'check-jsonschema not found — skipping schema validation' \
  && ok "validate without a schema validator warns and passes" || bad "validate without a validator: $out"

# verify is the pre-push check of the engine's code (the tests, then the lint),
# never the site check (make -n: printed, not run)
vn="$(make --no-print-directory -C "$ROOT" -n verify 2>/dev/null)"
printf '%s' "$vn" | grep -q '_test.sh' && printf '%s' "$vn" | grep -q 'actionlint' && ! printf '%s' "$vn" | grep -q gpgv \
  && ok "make verify runs the tests and the lint" || bad "make verify: $vn"

# the engine checkout builds its bundled example instance
[ "$(make --no-print-directory -C "$ROOT" help 2>/dev/null | sed -n 2p)" = "instance: $ROOT/example" ] \
  && ok "engine checkout defaults to example/" || bad "engine checkout instance"
# an instance's own Makefile can include the engine's
inc="$tmp/inc"; mkdir -p "$inc"; printf 'include %s/Makefile\n' "$ROOT" > "$inc/Makefile"
[ "$(make --no-print-directory -C "$inc" help 2>/dev/null | sed -n 1,2p | tr '\n' '|')" = "engine:   $ROOT|instance: $inc|" ] \
  && make --no-print-directory -C "$inc" validate >/dev/null 2>&1 \
  && ok "include <engine>/Makefile from an instance" || bad "include of the engine Makefile"
exa="$tmp/example"; cp -r "$ROOT/example" "$exa"; rm -rf "$exa/debs" "$exa/_site"; git init --quiet "$exa"
if make --no-print-directory -C "$ROOT" INSTANCE="$exa" GNUPGHOME="$tmp/exg" KEY_EMAIL=t@example.org \
        EXAMPLE_DEBS="$exa/debs" key example-debs >/dev/null 2>&1 \
   && make --no-print-directory -C "$ROOT" INSTANCE="$exa" GNUPGHOME="$tmp/exg" publish verify-site >/dev/null 2>&1; then
  ok "example instance: example-debs + publish + verify-site"
else bad "example instance build"; fi
# a copy of example/ ignores its build output (its debs/ stay committable)
junk="$(git -C "$exa" status --porcelain --untracked-files=all | grep -E '^\?\? (_site|\.cache)/')"
[ -z "$junk" ] && [ -f "$exa/_site/index.html" ] && git -C "$exa" status --porcelain | grep -q '^?? debs/' \
  && ok "example/.gitignore: build output ignored, debs/ kept" || bad "example/.gitignore: $junk"

[ "$fail" = 0 ] && echo "PASS make_test" || { echo "FAIL make_test"; exit 1; }
