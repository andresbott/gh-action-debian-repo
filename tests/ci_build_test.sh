#!/usr/bin/env bash
# scripts/ci-build.sh — the build action's body — run the way the publish job
# runs it: workflow inputs in INPUT_*, the Pages URL in BASE_URL, the key in
# APT_SIGNING_KEY (or EPHEMERAL_KEY=1), a RUNNER_TEMP outside the instance.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need make dpkg-deb apt-ftparchive gpg gpgv jq
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
unset SITE GNUPGHOME THEME APT_SIGNING_KEY EPHEMERAL_KEY PKG_DIR DEBS_DIR OWNERS_CONF SITE_CONF DISTS_CONF INDEX_TEMPLATE
export RUNNER_TEMP="$tmp/runner"; mkdir -p "$RUNNER_TEMP"

make_instance "$tmp/acme-debs"
printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64"\n' > "$INSTANCE/conf/dists.conf"
make_deb "$INSTANCE/debs" widget 1.0 amd64 w >/dev/null
( cd "$INSTANCE" && find conf -type f -exec sha256sum {} + ) > "$tmp/conf.sum"
ci(){ env -u GITHUB_OUTPUT "$@" "$ROOT/scripts/ci-build.sh"; }

out="$(ci 2>&1)" && bad "no key accepted" \
  || { printf '%s' "$out" | grep -q 'no APT_SIGNING_KEY secret' && ok "no key -> actionable error" || bad "no-key message: $out"; }

# a real key, as 'make key-to-repo' stores it
make_test_key "$tmp/owner" owner@example.org
key="$(GNUPGHOME="$tmp/owner" gpg --batch --export-secret-keys --armor)"
fpr="$(GNUPGHOME="$tmp/owner" gpg --batch --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
if ci APT_SIGNING_KEY="$key" SITE="$tmp/site" BASE_URL=https://acme.github.io/acme-debs GITHUB_OUTPUT="$tmp/gh_out" \
      INPUT_SITE_TITLE="Acme & co" INPUT_THEME=teal >"$tmp/ci.log" 2>&1; then ok "build with APT_SIGNING_KEY"
else bad "build with APT_SIGNING_KEY: $(tail -5 "$tmp/ci.log")"; fi
grep -qx "site=$tmp/site" "$tmp/gh_out" 2>/dev/null && ok "site path written to GITHUB_OUTPUT" || bad "GITHUB_OUTPUT: $(cat "$tmp/gh_out" 2>/dev/null)"
[ "$(gpg --show-keys --with-colons "$tmp/site/acme-debs-archive-keyring.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')" = "$fpr" ] \
  && ok "published keyring is the secret's key" || bad "published keyring fingerprint"
grep -q '^URIs: https://acme.github.io/acme-debs$' "$tmp/site/acme-debs.sources" \
  && ok "Pages URL becomes REPO_URL" || bad "sources URIs: $(grep URIs "$tmp/site/acme-debs.sources")"
grep -q 'Acme &amp; co' "$tmp/site/index.html" && grep -q -- '--accent:#33D6B5' "$tmp/site/index.html" \
  && ok "site-title/theme inputs reach the page" || bad "inputs not rendered"
grep -rqs 'PRIVATE KEY' "$tmp/site" && bad "private key material in the site" || ok "no private key in the site"
[ -z "$(ls -A "$RUNNER_TEMP" | grep -v '^debrepo-site$')" ] && ok "temp keyring removed" || bad "left in RUNNER_TEMP: $(ls -A "$RUNNER_TEMP")"
( cd "$INSTANCE" && sha256sum -c --quiet "$tmp/conf.sum" ) && [ ! -e "$INSTANCE/_site" ] && [ ! -e "$INSTANCE/.gnupg-repo" ] \
  && ok "instance checkout untouched" || bad "ci-build modified the instance"

# committed site.conf wins over the Pages URL; inputs win over committed dists.conf
printf 'REPO_URL=https://apt.acme.example\n' > "$INSTANCE/conf/site.conf"
ci EPHEMERAL_KEY=1 SITE="$tmp/site2" BASE_URL=https://acme.github.io/acme-debs INPUT_DISTS="trixie" INPUT_ALIASES="stable:trixie" \
  >"$tmp/ci2.log" 2>&1 || bad "ephemeral build: $(tail -5 "$tmp/ci2.log")"
grep -q '^URIs: https://apt.acme.example$' "$tmp/site2/acme-debs.sources" && ok "committed REPO_URL beats the Pages URL" || bad "REPO_URL precedence"
[ -d "$tmp/site2/dists/trixie" ] && [ ! -d "$tmp/site2/dists/bookworm" ] && grep -q '^Codename: trixie' "$tmp/site2/dists/stable/Release" \
  && ok "dists/aliases inputs override dists.conf" || bad "dists inputs: $(ls "$tmp/site2/dists")"
grep -q 'EPHEMERAL' "$tmp/ci2.log" && ok "ephemeral key is announced" || bad "no ephemeral warning"

# a self-mode branch has no conf/: a dists input alone keeps the engine default
# aliases that still have a target (stable:trixie) and drops the others
make_instance "$tmp/selfmode"; make_deb "$INSTANCE/debs" widget 1.0 amd64 w >/dev/null
if ci EPHEMERAL_KEY=1 SITE="$tmp/site6" INPUT_DISTS="bookworm trixie" >"$tmp/ci6.log" 2>&1 \
   && grep -q '^Codename: trixie' "$tmp/site6/dists/stable/Release" && [ ! -e "$tmp/site6/dists/testing" ] \
   && grep -q 'dropped alias(es) testing:forky unstable:sid' "$tmp/ci6.log"; then ok "dists input alone drops the dangling default aliases"
else bad "dists input alone: $(grep '❌\|⚠️' "$tmp/ci6.log")"; fi
INSTANCE="$tmp/acme-debs"

pub="$(GNUPGHOME="$tmp/owner" gpg --batch --export --armor)"
out="$(ci APT_SIGNING_KEY="$pub" SITE="$tmp/site3" 2>&1)" && bad "public-only key accepted" \
  || { printf '%s' "$out" | grep -q 'holds no private key' && ok "public-only secret rejected" || bad "public key message: $out"; }
out="$(ci APT_SIGNING_KEY="not a key" SITE="$tmp/site4" 2>&1)" && bad "garbage key accepted" || ok "garbage secret rejected"
ci EPHEMERAL_KEY=1 INPUT_DISTS='bookworm; touch pwned' SITE="$tmp/site5" >/dev/null 2>&1 && bad "invalid dists input accepted" || ok "invalid dists input rejected"
[ ! -e pwned ] && [ ! -e "$INSTANCE/pwned" ] || bad "an input was executed"

[ "$fail" = 0 ] && echo "PASS ci_build_test" || { echo "FAIL ci_build_test"; exit 1; }
