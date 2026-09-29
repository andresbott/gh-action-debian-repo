#!/usr/bin/env bash
# One-time GitHub setup for a repository that publishes an APT repository with
# the reusable workflow (self mode, or a collection repository):
#   1. GitHub Pages enabled, built by GitHub Actions (build_type=workflow);
#   2. the `github-pages` environment restricted to deployments from the default
#      branch and from release tags matching each TAG pattern — the publish job
#      runs on the ref that triggered it, so a tag-triggered release needs its
#      tag pattern here (e.g. 'v*', or 'debian_*' for tags like debian_sid-v1.2).
# Idempotent: existing Pages and policies are kept. Needs an authenticated `gh`
# (admin on the repository); $GH overrides the binary (tests use a fake).
# Usage: setup-repo.sh <owner/name> ['<tag-pattern> ...']   (default 'v*'; '' = none)
set -euo pipefail

REPO="${1:?usage: setup-repo.sh <owner/name> ['<tag-pattern> ...']}"
TAGS="${2-v*}"
GH="${GH:-gh}"
printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' || { echo "❌ want owner/name, got '$REPO'" >&2; exit 2; }
ENV_API="repos/$REPO/environments/github-pages"

if "$GH" api -X GET "repos/$REPO/pages" >/dev/null 2>&1; then
  "$GH" api -X PUT "repos/$REPO/pages" -f build_type=workflow >/dev/null
  echo "✅ Pages: already enabled — source set to GitHub Actions"
else
  "$GH" api -X POST "repos/$REPO/pages" -f build_type=workflow >/dev/null
  echo "✅ Pages: enabled, built by GitHub Actions"
fi

"$GH" api -X PUT "$ENV_API" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
echo "✅ environment github-pages: deployments limited to the policies below"

existing="$("$GH" api -X GET "$ENV_API/deployment-branch-policies" --paginate \
             --jq '.branch_policies[] | "\(.type // "branch") \(.name)"')"
policy(){ # <type> <pattern>
  if printf '%s\n' "$existing" | grep -qxF "$1 $2"; then echo "✅ policy: $1 '$2' (already present)"; return 0; fi
  "$GH" api -X POST "$ENV_API/deployment-branch-policies" -f name="$2" -f type="$1" >/dev/null
  echo "✅ policy: $1 '$2' added"
}
policy branch "$("$GH" api -X GET "repos/$REPO" --jq .default_branch)"
read -ra tags <<< "$TAGS"   # word-split without globbing: v* stays v*
for t in "${tags[@]}"; do policy tag "$t"; done
echo ">> next: make key-to-repo REPO=$REPO   (stores APT_SIGNING_KEY in the github-pages environment)"
