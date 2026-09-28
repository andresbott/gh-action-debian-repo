# gh-action-debian-repo: developer manual

How the engine works inside, how to operate a repository, and how to release the
engine. For using it, see [README.md](README.md).

## Layout

```
Makefile                      # every local operation; engine or instance (see below)
scripts/                      # the build: hydrate, gen-index, render-index, register, push-ref, …
  instance-lib.sh             # ENGINE/INSTANCE paths + the repository's identity (site_load)
  dists-lib.sh                # loads + validates dists.conf (DISTS/ALIASES/ARCHES)
  owners-lib.sh               # conf/owners.conf: who may publish which package
  conf-overlay.sh             # workflow inputs layered over a committed config, as data
  dists-overlay.sh            # the dists/aliases/arches inputs over dists.conf (publish + pre-push check)
  check-mode.sh               # the workflow's input validation + mode decision
  ci-build.sh                 # the build action's body: key import, overlays, make publish verify
  push-ref.sh                 # the register action's body: register, check against the target, push
  setup-repo.sh               # Pages + github-pages environment policy through gh
  release.sh                  # engine release: pin, tag, move the major tag
schema/package.schema.json    # the packages/*.json reference format (frozen per major version)
template/index.html           # landing page; template/themes/*.css alternate colour themes
defaults/dists.conf           # releases published when an instance has no conf/dists.conf
actions/build/                # composite: scripts/ci-build.sh
actions/register/             # composite: scripts/push-ref.sh, with the token as an HTTP header
.github/workflows/publish.yml # THE reusable workflow clients call
.github/workflows/ci.yml      # the engine's own CI
example/                      # a bundled instance: what the Makefile builds from this checkout
tests/                        # shell tests: `make test`
```

## Engine and instance

Every script resolves two roots (`scripts/instance-lib.sh`):

- **`ENGINE`**: this checkout. It holds the scripts, schema, template and defaults.
- **`INSTANCE`**: the repository being built. It is `$INSTANCE` if set, else the
  current directory. The Makefile uses `example/` when it runs from the engine
  checkout.

Each instance path can be overridden from the environment. The overlays in CI
depend on this.

| Variable | Default |
| --- | --- |
| `PKG_DIR` | `$INSTANCE/packages` |
| `DEBS_DIR` | `$INSTANCE/debs` |
| `OWNERS_CONF` | `$INSTANCE/conf/owners.conf` |
| `SITE_CONF` | `$INSTANCE/conf/site.conf` |
| `DISTS_CONF` | `$INSTANCE/conf/dists.conf`, else `$ENGINE/defaults/dists.conf` |
| `INDEX_TEMPLATE` | `$INSTANCE/conf/index.html`, else `$ENGINE/template/index.html` |
| theme `<n>` | `$INSTANCE/conf/themes/<n>.css`, else `$ENGINE/template/themes/<n>.css` |

**Identity** (`site_load`) starts from `site.conf` and derives every unset key.
`owner/repo` comes from:

1. `GITHUB_REPOSITORY`
2. the `origin` remote, when it is a github.com URL
3. the instance directory's name

From that, `REPO_NAME` is `<owner>-<repo>`, lowercased with `_` turned into `-`.
The keyring, `.sources` file, Release `Origin`/`Label`/`Description` and page
title all follow from `REPO_NAME`. `REPO_URL` is:

- `https://<owner>.github.io/<repo>` for a normal repository
- the root URL for an `<owner>.github.io` repository
- `http://localhost:8000` otherwise

In CI, the Pages URL from `actions/configure-pages` fills `REPO_URL` only when
`site.conf` leaves it unset, so a custom domain set in `site.conf` wins.
`scripts/instance-info.sh KEY` prints any of these values. The Makefile uses it
so that nothing is derived twice.

## The build

`make publish` runs `validate` → `hydrate` → `build`. It is exactly what CI runs.
Nothing is kept between runs: every publish rebuilds the whole site from the
instance.

1. **validate**: the config loads (`dists.conf` names, `site.conf` identity), and
   every `packages/*.json` validates against the schema. The schema check uses
   `scripts/jsonschema.sh`, which runs `check-jsonschema`, else `uvx`, else
   `pipx run`.
2. **hydrate** (`scripts/hydrate.sh`):
   1. If `conf/owners.conf` exists, every reference is checked against it
      *before anything is downloaded*. Each URL must be
      `https://github.com/<an owner>/releases/download/<tag>/<file>` with no
      `.`/`..` segments.
   2. Each artifact is downloaded, its sha256 checked, and its control fields
      compared with `name`/`version`/`arch`.
   3. It is pooled as `pool/<codename>/main/<p>/<pkg>/<Package>_<Version>_<Arch>.deb`.
      `release: any` goes into every `DISTS` codename.
   4. `debs/*.deb` (any) and `debs/<codename>/*.deb` are merged in the same way.
   5. Two sources claiming one (package, codename, arch) is a hard error that
      names both.
