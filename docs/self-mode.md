# Self mode: a project publishes its own repository

A project publishes its `.deb`s as an APT repository on its own GitHub Pages,
`https://<owner>.github.io/<repo>`. Its release workflow calls the reusable
workflow, which:

1. writes a reference to the release's `.deb`s (`packages/<name>.json`: a URL
   and a sha256 per artifact) to an orphan branch, `apt`, created on first use;
2. rebuilds the whole repository from that branch, signs it and deploys it to
   Pages.

The `apt` branch is the instance. It holds only references, never your code or
your binaries.

## Before you start

- The repository and its release assets must be public, because the publish
  downloads the assets anonymously. Pages for a private repository need a paid
  plan.
- Locally you need `gpg`, `make`, and the `gh` CLI logged in with admin rights on
  the repository.

## One-time setup

From a checkout of this repository:

```bash
export GNUPGHOME=~/.apt-keys/myapp               # keep the private key out of every checkout
make key KEY_NAME="myapp APT repository" KEY_EMAIL=you@example.org
make backup-key                                  # then move the file into your password vault
make setup-repo REPO=acme/myapp                  # Pages from Actions + the github-pages environment
make key-to-repo REPO=acme/myapp                 # the APT_SIGNING_KEY repository secret
```

- `make key` creates a signing key without a passphrase, because CI signs
  unattended. It drops a `*` `.gitignore` into the keyring directory, so git
  never offers the key for a commit.
- `make backup-key` writes `signing-key.secret.asc` into the keyring directory.
  Move it into your password vault, then `shred -u` it.
- `make setup-repo` enables Pages built by GitHub Actions and limits the
  `github-pages` environment to deployments from the default branch and from
  tags matching `v*`. Release tags of another shape need their own pattern, for
  example `TAGS='v* debian_*'`. Running it again keeps the existing Pages and
  policies.
- `make key-to-repo` stores the private key as the `APT_SIGNING_KEY`
  repository secret. The release workflow passes it to the reusable workflow by
  name: see [the `APT_SIGNING_KEY` secret](reference.md#secrets) for why
  `secrets: inherit` does not work.

To use a key you already have, or one kept in an instance's `.gnupg-repo/`, see
[which keyring `make` uses](reference.md#which-keyring-make-uses).

## The release workflow

`.github/workflows/release.yml` in `acme/myapp`:

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
    secrets:
      APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
```

The build decides where each `.deb` goes:

- `dist/*.deb` is published to every release.
- `dist/<codename>/*.deb` is published only to that release.

Upload the whole `dist/` directory as the artifact, so the `<codename>/`
directories survive. Uploading `dist/trixie/` alone would flatten it and publish
the build to every release. Only the `.deb`s are read, so a flat build can
upload `path: dist/*.deb` instead. That leaves out the binaries and archives
that tools such as GoReleaser also write to `dist/`.

When the tag is pushed:

1. `build` creates the release and uploads the artifact.
2. `apt / register` writes `packages/myapp.json` to the `apt` branch. Before it
   pushes, it checks the reference against the releases and architectures you
   publish, and downloads every release asset to compare its sha256.
3. `apt / publish` rebuilds the repository and deploys it.

The repository goes live at `https://acme.github.io/myapp`, and its landing page
shows the install commands. Its keyring and `.sources` file are named after the
repository (`acme-myapp-archive-keyring.gpg`, `acme-myapp.sources`). The
`repo-name` input changes that.

## Releases, aliases and architectures

The `apt` branch has no `conf/`, so the workflow inputs are the repository's
configuration:

| Input | Default |
| --- | --- |
| `dists`: the codenames, each with a pool and a signed index | `trixie forky sid` |
| `aliases`: rolling suites, `alias:codename`; `none` for no aliases | `stable:trixie testing:forky unstable:sid` |
| `arches` | `amd64 arm64` |
| `repo-name`, `site-title`, `site-tagline`, `theme` | derived from the repository |

With `dists` but no `aliases`, the default aliases whose codename is not in
`dists` are dropped with a warning. Pass the same values on every call,
including the re-publish below. See the reference for
[how releases and aliases work](reference.md#releases-and-aliases) and
[what each input does](reference.md#the-workflow).

## A different version per release

One reference file holds one version. To ship, for example, v6.5.3 to trixie
and v6.7.2 to sid, register each version group into its own file with the
`file` input (`packages/myapp.trixie.json`), from its own `dist/<codename>/`.
See [artifacts and versions](reference.md#artifacts-and-versions).

## Re-publishing without a new release

To rebuild and redeploy the repository without a new release (after a key
rotation, for example), make a publish-only call on the `apt` branch. Without
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
    secrets:
      APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
```

Run it from the default branch: the `github-pages` environment lets only the
default branch and the release tags deploy.

## Rotating the signing key

Follow [key rotation](reference.md#rotating-a-key). In self mode, "publish" means
running the re-publish workflow above.

## When something fails

| Symptom | Fix |
| --- | --- |
| `Configure Pages` fails with `Get Pages site failed` | Pages is not enabled: `make setup-repo REPO=…` |
| `❌ no APT_SIGNING_KEY secret` | `make key-to-repo REPO=…`, and pass it by name: `APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}` under `secrets:`. `secrets: inherit` passes nothing to this workflow |
| `❌ APT_SIGNING_KEY cannot sign unattended` | the stored key has a passphrase: store one made by `make key` |
| The deploy is refused by the environment's protection rules | the tag does not match the environment's patterns: `make setup-repo REPO=… TAGS='<pattern>'` |
| `Download the .debs` fails with `Artifact not found for name: debs` | the `artifact` input must match the `name` of the `upload-artifact` step in the same run |
| `❌ push to 'apt' refused (token scope? branch protection?)` | the calling job lacks `contents: write`, or a ruleset or branch protection covers `apt`: exclude that branch from it |
| `apt / register` rejects the reference | its message names the problem: a release or architecture you do not publish, a duplicate asset name, or an asset whose sha256 does not match |
