#!/usr/bin/env bash
# Register an app's built .debs as a packages/*.json reference in a repository
# instance and push it: the app's own publishing branch (self mode) or a shared
# collection repository. Runs scripts/register.sh inside a fresh clone, checks
# the reference against the TARGET's config before committing — its releases
# and arches (dists.conf), its owners.conf, and no (package, release, arch)
# already claimed by another reference file or a committed debs/ .deb — so an
# honest mistake cannot break a shared repository's next publish. Then commits
# and pushes, rebasing onto concurrent pushes (other apps publishing at the same
# time) and retrying.
#
# Usage: push-ref.sh --remote <git-url> --branch <branch> --name <pkg>
#          --dist-dir <dir> --repo <owner/app> --tag <tag>
#          [--file packages/<x>.json] [--create-branch] [--verify-assets]
#          [--dists <codenames>] [--aliases <alias:codename...>] [--arches <arches>]
#          [--author-name <n>] [--author-email <e>]
# --dists/--aliases/--arches are the workflow inputs of the same names. They are
# layered over the target's dists.conf exactly as the publish will layer them
# (scripts/dists-overlay.sh; --aliases none = no aliases) — a self-mode branch
# has no conf/, so they are its only release list.
# --verify-assets downloads every referenced release asset (anonymously, as the
# publish will) and checks its sha256: a reference to an asset that was never
# uploaded, or that is private, would otherwise only fail the target's NEXT
# publish — for every package in a shared collection.
# Credentials are the caller's: the register action passes a token through git
# config in the environment, so it never appears in the remote URL or the logs.
set -euo pipefail

REMOTE=""; BRANCH=""; NAME=""; DIST_DIR=""; SRC_REPO=""; TAG=""; FILE=""; CREATE=0; VERIFY=0
IN_DISTS=""; IN_ALIASES=""; IN_ARCHES=""
AUTHOR_NAME="github-actions[bot]"; AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2;;       --branch) BRANCH="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;           --dist-dir) DIST_DIR="$2"; shift 2;;
    --repo) SRC_REPO="$2"; shift 2;;       --tag) TAG="$2"; shift 2;;
    --file) FILE="$2"; shift 2;;           --create-branch) CREATE=1; shift;;
    --verify-assets) VERIFY=1; shift;;
    --dists) IN_DISTS="$2"; shift 2;;      --aliases) IN_ALIASES="$2"; shift 2;;
    --arches) IN_ARCHES="$2"; shift 2;;
    --author-name) AUTHOR_NAME="$2"; shift 2;; --author-email) AUTHOR_EMAIL="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
required(){ [ -n "$2" ] || { echo "❌ $1 is required" >&2; exit 2; }; }
required --remote "$REMOTE"; required --branch "$BRANCH"; required --name "$NAME"
required --dist-dir "$DIST_DIR"; required --repo "$SRC_REPO"; required --tag "$TAG"
FILE="${FILE:-packages/$NAME.json}"
# the reference lands at a fixed depth under packages/ — never elsewhere in the target
printf '%s' "$FILE" | grep -qE '^packages/[A-Za-z0-9][A-Za-z0-9._+-]*\.json$' \
  || { echo "❌ --file must be packages/<name>.json (no subdirectories), got '$FILE'" >&2; exit 2; }
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
work="$tmpd/target"   # the clone; the dists.conf overlay sits next to it, outside the tree
g(){ GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
     GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" git -C "$work" "$@"; }
# 0 = the branch exists, 1 = it does not (ls-remote --exit-code says 2). Any other
# failure — credentials, a missing repository, the network — stops here with
# git's message: it must never pass for "no branch" (and, in self mode, for a
# licence to create an orphan branch without the target's checks).
branch_exists(){
  local rc=0 err
  err="$(git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" 2>&1 >/dev/null)" || rc=$?
  case "$rc" in 0) return 0;; 2) return 1;; esac
  printf '%s\n' "$err" >&2; echo "❌ cannot reach $REMOTE" >&2; exit 1
}

if branch_exists; then
  git clone --quiet --no-tags --single-branch --branch "$BRANCH" "$REMOTE" "$work"
elif [ "$CREATE" = 1 ]; then
  echo ">> branch '$BRANCH' does not exist yet — creating it (orphan: it holds only the repository data)"
  git init --quiet "$work"; g remote add origin "$REMOTE"; g checkout --quiet --orphan "$BRANCH"
else
  echo "❌ branch '$BRANCH' not found in the target repository" >&2; exit 1
fi

# a reference file belongs to one package: never overwrite another package's
if [ -f "$work/$FILE" ]; then
  owner="$(jq -r '.name // empty' "$work/$FILE" 2>/dev/null)" || owner=""
  [ -z "$owner" ] || [ "$owner" = "$NAME" ] \
    || { echo "❌ $FILE belongs to package '$owner' — choose another --file for '$NAME'" >&2; exit 1; }
fi
"$ENGINE/scripts/register.sh" --name "$NAME" --dist-dir "$DIST_DIR" --repo "$SRC_REPO" --tag "$TAG" --out "$work/$FILE"