3. **build** (`scripts/gen-index.sh`):
   1. `apt-ftparchive` produces `Packages` for each codename and architecture,
      and a `Release` file carrying the branded `Origin`/`Label`/`Description`.
   2. The Release is signed as `InRelease` (clearsigned) and `Release.gpg`
      (detached).
   3. Each alias gets its own signed `dists/<alias>/` (`Suite=<alias>`,
      `Codename=<target>`), which reuses the target's `Packages` without a
      separate pool.
   4. It exports the public keyring (`.gpg` + `.asc`), writes the `.sources`
      file, and renders `index.html` (`scripts/render-index.sh`).

`make verify` checks a built site the way apt does. Every suite's `InRelease`
must verify against the *published* keyring, and every pooled `.deb` must
parse. `tests/apt_test.sh` goes further: an unprivileged, sandboxed `apt-get
update` resolves packages through the site's own `.sources` file.

### A different version per release

A reference file has one `version`. An app that ships different versions to
different releases registers each group into its own file. For example, it
might build v6.5.3 for trixie because trixie's libraries cannot build v6.7.
Each group goes in its own file, such as `file: packages/myapp.trixie.json`
with `dist/trixie/`. All files are merged at publish time. The only rule is one
(package, release, arch) across every file and `debs/`. Release assets share one
flat namespace per tag, so each `.deb` needs a distinct file name.
`register.sh` rejects duplicates. A `~<codename>` version suffix gives you that
naturally.

### The reference format

```json
{
  "name": "myapp",
  "version": "1.3.0",
  "artifacts": [
    { "release": "any", "arch": "amd64",
      "url": "https://github.com/acme/myapp/releases/download/v1.3.0/myapp_1.3.0_amd64.deb",
      "sha256": "<64 hex>" }
  ]
}
```

`schema/package.schema.json` is the contract between clients and instances, and
it is **frozen within a major version**. Any change that an older engine would
reject, or that a newer engine would read differently, needs a new major
version. `version` is always read from the `.deb`, never from the tag: a tag
need not be a version, and a packaging suffix exists only in the `.deb`.

## The reusable workflow

`scripts/check-mode.sh` runs first. It validates the inputs, reporting every
problem at once as annotations, and picks the mode:

| Inputs | Mode | Jobs |
| --- | --- | --- |
| none | publish-only | `publish` |
| `name` + `artifact` | self | `register` → `publish` |
| `name` + `artifact` + `collection` | collection | `register` |

In collection mode the build inputs (`dists`, `aliases`, `arches`, `repo-name`,
`site-title`, `site-tagline`, `theme`) are rejected: the collection's own
`conf/` decides them, so they would be silently ignored.

**`register`**:

1. Checks out the engine at the pinned release.
2. Downloads the artifact.
3. Mints an App token when `app-id` is set.
4. Runs `actions/register` → `scripts/push-ref.sh`, which:
   1. Clones the target branch, creating it as an orphan in self mode.
   2. Writes the reference with `register.sh`.
   3. Checks it against the **target's** config: releases and arches in its
      `dists.conf`, its `owners.conf`, and collisions with its other references
      and its committed `debs/`.
      In self mode the `dists`/`aliases`/`arches` inputs are layered over that
      `dists.conf` first by `scripts/dists-overlay.sh`, which the publish uses
      too: a fresh `apt` branch has no `conf/` of its own. `aliases: none`
      clears the aliases. `dists` without `aliases` drops every alias whose
      target is no longer in `DISTS`, with a warning.
   4. Downloads every release asset anonymously and compares its sha256.
   5. Commits as `github-actions[bot]` and pushes. A push that loses a race with
      a concurrent publish is rebased and retried, up to 5 times with jitter.
      Any other refusal (credentials, branch protection) fails immediately with
      git's message.

The token never appears in a URL or on a command line. It reaches git as
`http.https://github.com/.extraheader` through `GIT_CONFIG_COUNT` environment
config, and its base64 form is masked.

**`publish`** runs in the `github-pages` environment.

- It is skipped in collection mode; the collection's own push-triggered run
  deploys instead. An App token or PAT push does trigger workflows, and a
  `github.token` push does not.
- Steps:
  1. Checks out the instance: the `self-branch`, or `instance-ref`.
  2. Checks out the engine.
  3. Runs `configure-pages`.
  4. Runs `actions/build` (`scripts/ci-build.sh`), which does four things:
     - imports `APT_SIGNING_KEY` into a temporary `GNUPGHOME` outside the site
       and the instance
     - writes the input overlays to temporary `SITE_CONF`/`DISTS_CONF` files,
       leaving the committed files untouched
     - runs `make publish verify`
     - removes the keyring
  5. Runs `upload-pages-artifact` and then `deploy-pages`.
- One deploy per repository runs at a time. A newer queued run supersedes an
  older one that is still waiting. That is safe, because every run rebuilds from
  the latest references.

**No `permissions:` block** is set inside the workflow. A called workflow can
only narrow the caller's permissions, and the modes need different ones, so
callers grant them (see the README).

