#!/usr/bin/env bash
# scripts/release.sh in a throwaway copy of the engine layout, pushing to a
# local bare remote.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org

r="$tmp/engine"; mkdir -p "$r/scripts" "$r/.github/workflows"; cp "$ROOT/scripts/release.sh" "$r/scripts/"
cat > "$r/.github/workflows/publish.yml" <<'YML'
jobs:
  register:
    steps:
      - with: { ref: "${{ inputs.engine-ref || 'v0.0.0' }}" }
  publish:
    steps:
      - with: { ref: "${{ inputs.engine-ref || 'v0.0.0' }}" }
YML
git init --quiet --initial-branch=main "$r"; git -C "$r" add -A; git -C "$r" commit --quiet -m init
git init --quiet --bare "$tmp/remote.git"; git -C "$r" remote add origin "$tmp/remote.git"
rel(){ "$r/scripts/release.sh" "$@"; }
pins(){ grep -oE "engine-ref \|\| '[^']*'" "$r/.github/workflows/publish.yml" | sort -u | tr '\n' ' '; }
at(){ git -C "$r" rev-parse -q --verify "$1^{commit}" 2>/dev/null; }
rat(){ git --git-dir="$tmp/remote.git" rev-parse -q --verify "$1^{commit}" 2>/dev/null; }

for v in 1.0.0 v1.0 v1.0.0-beta v1.0.0-rc v01.0.0 v1.00.0 v1.0.0-rc.01; do rel "$v" >/dev/null 2>&1 && bad "version '$v' accepted" || ok "version '$v' rejected"; done
echo x > "$r/dirty"; rel v1.0.0 >/dev/null 2>&1 && bad "dirty tree accepted" || ok "dirty tree refused"; rm "$r/dirty"
git -C "$r" checkout --quiet --detach; rel v1.0.0 >/dev/null 2>&1 && bad "detached HEAD accepted" || ok "detached HEAD refused"; git -C "$r" checkout --quiet main
git -C "$r" remote set-url origin "$tmp/nowhere.git"
rel v1.0.0 >/dev/null 2>&1 && bad "unreachable origin accepted" || ok "unreachable origin refused"
git -C "$r" remote set-url origin "$tmp/remote.git"
[ -z "$(git -C "$r" tag)" ] && [ "$(git -C "$r" log -1 --format=%s)" = init ] || bad "a refused release created a tag or a commit"
[ -z "$(git --git-dir="$tmp/remote.git" for-each-ref)" ] || bad "a refused release pushed"

out="$(rel v1.0.0-rc.1 2>&1)" || bad "rc release: $out"
[ "$(pins)" = "engine-ref || 'v1.0.0-rc.1' " ] && ok "rc pins every engine checkout" || bad "rc pins: $(pins)"
[ "$(git -C "$r" log -1 --format=%s)" = "release v1.0.0-rc.1" ] && ok "pin committed" || bad "commit subject"
[ "$(git -C "$r" cat-file -t v1.0.0-rc.1)" = tag ] && ok "annotated tag" || bad "tag not annotated"
[ "$(at v1.0.0-rc.1)" = "$(at HEAD)" ] && ok "tag is the pinning commit" || bad "tag is not HEAD"
[ "$(rat main)" = "$(at HEAD)" ] && [ "$(rat v1.0.0-rc.1)" = "$(at HEAD)" ] && ok "rc pushes the branch and the tag" || bad "rc push: $out"
{ at v1 || rat v1; } >/dev/null && bad "rc moved the major tag" || ok "rc leaves the major tag alone"

rel v1.0.0 >/dev/null 2>&1 || bad "v1.0.0 release"
[ "$(pins)" = "engine-ref || 'v1.0.0' " ] && [ "$(at v1)" = "$(at v1.0.0)" ] && ok "v1.0.0 pinned, v1 -> v1.0.0" || bad "v1.0.0: $(pins) v1=$(at v1)"
[ "$(rat v1.0.0)" = "$(at v1.0.0)" ] && [ "$(rat v1)" = "$(at v1.0.0)" ] && ok "v1.0.0 and v1 pushed" || bad "v1.0.0 push"
git -C "$r" show v1.0.0:.github/workflows/publish.yml | grep -q "'v1.0.0'" && ok "the tagged workflow pins itself" || bad "tagged workflow pin"
rel v1.0.0-rc.2 >/dev/null 2>&1 && bad "an rc after its final accepted" || ok "an rc after its final refused"
echo change > "$r/scripts/new"; git -C "$r" add -A; git -C "$r" commit --quiet -m feat
rel v1.1.0 >/dev/null 2>&1 && [ "$(at v1)" = "$(at v1.1.0)" ] && [ "$(rat v1)" = "$(at v1.1.0)" ] \
  && ok "v1 moves to v1.1.0, here and on origin" || bad "v1 not moved"
