#!/usr/bin/env bash
# scripts/dists-overlay.sh: the dists/aliases/arches workflow inputs layered over
# a dists.conf, as the publish (ci-build.sh) and the pre-push check (push-ref.sh)
# both build it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
# dov <base> <dists> <aliases> <arches> -> overlay in $tmp/o.conf, stderr in $tmp/err
dov(){ "$ROOT/scripts/dists-overlay.sh" "$@" > "$tmp/o.conf" 2> "$tmp/err"; }
# val <KEY> -> its value after sourcing the overlay in a clean shell
val(){ env -i bash -c '. "$1"; eval "printf %s \"\${$2-}\""' _ "$tmp/o.conf" "$1"; }
# loads <conf> -> the overlay passes dists_load (what hydrate/gen-index run)
loads(){ ( . "$ROOT/scripts/dists-lib.sh"; dists_load "$1" >/dev/null 2>&1 ); }
defaults="$ROOT/defaults/dists.conf"   # trixie forky sid; stable:trixie testing:forky unstable:sid

# dists alone: an alias whose target left DISTS is dropped (with a warning), the others stay
dov "$defaults" "bookworm trixie" "" ""
[ "$(val DISTS)" = "bookworm trixie" ] && [ "$(val ALIASES)" = "stable:trixie" ] && loads "$tmp/o.conf" \
  && ok "dists alone keeps only the aliases whose target is still published" || bad "dists alone: ALIASES='$(val ALIASES)' ($(cat "$tmp/err"))"
grep -q "dropped alias(es) testing:forky unstable:sid — their target is not in DISTS" "$tmp/err" \
  && ok "dropped aliases are warned about" || bad "warning: $(cat "$tmp/err")"
dov "$defaults" "bookworm" "" ""
[ "$(val ALIASES)" = "" ] && loads "$tmp/o.conf" && ok "every alias dropped -> no aliases" || bad "all dropped: '$(val ALIASES)'"

# none: no aliases at all, with or without dists
dov "$defaults" "" none ""
[ "$(val ALIASES)" = "" ] && [ "$(val DISTS)" = "trixie forky sid" ] && loads "$tmp/o.conf" && [ ! -s "$tmp/err" ] \
  && ok "aliases=none clears the aliases" || bad "none: ALIASES='$(val ALIASES)' ($(cat "$tmp/err"))"
dov "$defaults" "bookworm trixie" none ""
[ "$(val ALIASES)" = "" ] && [ ! -s "$tmp/err" ] && ok "aliases=none with dists: no aliases, no warning" || bad "none + dists"

# explicit aliases win over the base, and nothing is filtered
dov "$defaults" "bookworm trixie" "stable:bookworm" "amd64"
[ "$(val ALIASES)" = "stable:bookworm" ] && [ "$(val ARCHES)" = "amd64" ] && [ ! -s "$tmp/err" ] && loads "$tmp/o.conf" \
  && ok "explicit aliases win" || bad "explicit: ALIASES='$(val ALIASES)' ARCHES='$(val ARCHES)'"

# empty inputs: the base, unchanged
dov "$defaults" "" "" ""
[ "$(val DISTS)" = "trixie forky sid" ] && [ "$(val ALIASES)" = "stable:trixie testing:forky unstable:sid" ] \
  && [ "$(val ARCHES)" = "amd64 arm64" ] && [ ! -s "$tmp/err" ] && ok "empty inputs leave the base unchanged" || bad "empty inputs"

# inputs are data, never code — the filtered line included
dov "$defaults" 'trixie $(touch '"$tmp"'/pwned)' "" ""
[ "$(val DISTS)" = 'trixie $(touch '"$tmp"'/pwned)' ] && [ ! -e "$tmp/pwned" ] \
  && ok "values are quoted, never executed" || bad "an input was executed"

[ "$fail" = 0 ] && echo "PASS dists_overlay_test" || { echo "FAIL dists_overlay_test"; exit 1; }
