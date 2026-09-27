# gh-action-debian-repo — build, sign and publish a static APT repository to
# GitHub Pages, across several Debian/Ubuntu releases at once (a pool + signed
# index per codename, plus rolling-suite aliases).
#
# This checkout is the ENGINE (scripts/, schema/, template/, defaults/). The
# repository it builds is an INSTANCE: packages/*.json references, committed
# debs/ and optional conf/ (site.conf, dists.conf, owners.conf, themes/,
# index.html). Run from the engine checkout, the bundled example/ instance is
# built; run from an instance — `make -f <engine>/Makefile serve`, or
# `include <engine>/Makefile` in its own Makefile — that instance is. INSTANCE=
# overrides both.
#
# Two ways a package enters the repo:
#   1. Automated: an app's CI publishes packages/<app>.json (a checksummed
#      reference to its release .debs) through the reusable workflow; `hydrate`
#      downloads + verifies it into that release's pool.
#   2. Manual:    `make add DEB=foo.deb` stages a binary into debs/, which you
#      commit. Both are merged into the published pool.
#
# Local dry-run of the whole CI publish:  make publish verify serve

ENGINE := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ifeq ($(abspath $(CURDIR)),$(ENGINE))
INSTANCE ?= $(ENGINE)/example
else
INSTANCE ?= $(abspath $(CURDIR))
endif
export INSTANCE

SITE      ?= $(INSTANCE)/_site
DIST      ?= dist
PORT      ?= 8000
# Colour theme for a single build/preview; set it for good in conf/site.conf.
# 'violet' is built in; `make themes` lists the alternates.
THEME     ?=
KEY_EMAIL ?= $(shell git config user.email)
KEY_NAME  ?= $(shell $(INFO) SITE_TITLE) APT repository
GH        ?= gh
SCRIPTS   := $(ENGINE)/scripts
INFO      := $(SCRIPTS)/instance-info.sh

# All GPG operations use an instance-local keyring by default so the private key
# never mixes with your personal one. CI points GNUPGHOME at a temp dir outside
# the tree; `?=` lets that win.
GNUPGHOME ?= $(INSTANCE)/.gnupg-repo
export GNUPGHOME

