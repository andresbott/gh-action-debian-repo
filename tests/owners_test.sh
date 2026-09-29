#!/usr/bin/env bash
# Package ownership allowlist (scripts/owners-lib.sh) and its enforcement in
# hydrate.sh, plus hydrate's packages/*.json path (download + verify) using
# file:// URLs so no network is needed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb jq curl
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }

# ref <out.json> <name> <version> <url> [sha256]
ref(){ jq -n --arg n "$2" --arg v "$3" --arg u "$4" --arg s "${5:-$(printf '0%.0s' {1..64})}" \
  '{name:$n, version:$v, artifacts:[{release:"any", arch:"amd64", url:$u, sha256:$s}]}' > "$1"; }

owners="$tmp/owners.conf"
cat > "$owners" <<'EOF'
# package   owner/repo...
myapp       Example-Org/myapp  example-org/myapp-legacy
other       acme/other   # trailing comment
EOF
rel="https://github.com/example-org/myapp/releases/download"

# check <url> [name] -> ACCEPT / REJECT
check(){ ref "$tmp/c.json" "${2:-myapp}" 1.0 "$1"
  ( . "$ROOT/scripts/owners-lib.sh"; owners_load "$owners" || exit 2
    owners_check_ref "$tmp/c.json" 2>/dev/null ) && echo ACCEPT || echo REJECT; }

[ "$(check "$rel/v1.0/myapp_1.0_amd64.deb")" = ACCEPT ] && ok "listed repo accepted" || bad "listed repo rejected"
[ "$(check "https://github.com/EXAMPLE-ORG/MyApp/releases/download/v1.0/myapp_1.0_amd64.deb")" = ACCEPT ] \
  && ok "owner/repo compared case-insensitively" || bad "case-mismatched owner rejected"
[ "$(check "https://github.com/example-org/myapp-legacy/releases/download/v0.9/m.deb")" = ACCEPT ] \
  && ok "second listed repo accepted" || bad "second listed repo rejected"
[ "$(check "https://github.com/example-org/myapp-evil/releases/download/v1.0/m.deb")" = REJECT ] \
  && ok "prefix-sharing repo rejected" || bad "prefix-sharing repo (myapp-evil) accepted"
[ "$(check "$rel/../../../evil/x/releases/download/v1/m.deb")" = REJECT ] \
  && ok "dot-segment escape rejected" || bad "'..' segment accepted"
[ "$(check "$rel/v1.0/./m.deb")" = REJECT ] && ok "'.' segment rejected" || bad "'.' segment accepted"
[ "$(check "$rel/m.deb")" = REJECT ] && ok "asset without a tag rejected" || bad "tagless asset accepted"
[ "$(check "$rel/v1.0/m.deb?x=1")" = REJECT ] && ok "query string rejected" || bad "query string accepted"
[ "$(check "https://github.com/acme/other/releases/download/v1/m.deb")" = REJECT ] \
  && ok "another package's repo rejected" || bad "another package's repo accepted"
[ "$(check "https://github.com/acme/other/releases/download/v1/o.deb" other)" = ACCEPT ] \
  && ok "trailing comment ignored" || bad "trailing comment broke the line"
[ "$(check "$rel/v1.0/u.deb" unlisted)" = REJECT ] && ok "unlisted package rejected" || bad "unlisted package accepted"
msg="$(ref "$tmp/c.json" unlisted 1.0 "$rel/v1/u.deb"; . "$ROOT/scripts/owners-lib.sh"; owners_load "$owners"; owners_check_ref "$tmp/c.json" 2>&1)"
printf '%s' "$msg" | grep -q 'not listed in owners.conf' && ok "unlisted message names the fix" || bad "unlisted message, got: $msg"

# no owners.conf = not enforced
( . "$ROOT/scripts/owners-lib.sh"; owners_load "$tmp/absent.conf"; ref "$tmp/c.json" x 1 "file:///x"; owners_check_ref "$tmp/c.json" ) \
  && ok "no owners.conf -> not enforced" || bad "missing owners.conf enforced"

# malformed lines fail with file:line
printf 'myapp\n' > "$tmp/bad1.conf"; printf 'myapp not-a-repo\n' > "$tmp/bad2.conf"; printf 'Bad_Name a/b\n' > "$tmp/bad3.conf"
for b in bad1 bad2 bad3; do
  err="$( . "$ROOT/scripts/owners-lib.sh"; owners_load "$tmp/$b.conf" 2>&1 )" && bad "$b.conf accepted" \
    || { printf '%s' "$err" | grep -q "$b.conf:1:" && ok "$b.conf rejected with file:line" || bad "$b.conf message, got: $err"; }
done

# --- hydrate: the packages/*.json path ---
build="$tmp/build"; deb="$(make_deb "$build" myapp 1.0 amd64 j)"
sha="$(sha256sum "$deb" | cut -d' ' -f1)"
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES=""\nARCHES="amd64"\n' > "$conf"

make_instance "$tmp/inst"
ref "$tmp/inst/packages/myapp.json" myapp 1.0 "file://$deb" "$sha"
if DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$tmp/site" >/dev/null 2>&1 \
   && [ -f "$tmp/site/pool/bookworm/main/m/myapp/myapp_1.0_amd64.deb" ] \
   && [ -f "$tmp/site/pool/trixie/main/m/myapp/myapp_1.0_amd64.deb" ]; then
  ok "json reference downloaded, verified and pooled"
else bad "json reference not pooled"; fi

ref "$tmp/inst/packages/myapp.json" myapp 1.0 "file://$deb" "$(printf 'f%.0s' {1..64})"
DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$tmp/site" >/dev/null 2>&1 \
  && bad "sha256 mismatch accepted" || ok "sha256 mismatch rejected"
ref "$tmp/inst/packages/myapp.json" myapp 2.0 "file://$deb" "$sha"
DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$tmp/site" >/dev/null 2>&1 \
  && bad "version mismatch accepted" || ok "version mismatch rejected"

# with owners.conf present every reference is checked BEFORE anything is
# downloaded: a file:// URL is not a GitHub release asset, so it never runs
cp "$owners" "$tmp/inst/conf/owners.conf"
ref "$tmp/inst/packages/myapp.json" myapp 1.0 "file://$deb" "$sha"
out="$(DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$tmp/site" 2>&1)" && bad "owners.conf not enforced by hydrate" \
  || { printf '%s' "$out" | grep -q '>> myapp' && bad "hydrate downloaded before checking owners" || ok "hydrate enforces owners.conf before downloading"; }

# committed debs/ are the maintainer's own and are not subject to owners.conf
rm -f "$tmp/inst/packages/myapp.json"; mkdir -p "$tmp/inst/debs"; cp "$deb" "$tmp/inst/debs/"
DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$tmp/site" >/dev/null 2>&1 \
  && ok "debs/ exempt from owners.conf" || bad "debs/ rejected by owners.conf"

[ "$fail" = 0 ] && echo "PASS owners_test" || { echo "FAIL owners_test"; exit 1; }
