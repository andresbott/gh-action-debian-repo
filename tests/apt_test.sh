#!/usr/bin/env bash
# The real client: point an unprivileged, sandboxed apt at a built site through
# the .sources file the site itself serves (Signed-By swapped for the local
# keyring path) and install-resolve from it — for a codename and an alias, and
# with two signing keys where apt only knows one (a rotation's first phase).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need apt-get apt-cache dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }

make_instance "$tmp/inst"; site="$tmp/inst/_site"
printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64"\n' > "$tmp/inst/conf/dists.conf"
printf 'REPO_NAME=acme\nREPO_URL=file://%s\n' "$site" > "$tmp/inst/conf/site.conf"
make_deb "$tmp/inst/debs/bookworm" widget 1.0 amd64 bk >/dev/null
make_deb "$tmp/inst/debs/trixie"   widget 2.0 amd64 tx >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" old@example.org
"$ROOT/scripts/hydrate.sh" "$site" >/dev/null && "$ROOT/scripts/gen-index.sh" "$site" >/dev/null \
  || { echo "FAIL apt_test (build)"; exit 1; }

# apt_sandbox <suite> <keyring> -> runs `apt-get update`, prints widget's candidate version
apt_sandbox(){
  local r="$tmp/apt-$1"; rm -rf "$r"; mkdir -p "$r/etc/sources.list.d" "$r/etc/preferences.d" "$r/etc/apt.conf.d" "$r/state/lists/partial" "$r/cache/archives/partial"
  sed -e "s|^Suites: .*|Suites: $1|" -e "s|^Signed-By: .*|Signed-By: $2|" "$site/acme.sources" > "$r/etc/sources.list.d/acme.sources"
  local o=(-o Dir::Etc="$r/etc" -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::Parts="$r/etc/apt.conf.d"
           -o Dir::State="$r/state" -o Dir::State::status=/dev/null -o Dir::Cache="$r/cache"
           -o Debug::NoLocking=1 -o APT::Sandbox::User="$(id -un)" -o APT::Architecture=amd64)
  apt-get "${o[@]}" update >"$r/update.log" 2>&1 || { cat "$r/update.log" >&2; return 1; }
  grep -qiE '^(W|E):' "$r/update.log" && { cat "$r/update.log" >&2; return 1; }
  apt-cache "${o[@]}" policy widget | awk '/Candidate:/{print $2}'
}

got="$(apt_sandbox bookworm "$site/acme-archive-keyring.gpg")" && [ "$got" = 1.0 ] \
  && ok "apt resolves widget 1.0 from bookworm" || bad "bookworm: got '$got'"
got="$(apt_sandbox stable "$site/acme-archive-keyring.gpg")" && [ "$got" = 1.0 ] \
  && ok "apt resolves the alias stable -> bookworm" || bad "stable: got '$got'"
got="$(apt_sandbox trixie "$site/acme-archive-keyring.gpg")" && [ "$got" = 2.0 ] \
  && ok "apt resolves widget 2.0 from trixie" || bad "trixie: got '$got'"

# rotation, phase 1: sign with old+new; a client that only has the OLD key still updates
cp "$site/acme-archive-keyring.gpg" "$tmp/old-only.gpg"
make_test_key "$GNUPGHOME" new@example.org
"$ROOT/scripts/gen-index.sh" "$site" >/dev/null
got="$(apt_sandbox bookworm "$tmp/old-only.gpg")" && [ "$got" = 1.0 ] \
  && ok "old-key client accepts the dual-signed repo" || bad "old-key client after rotation: got '$got'"

# a client with an unrelated key must be refused
mkdir -p "$tmp/other"; make_test_key "$tmp/other" other@example.org
GNUPGHOME="$tmp/other" gpg --export > "$tmp/other.gpg"
apt_sandbox bookworm "$tmp/other.gpg" >/dev/null 2>&1 && bad "apt accepted a repo signed by an unknown key" \
  || ok "apt refuses a repo signed by an unknown key"

[ "$fail" = 0 ] && echo "PASS apt_test" || { echo "FAIL apt_test"; exit 1; }
