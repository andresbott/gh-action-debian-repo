#!/usr/bin/env bash
# Cut an engine release and push it: pin the reusable workflow's engine checkout
# to the new version, commit, tag, (for a final release) move the major tag
# clients call (@v1), then push the branch and the tags to origin in one atomic
# push. Callers run the workflow file from the ref they name, and that file
# checks the engine out at its own pinned version — so @v1 and @v1.2.3 always
# run scripts from the same release. The version must be newer than every
# release of its major line, here or on origin, so @vN never moves backwards.
# Usage: scripts/release.sh vX.Y.Z[-rc.N]
set -euo pipefail

N='(0|[1-9][0-9]*)'
SEMVER="^v$N\.$N\.$N(-rc\.$N)?\$"
VERSION="${1:-}"
[[ "$VERSION" =~ $SEMVER ]] \
  || { echo "❌ version must be vX.Y.Z or vX.Y.Z-rc.N (no leading zeros), got '$VERSION'" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF=.github/workflows/publish.yml
g(){ git -C "$ROOT" "$@"; }
# "X Y Z final rc tag", sortable: an rc sorts before its final release
key(){ local v="${1#v}"; case "$v" in *-rc.*) printf '%s 0 %s' "${v%%-*}" "${v##*.}";; *) printf '%s 1 0' "$v";; esac | tr . ' '; echo " $1"; }

[ -z "$(g status --porcelain)" ] || { echo "❌ the working tree is not clean — commit or stash first" >&2; exit 1; }
branch="$(g symbolic-ref -q --short HEAD)" || { echo "❌ HEAD is detached — check out the branch to release from" >&2; exit 1; }
pin="inputs.engine-ref || '"
grep -qF "$pin" "$ROOT/$WF" || { echo "❌ no \"${pin}vX.Y.Z'\" engine pin in $WF" >&2; exit 1; }

remote="$(g ls-remote --refs origin "refs/heads/$branch" 'refs/tags/*')" || { echo "❌ cannot reach origin" >&2; exit 1; }
tags="$( { g tag -l; printf '%s\n' "$remote" | awk '$2 ~ /^refs\/tags\// { sub(/^refs\/tags\//, "", $2); print $2 }'; } | sort -u)"
! grep -qxF "$VERSION" <<<"$tags" || { echo "❌ tag $VERSION already exists (here or on origin)" >&2; exit 1; }
major="${VERSION%%.*}"
newest="$( { grep -E "$SEMVER" <<<"$tags" | grep "^$major\." || true; echo "$VERSION"; } | while read -r t; do key "$t"; done \
  | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | tail -n1 | awk '{ print $NF }')"
[ "$newest" = "$VERSION" ] || { echo "❌ $VERSION is not newer than $newest, the latest $major release" >&2; exit 1; }
upstream="$(awk -v r="refs/heads/$branch" '$2 == r { print $1 }' <<<"$remote")"
[ -z "$upstream" ] || g merge-base --is-ancestor "$upstream" HEAD 2>/dev/null \
  || { echo "❌ origin/$branch has commits this checkout lacks — pull first" >&2; exit 1; }

sed -i -E "s/(inputs\.engine-ref \|\| ')v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?'/\1$VERSION'/g" "$ROOT/$WF"
if grep -oE "inputs\.engine-ref \|\| '[^']*'" "$ROOT/$WF" | grep -vqF "'$VERSION'"; then
  g checkout -- "$WF"; echo "❌ an engine pin in $WF is not a version — fix it by hand" >&2; exit 1
fi
if ! g diff --quiet -- "$WF"; then
  g add "$WF"; g commit --quiet -m "release $VERSION"
fi
g tag -a "$VERSION" -m "$VERSION"
echo "✅ tagged $VERSION ($(g rev-parse --short "$VERSION^{commit}"), $WF pinned to $VERSION)"
refs=("$branch" "refs/tags/$VERSION")
if [[ "$VERSION" == *-rc.* ]]; then
  echo ">> release candidate: the major tag is not moved"
else
  g tag -f -a "$major" -m "$major -> $VERSION" "$VERSION^{commit}" >/dev/null
  echo "✅ moved $major -> $VERSION"
  refs+=("+refs/tags/$major")
fi
g push --quiet --atomic origin "${refs[@]}" || {
  echo "❌ push failed — $VERSION is tagged locally; retry with:" >&2
  echo "   git push --atomic origin ${refs[*]}" >&2; exit 1; }
echo "✅ pushed $branch, $VERSION$([[ "$VERSION" == *-rc.* ]] || echo " and $major") to origin"