rel v1.1.0 >/dev/null 2>&1 && bad "existing tag re-released" || ok "existing tag refused"
rel v1.0.5 >/dev/null 2>&1 && bad "an older version accepted" || ok "an older version refused"
git -C "$r" push --quiet origin HEAD:refs/tags/v1.2.0
rel v1.2.0 >/dev/null 2>&1 && bad "a tag only on origin re-released" || ok "a tag only on origin refused"
rel v1.1.5 >/dev/null 2>&1 && bad "a version older than a tag on origin accepted" || ok "a version older than a tag on origin refused"
git -C "$r" push --quiet origin :refs/tags/v1.2.0

git clone --quiet --branch main "$tmp/remote.git" "$tmp/other"; echo other > "$tmp/other/other"
git -C "$tmp/other" add -A; git -C "$tmp/other" commit --quiet -m other; git -C "$tmp/other" push --quiet origin main
rel v1.2.0 >/dev/null 2>&1 && bad "a branch behind origin accepted" || ok "a branch behind origin refused"
! at v1.2.0 >/dev/null && [ "$(at HEAD)" = "$(at v1.1.0)" ] || bad "the refusal left a tag or a commit"
git -C "$r" pull --quiet --ff-only origin main

rel v2.0.0 >/dev/null 2>&1 && [ "$(at v1)" = "$(at v1.1.0)" ] && [ "$(at v2)" = "$(at v2.0.0)" ] && [ "$(rat v2)" = "$(at v2.0.0)" ] \
  && ok "v2.0.0 creates v2 and leaves v1" || bad "major bump"
git -C "$r" checkout --quiet -b v1-maint v1.1.0
rel v1.2.0 >/dev/null 2>&1 && [ "$(rat v1)" = "$(at v1.2.0)" ] && [ "$(rat v1-maint)" = "$(at v1.2.0)" ] && [ "$(rat v2)" = "$(at v2.0.0)" ] \
  && ok "a v1 maintenance release after v2 moves only v1" || bad "maintenance release"
git -C "$r" checkout --quiet main

# the remote's own hooks dir, whatever a global core.hooksPath says
git --git-dir="$tmp/remote.git" config core.hooksPath "$tmp/remote.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$tmp/remote.git/hooks/pre-receive"; chmod +x "$tmp/remote.git/hooks/pre-receive"
out="$(rel v2.0.1 2>&1)" && bad "a rejected push reported success" || ok "a rejected push fails"
at v2.0.1 >/dev/null && ! rat v2.0.1 >/dev/null && [ "$(rat v2)" = "$(at v2.0.0)" ] && ok "a rejected push keeps the local tag, pushes nothing" || bad "rejected push refs"
printf '%s' "$out" | grep -q 'git push --atomic origin main refs/tags/v2.0.1 +refs/tags/v2' && ok "prints the retry command" || bad "retry command: $out"
rm "$tmp/remote.git/hooks/pre-receive"

sed -i "s/engine-ref || '[^']*'/engine-ref || 'main'/" "$r/.github/workflows/publish.yml"; git -C "$r" commit --quiet -am unpin
rel v2.0.2 >/dev/null 2>&1 && bad "non-version pin accepted" || ok "non-version pin refused"
[ -z "$(git -C "$r" status --porcelain)" ] && ! at v2.0.2 >/dev/null && ok "refusal leaves the tree clean, no tag" || bad "refusal left changes"
sed -i "s/engine-ref || 'main'/engine-ref/" "$r/.github/workflows/publish.yml"; git -C "$r" commit --quiet -am nopin
rel v2.0.2 >/dev/null 2>&1 && bad "missing pin accepted" || ok "missing pin refused"
! rat v2.0.2 >/dev/null && ok "refusals push nothing" || bad "a refusal pushed"

[ "$fail" = 0 ] && echo "PASS release_test" || { echo "FAIL release_test"; exit 1; }
