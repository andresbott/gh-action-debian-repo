# Optional package ownership allowlist for a shared (collection) repository.
# When <instance>/conf/owners.conf exists, every packages/*.json must name a
# listed package, and every artifact URL must be a GitHub release asset of one
# of the repos listed for it — so a client holding a write token cannot publish
# binaries under another project's package name. No file = not enforced.
# Manually committed debs/ are not subject to it (only the maintainer adds those).
#
# Format, one package per line (# comments allowed):
#   <package>  <owner/repo> [<owner/repo>...]
# Source this, call owners_load "$OWNERS_CONF", then owners_check_ref <json>.
# shellcheck shell=bash

declare -gA OWNERS=()
OWNERS_ENFORCED=0

owners_load() { # [file]
  OWNERS=(); OWNERS_ENFORCED=0
  local f="${1:-}" line pkg repos r n=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  OWNERS_ENFORCED=1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); line="${line%%#*}"
    read -r pkg repos <<< "$line" || true
    [ -n "${pkg:-}" ] || continue
    printf '%s' "$pkg" | grep -qE '^[a-z0-9][a-z0-9+.-]+$' \
      || { echo "❌ $f:$n: invalid package name '$pkg'" >&2; return 1; }
    [ -n "${repos:-}" ] || { echo "❌ $f:$n: '$pkg' lists no owner/repo" >&2; return 1; }
    for r in $repos; do
      printf '%s' "$r" | grep -qE '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' \
        || { echo "❌ $f:$n: invalid repo '$r' (want owner/name)" >&2; return 1; }
    done
    # GitHub owner/repo names are case-insensitive: store lowercase, compare lowercase
    OWNERS[$pkg]="${OWNERS[$pkg]:+${OWNERS[$pkg]} }$(printf '%s' "$repos" | tr 'A-Z' 'a-z')"
  done < "$f"
}

# the <tag>/<asset> remainder of a release URL: plain characters only and no
# "." / ".." segment — curl normalizes dot segments, so ".." could walk out of
# the allowed repo's path into another one
asset_path_ok() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._+~-]+(/[A-Za-z0-9._+~-]+)+$' || return 1
  case "/$1/" in */./*|*/../*) return 1;; esac
  return 0
}

owners_check_ref() { # <package.json>
  [ "$OWNERS_ENFORCED" = 1 ] || return 0
  local f="$1" name allowed url lower r prefix ok
  name="$(jq -r '.name' "$f")"
  allowed="${OWNERS[$name]:-}"
  [ -n "$allowed" ] || {
    echo "❌ $(basename "$f"): package '$name' is not listed in owners.conf — the repository maintainer must add it" >&2
    return 1; }
  while IFS= read -r url; do
    ok=0; lower="$(printf '%s' "$url" | tr 'A-Z' 'a-z')"
    for r in $allowed; do
      prefix="https://github.com/$r/releases/download/"
      case "$lower" in "$prefix"*) asset_path_ok "${url:${#prefix}}" && ok=1;; esac
    done
    [ "$ok" = 1 ] || {
      echo "❌ $(basename "$f"): '$url' is not a release asset of the repo(s) owning '$name': $allowed" >&2
      return 1; }
  done < <(jq -r '.artifacts[].url' "$f")
  return 0
}
