#!/usr/bin/env bash
# Engine/instance path resolution and the derived repository identity
# (scripts/instance-lib.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need git
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }

# identity <instance> [env...] -> "REPO_NAME|REPO_URL|KEYRING_FILE|SOURCES_FILE|SOURCES_SUITE|GITHUB_URL", or REJECTED
identity(){ local inst="$1"; shift
  env -u SITE_CONF -u DISTS_CONF "$@" INSTANCE="$inst" bash -c '
    set -euo pipefail
    . "$0/scripts/instance-lib.sh"; instance_init
    . "$0/scripts/dists-lib.sh"; dists_load "$DISTS_CONF"
    if site_load 2>/dev/null; then
      echo "$REPO_NAME|$REPO_URL|$KEYRING_FILE|$SOURCES_FILE|$SOURCES_SUITE|$GITHUB_URL"
    else echo REJECTED; fi' "$ROOT"; }

# 1. no git remote, no site.conf: the directory name, served from localhost
make_instance "$tmp/My_Repo"
got="$(identity "$tmp/My_Repo")"
[ "$got" = "my-repo|http://localhost:8000|my-repo-archive-keyring.gpg|my-repo.sources|stable|https://github.com/andresbott/gh-action-debian-repo" ] \
  && ok "basename identity" || bad "basename identity, got: $got"

# 2. in Actions: GITHUB_REPOSITORY names it (lowercased, owner-repo)
got="$(identity "$tmp/My_Repo" GITHUB_REPOSITORY=Andresbott/APT-Repo)"
[ "$got" = "andresbott-apt-repo|https://andresbott.github.io/APT-Repo|andresbott-apt-repo-archive-keyring.gpg|andresbott-apt-repo.sources|stable|https://github.com/Andresbott/APT-Repo" ] \
  && ok "GITHUB_REPOSITORY identity" || bad "GITHUB_REPOSITORY identity, got: $got"

# 3. locally: the origin remote gives the same names CI derives (ssh and https forms)
make_instance "$tmp/clone"; git -C "$tmp/clone" init -q
git -C "$tmp/clone" remote add origin git@github.com:acme/debs.git
got="$(identity "$tmp/clone")"
[ "${got%%|*}" = "acme-debs" ] && ok "ssh origin remote" || bad "ssh origin remote, got: $got"
git -C "$tmp/clone" remote set-url origin https://github.com/acme/debs/
got="$(identity "$tmp/clone")"
[ "${got%%|*}" = "acme-debs" ] && ok "https origin remote" || bad "https origin remote, got: $got"
git -C "$tmp/clone" remote set-url origin https://gitlab.com/acme/debs.git
got="$(identity "$tmp/clone")"
[ "${got%%|*}" = "clone" ] && ok "non-GitHub remote ignored" || bad "non-GitHub remote, got: $got"

# 4. a user/org Pages site is served from the root
got="$(identity "$tmp/My_Repo" GITHUB_REPOSITORY=acme/ACME.github.io)"
[ "$(echo "$got" | cut -d'|' -f2)" = "https://acme.github.io" ] && ok "user site served at root" || bad "user site URL, got: $got"

# 5. site.conf wins over derivation; a trailing slash on REPO_URL is dropped
make_instance "$tmp/conf"
printf 'REPO_NAME=widgets\nREPO_URL=https://apt.example.org/\n' > "$tmp/conf/conf/site.conf"
got="$(identity "$tmp/conf" GITHUB_REPOSITORY=acme/debs)"
[ "$got" = "widgets|https://apt.example.org|widgets-archive-keyring.gpg|widgets.sources|stable|https://github.com/acme/debs" ] \
  && ok "site.conf overrides" || bad "site.conf overrides, got: $got"

# 6. names that become /etc/apt paths on every client are validated
printf 'REPO_NAME="bad name"\n' > "$tmp/conf/conf/site.conf"
[ "$(identity "$tmp/conf")" = REJECTED ] && ok "invalid REPO_NAME rejected" || bad "invalid REPO_NAME accepted"
printf 'KEYRING_FILE=../../etc/x.gpg\n' > "$tmp/conf/conf/site.conf"
[ "$(identity "$tmp/conf")" = REJECTED ] && ok "path-like KEYRING_FILE rejected" || bad "path-like KEYRING_FILE accepted"

# 7. SOURCES_SUITE: first alias, else first codename
make_instance "$tmp/noalias"
printf 'DISTS="bookworm trixie"\nALIASES=""\nARCHES="amd64"\n' > "$tmp/noalias/conf/dists.conf"
got="$(identity "$tmp/noalias")"
[ "$(echo "$got" | cut -d'|' -f5)" = bookworm ] && ok "suite falls back to first codename" || bad "suite fallback, got: $got"

# 8. instance files win over engine defaults: dists.conf, template, themes
paths="$(INSTANCE="$tmp/noalias" bash -c '. "$0/scripts/instance-lib.sh"; instance_init
  echo "$DISTS_CONF|$INDEX_TEMPLATE|$(theme_file teal)"' "$ROOT")"
[ "$paths" = "$tmp/noalias/conf/dists.conf|$ROOT/template/index.html|$ROOT/template/themes/teal.css" ] \
  && ok "engine defaults used when the instance has none" || bad "default paths, got: $paths"
mkdir -p "$tmp/noalias/conf/themes"; : > "$tmp/noalias/conf/themes/teal.css"; : > "$tmp/noalias/conf/index.html"
paths="$(INSTANCE="$tmp/noalias" bash -c '. "$0/scripts/instance-lib.sh"; instance_init
  echo "$INDEX_TEMPLATE|$(theme_file teal)"' "$ROOT")"
[ "$paths" = "$tmp/noalias/conf/index.html|$tmp/noalias/conf/themes/teal.css" ] \
  && ok "instance template + theme override the engine's" || bad "override paths, got: $paths"
( . "$ROOT/scripts/instance-lib.sh"; INSTANCE="$tmp/noalias"; instance_init; theme_file nope >/dev/null ) \
  && bad "unknown theme must not resolve" || ok "unknown theme does not resolve"

# 9. a missing instance directory is an error, not the current directory
( INSTANCE="$tmp/absent"; . "$ROOT/scripts/instance-lib.sh"; instance_init 2>/dev/null ) \
  && bad "missing instance accepted" || ok "missing instance rejected"

[ "$fail" = 0 ] && echo "PASS instance_test" || { echo "FAIL instance_test"; exit 1; }
