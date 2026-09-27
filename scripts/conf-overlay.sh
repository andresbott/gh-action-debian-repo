#!/usr/bin/env bash
# Print a shell config file (site.conf / dists.conf format) made of <base> plus
# overrides, for the build action to turn workflow inputs into config without
# editing the instance's committed files:
#   --set KEY=VALUE      always wins over the base file
#   --default KEY=VALUE  used only when the base leaves KEY unset or empty
# Empty VALUEs are skipped, so an unset workflow input changes nothing. Values
# are written %q-quoted: the output is sourced, and an input must never run code.
# Usage: conf-overlay.sh <base|""> [--set K=V]... [--default K=V]... > out.conf
set -euo pipefail

BASE="${1-}"; shift || true
[ -z "$BASE" ] || [ ! -f "$BASE" ] || { cat "$BASE"; echo; }
while [ $# -gt 0 ]; do
  mode="$1"; kv="${2-}"
  case "$mode" in --set|--default) ;; *) echo "unknown argument: $mode" >&2; exit 2;; esac
  [ $# -ge 2 ] || { echo "$mode needs KEY=VALUE" >&2; exit 2; }
  shift 2
  key="${kv%%=*}"; val="${kv#*=}"
  { [ "$key" != "$kv" ] && printf '%s' "$key" | grep -qE '^[A-Z_][A-Z0-9_]*$'; } \
    || { echo "invalid KEY=VALUE '$kv'" >&2; exit 2; }
  [ -n "$val" ] || continue
  if [ "$mode" = --set ]; then printf '%s=%q\n' "$key" "$val"
  else printf '[ -n "${%s:-}" ] || %s=%q\n' "$key" "$key" "$val"; fi
done
