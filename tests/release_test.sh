#!/usr/bin/env bash
# scripts/release.sh in a throwaway copy of the engine layout with a local
# bare remote, which must never receive anything.
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

for v in 1.0.0 v1.0 v1.0.0-beta v1.0.0-rc; do rel "$v" >/dev/null 2>&1 && bad "version '$v' accepted" || ok "version '$v' rejected"; done
echo x > "$r/dirty"; rel v1.0.0 >/dev/null 2>&1 && bad "dirty tree accepted" || ok "dirty tree refused"; rm "$r/dirty"
[ -z "$(git -C "$r" tag)" ] || bad "a refused release created a tag"

out="$(rel v1.0.0-rc.1 2>&1)" || bad "rc release: $out"
[ "$(pins)" = "engine-ref || 'v1.0.0-rc.1' " ] && ok "rc pins every engine checkout" || bad "rc pins: $(pins)"
[ "$(git -C "$r" log -1 --format=%s)" = "release v1.0.0-rc.1" ] && ok "pin committed" || bad "commit subject"
[ "$(git -C "$r" cat-file -t v1.0.0-rc.1)" = tag ] && ok "annotated tag" || bad "tag not annotated"
[ "$(at v1.0.0-rc.1)" = "$(at HEAD)" ] && ok "tag is the pinning commit" || bad "tag is not HEAD"
at v1 >/dev/null && bad "rc moved the major tag" || ok "rc leaves the major tag alone"
printf '%s' "$out" | grep -q 'git push origin main v1.0.0-rc.1' && ok "prints the push command" || bad "push command: $out"

rel v1.0.0 >/dev/null 2>&1 || bad "v1.0.0 release"
[ "$(pins)" = "engine-ref || 'v1.0.0' " ] && [ "$(at v1)" = "$(at v1.0.0)" ] && ok "v1.0.0 pinned, v1 -> v1.0.0" || bad "v1.0.0: $(pins) v1=$(at v1)"
git -C "$r" show v1.0.0:.github/workflows/publish.yml | grep -q "'v1.0.0'" && ok "the tagged workflow pins itself" || bad "tagged workflow pin"
echo change > "$r/scripts/new"; git -C "$r" add -A; git -C "$r" commit --quiet -m feat
rel v1.1.0 >/dev/null 2>&1 && [ "$(at v1)" = "$(at v1.1.0)" ] && ok "v1 moves to v1.1.0" || bad "v1 not moved"
rel v1.1.0 >/dev/null 2>&1 && bad "existing tag re-released" || ok "existing tag refused"
rel v2.0.0 >/dev/null 2>&1 && [ "$(at v1)" = "$(at v1.1.0)" ] && [ "$(at v2)" = "$(at v2.0.0)" ] \
  && ok "v2.0.0 creates v2 and leaves v1" || bad "major bump"

sed -i "s/engine-ref || '[^']*'/engine-ref || 'main'/" "$r/.github/workflows/publish.yml"; git -C "$r" commit --quiet -am unpin
rel v2.0.1 >/dev/null 2>&1 && bad "non-version pin accepted" || ok "non-version pin refused"
[ -z "$(git -C "$r" status --porcelain)" ] && ! at v2.0.1 >/dev/null && ok "refusal leaves the tree clean, no tag" || bad "refusal left changes"
sed -i "s/engine-ref || 'main'/engine-ref/" "$r/.github/workflows/publish.yml"; git -C "$r" commit --quiet -am nopin
rel v2.0.1 >/dev/null 2>&1 && bad "missing pin accepted" || ok "missing pin refused"

[ -z "$(git --git-dir="$tmp/remote.git" for-each-ref)" ] && ok "nothing pushed" || bad "the remote received refs"
[ "$fail" = 0 ] && echo "PASS release_test" || { echo "FAIL release_test"; exit 1; }
