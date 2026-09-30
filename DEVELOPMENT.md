# Developing gh-action-debian-repo

How to work on the engine: setting it up, its conventions, the tests, trying a
change on GitHub, contributing, how it works inside, and releasing it. For using
it, see the [README](README.md) and [`docs/`](docs/).

## Getting started

You need `bash`, `make`, `git`, `gpg`/`gpgv`, `dpkg-deb`, `apt-ftparchive`
(`apt-utils`), `apt-get`, `jq`, `curl`, `python3` with `yaml`, one of
`check-jsonschema`, `uvx` or `pipx`, and `docker` for `make lint`.

```bash
make verify                               # before a push: make test, then make lint
make test                                 # every test suite, about a minute
make lint                                 # actionlint + shellcheck, through docker
make key KEY_EMAIL=you@example.org        # once: a local key for the example, in example/.gnupg-repo (git-ignored)
make example-debs publish verify-site serve  # sample packages, the full CI build, apt's checks, http://localhost:8000
make help                                 # every target
```

From this checkout, every Makefile target works on the bundled
[`example/`](example/) instance. `make serve THEME=teal` previews the page with
another theme.

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
  ci-build.sh                 # the build action's body: key import, overlays, make publish verify-site
  push-ref.sh                 # the register action's body: register, check against the target, push
  setup-repo.sh               # Pages + github-pages environment policy through gh
  release.sh                  # engine release (make tag): pin, tag, move the major tag, push
schema/package.schema.json    # the packages/*.json reference format (frozen per major version)
template/index.html           # landing page; template/themes/*.css alternate colour themes
defaults/dists.conf           # releases published when an instance has no conf/dists.conf
actions/build/                # composite: scripts/ci-build.sh
actions/register/             # composite: scripts/push-ref.sh, with the token as an HTTP header
.github/workflows/publish.yml # THE reusable workflow every repository calls
.github/workflows/ci.yml      # the engine's own CI
example/                      # a bundled instance: what the Makefile builds from this checkout
docs/                         # user documentation: self mode, collection mode, reference
tests/                        # shell tests: `make test`
```

## Conventions

- **Shell.** Scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Sourced libraries (`*-lib.sh`, `tests/helpers.sh`) carry
  `# shellcheck shell=bash`, no `set`, and no executable bit. Output prefixes:
  `✅` success, `❌` error (to stderr), `⚠️ ` warning, `>>` progress.
- **Workflow inputs are data.** A `run:` step never interpolates
  `${{ inputs.* }}`: inputs reach scripts through `env:` (see the `IN_*`
  variables in `publish.yml`). `conf-overlay.sh` writes them `%q`-quoted, and
  every `dists.conf` name is validated.
