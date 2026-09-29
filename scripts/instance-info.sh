#!/usr/bin/env bash
# Print resolved instance settings, one line per KEY argument, for the Makefile
# and for scripting:  instance-info.sh KEYRING_FILE SUITES
# KEY is any setting from instance_init / dists_load / site_load (see
# instance-lib.sh), or SUITES: every signed suite, aliases first.
set -euo pipefail
. "$(dirname "$0")/instance-lib.sh"; instance_init
. "$(dirname "$0")/dists-lib.sh"; dists_load "$DISTS_CONF"
site_load
SUITES="$(alias_pairs | awk '{printf "%s ", $1}')$DISTS"
for k in "$@"; do
  case "$k" in
    ENGINE|INSTANCE|PKG_DIR|DEBS_DIR|OWNERS_CONF|SITE_CONF|DISTS_CONF|INDEX_TEMPLATE|\
    DISTS|ALIASES|ARCHES|SUITES|REPO_NAME|SITE_TITLE|SITE_TAGLINE|REPO_URL|GITHUB_URL|\
    KEYRING_FILE|SOURCES_FILE|SOURCES_SUITE|APT_ORIGIN|APT_LABEL|APT_DESCRIPTION|THEME)
      printf '%s\n' "${!k}";;
    *) echo "unknown key: $k" >&2; exit 2;;
  esac
done
