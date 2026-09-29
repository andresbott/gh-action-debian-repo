#!/usr/bin/env bash
# Cut an engine release: pin the reusable workflow's engine checkout to the new
# version, commit, tag, and (for a final release) move the major tag clients
# call (@v1). Callers run the workflow file from the ref they name, and that
# file checks the engine out at its own pinned version — so @v1 and @v1.2.3
# always run scripts from the same release. Never pushes: prints the commands.
# Usage: scripts/release.sh vX.Y.Z[-rc.N]
set -euo pipefail

VERSION="${1:-}"
printf '%s' "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$' \
  || { echo "❌ version must be vX.Y.Z or vX.Y.Z-rc.N, got '$VERSION'" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF=.github/workflows/publish.yml
g(){ git -C "$ROOT" "$@"; }

[ -z "$(g status --porcelain)" ] || { echo "❌ the working tree is not clean — commit or stash first" >&2; exit 1; }
! g rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || { echo "❌ tag $VERSION already exists" >&2; exit 1; }
pin="inputs.engine-ref || '"
grep -qF "$pin" "$ROOT/$WF" || { echo "❌ no \"${pin}vX.Y.Z'\" engine pin in $WF" >&2; exit 1; }

sed -i -E "s/(inputs\.engine-ref \|\| ')v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?'/\1$VERSION'/g" "$ROOT/$WF"
if grep -oE "inputs\.engine-ref \|\| '[^']*'" "$ROOT/$WF" | grep -vqF "'$VERSION'"; then
  g checkout -- "$WF"; echo "❌ an engine pin in $WF is not a version — fix it by hand" >&2; exit 1
fi
if ! g diff --quiet -- "$WF"; then
  g add "$WF"; g commit --quiet -m "release $VERSION"
fi
g tag -a "$VERSION" -m "$VERSION"
branch="$(g rev-parse --abbrev-ref HEAD)"
echo "✅ tagged $VERSION ($(g rev-parse --short "$VERSION^{commit}"), $WF pinned to $VERSION)"
if [[ "$VERSION" == *-rc.* ]]; then
  echo ">> release candidate: the major tag is not moved. Push with:"
  echo "   git push origin $branch $VERSION"
else
  major="${VERSION%%.*}"
  g tag -f -a "$major" -m "$major -> $VERSION" "$VERSION^{commit}" >/dev/null
  echo "✅ moved $major -> $VERSION"
  echo ">> push with:"
  echo "   git push origin $branch $VERSION && git push --force origin $major"
fi
