#!/usr/bin/env bash
# Print the dists.conf a build uses: <base> with the dists/aliases/arches
# workflow inputs layered over it (scripts/conf-overlay.sh --set). The publish
# (ci-build.sh) and the pre-push check (push-ref.sh) both build it here, so they
# always agree on the releases. On top of a plain overlay:
#   aliases = none          no aliases at all (ALIASES='')
#   dists without aliases   the base's aliases are kept only when their target
#                           is still in DISTS, and the dropped ones are warned
#                           about: `dists: bookworm trixie` alone must not leave
#                           the engine default's testing:forky dangling
# Empty inputs change nothing.
# Usage: dists-overlay.sh <base|""> <dists> <aliases> <arches> > out.conf
set -euo pipefail
set -f   # the inputs are word-split below, never globbed

BASE="${1-}"; IN_DISTS="${2-}"; IN_ALIASES="${3-}"; IN_ARCHES="${4-}"
set_aliases="$IN_ALIASES"; [ "$IN_ALIASES" != none ] || set_aliases=""
"$(dirname "$0")/conf-overlay.sh" "$BASE" \
  --set DISTS="$IN_DISTS" --set ALIASES="$set_aliases" --set ARCHES="$IN_ARCHES"

if [ "$IN_ALIASES" = none ]; then
  echo "ALIASES=''"
elif [ -n "$IN_DISTS" ] && [ -z "$IN_ALIASES" ]; then
  base_aliases="$(unset ALIASES
    # shellcheck disable=SC1090
    if [ -n "$BASE" ] && [ -f "$BASE" ]; then . "$BASE" >/dev/null; fi
    printf '%s' "${ALIASES:-}")"
  in_dists(){ local d; for d in $IN_DISTS; do [ "$d" = "$1" ] && return 0; done; return 1; }
  kept=(); dropped=()
  for pair in $base_aliases; do
    # a malformed entry (no ':') is kept, so dists_validate still reports it
    case "$pair" in *:*) in_dists "${pair##*:}" || { dropped+=("$pair"); continue; };; esac
    kept+=("$pair")
  done
  printf 'ALIASES=%q\n' "${kept[*]:-}"
  [ ${#dropped[@]} -eq 0 ] || echo "⚠️  dropped alias(es) ${dropped[*]} — their target is not in DISTS" >&2
fi
