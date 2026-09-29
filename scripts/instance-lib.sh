# Engine/instance split + repository identity. Source this, call instance_init
# (paths), then dists_load "$DISTS_CONF", then site_load (identity). Sourced by
# hydrate.sh, gen-index.sh, render-index.sh and instance-info.sh.
#
# ENGINE   = this checkout: scripts/, schema/, template/, defaults/.
# INSTANCE = the repository being published: packages/, debs/, conf/. Taken
#            from $INSTANCE, else the current directory.
# Every derived path may be preset in the environment to override it.
# shellcheck shell=bash

# first existing file among the arguments; the last one when none exists, so a
# caller's "missing file" error names the path it would finally have used
first_file() { local f; for f in "$@"; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done; printf '%s\n' "${!#}"; }

instance_init() {
  ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local inst="${INSTANCE:-$PWD}"
  [ -d "$inst" ] || { echo "❌ instance directory not found: $inst" >&2; return 1; }
  INSTANCE="$(cd "$inst" && pwd)"
  PKG_DIR="${PKG_DIR:-$INSTANCE/packages}"
  DEBS_DIR="${DEBS_DIR:-$INSTANCE/debs}"
  OWNERS_CONF="${OWNERS_CONF:-$INSTANCE/conf/owners.conf}"
  SITE_CONF="${SITE_CONF:-$INSTANCE/conf/site.conf}"
  DISTS_CONF="${DISTS_CONF:-$(first_file "$INSTANCE/conf/dists.conf" "$ENGINE/defaults/dists.conf")}"
  INDEX_TEMPLATE="${INDEX_TEMPLATE:-$(first_file "$INSTANCE/conf/index.html" "$ENGINE/template/index.html")}"
}

# theme_file <name> — the instance's conf/themes/<name>.css, else the engine's
# template/themes/<name>.css; non-zero when neither exists
theme_file() {
  local f
  for f in "$INSTANCE/conf/themes/$1.css" "$ENGINE/template/themes/$1.css"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# owner/name of the GitHub repo the instance publishes from: $GITHUB_REPOSITORY
# in Actions, else parsed from the instance's `origin` remote, else nothing.
# Local builds therefore derive the same names CI does.
instance_gh_repo() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then printf '%s\n' "$GITHUB_REPOSITORY"; return 0; fi
  local url
  url="$(git -C "$INSTANCE" remote get-url origin 2>/dev/null)" || return 0
  url="${url%/}"; url="${url%.git}"
  case "$url" in *github.com[:/]*) ;; *) return 0;; esac
  url="${url##*github.com[:/]}"
  case "$url" in */*/*|/*|*/) return 0;; */*) printf '%s\n' "$url";; esac
}

# pages_url <owner/name> — where GitHub Pages serves that repo (a user/org site
# "<owner>.github.io" is served at the root); localhost when there is no repo
pages_url() {
  [ -n "$1" ] || { echo "http://localhost:8000"; return 0; }
  local o r
  o="$(printf '%s' "${1%%/*}" | tr 'A-Z' 'a-z')"; r="${1#*/}"
  if [ "$(printf '%s' "$r" | tr 'A-Z' 'a-z')" = "$o.github.io" ]; then echo "https://$o.github.io"
  else echo "https://$o.github.io/$r"; fi
}

# the suite the served .sources file tracks: the first alias, else the first codename
default_suite() {
  local p
  for p in ${ALIASES:-}; do printf '%s\n' "${p%%:*}"; return 0; done
  # shellcheck disable=SC2086
  set -- $DISTS; printf '%s\n' "$1"
}

# site_load — identity of the published repo from $SITE_CONF (optional) plus
# derived defaults. THEME from the environment wins over the file
# (make build THEME=teal). Call after dists_load (SOURCES_SUITE needs DISTS).
site_load() {
  local theme_env="${THEME:-}" gh name
  if [ -f "$SITE_CONF" ]; then
    # shellcheck disable=SC1090
    . "$SITE_CONF"
  fi
  [ -n "$theme_env" ] && THEME="$theme_env"
  gh="$(instance_gh_repo)"
  if [ -z "${REPO_NAME:-}" ]; then
    if [ -n "$gh" ]; then name="${gh%%/*}-${gh#*/}"; else name="$(basename "$INSTANCE")"; fi
    REPO_NAME="$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')"
  fi
  printf '%s' "$REPO_NAME" | grep -qE '^[a-z0-9][a-z0-9.-]*$' \
    || { echo "❌ invalid REPO_NAME '$REPO_NAME' (want ^[a-z0-9][a-z0-9.-]*\$) — set REPO_NAME in $SITE_CONF" >&2; return 1; }
  : "${SITE_TITLE:=$REPO_NAME}"
  : "${SITE_TAGLINE:=A signed APT repository for Debian and Ubuntu}"
  : "${REPO_URL:=$(pages_url "$gh")}"
  REPO_URL="${REPO_URL%/}"
  : "${GITHUB_URL:=https://github.com/${gh:-andresbott/gh-action-debian-repo}}"
  : "${KEYRING_FILE:=$REPO_NAME-archive-keyring.gpg}"
  : "${SOURCES_FILE:=$REPO_NAME.sources}"
  : "${SOURCES_SUITE:=$(default_suite)}"
  : "${APT_ORIGIN:=$REPO_NAME}"
  : "${APT_LABEL:=$REPO_NAME}"
  : "${APT_DESCRIPTION:=$SITE_TITLE APT repository}"
  : "${THEME:=violet}"
  # both names become paths under /etc/apt on every client — keep them plain
  printf '%s' "$KEYRING_FILE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*\.gpg$' \
    || { echo "❌ KEYRING_FILE '$KEYRING_FILE' must be a plain file name ending in .gpg" >&2; return 1; }
  printf '%s' "$SOURCES_FILE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*\.sources$' \
    || { echo "❌ SOURCES_FILE '$SOURCES_FILE' must be a plain file name ending in .sources" >&2; return 1; }
  return 0
}
