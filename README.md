# gh-action-debian-repo

Publish your `.deb` packages as a **signed APT repository on GitHub Pages**, for
several Debian and Ubuntu releases at once, from a release workflow.

- One reusable workflow, three ways to use it:
  - **self**: a project publishes its own repository on its own Pages.
  - **collection**: many projects publish into one shared repository.
  - **publish-only**: what the shared repository itself runs.
- Stateless. Every publish rebuilds the whole repository:
  1. Packages come from checksummed references to your GitHub release assets, plus any `.deb`s committed to the repository.
  2. Each release gets a pool and a signed index. Rolling aliases (`stable`, `testing`, …) sit on top.
  3. The landing page is generated and shows install instructions.
- The same engine runs locally: `make publish verify serve` gives you the exact CI build at `http://localhost:8000`. `make serve` works on the page design.

## How it works

```
app repo (tag v1.2.0)                    repository instance                    GitHub Pages
─────────────────────                    ───────────────────                    ────────────
build .debs ─► release assets            packages/myapp.json   (url + sha256)
            └► artifact ─► register ───► conf/ (dists, site, owners)  ─► publish ─► pool/ dists/ (signed)
                                         debs/  (committed .debs)                   index.html, keyring, .sources
```

The files that describe a repository form an **instance**:

- `packages/*.json`: the references
- `debs/`: committed binaries
- optional `conf/`

In self mode the instance is an orphan branch (`apt`) of the app repository. In
collection mode it is the collection repository. This repository is the
**engine**: scripts, schema, page template and the workflow. Instances hold no
code.

## Self mode: a project publishes its own repository

One-time setup, from a checkout of this repository (needs `gpg`, `make`, and the
`gh` CLI logged in):

```bash
export GNUPGHOME=~/.apt-keys/myapp               # keep the private key out of every checkout
make key KEY_NAME="myapp APT repository" KEY_EMAIL=you@example.org
make backup-key                                  # then move the file into your password vault
make setup-repo REPO=acme/myapp                  # Pages from Actions + the github-pages environment (default branch + v* tags may deploy)
make key-to-repo REPO=acme/myapp                 # APT_SIGNING_KEY secret in that environment (needs setup-repo first)
```

The release workflow (`.github/workflows/release.yml` in `acme/myapp`):

```yaml
on:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write                            # create the release
    steps:
      - uses: actions/checkout@v5
      - run: make deb                            # your build: dist/*.deb (every release) or dist/<codename>/*.deb
      - run: gh release create "$GITHUB_REF_NAME" --verify-tag $(find dist -name '*.deb')
        env:
          GH_TOKEN: ${{ github.token }}
      - uses: actions/upload-artifact@v4
        with:
          name: debs
          path: dist

  apt:
    needs: build
    permissions:
      contents: write                            # push packages/myapp.json to the apt branch
      pages: write
      id-token: write
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1
    with:
      name: myapp                                # the .debs' Package field
      artifact: debs
      dists: bookworm trixie
      aliases: stable:trixie
      arches: amd64 arm64
    secrets: inherit
```

The repository goes live at `https://acme.github.io/myapp`, and its landing page
shows the install commands.

To rebuild and redeploy it without a new release (after a key rotation, for
example), call the workflow in publish-only mode on the `apt` branch. Without
`instance-ref: apt` it would build the branch the run is for, which holds your
code and no references, and deploy an empty repository:

```yaml
# acme/myapp: .github/workflows/apt-republish.yml
on: workflow_dispatch

jobs:
  apt:
    permissions:
      contents: read
      pages: write
      id-token: write
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1
    with:
      instance-ref: apt                          # the self-branch holding the references
      dists: bookworm trixie                     # the same build inputs as the release workflow
      aliases: stable:trixie
      arches: amd64 arm64
    secrets: inherit
```

Run it from the default branch: the `github-pages` environment lets only the
default branch and the release tags deploy.

## Collection mode: many projects, one repository

**The collection** (for example `acme/apt`) is an instance repository:

- `conf/dists.conf`
- `conf/site.conf`
- `conf/owners.conf`
- `packages/`

To start one, copy [`example/conf/dists.conf`](example/conf/dists.conf) and
[`example/.gitignore`](example/.gitignore) into it. Write your own
`conf/site.conf`: every key is optional, and usually `SITE_TITLE` is all you
need. Do **not** copy example's `site.conf`. Its `REPO_NAME`, `REPO_URL` and
`GITHUB_URL` belong to the local demo (`http://localhost:8000`), and a committed
`REPO_URL` beats the Pages URL. Left unset, they are derived from the repository
and its Pages URL.

The collection publishes on every push:

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

Set it up once, as in self mode, from a checkout of this repository:

```bash
export GNUPGHOME=~/.apt-keys/acme-apt            # keep the private key out of every checkout
make key KEY_NAME="Acme APT repository" KEY_EMAIL=you@example.org
make backup-key                                  # then move the file into your password vault
make setup-repo REPO=acme/apt TAGS=              # Pages from Actions; only the default branch may deploy
make key-to-repo REPO=acme/apt
```

Then create a **GitHub App** with
*Contents: read and write* and install it on `acme/apt` only. Store its ID as the
org variable `APT_APP_ID` and its private key as the org secret
`APT_APP_PRIVATE_KEY`.