# --- the target's rules, checked before anything is committed ---
INSTANCE="$work"; unset PKG_DIR DEBS_DIR OWNERS_CONF SITE_CONF DISTS_CONF INDEX_TEMPLATE
. "$ENGINE/scripts/instance-lib.sh"; instance_init
# the workflow's dists/aliases/arches inputs win over the target's dists.conf,
# layered by the same script the publish uses; empty ones leave it unchanged
"$ENGINE/scripts/dists-overlay.sh" "$DISTS_CONF" "$IN_DISTS" "$IN_ALIASES" "$IN_ARCHES" > "$tmpd/dists.conf"
DISTS_CONF="$tmpd/dists.conf"
. "$ENGINE/scripts/dists-lib.sh"; dists_load "$DISTS_CONF"
. "$ENGINE/scripts/owners-lib.sh"; owners_load "$OWNERS_CONF"
ref="$work/$FILE"
while read -r rel arch; do
  release_targets "$rel" >/dev/null || { echo "   the target publishes: $DISTS" >&2; exit 1; }
  arch_valid "$arch" || { echo "❌ arch '$arch' is not published by the target (ARCHES: $ARCHES)" >&2; exit 1; }
done < <(jq -r '.artifacts[] | "\(.release) \(.arch)"' "$ref")
owners_check_ref "$ref"
claims(){ # <ref.json> -> "<package> <codename> <arch>" per pooled artifact
  jq -r '.name as $n | .artifacts[] | "\($n) \(.release) \(.arch)"' "$1" \
    | while read -r n r a; do for cn in $(release_targets "$r"); do echo "$n $cn $a"; done; done; }
deb_claims(){ # <deb> <release> -> "<package> <codename> <arch>", as hydrate pools a committed deb
  local p a cn
  p="$(dpkg-deb -f "$1" Package 2>/dev/null)" && a="$(dpkg-deb -f "$1" Architecture 2>/dev/null)" || return 0
  # a release dir the target does not publish fails the target's own build, not this check
  for cn in $(release_targets "$2" 2>/dev/null); do echo "$p $cn $a"; done; }
mine="$(claims "$ref" | sort -u)"
shopt -s nullglob
for other in "$PKG_DIR"/*.json; do
  [ "$other" = "$ref" ] && continue
  dup="$(comm -12 <(printf '%s\n' "$mine") <(claims "$other" | sort -u) | head -1)"
  [ -z "$dup" ] || { echo "❌ ($dup) is already provided by ${other#"$work"/} — one file per (package, release, arch)" >&2; exit 1; }
done
# the target's committed debs/ count too: bare debs/*.deb = any, debs/<codename>/*.deb
for deb in "$DEBS_DIR"/*.deb "$DEBS_DIR"/*/*.deb; do
  rel=any; [ "$(dirname "$deb")" = "$DEBS_DIR" ] || rel="$(basename "$(dirname "$deb")")"
  dup="$(comm -12 <(printf '%s\n' "$mine") <(deb_claims "$deb" "$rel" | sort -u) | head -1)"
  [ -z "$dup" ] || { echo "❌ ($dup) is already provided by ${deb#"$work"/} — one source per (package, release, arch) across packages/ and debs/" >&2; exit 1; }
done
if [ "$VERIFY" = 1 ]; then
  while read -r url want; do
    got="$(curl -fsSL --retry 3 --retry-all-errors "$url" | sha256sum | cut -d' ' -f1)" || got=""   # pipefail: a failed download empties it
    [ -n "$got" ] || { echo "❌ $url is not downloadable — upload the .debs to release $TAG first (as public assets)" >&2
      echo "   (GitHub renames special characters in asset names — '~' is stored as '.', which the URL already expects)" >&2; exit 1; }
    [ "$got" = "$want" ] || { echo "❌ $url: sha256 mismatch (release asset $got, built .deb $want)" >&2; exit 1; }
  done < <(jq -r '.artifacts[] | "\(.url) \(.sha256)"' "$ref")
  echo "✅ release assets downloadable and matching"
fi

g add "$FILE"
if g diff --cached --quiet; then echo "✅ $FILE unchanged — nothing to push"; exit 0; fi
g commit --quiet -m "$NAME $(jq -r .version "$ref") ($FILE)"

for attempt in 1 2 3 4 5; do
  if branch_exists; then
    g fetch --quiet origin "$BRANCH"
    g rebase --quiet FETCH_HEAD || { g rebase --abort || true
      echo "❌ $FILE was changed concurrently in '$BRANCH' — re-run to publish" >&2; exit 1; }
  fi
  if out="$(g push --quiet origin "HEAD:refs/heads/$BRANCH" 2>&1)"; then
    echo "✅ pushed $FILE to $BRANCH"; exit 0
  fi
  # only losing a race to a concurrent push is worth a retry; anything else
  # (credentials, branch protection, a missing repository) fails as git said
  printf '%s' "$out" | grep -qE 'fetch first|non-fast-forward|cannot lock ref|failed to update ref|reference already exists|incorrect old value' \
    || { printf '%s\n' "$out" >&2; echo "❌ push to '$BRANCH' refused (token scope? branch protection?)" >&2; exit 1; }
  echo ">> push lost a race with a concurrent publish — retrying ($attempt/5)"
  sleep "$attempt.$((RANDOM % 10))"   # jitter, so racing publishers spread out
done
echo "❌ could not push to '$BRANCH' after 5 attempts" >&2; exit 1
