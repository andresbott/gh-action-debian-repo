#!/usr/bin/env bash
# scripts/conf-overlay.sh: workflow inputs layered over a committed config.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
ov(){ "$ROOT/scripts/conf-overlay.sh" "$@"; }
# val <conf> <KEY> -> the value after sourcing the file in a clean shell
val(){ env -i bash -c '. "$1"; eval "printf %s \"\${$2-}\""' _ "$1" "$2"; }

printf 'DISTS="trixie forky"\nREPO_URL=https://apt.example.org\nARCHES="amd64"' > "$tmp/base.conf"  # no final newline
ov "$tmp/base.conf" --set DISTS="bookworm trixie" --set ARCHES= \
   --default REPO_URL=https://pages.example --default SITE_TITLE="Acme & co" > "$tmp/out.conf"
[ "$(val "$tmp/out.conf" DISTS)" = "bookworm trixie" ] && ok "--set overrides the base" || bad "--set, got: $(val "$tmp/out.conf" DISTS)"
[ "$(val "$tmp/out.conf" ARCHES)" = "amd64" ] && ok "empty --set value is skipped" || bad "empty --set changed ARCHES"
[ "$(val "$tmp/out.conf" REPO_URL)" = "https://apt.example.org" ] && ok "--default loses to the base" || bad "--default overrode the base"
[ "$(val "$tmp/out.conf" SITE_TITLE)" = "Acme & co" ] && ok "--default fills an unset key" || bad "--default, got: $(val "$tmp/out.conf" SITE_TITLE)"

# no base file: overrides alone
ov "" --set THEME=teal > "$tmp/nobase.conf"
[ "$(val "$tmp/nobase.conf" THEME)" = teal ] && ok "works without a base file" || bad "no base file"
ov "$tmp/absent.conf" --set THEME=teal > "$tmp/nobase2.conf"
[ "$(val "$tmp/nobase2.conf" THEME)" = teal ] && ok "missing base file is not an error" || bad "missing base file"

# an input is data, never code
evil='x"; touch '"$tmp"'/pwned; echo "$(touch '"$tmp"'/pwned2)`touch '"$tmp"'/pwned3`'
ov "" --set SITE_TAGLINE="$evil" --default SITE_TITLE="$evil" > "$tmp/evil.conf"
[ "$(val "$tmp/evil.conf" SITE_TAGLINE)" = "$evil" ] && [ "$(val "$tmp/evil.conf" SITE_TITLE)" = "$evil" ] \
  && ! ls "$tmp"/pwned* >/dev/null 2>&1 && ok "values are quoted, never executed" || bad "overlay value executed or altered"

# only config-style keys
for a in "--set lower=x" "--set 1X=x" "--set NOEQUALS" "--bogus X=1"; do
  # shellcheck disable=SC2086
  ov "" $a >/dev/null 2>&1 && bad "accepted: $a" || ok "rejected: $a"
done

[ "$fail" = 0 ] && echo "PASS overlay_test" || { echo "FAIL overlay_test"; exit 1; }
