# gh-action-debian-repo

Publish your `.deb` packages as a **signed APT repository on GitHub Pages**, for
several Debian and Ubuntu releases at once, from a release workflow.

- One reusable workflow, two ways to use it:
  - **[Self mode](docs/self-mode.md)**: a project publishes its own repository on its own Pages.
  - **[Collection mode](docs/collection-mode.md)**: many projects publish into one shared repository. Each project's release pushes its reference there, and the shared repository deploys itself.
- Stateless. Every publish rebuilds the whole repository from checksummed references to your GitHub release assets, plus any `.deb`s committed to it. Each release gets a pool and a signed index, rolling aliases (`stable`, `testing`, …) sit on top, and a landing page shows the install instructions.
- The same engine runs locally: `make publish verify serve` gives you the exact CI build at `http://localhost:8000`.

## How it works

```
app repo (tag v1.2.0)                    repository instance                    GitHub Pages
─────────────────────                    ───────────────────                    ────────────
build .debs ─► release assets            packages/myapp.json   (url + sha256)
            └► artifact ─► register ───► conf/ (dists, site, owners)  ─► publish ─► pool/ dists/ (signed)
                                         debs/  (committed .debs)                   index.html, keyring, .sources
```

The files that describe a repository form an **instance**: `packages/*.json`
(the references), `debs/` (committed binaries) and an optional `conf/`. In self
mode the instance is an orphan branch (`apt`) of the app repository. In
collection mode it is the collection repository. This repository is the
**engine**: scripts, schema, page template and the workflow. Instances hold no
code.

Called without a package, the workflow only rebuilds and deploys what is already
committed: a **publish-only** run. That is how a collection deploys itself, and
how a self-mode repository re-publishes without a new release.

## Quick start

A project that publishes its own repository adds one job to its release
workflow, after the job that builds the `.deb`s, creates the release and uploads
the `.deb`s as the `debs` artifact:

```yaml
  apt:
    needs: build
    permissions:
      contents: write                            # push the reference to the apt branch
      pages: write
      id-token: write
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1
    with:
      name: myapp                                # the .debs' Package field
      artifact: debs
    secrets: inherit
```

The repository also needs a signing key and GitHub Pages, set up once: see
[Self mode](docs/self-mode.md). To publish several projects into one repository,
see [Collection mode](docs/collection-mode.md).

## Documentation

| Document | Covers |
| --- | --- |
| [Self mode](docs/self-mode.md) | setup, the release workflow, releases and versions, re-publishing |
| [Collection mode](docs/collection-mode.md) | the collection repository, client credentials, `owners.conf`, the trust model |
| [Reference](docs/reference.md) | workflow inputs, configuration, the reference format, signing keys, local builds, limits |
| [DEVELOPMENT.md](DEVELOPMENT.md) | working on the engine: internals, tests, conventions, releases |

## License

GPL-3.0-or-later: see [LICENSE](LICENSE). That includes the page template and
themes, so the landing page every repository publishes carries the same license.
