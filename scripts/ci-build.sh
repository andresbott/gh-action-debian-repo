#!/usr/bin/env bash
# The build action's body (actions/build/action.yml): turn the workflow inputs
# into config overlays, import the signing key into a throwaway keyring outside
# the site, then `make publish verify` for the instance. Runnable locally too.
# Env:
#   INSTANCE          instance checkout (required)
#   SITE              output directory (default: $RUNNER_TEMP/debrepo-site)
#   APT_SIGNING_KEY   armored private key(s); required unless EPHEMERAL_KEY=1
#   EPHEMERAL_KEY=1   sign with a generated throwaway key (engine CI/tests only:
#                     clients could never verify such a repository)
#   INPUT_DISTS INPUT_ALIASES INPUT_ARCHES                 -> dists.conf overlay
#   INPUT_REPO_NAME INPUT_SITE_TITLE INPUT_SITE_TAGLINE INPUT_THEME -> site.conf overlay
#   BASE_URL          the Pages URL (configure-pages); REPO_URL when site.conf has none
# Writes site=<dir> to $GITHUB_OUTPUT when set.
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
: "${INSTANCE:?INSTANCE (the instance checkout) is required}"
INSTANCE="$(cd "$INSTANCE" && pwd)"; export INSTANCE
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/debrepo.XXXXXX")"
export GNUPGHOME="$tmp/gnupg"; install -d -m 700 "$GNUPGHOME"
cleanup(){ gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
SITE="${SITE:-${RUNNER_TEMP:-/tmp}/debrepo-site}"
mkdir -p "$SITE"; SITE="$(cd "$SITE" && pwd)"
case "$SITE/" in "$GNUPGHOME/"*|"$tmp/"*) echo "❌ SITE must not be inside the keyring dir" >&2; exit 1;; esac

# --- signing key ---
if [ -n "${APT_SIGNING_KEY:-}" ]; then
  printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --import 2>/dev/null \
    || { echo "❌ APT_SIGNING_KEY could not be imported (want an armored private key)" >&2; exit 1; }
  gpg --batch --list-secret-keys --with-colons | grep -q '^sec' \
    || { echo "❌ APT_SIGNING_KEY holds no private key — export it with 'make key-to-repo'" >&2; exit 1; }
elif [ "${EPHEMERAL_KEY:-}" = 1 ]; then
  echo "⚠️  signing with an EPHEMERAL key — no client can verify this repository"
  gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "ephemeral <ephemeral@localhost>" default sign never 2>/dev/null
else
  echo "❌ no APT_SIGNING_KEY secret. Create a key with 'make key' and store it with" >&2
  echo "   'make key-to-repo REPO=<owner/name>' (github-pages environment), and pass it to" >&2
  echo "   the workflow: 'secrets: inherit' or 'secrets: { APT_SIGNING_KEY: ... }'" >&2
  exit 1
fi

# --- workflow inputs -> config overlays (committed files stay untouched) ---
base_dists="$("$ENGINE/scripts/instance-info.sh" DISTS_CONF)"
"$ENGINE/scripts/conf-overlay.sh" "$base_dists" \
  --set DISTS="${INPUT_DISTS:-}" --set ALIASES="${INPUT_ALIASES:-}" --set ARCHES="${INPUT_ARCHES:-}" > "$tmp/dists.conf"
"$ENGINE/scripts/conf-overlay.sh" "$INSTANCE/conf/site.conf" \
  --set REPO_NAME="${INPUT_REPO_NAME:-}" --set SITE_TITLE="${INPUT_SITE_TITLE:-}" \
  --set SITE_TAGLINE="${INPUT_SITE_TAGLINE:-}" --set THEME="${INPUT_THEME:-}" \
  --default REPO_URL="${BASE_URL:-}" > "$tmp/site.conf"
export DISTS_CONF="$tmp/dists.conf" SITE_CONF="$tmp/site.conf"

make --no-print-directory -f "$ENGINE/Makefile" SITE="$SITE" publish verify
[ -z "${GITHUB_OUTPUT:-}" ] || echo "site=$SITE" >> "$GITHUB_OUTPUT"
echo "✅ site ready: $SITE ($("$ENGINE/scripts/instance-info.sh" REPO_URL))"
