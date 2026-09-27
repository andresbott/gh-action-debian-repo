#!/usr/bin/env bash
# scripts/check-mode.sh: which input combinations select which mode, and which
# are rejected up front (before anything is pushed or deployed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
# cm KEY=VAL... -> runs check-mode with only those inputs; prints "<exit> <outputs...>"
cm(){ : > "$tmp/out"; env -i PATH="$PATH" GITHUB_OUTPUT="$tmp/out" GITHUB_REPOSITORY=acme/myapp "$@" "$ROOT/scripts/check-mode.sh" >"$tmp/log" 2>&1
      echo "$? $(tr '\n' ' ' < "$tmp/out")"; }
is(){ local want="$1" desc="$2"; shift 2; local got; got="$(cm "$@")"
      [ "$got" = "$want" ] && ok "$desc" || bad "$desc: got '$got' ($(cat "$tmp/log"))"; }
rejects(){ local msg="$1" desc="$2"; shift 2; local got; got="$(cm "$@")"
      [ "${got%% *}" = 1 ] && grep -q -- "$msg" "$tmp/log" && ok "$desc" || bad "$desc: got '$got' ($(cat "$tmp/log"))"; }

is "0 mode=publish-only tag= branch= target= target-owner= target-name= " "no inputs -> publish-only"
is "0 mode=self tag=v1.2 branch=apt target=acme/myapp target-owner=acme target-name=myapp " "name + artifact on a tag -> self, branch apt" \
   IN_NAME=myapp IN_ARTIFACT=debs REF_TYPE=tag REF_NAME=v1.2
is "0 mode=self tag=v9 branch=gh-apt target=acme/myapp target-owner=acme target-name=myapp " "tag and self-branch inputs win" \
   IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v9 IN_SELF_BRANCH=gh-apt REF_TYPE=branch REF_NAME=main
is "0 mode=collection tag=v1.2 branch=main target=acme/apt target-owner=acme target-name=apt " "collection + app -> collection, branch main" \
   IN_NAME=myapp IN_ARTIFACT=debs IN_COLLECTION=acme/apt IN_APP_ID=123 HAS_APP_KEY=true REF_TYPE=tag REF_NAME=v1.2
is "0 mode=collection tag=v1.2 branch=pages target=acme/apt target-owner=acme target-name=apt " "collection + token, collection-branch" \
   IN_NAME=myapp IN_ARTIFACT=debs IN_COLLECTION=acme/apt IN_COLLECTION_BRANCH=pages HAS_COLLECTION_TOKEN=true REF_TYPE=tag REF_NAME=v1.2
is "0 mode=self tag=v1 branch=apt target=acme/myapp target-owner=acme target-name=myapp " "build inputs allowed in self mode" \
   IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_DISTS=trixie IN_THEME=teal

rejects "needs 'name'" "collection without name" IN_COLLECTION=acme/apt
rejects "needs 'name'" "artifact without name" IN_ARTIFACT=debs
rejects "'artifact' is required" "name without artifact" IN_NAME=myapp REF_TYPE=tag REF_NAME=v1
rejects "not running for a tag" "branch push without a tag input" IN_NAME=myapp IN_ARTIFACT=debs REF_TYPE=branch REF_NAME=main
rejects "not a Debian package name" "invalid package name" IN_NAME=MyApp IN_ARTIFACT=debs IN_TAG=v1
rejects "needs credentials" "collection without app or token" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_COLLECTION=acme/apt
rejects "app-private-key secret is not" "app-id without its key" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_COLLECTION=acme/apt IN_APP_ID=1
rejects "must be owner/name" "malformed collection" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_COLLECTION=https://github.com/acme/apt HAS_COLLECTION_TOKEN=true
rejects "only applies to collection" "app-id in self mode" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_APP_ID=1 HAS_APP_KEY=true
rejects "not a valid branch name" "invalid self-branch" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_SELF_BRANCH='a..b'
rejects "must be packages/" "file outside packages/" IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_FILE=../x.json
rejects "no effect in collection mode" "build inputs in collection mode" \
   IN_NAME=myapp IN_ARTIFACT=debs IN_TAG=v1 IN_COLLECTION=acme/apt HAS_COLLECTION_TOKEN=true IN_DISTS=trixie IN_THEME=teal
cm IN_NAME=MyApp IN_COLLECTION=x >/dev/null; [ "$(grep -c '❌' "$tmp/log")" -ge 3 ] && ok "all problems reported at once" || bad "errors: $(cat "$tmp/log")"
[ ! -s "$tmp/out" ] && ok "no outputs on rejection" || bad "outputs written on rejection"
cm GITHUB_ACTIONS=true IN_COLLECTION=acme/apt >/dev/null; grep -q '^::error title=debian-repo::' "$tmp/log" && ok "annotations in Actions" || bad "no ::error annotation"

[ "$fail" = 0 ] && echo "PASS check_mode_test" || { echo "FAIL check_mode_test"; exit 1; }
