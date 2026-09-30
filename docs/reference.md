# Reference

The details both setups share: the workflow, an instance's configuration, the
reference format, signing keys, local builds and limits. For the setups
themselves, see [self mode](self-mode.md) and
[collection mode](collection-mode.md).

## The workflow

`andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1`

`@v1` follows the latest v1 release, and `@v1.2.3` pins one. Release
candidates such as `@v1.2.0-rc.1` let you try a release before it is final.
They never move `@v1`, so you have to pin one to use it.

| Input | Default | Meaning |
| --- | --- | --- |
| `name` | | Package to publish. Empty means publish-only. |
| `artifact` | | Artifact from this run holding the `.deb`s: flat means every release, `<codename>/*.deb` means that release. |
| `tag` | the run's tag | Release whose assets are the `.deb`s. Required when not running for a tag. |
| `file` | `packages/<name>.json` | Reference file. Use one per version group, e.g. `packages/myapp.trixie.json`. |
| `collection` | | `owner/name` of the collection a client pushes its reference to. Empty means this repository. |
| `collection-branch` | `main` | Branch of the collection holding its instance. |
| `app-id` | the `app-id` secret | GitHub App that may push to the collection (with the `app-private-key` secret). |
| `self-branch` | `apt` | Self mode: the branch holding the references. It is created on first use. |
| `instance-ref` | the run's ref | Publish-only: the ref holding the instance. Not allowed with `name`. |
| `instance-path` | `.` | Publish-only: directory of the instance inside that ref. Not allowed with `name`. |
| `dists`, `aliases`, `arches` | `conf/dists.conf` | Releases, rolling aliases (`stable:trixie`) and architectures. `aliases: none` publishes no aliases. With `dists` but no `aliases`, the configured aliases whose codename is not in `dists` are dropped with a warning (in self mode that is the engine default `stable:trixie testing:forky unstable:sid`). In self mode the reference is also checked against them before it is pushed. Not allowed with `collection`: the collection's `conf/` decides. |
| `repo-name`, `site-title`, `site-tagline`, `theme` | `conf/site.conf` | Identity and page. See [`site.conf`](#confsiteconf). Not allowed with `collection`. |
| `engine-ref` | this release | Engine version to run. Only for testing the engine. |

### Secrets

- `APT_SIGNING_KEY`: the signing key, used by the deploying job only (self and
  publish-only calls).
- `collection-token`: a token that can push to the collection, instead of
  `app-id`.
- `app-private-key`: the private key of the `app-id` App.
- `app-id`: the App ID, for callers that keep it as a secret. A calling job
  cannot pass a secret as an input, so this is the secret's way in. The
  `app-id` input wins when both are set.

Pass each one by name, from a repository or organization secret:

```yaml
    secrets:
      APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
```

`secrets: inherit` does not work here. GitHub honours it only when the caller
is in the same organization as the workflow, so from any other account it
passes nothing. The caller's environment secrets do not reach the workflow
either, and a calling job cannot hand one over. That is why `make key-to-repo`
stores `APT_SIGNING_KEY` as a repository secret. Every workflow in the
repository can read a repository secret, not only the deploying job. The
`github-pages` environment still decides which refs may deploy.

Keep a single copy of the key. GitHub gives an environment secret precedence
over a passed one, so an `APT_SIGNING_KEY` left in the `github-pages`
environment by an older setup can override the repository secret. Delete it
with `gh secret delete APT_SIGNING_KEY --repo … --env github-pages`.

### Outputs

- `mode`: `self`, `collection` (a client's call) or `publish-only`
- `page-url`: the deployed repository (self and publish-only calls)

### Permissions

The workflow sets no `permissions:` itself. A called workflow can only narrow
its caller's permissions, so the calling job grants them:

| Caller | Permissions |
| --- | --- |
| self: the release workflow | `contents: write`, `pages: write`, `id-token: write` |
| collection: each client | `contents: read` |
| publish-only: the collection itself, or a self re-publish | `contents: read`, `pages: write`, `id-token: write` |

## Configuration

An instance holds:

- `packages/*.json`: the [references](#the-reference-format).
- `debs/`: committed `.deb`s. `debs/*.deb` goes to every release,
  `debs/<codename>/*.deb` only to that one.
- `conf/`, optional. Workflow inputs override it.

### `conf/dists.conf`

When an instance has none, the engine's [`defaults/dists.conf`](../defaults/dists.conf)
applies:

```bash
DISTS="trixie forky sid"                             # codenames: each gets a pool and a signed index
ALIASES="stable:trixie testing:forky unstable:sid"   # alias:codename: each gets its own signed index
ARCHES="amd64 arm64"
```

See [releases and aliases](#releases-and-aliases) for what each one does.

### `conf/site.conf`

Every key is optional.

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

A committed `REPO_URL` beats the Pages URL, which is how a custom domain is set.

`REPO_NAME` also names the published keyring and `.sources` file, unless
`KEYRING_FILE` and `SOURCES_FILE` are set. Changing `REPO_NAME`, `APT_ORIGIN` or
`APT_LABEL` of a live repository changes its `Release` file's `Origin`/`Label`,
and every client's `apt-get update` then refuses it until run with
`--allow-releaseinfo-change`. Changing `REPO_NAME` also moves the keyring and
`.sources` URLs your users downloaded from. Pin these keys when you move an
existing repository to this engine.

### `conf/owners.conf`

The publishing allowlist of a collection: see
[collection mode](collection-mode.md#who-may-publish-what-ownersconf).

### `conf/themes/<name>.css` and `conf/index.html`

Your own colour theme, and your own page template. A template starts from
[`template/index.html`](../template/index.html) and keeps its `@@…@@` tokens and
its `<!-- PACKAGES_TABLE -->` marker.

## Releases and aliases

- Each codename in `DISTS` gets a pool and a signed `dists/<codename>/`. Any
  name works: an Ubuntu codename such as `resolute` is an ordinary entry, and
  so is a plain suite name. `DISTS="stable"` with `ALIASES=""` publishes a
  single `dists/stable/` whose `Suite` and `Codename` are both `stable`.
- An artifact's `release: any` (a flat `dist/*.deb`, or `debs/*.deb`) lands in
  every codename. Adding a codename therefore publishes every existing `any`
  artifact to it too. Check that such builds suit the new release first.
- The order of `DISTS` is the order the landing page lists a package's releases
  in, so keep it most-stable first.
- Each alias gets its own signed `dists/<alias>/` (`Suite=<alias>`,
  `Codename=<target>`) that reuses its target's `Packages`, with no separate
  pool. The first alias is the suite the served `.sources` file tracks.
- Moving `stable` forward is a one-line change of `ALIASES` (or of the `aliases`
  input). It changes `dists/stable/Release`'s `Codename`, so clients tracking
  `stable` need `apt-get update --allow-releaseinfo-change` once, as with
  Debian's own releases.

## Artifacts and versions

The artifact's layout decides where each `.deb` goes: `*.deb` to every release,
`<codename>/*.deb` to that release. Other files, and directories without
`.deb`s, are ignored. Upload the whole directory, so the `<codename>/`
directories survive. A flat build can upload just `dist/*.deb`. That leaves out
the binaries and archives that tools such as GoReleaser also write to `dist/`.

A reference file has one `version`, always read from the `.deb` itself, never
from the tag: a tag need not be a version, and a packaging suffix exists only in
the `.deb`. An app that ships different versions to different releases
registers each group into its own file. For example, it might build v6.5.3 for
trixie because trixie's libraries cannot build v6.7: that group goes in
`file: packages/myapp.trixie.json`, from `dist/trixie/`. All files are merged at
publish time. The only rule is one (package, release, arch) across every file
and `debs/`.

Release assets share one flat namespace per tag, so each `.deb` needs a
distinct file name, and the register step rejects duplicates. A `~<codename>`
version suffix gives you that naturally. GitHub stores `~` in an asset name as
`.`: `myapp_6.7.2-1~trixie_amd64.deb` is served as
`myapp_6.7.2-1.trixie_amd64.deb`. The register step builds each URL from that
stored name, and counts `a~b.deb` and `a.b.deb` as the same asset.

## The reference format

```json
{
  "name": "myapp",
  "version": "1.3.0",
  "homepage": "https://github.com/acme/myapp",
  "description": "What myapp does",
  "artifacts": [
    { "release": "any", "arch": "amd64",
      "url": "https://github.com/acme/myapp/releases/download/v1.3.0/myapp_1.3.0_amd64.deb",
      "sha256": "<64 hex>" }
  ]
}
```

- Required: `name`, `version` and `artifacts`, each artifact with `release`,
  `arch`, `url` and `sha256`. `homepage` and `description` are optional, and no
  other field is allowed.
- `release` is one of the instance's codenames, or `any`. `arch` is one of its
  architectures, or `all`, which is indexed under every architecture.
- URLs must be `https://`.
- Every publish downloads each artifact, checks its sha256, and compares the
  `.deb`'s `Package`/`Version`/`Architecture` with `name`/`version`/`arch`. A
  mismatch fails the publish, and the previous deployment stays live.

[`schema/package.schema.json`](../schema/package.schema.json) is the contract
between clients and instances, and it is frozen within a major version.

## Signing keys

- The private key lives in the `APT_SIGNING_KEY` secret of the repository that
  deploys, and in your local keyring: `GNUPGHOME`, else
  `<instance>/.gnupg-repo/`. `make key` drops a `*` `.gitignore` into the
  keyring directory, so git never offers it for a commit.
- In CI the key is imported into a temporary keyring outside the site and the
  instance, only for the deploying job. The job first proves that every key
  signs without a passphrase.
- Every usable secret key in the keyring signs, and the published keyring holds
  them all. Expired, revoked and disabled keys are skipped. The published
  keyring is exported from those keys at every publish, so there is no keyring
  file to commit.
- `make key-to-repo` prints the fingerprint and uid of every secret key before
  uploading, so you can check what you are about to publish.

### Which keyring `make` uses

The signing targets (`key`, `backup-key`, `key-info`, `key-to-repo`, `build`,
`publish`) use `GNUPGHOME` when it is set, else `<instance>/.gnupg-repo/`. The
instance is the directory you run `make` in. In the engine checkout that is
`example/`, so without `GNUPGHOME` a `make key-to-repo` there uploads the
example's key, or finds none. That is why the setups export `GNUPGHOME` first.
For a key that lives in an instance's `.gnupg-repo/`, run the targets from that
instance instead:

```bash
cd acme-apt                                       # the instance holding .gnupg-repo/
make -f ../gh-action-debian-repo/Makefile key-info
make -f ../gh-action-debian-repo/Makefile key-to-repo REPO=acme/apt
```

To sign with a key you already have, import it into that keyring
(`gpg --import key.asc` with the same `GNUPGHOME`), check it with
`make key-info`, then run `make key-to-repo`. The key must be able to sign and
have no passphrase, or CI fails with `❌ APT_SIGNING_KEY cannot sign
unattended`. Every secret key in the keyring is uploaded, so keep only the
repository's keys in it.

### Rotating a key

apt accepts a signature from any key it trusts, even when other signatures on
the file are unknown to it. Rotation relies on that:

1. **Add**: run `make key ROTATE=1`, then `make key-to-repo REPO=…`, then
   publish. Both keys now sign, and the published keyring holds both. Old
   clients keep working. Tell users to re-download the keyring.
2. **Retire**: once clients have the new keyring, run
   `gpg --delete-secret-keys <old fpr>`, then `make key-to-repo REPO=…`, then
   publish. Clients that never re-downloaded the keyring stop verifying at this
   point. apt has no key-update channel, so leave phase 1 long enough.

How to "publish" without a new release depends on the setup: see
[self mode](self-mode.md#re-publishing-without-a-new-release) and
[collection mode](collection-mode.md#rotating-the-signing-key).

### Backup and restore

`make backup-key` writes `$GNUPGHOME/signing-key.secret.asc` (mode 600), inside
the git-ignored keyring directory. Move it into a vault, then `shred -u` it. To
restore, run `gpg --import` into `GNUPGHOME`, then `make key-to-repo REPO=…`.

Once the key is in the vault and in the `APT_SIGNING_KEY` secret, the local
copy is optional. `make clean-key` lists the keys it would delete, and
`make clean-key CONFIRM=1` deletes the keyring directory along with any backup
still inside it. It only deletes a directory that holds nothing but GnuPG
files, and never `~/.gnupg`. Local builds and key rotation need the key again,
so restore it from the vault first.

## Local builds

From an instance checkout, point the engine's Makefile at the instance with
`make -f ../gh-action-debian-repo/Makefile <target>`, or add
`include ../gh-action-debian-repo/Makefile` to the instance's own Makefile. A
self-mode instance is a checkout of the `apt` branch.

| Target | Does |
| --- | --- |
| `publish` | the full CI build into `_site/`: validate, download and verify, sign |
| `verify-site` | check the built site as apt would: every suite against the published keyring, every pooled `.deb` parses |
| `serve` | preview the site at `http://localhost:8000`, or a demo page when there are no packages |
| `add DEB=… [RELEASE=…]` | copy a `.deb` into `debs/` (or `debs/<RELEASE>/`) to commit it |
| `register NAME=… REPO=… TAG=… [DIST=…] [FILE=…]` | write a reference from built `.deb`s by hand |
| `themes` | list the colour themes (`make serve THEME=teal` to try one) |
| `key`, `backup-key`, `key-info`, `key-to-repo`, `setup-repo` | signing key and GitHub setup |
| `clean-key [CONFIRM=1]` | list, then with `CONFIRM=1` delete, the local keyring and its backup |
| `help` | every target |

A local build signs with the local keyring, so it needs a key there first:
`make key`, or `gpg --import` of your backup.

## Limits

- GitHub Pages sites are limited to 1 GB, and every `.deb` of every release is
  in the site.
- Release assets must be public, because the publish downloads them
  anonymously. A private app repository needs `debs/` instead.
- Pages for private repositories need a paid plan.
