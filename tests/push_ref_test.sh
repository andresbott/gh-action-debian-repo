#!/usr/bin/env bash
# scripts/push-ref.sh against local bare repositories (file:// remotes): the
# register action's git side, in self mode (orphan branch) and collection mode.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need git dpkg-deb jq
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org

# a collection repository: main holds conf/ and one existing reference
git init --quiet --bare --initial-branch=main "$tmp/collection.git"
git clone --quiet "$tmp/collection.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/conf" "$tmp/seed/packages"
printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64"\n' > "$tmp/seed/conf/dists.conf"
jq -n '{name:"other", version:"1.0", artifacts:[{release:"any", arch:"amd64",
  url:"https://github.com/acme/other/releases/download/v1/other_1.0_amd64.deb", sha256:("0"*64)}]}' > "$tmp/seed/packages/other.json"
git -C "$tmp/seed" add -A && git -C "$tmp/seed" commit --quiet -m seed && git -C "$tmp/seed" push --quiet origin main
REMOTE="file://$tmp/collection.git"

dist="$tmp/dist"; make_deb "$dist" myapp 1.0 amd64 a >/dev/null
push(){ "$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name myapp --dist-dir "$dist" \
          --repo acme/myapp --tag v1.0 "$@"; }
show(){ git --git-dir="$tmp/collection.git" show "main:$1" 2>/dev/null; }
commits(){ git --git-dir="$tmp/collection.git" rev-list --count "${1:-main}"; }

push >/dev/null 2>&1 && [ "$(show packages/myapp.json | jq -r .version)" = 1.0 ] \
  && ok "reference pushed to the collection" || bad "first push"
[ "$(git --git-dir="$tmp/collection.git" log -1 --format=%s main)" = "myapp 1.0 (packages/myapp.json)" ] \
  && ok "commit subject names package, version and file" || bad "commit subject: $(git --git-dir="$tmp/collection.git" log -1 --format=%s main)"
[ "$(git --git-dir="$tmp/collection.git" log -1 --format=%an main)" = "github-actions[bot]" ] \
  && ok "committed as github-actions[bot] by default" || bad "author"
n=$(commits); out="$(push 2>&1)"
[ "$(commits)" = "$n" ] && printf '%s' "$out" | grep -q 'nothing to push' && ok "unchanged reference -> no commit" || bad "re-push created a commit"

# rejected BEFORE anything is committed: the collection is left untouched
n=$(commits)
make_deb "$tmp/badrel/forky" myapp 1.0 amd64 f >/dev/null
out="$("$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name myapp --dist-dir "$tmp/badrel" \
  --repo acme/myapp --tag v1.0 2>&1)" && bad "release unknown to the target accepted" \
  || { printf '%s' "$out" | grep -q "unknown release 'forky'" && ok "release unknown to the target rejected" || bad "unknown release message: $out"; }
make_deb "$tmp/badarch" myapp 1.0 arm64 r >/dev/null
out="$("$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name myapp --dist-dir "$tmp/badarch" \
  --repo acme/myapp --tag v1.0 2>&1)" && bad "arch unknown to the target accepted" \
  || { printf '%s' "$out" | grep -q "arch 'arm64' is not published by the target" && ok "arch unknown to the target rejected" || bad "unknown arch message: $out"; }
make_deb "$tmp/dup" other 2.0 amd64 d >/dev/null
out="$("$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name other --dist-dir "$tmp/dup" \
  --repo acme/other --tag v2 --file packages/other.v2.json 2>&1)" && bad "colliding (package, release, arch) accepted" \
  || { printf '%s' "$out" | grep -q 'already provided by packages/other.json' && ok "collision with another reference rejected" || bad "collision message: $out"; }
out="$(push --file packages/other.json 2>&1)" && bad "another package's reference overwritten" \
  || { printf '%s' "$out" | grep -q "packages/other.json belongs to package 'other'" \
       && [ "$(show packages/other.json | jq -r .name)" = other ] && ok "--file naming another package's reference rejected" \
       || bad "foreign --file message: $out"; }