# `preview` renders into, and `serve` serves, the built site when it has
# packages — else a demo page in .cache/preview, so an empty repository's design
# can still be worked on. The demo is never part of a build.
PREVIEW_DIR = $(if $(wildcard $(SITE)/pool/*/main/*/*/*.deb),$(SITE),$(INSTANCE)/.cache/preview)

default: help

#==========================================================================================
##@ Repository
#==========================================================================================

.PHONY: publish
publish: validate hydrate build ## full local rebuild (mirrors CI): validate -> hydrate -> build

.PHONY: validate
validate: ## check the instance config and packages/*.json against the JSON schema
	@$(INFO) DISTS >/dev/null && echo "✅ config valid ($$($(INFO) DISTS_CONF))"
	@files=$$(find "$(INSTANCE)/packages" -name '*.json' 2>/dev/null); \
	 if [ -z "$$files" ]; then echo "⚠️  no package files to validate"; exit 0; fi; \
	 $(SCRIPTS)/jsonschema.sh --schemafile "$(ENGINE)/schema/package.schema.json" $$files && echo "✅ all package files valid"

.PHONY: hydrate
hydrate: ## assemble $(SITE)/pool from packages/*.json (download + verify) and debs/
	@$(SCRIPTS)/hydrate.sh "$(SITE)"

.PHONY: build
build: require-key ## generate + GPG-sign the index in $(SITE) from the pool
	@THEME="$(THEME)" $(SCRIPTS)/gen-index.sh "$(SITE)"
	@echo ">> tip: 'make verify serve' to check it locally"

.PHONY: verify
verify: ## check a built site as apt would: every suite verifies against the published keyring, pooled debs parse
	@kr="$(SITE)/$$($(INFO) KEYRING_FILE)"; ok=1; \
	 [ -f "$$kr" ] || { echo "❌ no published keyring $$kr (run 'make publish')"; exit 1; }; \
	 for s in $$($(INFO) SUITES); do \
	   if gpgv --keyring "$$kr" "$(SITE)/dists/$$s/InRelease" >/dev/null 2>&1; then echo "✅ $$s signature OK"; \
	   else echo "❌ $$s signature failed"; ok=0; fi; done; \
	 debs=$$(find "$(SITE)/pool" -name '*.deb' 2>/dev/null); \
	 [ -n "$$debs" ] || echo "⚠️  no .deb files in the pool"; \
	 for d in $$debs; do dpkg-deb --info "$$d" >/dev/null 2>&1 || { echo "❌ $$d"; ok=0; }; done; \
	 [ $$ok -eq 1 ]

.PHONY: add
add: ## stage a local .deb into debs/ (or debs/<RELEASE>/) for git-committed hosting: make add DEB=path/to.deb [RELEASE=trixie]
	@[ "$(DEB)" ] || { echo ">> usage: make add DEB=path/to/pkg.deb [RELEASE=<codename>]"; exit 1; }
	@[ -f "$(DEB)" ] || { echo "❌ no such file: $(DEB)"; exit 1; }
	@dpkg-deb --info "$(DEB)" >/dev/null 2>&1 || { echo "❌ not a valid .deb: $(DEB)"; exit 1; }
	@[ -z "$(RELEASE)" ] || $(INFO) DISTS | tr ' ' '\n' | grep -qx "$(RELEASE)" \
	  || { echo "❌ RELEASE '$(RELEASE)' is not one of: $$($(INFO) DISTS)"; exit 1; }
	@dest="$(INSTANCE)/debs$(if $(RELEASE),/$(RELEASE))"; mkdir -p "$$dest"; cp "$(DEB)" "$$dest/"; \
	 echo "✅ staged $$dest/$$(basename "$(DEB)")  ($$(dpkg-deb -f "$(DEB)" Package) $$(dpkg-deb -f "$(DEB)" Version) $$(dpkg-deb -f "$(DEB)" Architecture))"; \
	 echo ">> commit it; the next publish includes it"

# FILE overrides the default packages/<name>.json. One file holds one version, so
# an app whose suites ship different versions registers each group separately:
#   make register NAME=myapp ... DIST=dist/trixie-only FILE=packages/myapp.trixie.json
# All packages/*.json are merged at publish time; no two may claim the same
# (package, release, arch).
REGISTER_OUT = $(if $(FILE),$(FILE),packages/$(NAME).json)

.PHONY: register
register: ## write a packages/*.json from built debs (DIST: flat *.deb = "any", or <release>/*.deb): make register NAME=app REPO=owner/app TAG=vX.Y.Z [DIST=dist] [FILE=packages/app.trixie.json]
	@[ "$(NAME)" ] && [ "$(REPO)" ] && [ "$(TAG)" ] || { echo ">> usage: make register NAME=myapp REPO=owner/myapp TAG=v1.3.0 [DIST=dist] [FILE=packages/<app>.<release>.json]"; exit 1; }
	@case "$(REGISTER_OUT)" in packages/*.json) ;; *) echo "❌ FILE must be packages/<something>.json, got '$(REGISTER_OUT)'"; exit 1;; esac
	@$(SCRIPTS)/register.sh --name "$(NAME)" --dist-dir "$(DIST)" --repo "$(REPO)" --tag "$(TAG)" --out "$(INSTANCE)/$(REGISTER_OUT)"
	@echo ">> commit $(REGISTER_OUT) to publish (normally the app's CI does this through the workflow)"

.PHONY: clean
clean: ## remove the built site and caches (keeps packages/, debs/ and the key)
	@rm -rf "$(SITE)" "$(INSTANCE)/.cache"
	@echo "✅ removed $(SITE)/ and $(INSTANCE)/.cache/"

#==========================================================================================
##@ Design
#==========================================================================================

.PHONY: preview
preview: ## re-render only the landing page (no signing) — the built site, or a demo page when it has no packages
	@dir="$(PREVIEW_DIR)"; \
	 if [ "$$dir" != "$(SITE)" ]; then \
	   rm -rf "$$dir"; mkdir -p "$$dir"; export DEMO_WHEN_EMPTY=1; \
	   echo "⚠️  no packages in $(SITE) — rendering the demo preview (never published; 'make example-debs publish' for real content)"; \
	 fi; \
	 THEME="$(THEME)" $(SCRIPTS)/render-index.sh "$$dir" && echo "✅ rendered $$dir/index.html"

.PHONY: serve
serve: preview ## preview, then serve it at http://localhost:$(PORT) (Ctrl-C to stop)
	@echo ">> serving $(PREVIEW_DIR) at http://localhost:$(PORT) (Ctrl-C to stop)"
	@cd "$(PREVIEW_DIR)" && python3 -m http.server $(PORT)

.PHONY: themes
themes: ## list the landing-page colour themes (use: make serve THEME=<name>)
	@echo "violet   (built-in default)"
	@for f in "$(INSTANCE)"/conf/themes/*.css "$(ENGINE)"/template/themes/*.css; do \
	   [ -e "$$f" ] && basename "$$f" .css; done | awk '!seen[$$0]++'

EXAMPLE_DEBS ?= $(ENGINE)/example/debs

.PHONY: example-debs
example-debs: ## generate sample .debs into example/debs (git-ignored) for a populated local site
	@bash -c '. "$(ENGINE)/tests/helpers.sh"; d="$(EXAMPLE_DEBS)"; rm -rf "$$d"; \
	  make_deb "$$d" hello-cli 1.2.0 all any >/dev/null; \
	  make_deb "$$d/trixie" hello-daemon 0.9.0-1~trixie amd64 trixie >/dev/null; \
	  make_deb "$$d/trixie" hello-daemon 0.9.0-1~trixie arm64 trixie >/dev/null; \
	  make_deb "$$d/forky" hello-daemon 1.0.0-1~forky amd64 forky >/dev/null; \
	  make_deb "$$d/resolute" hello-daemon 1.0.0-1~resolute amd64 resolute >/dev/null; \
	  echo "✅ sample debs in $$d"'

#==========================================================================================
##@ Signing
#==========================================================================================

.PHONY: key
key: ## generate a GPG signing key (refuses if one exists; ROTATE=1 adds another for a key rotation)
	@[ "$(KEY_EMAIL)" ] || { echo "❌ KEY_EMAIL is empty (set it, or git config user.email)"; exit 1; }
	@mkdir -p -m 700 "$(GNUPGHOME)"
	@if [ -z "$(ROTATE)" ] && gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then \
	   echo "⚠️  $(GNUPGHOME) already holds a signing key — refusing to add another"; \
	   echo ">> 'make key-info' to inspect it; 'make key ROTATE=1' to add a second key for a rotation"; exit 1; fi
	@echo ">> generating RSA-4096 signing key '$(KEY_NAME) <$(KEY_EMAIL)>' in $(GNUPGHOME)"
	@echo ">> (no passphrase — required for unattended signing; keep $(GNUPGHOME) private)"
	@printf '%s\n' '%no-protection' 'Key-Type: RSA' 'Key-Length: 4096' 'Key-Usage: sign' \
	   'Name-Real: $(KEY_NAME)' 'Name-Email: $(KEY_EMAIL)' 'Expire-Date: 0' '%commit' | gpg --batch --gen-key
	@echo "✅ signing key created. next: 'make backup-key', then 'make setup-repo REPO=owner/name' and 'make key-to-repo REPO=owner/name'"

.PHONY: backup-key
backup-key: require-key ## export the PRIVATE signing key(s), armored, for an offline/vault backup
	@out="$(INSTANCE)/signing-key.secret.asc"; umask 077; gpg --batch --export-secret-keys --armor > "$$out"; \
	 echo "✅ wrote $$out (armored PRIVATE key — git-ignored)"; \
	 echo "⚠️  move it to your password vault, then: shred -u $$out"

.PHONY: key-info
key-info: require-key ## show the signing key(s): fingerprint, uid, expiry
	@gpg --batch --list-secret-keys --keyid-format long

.PHONY: require-key
require-key:
	@gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec' || { \
	   echo "❌ no signing key in $(GNUPGHOME)"; \
	   echo ">> 'make key' to generate one, or import yours: gpg --import <key.asc>"; exit 1; }

#==========================================================================================
##@ GitHub
#==========================================================================================

# release-tag patterns allowed to deploy (space-separated; empty = none)
TAGS ?= v*

.PHONY: setup-repo
setup-repo: ## enable Pages (GitHub Actions) + the github-pages environment policy: make setup-repo REPO=owner/name [TAGS='v*']
	@[ "$(REPO)" ] || { echo ">> usage: make setup-repo REPO=owner/name [TAGS='v*']"; exit 1; }
	@GH="$(GH)" $(SCRIPTS)/setup-repo.sh "$(REPO)" "$(TAGS)"

.PHONY: key-to-repo
key-to-repo: require-key ## store the private key as the APT_SIGNING_KEY secret: make key-to-repo REPO=owner/name [ENVIRONMENT=github-pages]
	@[ "$(REPO)" ] || { echo ">> usage: make key-to-repo REPO=owner/name [ENVIRONMENT=github-pages]"; exit 1; }
	@gpg --batch --export-secret-keys --armor | $(GH) secret set APT_SIGNING_KEY --repo "$(REPO)" --env "$(or $(ENVIRONMENT),github-pages)"
	@echo "✅ APT_SIGNING_KEY set on $(REPO) (environment $(or $(ENVIRONMENT),github-pages))"

#==========================================================================================
##@ Engine
#==========================================================================================

.PHONY: test
test: ## run the engine's shell tests
	@fail=0; for t in "$(ENGINE)"/tests/*_test.sh; do echo ">> $$t"; bash "$$t" || fail=1; done; \
	 [ $$fail -eq 0 ] && echo "✅ all tests passed"

#==========================================================================================
#  Help
#==========================================================================================
.PHONY: help
help: ## Display this help.
	@echo "engine:   $(ENGINE)"; echo "instance: $(INSTANCE)"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
