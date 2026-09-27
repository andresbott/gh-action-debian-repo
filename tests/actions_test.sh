#!/usr/bin/env bash
# The composite actions' own `run:` steps (actionlint does not read action.yml),
# executed the way the runner does: env resolved from the inputs, bash -eo
# pipefail, GITHUB_ACTION_PATH pointing at the action. Catches an input that is
# mapped to the wrong variable, and proves the push token stays out of git's
# arguments and URLs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need python3 git jq dpkg-deb apt-ftparchive gpg gpgv make
python3 -c 'import yaml' 2>/dev/null || { echo "⚠️  skipping: python3 yaml module missing"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
unset SITE GNUPGHOME THEME APT_SIGNING_KEY EPHEMERAL_KEY INSTANCE PKG_DIR DEBS_DIR OWNERS_CONF SITE_CONF DISTS_CONF INDEX_TEMPLATE

# step <action> <step> [input=value...] -> runs that step; stdout+stderr to $tmp/step.log
step(){
  local a="$ROOT/actions/$1" run; shift
  run="$("$ROOT/tests/action-step.py" "$a/action.yml" "$@" 3>"$tmp/env")" || return 1
  local envs=(); while IFS= read -r -d '' kv; do envs+=("$kv"); done < "$tmp/env"
  env -i PATH="$STEP_PATH" HOME="$HOME" RUNNER_TEMP="$RUNNER_TEMP" GITHUB_OUTPUT="$GITHUB_OUTPUT" \
      GIT_CONFIG_GLOBAL="$tmp/gitconfig" GITHUB_ACTION_PATH="$a" "${envs[@]}" \
      bash --noprofile --norc -eo pipefail -c "$run" >"$tmp/step.log" 2>&1
}
export RUNNER_TEMP="$tmp/runner" GITHUB_OUTPUT="$tmp/gh_out"; mkdir -p "$RUNNER_TEMP"; : > "$tmp/gitconfig"
STEP_PATH="$PATH"

# every declared input is used, every reference is declared
for a in build register; do
  y="$ROOT/actions/$a/action.yml"
  for i in $(python3 -c 'import yaml,sys; print(*yaml.safe_load(open(sys.argv[1]))["inputs"])' "$y"); do
    grep -q "inputs\.$i }}" "$y" || bad "actions/$a: input '$i' is never used"
  done
done
"$ROOT/tests/action-step.py" "$ROOT/actions/build/action.yml" build bogus=1 3>/dev/null >/dev/null 2>&1 \
  && bad "undeclared input accepted by the helper" || ok "undeclared inputs are caught"

# --- build: each input reaches ci-build.sh ---
make_instance "$tmp/acme-debs"
printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64 arm64"\n' > "$INSTANCE/conf/dists.conf"
make_deb "$INSTANCE/debs" widget 1.0 amd64 w >/dev/null
make_test_key "$tmp/owner" owner@example.org
key="$(GNUPGHOME="$tmp/owner" gpg --batch --export-secret-keys --armor)"
if step build build instance="$INSTANCE" signing-key="$key" base-url=https://acme.github.io/acme-debs \
     dists=trixie aliases=stable:trixie arches=amd64 repo-name=acme site-title="Acme T" site-tagline="Acme tag" theme=teal; then
  ok "build step runs"
else bad "build step: $(tail -5 "$tmp/step.log")"; fi
site="$(sed -n 's/^site=//p' "$GITHUB_OUTPUT" | tail -1)"
[ -n "$site" ] && [ -f "$site/acme.sources" ] && ok "repo-name -> REPO_NAME, site output set" || bad "repo-name/site output ($site)"
grep -q '^URIs: https://acme.github.io/acme-debs$' "$site/acme.sources" && ok "base-url -> REPO_URL" || bad "base-url"
grep -q '^Architectures: amd64$' "$site/acme.sources" && ok "arches -> ARCHES" || bad "arches"
[ -d "$site/dists/trixie" ] && [ ! -d "$site/dists/bookworm" ] && grep -q '^Codename: trixie' "$site/dists/stable/Release" \
  && ok "dists/aliases -> DISTS/ALIASES" || bad "dists/aliases"
grep -q 'Acme T' "$site/index.html" && grep -q 'Acme tag' "$site/index.html" && grep -q -- '--accent:#33D6B5' "$site/index.html" \
  && ok "site-title/site-tagline/theme -> page" || bad "page inputs"

# --- register: pushes through https://github.com/<repo>.git with the token in a header ---
mkdir -p "$tmp/remotes/acme" "$tmp/bin"
git init --quiet --bare --initial-branch=main "$tmp/remotes/acme/apt.git"
git clone --quiet "$tmp/remotes/acme/apt.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/conf"; printf 'DISTS="trixie"\nARCHES="amd64"\n' > "$tmp/seed/conf/dists.conf"
git -C "$tmp/seed" add -A; git -C "$tmp/seed" -c user.name=t -c user.email=t@e commit --quiet -m seed; git -C "$tmp/seed" push --quiet origin main
printf '[url "file://%s/remotes/"]\n\tinsteadOf = https://github.com/\n' "$tmp" > "$tmp/gitconfig"
# a git that logs its arguments and the header config it was given
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<SH
#!/usr/bin/env bash
printf 'ARGV %s\n' "\$*" >> "$tmp/git.log"
printf 'HEADER %s=%s\n' "\${GIT_CONFIG_KEY_0:-}" "\${GIT_CONFIG_VALUE_0:-}" >> "$tmp/git.log"
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/git"; STEP_PATH="$tmp/bin:$PATH"
dist="$tmp/dist"; make_deb "$dist" myapp 1.0 amd64 a >/dev/null
token="ghs_s3cr3tT0ken"
reg(){ step register "Register and push" name=myapp dist-dir="$dist" source-repository=acme/myapp tag=v1 token="$token" verify-assets=false "$@"; }
reg repository=acme/apt branch=main && git --git-dir="$tmp/remotes/acme/apt.git" show main:packages/myapp.json >/dev/null 2>&1 \
  && ok "register pushes packages/myapp.json to https://github.com/acme/apt.git" || bad "register: $(tail -5 "$tmp/step.log")"
want="HEADER http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
grep -qxF "$want" "$tmp/git.log" && ok "token passed as an extraheader" || bad "header: $(grep HEADER "$tmp/git.log" | sort -u)"
grep '^ARGV' "$tmp/git.log" | grep -qF "$token" && bad "token in a git argument" || ok "token never in git's arguments or URLs"
grep -qF "::add-mask::$(printf 'x-access-token:%s' "$token" | base64 -w0)" "$tmp/step.log" && ok "encoded token masked" || bad "no ::add-mask::"
grep -qF "$token" "$tmp/step.log" && bad "token printed" || ok "token never printed"
reg repository=acme/apt branch=apt >/dev/null 2>&1 && bad "missing branch created without create-branch" || ok "create-branch=false keeps a missing branch an error"
reg repository=acme/apt branch=apt create-branch=true >/dev/null 2>&1 \
  && git --git-dir="$tmp/remotes/acme/apt.git" show apt:packages/myapp.json >/dev/null 2>&1 \
  && ok "create-branch=true creates it" || bad "create-branch: $(tail -5 "$tmp/step.log")"
reg repository=acme/apt branch=main file=packages/myapp.v1.json >/dev/null 2>&1; grep -q 'unchanged\|already provided' "$tmp/step.log" \
  && ok "file input reaches push-ref" || bad "file: $(tail -3 "$tmp/step.log")"
# dists/aliases/arches reach push-ref: bookworm and arm64 are outside the
# target's conf/dists.conf (trixie, amd64), so only the inputs admit them
make_deb "$tmp/bkw/bookworm" bkwapp 1.0 arm64 b >/dev/null
bkw(){ step register "Register and push" name=bkwapp dist-dir="$tmp/bkw" source-repository=acme/bkwapp tag=v1 \
         token="$token" verify-assets=false repository=acme/apt branch=main "$@"; }
bkw >/dev/null 2>&1 && bad "bookworm/arm64 accepted without the inputs" || ok "the target's dists.conf applies without the inputs"
bkw aliases=stable >/dev/null 2>&1; grep -q 'malformed ALIASES' "$tmp/step.log" \
  && ok "aliases input reaches push-ref" || bad "aliases: $(tail -3 "$tmp/step.log")"
bkw dists="bookworm trixie" aliases=stable:trixie arches="amd64 arm64" >/dev/null 2>&1 \
  && git --git-dir="$tmp/remotes/acme/apt.git" show main:packages/bkwapp.json >/dev/null 2>&1 \
  && ok "dists/arches inputs reach push-ref" || bad "dists/arches: $(tail -3 "$tmp/step.log")"
printf '#!/bin/sh\necho "curl: (22) 404" >&2; exit 22\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"   # no network
step register "Register and push" name=myapp dist-dir="$dist" source-repository=acme/myapp tag=v1 token="$token" \
  repository=acme/apt branch=main >/dev/null 2>&1; grep -q 'not downloadable' "$tmp/step.log" \
  && ok "verify-assets defaults to on" || bad "verify-assets default: $(tail -3 "$tmp/step.log")"

[ "$fail" = 0 ] && echo "PASS actions_test" || { echo "FAIL actions_test"; exit 1; }