- **Tokens** never appear in a URL, on a command line or in the log (see
  [the register job](#the-reusable-workflow)).
- **gpg** generates keys only with `--pinentry-mode loopback --passphrase ''` or
  `%no-protection`, in scripts and tests alike. Anything else pops up a GUI
  pinentry.
- **Private keys are never committed.** `.gnupg-repo/` and `*.secret.asc` are
  git-ignored. In CI, `GNUPGHOME` is a temporary directory outside the site and
  the instance.
- **The reference format is frozen within a major version.** Any change to
  `schema/package.schema.json` that an older engine would reject, or that a
  newer engine would read differently, needs a new major version.
- **Action versions** are pinned to a major (`actions/checkout@v7`, …).
  Dependabot proposes bumps weekly for `.github/workflows/` and `actions/*/`. A
  bump changes what every caller runs, so it ships in an engine release, after
  an acceptance run.

## Tests

`make test` runs every `tests/*_test.sh` with `bash`. Run one suite with
`bash tests/<suite>_test.sh`.

A suite:

- sources `tests/helpers.sh`, which unsets `GITHUB_REPOSITORY` (so the suite
  does not pick up the identity of the repository running it) and provides
  `need`, `make_deb`, `make_test_key`, `make_expired_key` and `make_instance`;
- starts with `need <tool>…`, which skips the whole suite when a tool is
  missing;
- works in a `mktemp -d` directory removed by a `trap`;
- prints `❌ <what>` for each failed check, and ends with `PASS <suite>` (exit 0)
  or `FAIL <suite>` (exit 1);
- never touches the network: downloads use `file://` URLs or a fake `curl`, `gh`
  is a fake passed through `$GH`, and git remotes are local bare repositories.

| Suite | Covers |
| --- | --- |
| `dists`, `instance`, `overlay`, `dists_overlay` | config loading, path and identity resolution, input overlays |
| `hydrate`, `owners`, `register`, `schema` | pool assembly, allowlist, reference generation, the format |
| `gen_index`, `render`, `apt` | signing (multi-key, expired keys), page rendering and escaping, a real sandboxed apt |
| `make` | the Makefile end to end: key → add → register → publish → verify-site → preview, rotation, example/ |
| `push_ref`, `actions`, `check_mode` | register side: target checks, races, asset checks, token handling, mode rules |
| `ci_build`, `setup_repo`, `release` | publish side, repository setup, engine releases |

CI (`ci.yml`) runs on pull requests, on pushes to `main` and on `v*` tags:

- `test`: `make test`
- `lint`: `make lint`
- `build-action`: `actions/build` end to end on `example/`, with a throwaway key,
  then `make verify-site` and checks on the built site

## Trying a change on GitHub

Some behaviour only exists on GitHub: how secrets reach a reusable workflow, a
token push triggering another repository's run, Pages deploys,
`configure-pages`. Secrets behave differently when the caller and the engine
share an owner, so put at least one test repository under another account or
organization. To run a branch's engine from a throwaway public test
repository, call the branch's workflow file and pin the engine to the same
branch:

```yaml
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@my-branch
    with:
      engine-ref: my-branch
      # … the inputs under test
```

Without `engine-ref`, that workflow file would still check out the scripts of
the release it is pinned to. The engine is checked out from
`andresbott/gh-action-debian-repo`, so the branch must exist there. To test from
a fork, point `repository:` in both engine checkouts of your branch's
`publish.yml` at the fork.

## Contributing

1. Branch off `main`, and open a pull request against `main`. CI must pass.
2. Every behaviour change comes with a test. For a bug, reproduce it in a test
   first, then fix it.
3. Commit subjects are one line, in Conventional Commits form: `feat:`, `fix:`,
   `docs:`, `test:`, `chore:`.
4. Keep the docs in step: user-facing behaviour in the README and `docs/`,
   internals in this file.
5. A branch that carries a release tag is merged with a merge commit, never
   squashed or rebased, so the tag stays in `main`'s history.

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
   every `packages/*.json` (from `PKG_DIR`, as hydrate reads them) validates
   against the schema. The schema check uses `scripts/jsonschema.sh`, which
   runs `check-jsonschema`, else `uvx`, else `pipx run`. When none of them is
   available, validate warns and skips the schema check; hydrate still checks
   every artifact it downloads.
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
      (detached) with **every usable secret key** in `GNUPGHOME`. Expired,
      revoked and disabled keys are skipped, and `SIGNING_KEYS="<fpr> …"`
      narrows the set.
   3. Each alias gets its own signed `dists/<alias>/` (`Suite=<alias>`,
      `Codename=<target>`), which reuses the target's `Packages` without a
      separate pool.
   4. It exports the public keyring (`.gpg` + `.asc`) from the signing keys,
      writes the `.sources` file, and renders `index.html`
      (`scripts/render-index.sh`).

`make verify-site` checks a built site the way apt does. Every suite's `InRelease`
must verify against the *published* keyring, and every pooled `.deb` must
parse. `tests/apt_test.sh` goes further: an unprivileged, sandboxed `apt-get
update` resolves packages through the site's own `.sources` file.

## The reusable workflow

`scripts/check-mode.sh` runs first. It validates the inputs, reporting every
problem at once as annotations, and picks the mode:

| Inputs | Mode | Jobs |
| --- | --- | --- |
| none | publish-only | `publish` |
| `name` + `artifact` | self | `register` → `publish` |
| `name` + `artifact` + `collection` | collection | `register` |

These are the workflow's internal modes, not three setups. A self-mode
repository makes one self run per release. A collection needs a collection run in
each client plus the collection's own publish-only run, which the client's push
triggers. A publish-only run also re-publishes a self-mode repository.

In a collection-mode call (a client's) the build inputs (`dists`, `aliases`,
`arches`, `repo-name`, `site-title`, `site-tagline`, `theme`) are rejected: the
collection's own `conf/` decides them, so they would be silently ignored. For
the same reason `instance-ref` and `instance-path` are rejected whenever `name`
is set: they only pick the instance a publish-only run builds.

**`register`**:

1. Checks out the engine at the pinned release.
2. Downloads the artifact.
3. Mints an App token when `app-id` is set.
4. Runs `actions/register` → `scripts/push-ref.sh`, which:
   1. Clones the target branch, creating it as an orphan in self mode. Only a
      branch the remote reports missing is created: a remote that cannot be
      read (credentials, a missing repository) fails with git's message.
   2. Writes the reference with `register.sh`. An existing `file` that
      belongs to another package is never overwritten.
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

- It is skipped in collection mode; the collection's own push-triggered
  publish-only run deploys instead. An App token or PAT push does trigger
  workflows, and a `github.token` push does not.
- Steps:
  1. Checks out the instance: the `self-branch`, or `instance-ref`.
  2. Checks out the engine.
  3. Runs `configure-pages`.
  4. Runs `actions/build` (`scripts/ci-build.sh`), which does four things:
     - imports `APT_SIGNING_KEY` into a temporary `GNUPGHOME` outside the site
       and the instance, and proves every key in it signs without a passphrase
       (a protected key fails here, not halfway through signing)
     - writes the input overlays to temporary `SITE_CONF`/`DISTS_CONF` files,
       leaving the committed files untouched
     - runs `make publish verify-site`
     - removes the keyring
  5. Runs `upload-pages-artifact` and then `deploy-pages`.
- One deploy per repository runs at a time. A newer queued run supersedes an
  older one that is still waiting. That is safe, because every run rebuilds from
  the latest references.

**No `permissions:` block** is set inside the workflow. A called workflow can
only narrow the caller's permissions, and the modes need different ones, so
callers grant them (see the [reference](docs/reference.md#the-workflow)).

**Secrets.** Callers pass `APT_SIGNING_KEY` by name, from a repository secret.
A caller owned by another account than the engine gets nothing through
`secrets: inherit`. Its environment secrets never reach the `publish` job
either, even though that job declares the `github-pages` environment. The
environment's deployment policy still decides which refs may deploy (and so
sign). `make setup-repo` allows the default branch plus the given tag patterns.

**Engine pinning.** A caller picks the workflow file with `@v1` or `@v1.2.3`.
That file checks the engine out at `${{ inputs.engine-ref || 'vX.Y.Z' }}`,
which `scripts/release.sh` rewrites for every release. The workflow and the
scripts therefore always come from the same release.

## Security model

- **The signing key** lives in the deploying repository's `APT_SIGNING_KEY`
  secret. In CI it exists only during the `publish` job, and collection clients
  are never handed it. A client that can push `conf/` can still run code in that
  job: see [the trust model](docs/collection-mode.md#the-trust-model).
- **Workflow inputs are data.** `conf-overlay.sh` writes them `%q`-quoted, and
  `dists.conf` names are validated.
- **The landing page** escapes every value from `site.conf` and every package
  field (`&`, `<`, `>`, `"`). A package's `Homepage` is linked only when it is
  an `http(s)://` URL.
- **In a collection**, `owners.conf` limits each package to its listed
  repositories and their release URLs. The register step rejects a reference the
  target would reject. The build re-checks everything anyway, so a hand-edited
  reference is caught before download. These checks stop honest mistakes, not a
  malicious client: every client holds the App key (or the collection token),
  which is `contents: write` on the whole collection. See
  [the trust model](docs/collection-mode.md#the-trust-model).
- **Tokens**: App tokens are scoped to the one collection repository. Tokens
  never reach a URL, a command line or the log.

## Releasing the engine

```bash
make tag VERSION=v1.0.0-rc.1   # pin + commit + tag, then push the branch and the tag
```

`scripts/release.sh` needs a clean tree on a branch that is not behind
`origin`. The version must be `vX.Y.Z` or `vX.Y.Z-rc.N` with no leading zeros.
It must not be tagged yet, locally or on `origin`, and it must be newer than
every release of its major line. So `@v1` never moves backwards, and an rc can't
follow its final. The script rewrites both engine pins in `publish.yml` to the
version, commits `release <version>`, and tags it. For a final release it also
moves the major tag (`v1`). It then pushes the branch and the tags to `origin`
in one atomic push. If that push fails, the release stays tagged locally and
the script prints the command to retry.

1. **rc**: `make tag VERSION=vX.Y.Z-rc.N`.
   Run the acceptance checks against `publish.yml@vX.Y.Z-rc.N`, on throwaway
   public repositories:
   - A self-mode repository tags a release, and the package `apt install`s from
     its Pages in a clean container.
   - A collection plus one client (with a GitHub App) do the same through the
     collection, including an `owners.conf` rejection.

   A failure gets a test and a fix, then the next `rc.N`.
2. **final**: `make tag VERSION=vX.Y.Z` also moves `v1` and force-pushes it.
   Check `@v1` end to end with one more self-mode release.

Release candidates never move the major tag, so `@v1` users only ever get final
releases.
