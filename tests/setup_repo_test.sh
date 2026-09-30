#!/usr/bin/env bash
# scripts/setup-repo.sh and `make key-to-repo` against a fake `gh` that logs
# every call and answers the few GETs from canned state.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need gpg make
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }

# fake gh: logs "<args> [<stdin>]" per call; state via FAKE_PAGES / FAKE_POLICIES
cat > "$tmp/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"; in=""; case " $* " in *" --input - "*|*" secret set "*) in="$(cat)";; esac
printf '%s\n' "$args${in:+ <<< $(printf '%s' "$in" | head -c 120 | tr '\n' ' ')}" >> "$FAKE_LOG"
case "$args" in
  "api -X GET repos/"*/pages)                       [ "${FAKE_PAGES:-absent}" = present ] || { echo "HTTP 404" >&2; exit 1; };;
  "api -X GET repos/"*"/deployment-branch-policies"*) printf '%b' "${FAKE_POLICIES:-}";;
  "api -X GET repos/"*" --jq .default_branch")      echo trunk;;
esac
exit 0
FAKE
chmod +x "$tmp/gh"; export GH="$tmp/gh" FAKE_LOG="$tmp/log"

# fresh repository: Pages created, environment restricted, default branch + tag policy added
: > "$FAKE_LOG"; mkdir -p "$tmp/cwd"; touch "$tmp/cwd/vendor"   # a v* file must not glob
( cd "$tmp/cwd" && "$ROOT/scripts/setup-repo.sh" acme/debs ) >/dev/null || bad "setup-repo failed"
grep -qx 'api -X POST repos/acme/debs/pages -f build_type=workflow' "$FAKE_LOG" && ok "Pages created with build_type=workflow" || bad "Pages POST: $(cat "$FAKE_LOG")"
grep -q '^api -X PUT repos/acme/debs/environments/github-pages --input - <<< .*"custom_branch_policies": true' "$FAKE_LOG" \
  && ok "environment limited to custom policies" || bad "environment PUT"
grep -qx 'api -X POST repos/acme/debs/environments/github-pages/deployment-branch-policies -f name=trunk -f type=branch' "$FAKE_LOG" \
  && ok "default branch policy (from the repo, not assumed 'main')" || bad "branch policy"
grep -qx 'api -X POST repos/acme/debs/environments/github-pages/deployment-branch-policies -f name=v\* -f type=tag' "$FAKE_LOG" \
  && ok "default tag policy v*" || bad "tag policy: $(grep type=tag "$FAKE_LOG")"

# existing Pages + policies: updated in place, nothing duplicated; custom tag patterns
: > "$FAKE_LOG"
FAKE_PAGES=present FAKE_POLICIES='branch trunk\ntag v*\n' "$ROOT/scripts/setup-repo.sh" acme/debs 'v* debian_*' >/dev/null || bad "rerun failed"
grep -qx 'api -X PUT repos/acme/debs/pages -f build_type=workflow' "$FAKE_LOG" && ok "existing Pages switched to Actions" || bad "Pages PUT"
[ "$(grep -c 'deployment-branch-policies -f' "$FAKE_LOG")" = 1 ] && grep -q 'name=debian_\* -f type=tag' "$FAKE_LOG" \
  && ok "idempotent: only the missing debian_* policy added" || bad "policy re-add: $(grep 'policies -f' "$FAKE_LOG")"

# TAGS='' = no tag policy (a collection repo publishes from its default branch only)
: > "$FAKE_LOG"; "$ROOT/scripts/setup-repo.sh" acme/debs '' >/dev/null
grep -q 'type=tag' "$FAKE_LOG" && bad "empty TAGS still added a tag policy" || ok "empty TAGS adds no tag policy"
"$ROOT/scripts/setup-repo.sh" 'not a repo' >/dev/null 2>&1 && bad "invalid repo accepted" || ok "invalid repo rejected"

# make key-to-repo pipes the armored private key into a repository secret, or
# with ENVIRONMENT= into that environment's secret
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" k@example.org; : > "$FAKE_LOG"
out="$(make --no-print-directory -f "$ROOT/Makefile" -C "$tmp/cwd" key-to-repo REPO=acme/debs GNUPGHOME="$GNUPGHOME" 2>&1)" || bad "key-to-repo failed: $out"
grep -q '^secret set APT_SIGNING_KEY --repo acme/debs <<< -----BEGIN PGP PRIVATE KEY BLOCK-----' "$FAKE_LOG" \
  && ok "key-to-repo sets the APT_SIGNING_KEY repository secret" || bad "key-to-repo: $(cat "$FAKE_LOG")"
printf '%s' "$out" | grep -qF 'secrets: { APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }} }' \
  && ok "key-to-repo shows how to pass the secret" || bad "key-to-repo hint: $out"
: > "$FAKE_LOG"; make --no-print-directory -f "$ROOT/Makefile" -C "$tmp/cwd" key-to-repo REPO=acme/debs ENVIRONMENT=github-pages GNUPGHOME="$GNUPGHOME" >/dev/null 2>&1
grep -q '^secret set APT_SIGNING_KEY --repo acme/debs --env github-pages <<< -----BEGIN PGP PRIVATE KEY BLOCK-----' "$FAKE_LOG" \
  && ok "key-to-repo ENVIRONMENT= sets that environment's secret" || bad "key-to-repo ENVIRONMENT=: $(cat "$FAKE_LOG")"
# before uploading, it names every secret key it is about to upload
fpr="$(gpg --batch --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
printf '%s\n' "$out" | grep -qF "$fpr  test <k@example.org>" \
  && ok "key-to-repo lists the fingerprint and uid of each key it uploads" || bad "key-to-repo listing: $out"

[ "$fail" = 0 ] && echo "PASS setup_repo_test" || { echo "FAIL setup_repo_test"; exit 1; }
