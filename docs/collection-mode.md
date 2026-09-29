# Collection mode: many projects, one repository

One shared repository, the **collection** (for example `acme/apt`), serves the
packages of many projects, its **clients**. It takes two calls of the same
workflow:

- **Each client's release workflow** calls it with `collection: acme/apt`. That
  run writes the client's reference and pushes it into the collection. It builds
  and deploys nothing, and it never sees the signing key.
- **The collection's own workflow** calls it without a package (publish-only) on
  every push. That run rebuilds the whole repository from all the references,
  signs it and deploys it to the collection's Pages.

A client's push is what triggers the collection's run, so a release goes live
shortly after the client's workflow finishes.

## The collection repository

The collection is an instance repository:

- `conf/dists.conf`: the releases, aliases and architectures it publishes
- `conf/site.conf`: its identity and landing page
- `conf/owners.conf`: which repository may publish which package
- `packages/`: the references the clients push
- `debs/` (optional): committed binaries

To start one, copy [`example/conf/dists.conf`](../example/conf/dists.conf) and
[`example/.gitignore`](../example/.gitignore) into it. Write your own
`conf/site.conf`: every key is optional, and usually `SITE_TITLE` is all you
need. Do **not** copy example's `site.conf`. Its `REPO_NAME`, `REPO_URL` and
`GITHUB_URL` belong to the local demo (`http://localhost:8000`), and a committed
`REPO_URL` beats the Pages URL. Left unset, they are derived from the repository
and its Pages URL. See the [configuration reference](reference.md#configuration).

The collection deploys itself with a publish-only call on every push:

```yaml
# acme/apt: .github/workflows/publish.yml
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  publish:
    permissions:
      contents: read
      pages: write
      id-token: write
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1
    secrets: inherit
```

## One-time setup

From a checkout of this repository (needs `gpg`, `make`, and the `gh` CLI logged
in with admin rights on the collection):

```bash
export GNUPGHOME=~/.apt-keys/acme-apt            # keep the private key out of every checkout
make key KEY_NAME="Acme APT repository" KEY_EMAIL=you@example.org
make backup-key                                  # then move the file into your password vault
make setup-repo REPO=acme/apt TAGS=              # Pages from Actions; only the default branch may deploy
make key-to-repo REPO=acme/apt                   # APT_SIGNING_KEY secret in the github-pages environment
gh workflow run publish.yml --repo acme/apt      # first deploy: an empty, signed repository
```

The collection only ever deploys from its default branch, so `TAGS=` allows no
tags. A push made before this setup fails at `Configure Pages`: that is
expected, and the dispatched run above replaces it.

## Credentials for the clients

A client needs a token that can push to the collection. `github.token` cannot
push to another repository, and a push made with it would not trigger the
collection's workflow anyway.

- **A GitHub App** (recommended). Create it with *Repository permissions →
  Contents: Read and write*, with its webhook inactive, and install it on the
  collection only. Store its ID as the org variable `APT_APP_ID` and its private
  key as the org secret `APT_APP_PRIVATE_KEY`, or as a variable and a secret on
  each client. Every run mints a short-lived token scoped to the collection.
- **A fine-grained token** with *Contents: Read and write* on the collection
  only. Store it as a secret on the client and pass it as `collection-token`
  instead of `app-id`.

## Who may publish what: `owners.conf`

```
# <package>  <owner/repo>...   — enforced whenever this file exists
myapp        acme/myapp
myapp-tools  acme/myapp acme/tools
```

While the file exists, each package may only come from the release assets of
its listed repositories: every URL must be
`https://github.com/<owner/repo>/releases/download/<tag>/<file>`. A client's
register step checks this before it pushes, and every publish checks it again
before downloading anything.

A change that rejects an existing reference makes the next publish fail until
that reference is removed or re-registered.

## A client

A client builds and releases its `.deb`s exactly as in
[self mode](self-mode.md#the-release-workflow), then pushes a reference into the
collection instead of deploying:

```yaml
# acme/myapp: .github/workflows/release.yml
on:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write                            # create the release
    steps:
      - uses: actions/checkout@v7
      - run: make deb                            # your build: dist/*.deb (every release) or dist/<codename>/*.deb
      - run: gh release create "$GITHUB_REF_NAME" --verify-tag $(find dist -name '*.deb')
        env:
          GH_TOKEN: ${{ github.token }}
      - uses: actions/upload-artifact@v7
        with:
          name: debs
          path: dist

  apt:
    needs: build
    permissions:
      contents: read
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1
    with:
      name: myapp
      artifact: debs
      collection: acme/apt
      app-id: ${{ vars.APT_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.APT_APP_PRIVATE_KEY }}
```

The `tag` and `file` inputs work as in self mode, for example one reference file
per [version group](reference.md#artifacts-and-versions). The build inputs
(`dists`, `aliases`, `arches`, `repo-name`, `site-title`, `site-tagline`,
`theme`) are rejected: the collection's `conf/` decides them.

Before a reference is pushed, the register step checks it against the
collection:

- its releases and architectures
- `owners.conf`
- no other reference, and no `.deb` committed in its `debs/`, already providing
  the same (package, release, arch)
- every release asset is publicly downloadable and matches its sha256

It then commits as `github-actions[bot]` and pushes. A push that loses a race
with another client is rebased and retried. The client's `publish` job is
skipped: the collection's own run deploys.

## The trust model

The register checks keep an honest mistake (a wrong release, a missing asset,
someone else's package name) from breaking the next publish for everyone. They
are not a security boundary. Every client holds the App key, which is
`contents: write` on the whole collection, so a malicious client could edit
`conf/owners.conf` or `conf/index.html` directly. For a hard boundary, add a
push ruleset to the collection that blocks changes outside `packages/**`, and
let only the maintainers bypass it.

## Committed binaries

A `.deb` without a public release (a one-off, or from a private repository) can
be committed to the collection. From a checkout of the collection:

```bash
make -f ../gh-action-debian-repo/Makefile add DEB=path/to/foo_1.0_amd64.deb [RELEASE=trixie]
git add debs/ && git commit -m "add foo 1.0" && git push
```

Without `RELEASE` it goes to every release. A committed `.deb` takes part in the
same one-(package, release, arch) rule as the references.

## Changing the releases

Edit `conf/dists.conf` and push. See
[releases and aliases](reference.md#releases-and-aliases), including what adding
a codename does to `any` artifacts and what moving `stable` does to clients.

## Rotating the signing key

Follow [key rotation](reference.md#rotating-a-key). In a collection, "publish"
means any push, or `gh workflow run publish.yml --repo acme/apt`.

## When something fails

| Symptom | Fix |
| --- | --- |
| `❌ app-id is set but the app-private-key secret is not` | the client has the `APT_APP_ID` variable but not the `APT_APP_PRIVATE_KEY` secret |
| `❌ collection mode needs credentials for acme/apt` | pass `app-id` with the `app-private-key` secret, or the `collection-token` secret |
| `❌ input 'dists' has no effect in collection mode` | remove the build inputs from the client's call; set them in the collection's `conf/` |
| `❌ … is not a release asset of the repo(s) owning 'myapp'` | `owners.conf` does not list the client for that package |
| The client succeeded, but nothing was deployed | look at the collection's own run in its Actions tab: the deploy happens there |
| The collection's run fails at `Configure Pages` | Pages is not enabled: `make setup-repo REPO=acme/apt TAGS=` |