for f in ../x.json packages/../x.json packages/sub/x.json packages/x.txt /etc/x.json; do
  push --file "$f" >/dev/null 2>&1 && bad "--file $f accepted" || ok "--file $f rejected"
done
[ "$(commits)" = "$n" ] && ok "rejections leave the collection untouched" || bad "a rejected push committed"

# the collection's committed debs/ claim (package, release, arch) too, as hydrate counts them
git clone --quiet "$tmp/collection.git" "$tmp/withdebs"
make_deb "$tmp/withdebs/debs" tool 1.0 amd64 flat >/dev/null            # bare = any
make_deb "$tmp/withdebs/debs/trixie" gadget 1.0 amd64 tx >/dev/null
git -C "$tmp/withdebs" add -A && git -C "$tmp/withdebs" commit --quiet -m debs && git -C "$tmp/withdebs" push --quiet origin main
n=$(commits)
make_deb "$tmp/gadget" gadget 2.0 amd64 g >/dev/null                   # any -> bookworm + trixie
out="$("$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name gadget --dist-dir "$tmp/gadget" \
  --repo acme/gadget --tag v2 2>&1)" && bad "reference colliding with debs/<release>/ accepted" \
  || { printf '%s' "$out" | grep -q '(gadget trixie amd64) is already provided by debs/trixie/gadget_1.0_tx_amd64.deb' \
       && ok "collision with a committed debs/<release>/*.deb rejected" || bad "debs/<release> collision message: $out"; }
make_deb "$tmp/tool/bookworm" tool 2.0 amd64 t >/dev/null
out="$("$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name tool --dist-dir "$tmp/tool" \
  --repo acme/tool --tag v2 2>&1)" && bad "reference colliding with a bare debs/*.deb accepted" \
  || { printf '%s' "$out" | grep -q '(tool bookworm amd64) is already provided by debs/tool_1.0_flat_amd64.deb' \
       && ok "collision with a committed debs/*.deb (any) rejected" || bad "debs/ collision message: $out"; }
[ "$(commits)" = "$n" ] || bad "a debs/ collision committed"

# owners.conf in the collection: only listed packages from their own repos
git clone --quiet "$tmp/collection.git" "$tmp/own"
printf 'myapp acme/myapp\nother acme/other\n' > "$tmp/own/conf/owners.conf"
git -C "$tmp/own" add -A && git -C "$tmp/own" commit --quiet -m owners && git -C "$tmp/own" push --quiet origin main
make_deb "$tmp/v2" myapp 2.0 amd64 b >/dev/null
"$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name myapp --dist-dir "$tmp/v2" \
  --repo evil/myapp --tag v2 >/dev/null 2>&1 && bad "owners.conf: foreign repo accepted" || ok "owners.conf: foreign repo rejected"
"$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name myapp --dist-dir "$tmp/v2" \
  --repo acme/myapp --tag v2 >/dev/null 2>&1 && [ "$(show packages/myapp.json | jq -r .version)" = 2.0 ] \
  && ok "owners.conf: owner's new version accepted" || bad "owners.conf: owner rejected"

# concurrent publishes from several apps all land (fetch + rebase + retry)
for i in 1 2 3 4; do make_deb "$tmp/c$i" "app$i" 1.0 amd64 c >/dev/null; done
git -C "$tmp/own" pull --quiet --rebase origin main
printf 'myapp acme/myapp\nother acme/other\napp1 acme/app1\napp2 acme/app2\napp3 acme/app3\napp4 acme/app4\n' > "$tmp/own/conf/owners.conf"
git -C "$tmp/own" commit --quiet -am owners2 && git -C "$tmp/own" push --quiet origin main
pids=()
for i in 1 2 3 4; do
  "$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main --name "app$i" --dist-dir "$tmp/c$i" \
    --repo "acme/app$i" --tag v1 >"$tmp/c$i.log" 2>&1 & pids+=($!)
done
okc=0; for p in "${pids[@]}"; do wait "$p" && okc=$((okc + 1)); done
all=1; for i in 1 2 3 4; do show "packages/app$i.json" >/dev/null || all=0; done
[ "$okc" = 4 ] && [ "$all" = 1 ] && ok "4 concurrent publishes all landed" || bad "concurrent publishes: $okc/4 ok; $(cat "$tmp"/c*.log | grep '❌')"

# self mode: the publishing branch is created on first use, holding only data
git init --quiet --bare --initial-branch=main "$tmp/app.git"
git clone --quiet "$tmp/app.git" "$tmp/appsrc" 2>/dev/null; echo code > "$tmp/appsrc/main.go"
git -C "$tmp/appsrc" add -A && git -C "$tmp/appsrc" commit --quiet -m code && git -C "$tmp/appsrc" push --quiet origin main
self(){ "$ROOT/scripts/push-ref.sh" --remote "file://$tmp/app.git" --branch apt --name "$1" --dist-dir "$2" \
          --repo acme/app --tag v1 "${@:3}"; }
self myapp "$dist" >/dev/null 2>&1 && bad "missing branch without --create-branch accepted" || ok "missing branch needs --create-branch"
pids=(); self myapp "$dist" --create-branch >"$tmp/s1.log" 2>&1 & pids+=($!)
self app1 "$tmp/c1" --create-branch >"$tmp/s2.log" 2>&1 & pids+=($!)
okc=0; for p in "${pids[@]}"; do wait "$p" && okc=$((okc + 1)); done
files="$(git --git-dir="$tmp/app.git" ls-tree -r --name-only apt 2>/dev/null | tr '\n' ' ')"
[ "$okc" = 2 ] && [ "$files" = "packages/app1.json packages/myapp.json " ] \
  && ok "orphan publishing branch created (racing creators both land)" || bad "self mode: $okc/2 ok, files: $files; $(cat "$tmp"/s*.log | grep '❌')"
[ "$(git --git-dir="$tmp/app.git" rev-list --count main)" = 1 ] && ok "main left untouched" || bad "self mode touched main"

# a self-mode branch has no conf/ of its own: the workflow's dists/aliases/arches
# inputs are the releases the publish builds, so the target check must use them
# (without them, the engine's defaults/dists.conf applies: trixie forky sid, amd64 arm64)
make_deb "$tmp/perrel/bookworm" relapp 1.0 amd64 bk >/dev/null
self relapp "$tmp/perrel" >/dev/null 2>&1 && bad "release outside the engine defaults accepted without --dists" \
  || ok "without --dists the engine's default releases apply"
self relapp "$tmp/perrel" --dists "bookworm trixie" --aliases stable:trixie >/dev/null 2>&1 \
  && git --git-dir="$tmp/app.git" show apt:packages/relapp.json >/dev/null 2>&1 \
  && ok "--dists overrides the target's releases (self mode)" || bad "--dists override"
# --dists alone: the engine default aliases whose target left DISTS (testing:forky,
# unstable:sid) are dropped instead of failing the check
make_deb "$tmp/perrel2/bookworm" relapp2 1.0 amd64 bk >/dev/null
out="$(self relapp2 "$tmp/perrel2" --dists "bookworm trixie" 2>&1)" \
  && git --git-dir="$tmp/app.git" show apt:packages/relapp2.json >/dev/null 2>&1 \
  && ok "--dists without --aliases (self mode) drops the dangling default aliases" || bad "--dists alone: $out"
make_deb "$tmp/rv" rvapp 1.0 riscv64 rv >/dev/null
self rvapp "$tmp/rv" --arches "amd64 riscv64" >/dev/null 2>&1 \
  && git --git-dir="$tmp/app.git" show apt:packages/rvapp.json >/dev/null 2>&1 \
  && ok "--arches overrides the target's architectures" || bad "--arches override"

# a push refused for any other reason (bad token, branch protection) fails at
# once with git's own message instead of retrying as if it were a race
git init --quiet --bare --initial-branch=main "$tmp/locked.git"
git clone --quiet "$tmp/collection.git" "$tmp/lockseed" && git -C "$tmp/lockseed" push --quiet "$tmp/locked.git" main
printf '#!/bin/sh\necho "protected branch hook declined" >&2; exit 1\n' > "$tmp/locked.git/hooks/pre-receive"; chmod +x "$tmp/locked.git/hooks/pre-receive"
git --git-dir="$tmp/locked.git" config core.hooksPath "$tmp/locked.git/hooks"   # beat a global core.hooksPath
make_deb "$tmp/c9" myapp 9.0 amd64 n >/dev/null
out="$("$ROOT/scripts/push-ref.sh" --remote "file://$tmp/locked.git" --branch main --name myapp --dist-dir "$tmp/c9" \
        --repo acme/myapp --tag v9 2>&1)" && bad "refused push reported success" \
  || { printf '%s' "$out" | grep -q 'protected branch hook declined' && ! printf '%s' "$out" | grep -q retrying \
       && ok "non-race push failure: git's error, no retries" || bad "refused push output: $out"; }

# a remote that cannot be read (bad token, missing repository, network) is not a
# missing branch: git's own error, and never an orphan branch pushed in its place
nowhere="file://$tmp/nowhere.git"
out="$("$ROOT/scripts/push-ref.sh" --remote "$nowhere" --branch main --name myapp --dist-dir "$dist" \
        --repo acme/myapp --tag v1.0 2>&1)" && bad "unreachable remote accepted" \
  || { printf '%s' "$out" | grep -q 'does not appear to be a git repository' && printf '%s' "$out" | grep -qF "cannot reach $nowhere" \
       && ! printf '%s' "$out" | grep -q 'not found' && ok "unreachable remote: git's error, not 'branch not found'" || bad "unreachable remote output: $out"; }
out="$("$ROOT/scripts/push-ref.sh" --remote "$nowhere" --branch apt --name myapp --dist-dir "$dist" \
        --repo acme/myapp --tag v1.0 --create-branch 2>&1)" && bad "unreachable remote accepted with --create-branch" \
  || { printf '%s' "$out" | grep -qF "cannot reach $nowhere" && ! printf '%s' "$out" | grep -q 'creating it' \
       && ok "--create-branch: an unreachable remote fails instead of creating an orphan" || bad "unreachable remote + --create-branch: $out"; }

# --verify-assets: a reference is only pushed when its release assets are public
# and match (a fake curl serves $FAKE_ASSETS/<file> for any release URL)
mkdir -p "$tmp/bin" "$tmp/assets"
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"; f="$FAKE_ASSETS/${url##*/}"
[ -f "$f" ] && cat "$f" || { echo "curl: (22) 404" >&2; exit 22; }
SH
chmod +x "$tmp/bin/curl"
make_deb "$tmp/v3" myapp 3.0 amd64 v >/dev/null
vpush(){ PATH="$tmp/bin:$PATH" FAKE_ASSETS="$tmp/assets" "$ROOT/scripts/push-ref.sh" --remote "$REMOTE" --branch main \
           --name myapp --dist-dir "$tmp/v3" --repo acme/myapp --tag v3 --verify-assets; }
n=$(commits)
out="$(vpush 2>&1)" && bad "missing release asset accepted" \
  || { printf '%s' "$out" | grep -q 'not downloadable' && printf '%s' "$out" | grep -q 'GitHub renames special characters' \
       && ok "--verify-assets: asset not uploaded -> rejected (with the renaming hint)" || bad "missing asset message: $out"; }
make_deb "$tmp/assets" myapp 3.0 amd64 other >/dev/null; mv "$tmp/assets"/*.deb "$tmp/assets/$(basename "$tmp"/v3/*.deb)"
out="$(vpush 2>&1)" && bad "mismatching release asset accepted" \
  || { printf '%s' "$out" | grep -q 'sha256 mismatch' && ok "--verify-assets: different asset -> rejected" || bad "mismatch message: $out"; }
[ "$(commits)" = "$n" ] || bad "a failed asset check committed"
cp "$tmp"/v3/*.deb "$tmp/assets/"
vpush >/dev/null 2>&1 && [ "$(show packages/myapp.json | jq -r .version)" = 3.0 ] \
  && ok "--verify-assets: matching asset -> pushed" || bad "matching asset rejected"

[ "$fail" = 0 ] && echo "PASS push_ref_test" || { echo "FAIL push_ref_test"; exit 1; }
