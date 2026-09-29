#!/usr/bin/env bash
# The reusable workflow's first step: decide the mode from the inputs and
# reject combinations that cannot work, before anything is pushed or deployed.
#   self          name set, no collection -> reference pushed to this repo's
#                 publishing branch, then this repo's Pages are deployed
#   collection    name + collection       -> reference pushed to the collection
#                 repo, whose own publish run deploys it
#   publish-only  neither                 -> deploy this repo's references
#                 (the collection repo itself, or a re-publish)
# Env (from the workflow): IN_NAME IN_ARTIFACT IN_TAG IN_FILE IN_COLLECTION
#   IN_COLLECTION_BRANCH IN_SELF_BRANCH IN_APP_ID HAS_APP_KEY HAS_COLLECTION_TOKEN
#   IN_INSTANCE_REF IN_INSTANCE_PATH (publish-only; rejected with a name)
#   IN_DISTS IN_ALIASES IN_ARCHES IN_REPO_NAME IN_SITE_TITLE IN_SITE_TAGLINE IN_THEME
#   (the build inputs; rejected in collection mode, where they would be ignored)
#   REF_TYPE REF_NAME (github.ref_type / github.ref_name) GITHUB_REPOSITORY
# Writes mode=, tag=, branch= and target= (the repository the reference is
# pushed to: owner/name, plus target-owner= and target-name=) to $GITHUB_OUTPUT.
set -euo pipefail

errs=()
err(){ errs+=("$1"); }
v(){ printf '%s' "${!1:-}"; }
name="$(v IN_NAME)"; collection="$(v IN_COLLECTION)"; tag="$(v IN_TAG)"

if [ -z "$name" ]; then
  mode=publish-only
  for k in IN_ARTIFACT IN_COLLECTION IN_APP_ID IN_FILE IN_TAG; do
    [ -z "$(v "$k")" ] || err "input '$(tr '[:upper:]_' '[:lower:]-' <<< "${k#IN_}")' needs 'name' (the package to publish)"
  done
else
  [ -n "$collection" ] && mode=collection || mode=self
  printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9+.-]+$' \
    || err "name '$name' is not a Debian package name (lowercase letters, digits, + - .)"
  [ -n "$(v IN_ARTIFACT)" ] || err "input 'artifact' is required with 'name': the uploaded artifact holding the .debs"
  if [ -z "$tag" ]; then
    [ "$(v REF_TYPE)" = tag ] && tag="$(v REF_NAME)" \
      || err "not running for a tag: run on a release tag push, or pass 'tag' (the release holding the .debs)"
  fi
  [ -z "$(v IN_FILE)" ] || printf '%s' "$(v IN_FILE)" | grep -qE '^packages/[A-Za-z0-9][A-Za-z0-9._+-]*\.json$' \
    || err "file '$(v IN_FILE)' must be packages/<name>.json"
  # with a name the publish builds the self-branch (or the collection builds
  # itself): an instance-ref/instance-path given here would be silently ignored
  [ -z "$(v IN_INSTANCE_REF)" ] || err "input 'instance-ref' only applies to publish-only (without 'name')"
  case "$(v IN_INSTANCE_PATH)" in ""|.) ;; *) err "input 'instance-path' only applies to publish-only (without 'name')";; esac
fi

branch=""; target=""
case "$mode" in
  collection)
    printf '%s' "$collection" | grep -qE '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' \
      || err "collection '$collection' must be owner/name"
    branch="$(v IN_COLLECTION_BRANCH)"; branch="${branch:-main}"; target="$collection"
    if [ -n "$(v IN_APP_ID)" ]; then
      [ "$(v HAS_APP_KEY)" = true ] || err "app-id is set but the app-private-key secret is not"
    elif [ "$(v HAS_COLLECTION_TOKEN)" != true ]; then
      err "collection mode needs credentials for $collection: app-id + app-private-key (recommended) or the collection-token secret"
    fi
    # the collection's own publish run builds from ITS conf/: build inputs given
    # here would be silently ignored
    for k in IN_DISTS IN_ALIASES IN_ARCHES IN_REPO_NAME IN_SITE_TITLE IN_SITE_TAGLINE IN_THEME; do
      [ -z "$(v "$k")" ] || err "input '$(tr '[:upper:]_' '[:lower:]-' <<< "${k#IN_}")' has no effect in collection mode: set it in the collection's conf/"
    done;;
  self)
    [ -z "$(v IN_APP_ID)" ] || err "app-id only applies to collection mode"
    branch="$(v IN_SELF_BRANCH)"; branch="${branch:-apt}"; target="$(v GITHUB_REPOSITORY)";;
esac
[ -z "$branch" ] || git check-ref-format --branch "$branch" >/dev/null 2>&1 || err "'$branch' is not a valid branch name"

if [ ${#errs[@]} -gt 0 ]; then
  for e in "${errs[@]}"; do echo "❌ $e" >&2; [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=debian-repo::$e"; done
  exit 1
fi
echo "✅ mode: $mode${target:+ -> $target@$branch}${tag:+ (release $tag)}"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'mode=%s\ntag=%s\nbranch=%s\ntarget=%s\ntarget-owner=%s\ntarget-name=%s\n' \
  "$mode" "$tag" "$branch" "$target" "${target%%/*}" "${target#*/}" >> "$GITHUB_OUTPUT"