**Each client** (`acme/myapp`) builds and releases its `.deb`s exactly as in self
mode, then pushes a reference into the collection:

```yaml
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

The client never signs anything and never sees the key. The collection's
`conf/owners.conf` decides which repository may publish which package:

```
# <package>  <owner/repo>...   — enforced whenever this file exists
myapp        acme/myapp
myapp-tools  acme/myapp acme/tools
```

Before a reference is pushed, the register step checks it against the target
collection:

- its releases and architectures
- `owners.conf`
- no other reference, and no `.deb` committed in its `debs/`, already providing the same (package, release, arch)
- every release asset is publicly downloadable and matches its sha256

These checks keep an honest mistake (a wrong release, a missing asset, someone
else's package name) from breaking the next publish for everyone. They are not
a security boundary. Every client holds the App key, which is `contents: write`
on the whole collection, so a malicious client could edit `conf/owners.conf` or
`conf/index.html` directly. For a hard boundary, add a push ruleset to the
collection that blocks changes outside `packages/**`, and let only the
maintainers bypass it.

A fine-grained token that can push to the collection also works: pass it as the
`collection-token` secret instead of `app-id`. `github.token` cannot push to
another repository.

## Workflow reference

`andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1`

| Input | Default | Meaning |
| --- | --- | --- |
| `name` | | Package to publish. Empty means publish-only. |
| `artifact` | | Artifact from this run holding the `.deb`s: flat means every release, `<codename>/*.deb` means that release. |
| `tag` | the run's tag | Release whose assets are the `.deb`s. Required when not running for a tag. |
| `file` | `packages/<name>.json` | Reference file. Use one per version group, e.g. `packages/myapp.trixie.json`. |
| `collection` | | `owner/name` of a collection. Empty means self mode. |
| `collection-branch` | `main` | Branch of the collection holding its instance. |
| `app-id` | | GitHub App that may push to the collection (with the `app-private-key` secret). |
| `self-branch` | `apt` | Self mode: the branch holding the references. It is created on first use. |
| `instance-ref` | the run's ref | Publish-only: the ref holding the instance. Not allowed with `name`. |
| `instance-path` | `.` | Publish-only: directory of the instance inside that ref. Not allowed with `name`. |
| `dists`, `aliases`, `arches` | `conf/dists.conf` | Releases, rolling aliases (`stable:trixie`) and architectures. `aliases: none` publishes no aliases. With `dists` but no `aliases`, the configured aliases whose codename is not in `dists` are dropped with a warning (in self mode that is the engine default `stable:trixie testing:forky unstable:sid`). In self mode the reference is also checked against them before it is pushed. Not allowed in collection mode. |
| `repo-name`, `site-title`, `site-tagline`, `theme` | `conf/site.conf` | Identity and page. See [Configuration](#configuration). Not allowed in collection mode. |
| `engine-ref` | this release | Engine version to run. Only for testing the engine. |

Secrets:

- `APT_SIGNING_KEY`: defaults to the `github-pages` environment secret.
- `collection-token`
- `app-private-key`

Outputs: `mode` and `page-url`.

Permissions the calling job must grant:

| Mode | Permissions |
| --- | --- |
| self | `contents: write`, `pages: write`, `id-token: write` |
| collection | `contents: read` |
| publish-only | `contents: read`, `pages: write`, `id-token: write` |

## Configuration

An instance's `conf/` is optional. Workflow inputs override it.

- `conf/dists.conf`: see [`defaults/dists.conf`](defaults/dists.conf)
  - `DISTS`: the codenames, each with a pool and a signed index. An artifact's `release: any` lands in each one.
  - `ALIASES`: `alias:codename` pairs, each with its own signed index.
  - `ARCHES`
- `conf/site.conf`: every key is optional

  | Key | Default |
  | --- | --- |
  | `REPO_NAME` | `<owner>-<repo>`, lowercased |
  | `SITE_TITLE` | `REPO_NAME` |
  | `SITE_TAGLINE` | "A signed APT repository for Debian and Ubuntu" |
  | `REPO_URL` | the Pages URL |
  | `GITHUB_URL` | the repository |
  | `THEME` | `violet`; also `amber`, `blue`, `rose`, `teal`, or `conf/themes/<name>.css` |
  | `KEYRING_FILE` | `<REPO_NAME>-archive-keyring.gpg` |
  | `SOURCES_FILE` | `<REPO_NAME>.sources` |
  | `SOURCES_SUITE` | the first alias, else the first codename |
  | `APT_ORIGIN`, `APT_LABEL` | `REPO_NAME` |
  | `APT_DESCRIPTION` | "`SITE_TITLE` APT repository" |

- `conf/owners.conf`: the publishing allowlist, as above.
- `conf/themes/<name>.css` and `conf/index.html`: your own theme and page template.

## Working locally

From an instance checkout, point the engine's Makefile at the instance with
`make -f ../gh-action-debian-repo/Makefile <target>`, or add
`include ../gh-action-debian-repo/Makefile` to the instance's own Makefile. From
this checkout, the targets build [`example/`](example/).

```bash
make example-debs publish verify serve    # sample packages, the full CI build, apt's checks, http://localhost:8000
make serve THEME=teal                     # page design only: a demo page when there are no packages
make add DEB=foo.deb [RELEASE=trixie]     # commit a binary into debs/
make help
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for how it works inside, key rotation, and
releasing the engine.