**Environment secrets.** `APT_SIGNING_KEY` normally lives in the caller's
`github-pages` environment. Only the `publish` job, which declares that
environment, can read it. The environment's deployment policy decides which
refs may deploy (and so sign). `make setup-repo` allows the default branch
plus the given tag patterns.

**Engine pinning.** A caller picks the workflow file with `@v1` or `@v1.2.3`.
That file checks the engine out at `${{ inputs.engine-ref || 'vX.Y.Z' }}`,
which `scripts/release.sh` rewrites for every release. The workflow and the
scripts therefore always come from the same release.

## Signing and key rotation

`gen-index.sh` signs with **every usable secret key** in `GNUPGHOME`. Expired,
revoked and disabled keys are skipped. `SIGNING_KEYS="<fpr> …"` narrows the set.
The published keyring contains every signing key.

Locally, the keyring lives in `$(INSTANCE)/.gnupg-repo/` unless `GNUPGHOME` is
set. `make key` writes a `.gitignore` of `*` into the keyring directory, so git
never offers it for a commit, wherever `GNUPGHOME` points. In CI it is a
temporary directory. It is never inside the site.

apt accepts a signature from any key it trusts, even when other signatures on
the file are unknown to it. Rotation relies on that:

1. **Add**: run `make key ROTATE=1`, then `make key-to-repo REPO=…`, then publish.
   Both keys now sign, and the published keyring holds both. Old clients keep
   working. Tell users to re-download the keyring.
2. **Retire**: once clients have the new keyring, run
   `gpg --delete-secret-keys <old fpr>`, then `make key-to-repo`, then publish.
   Clients that never re-downloaded the keyring stop verifying at this point.
   apt has no key-update channel, so plan phase 1 long enough.

`make backup-key` writes `$(GNUPGHOME)/signing-key.secret.asc` (mode 600). It
sits inside the keyring directory, so it is private and git-ignored along with
it. Move it into a vault, then `shred -u` it. To restore, run `gpg --import`
into `GNUPGHOME`, then `make key-to-repo`.

## Security model

- **The signing key** exists only in the environment secret, and only during
  the `publish` job. Collection clients never see it.
- **Workflow inputs are data.** `conf-overlay.sh` writes them `%q`-quoted, and
  `dists.conf` names are validated.
- **The landing page** escapes every value from `site.conf` and every package
  field (`&`, `<`, `>`, `"`). A package's `Homepage` is linked only when it is
  an `http(s)://` URL.
- **In a collection**, `owners.conf` limits each package to its listed
  repositories and their release URLs. The register step rejects a reference the
  target would reject. The build re-checks everything anyway, so a hand-edited
  reference is caught before download.
- **Tokens**: App tokens are scoped to the one collection repository. Tokens
  never reach a URL, a command line or the log.

## Tests

`make test` runs every `tests/*_test.sh` and takes about 30 seconds.

- **Needs**: `bash`, `make`, `git`, `gpg`/`gpgv`, `dpkg-deb`, `apt-ftparchive`
  (`apt-utils`), `apt-get`, `jq`, `python3` with `yaml`, and `check-jsonschema`,
  `uvx` or `pipx`.
- **No network**: downloads use `file://` URLs or a fake `curl`, and `gh` is
  faked.

| Suite | Covers |
| --- | --- |
| `dists`, `instance`, `overlay`, `dists_overlay` | config loading, path and identity resolution, input overlays |
| `hydrate`, `owners`, `register`, `schema` | pool assembly, allowlist, reference generation, the format |
| `gen_index`, `render`, `apt` | signing (multi-key, expired keys), page rendering and escaping, a real sandboxed apt |
| `make` | the Makefile end to end: key → add → register → publish → verify → preview, rotation, example/ |
| `push_ref`, `actions`, `check_mode` | register side: target checks, races, asset checks, token handling, mode rules |
| `ci_build`, `setup_repo`, `release` | publish side, repository setup, engine releases |

`make lint` runs actionlint, including shellcheck on `run:` blocks, through
docker. CI (`ci.yml`) runs:

- `make test`
- `make lint`
- `actions/build` end to end on `example/`, with a throwaway key and `make verify`

## Releasing the engine

```bash
make release VERSION=v1.0.0-rc.1   # pin + commit + tag; prints the push commands, never pushes
```

1. **rc**: tag `vX.Y.Z-rc.N` and push it. Then run the acceptance checks:
   - A self-mode test repository calls `publish.yml@vX.Y.Z-rc.N`, tags a
     release, and `apt install`s the package from its Pages.
   - A collection test repository plus one client does the same through the
     collection, including an `owners.conf` rejection.
2. **final**: `make release VERSION=vX.Y.Z` also moves the major tag (`v1`).
   Push it with `git push --force origin v1`.

Release candidates never move the major tag, so `@v1` users only ever get final
releases.

## Limits

- GitHub Pages sites are limited to 1 GB, and every `.deb` of every release is
  in the site.
- Release assets must be public, because the publish downloads them
  anonymously. A private app repository needs `debs/` instead.
- Pages for private repositories need a paid plan.
