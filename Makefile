EMACS ?= emacs
SRC = anvil-pkg-compat.el anvil-pkg-state.el anvil-pkg.el anvil-pkg-dsl.el anvil-pkg-import.el anvil-pkg-emacs.el nelix.el nelix-dsl.el nelix-import.el nelix-emacs.el nelix-manifest.el nelix-fast.el nelix-store.el nelix-registry.el nelix-fetch.el nelix-builder.el nelix-backend.el nelix-substitute.el
PKG_METADATA = nelix-pkg.el
TEST_SRC = test/anvil-pkg-test.el test/anvil-pkg-uninstall-test.el test/anvil-pkg-upgrade-test.el test/anvil-pkg-pin-test.el test/anvil-pkg-info-test.el test/anvil-pkg-doctor-test.el test/anvil-pkg-dsl-test.el test/anvil-pkg-buildsys-test.el test/anvil-pkg-import-test.el test/anvil-pkg-compat-test.el test/anvil-pkg-emacs-test.el test/anvil-pkg-state-test.el test/nelix-manifest-test.el test/nelix-store-test.el test/nelix-cli-test.el
NELISP_EXEC_TEST_SRC ?= test/anvil-pkg-test.el test/anvil-pkg-uninstall-test.el test/anvil-pkg-upgrade-test.el test/anvil-pkg-pin-test.el test/anvil-pkg-info-test.el test/anvil-pkg-doctor-test.el test/anvil-pkg-dsl-test.el test/anvil-pkg-buildsys-test.el test/anvil-pkg-import-test.el
SCRIPT_SRC = scripts/anvil-pkg-render.el scripts/anvil-pkg-nelisp-smoke.el scripts/anvil-pkg-nelisp-ert-shim.el scripts/nelix-cli.el scripts/nelix-aot-manifest-engine.el scripts/nelix-aot-native-subset.el scripts/nelix-aot-native-cli-proof.el
BIN_SRC = bin/nelix
DOC_SRC = README.org examples/README.org docs/smoke-test.org packaging/README.org
REGISTRY_SRC = $(sort $(wildcard registry/packages/*/*.el))
EXPECTED_ERT_TESTS ?= 418
EXPECTED_NELISP_ERT_TESTS ?= 130
NELISP_CACHE_DIR ?= .cache/nelisp
NELISP_SUITE_IMAGE ?= $(NELISP_CACHE_DIR)/anvil-pkg-suite.nlri
NELIX_CLI_IMAGE ?= $(NELISP_CACHE_DIR)/nelix-cli.nlri
NELISP_ERT_SELECTOR ?=
NELISP_REPO ?= $(abspath ../nelisp)

EMACS_BATCH = $(EMACS) -Q --batch -L . -L test -L scripts
prefix ?= /usr/local
bindir ?= $(prefix)/bin
datarootdir ?= $(prefix)/share
lispdir ?= $(datarootdir)/emacs/site-lisp/nelix
docdir ?= $(datarootdir)/doc/nelix
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
INSTALL_DIR ?= $(INSTALL) -d
RM ?= rm -f
DEB_VERSION ?= 0.1.0-4
DEB_UPSTREAM_VERSION ?= $(firstword $(subst -, ,$(DEB_VERSION)))
DEB_ORIG ?= ../nelix_$(DEB_UPSTREAM_VERSION).orig.tar.gz
DEB_SOURCE_CHANGES ?= ../nelix_$(DEB_VERSION)_source.changes
DEB ?= ../elpa-nelix_$(DEB_VERSION)_all.deb
APT_REPO_DIR ?= ../nelix-apt-repo
APT_SUITE ?= unstable
APT_TEST_GNUPGHOME ?= $(APT_REPO_DIR)-gnupg-test
APT_PUBLISH_DIR ?= ../nelix-apt-public
APT_PUBLIC_URL ?= https://example.invalid/nelix
FEDORA_VERSION ?= 0.1.0
FEDORA_TOPDIR ?= ../nelix-rpmbuild
FEDORA_REPO_DIR ?= ../nelix-rpm-repo
FEDORA_PUBLISH_DIR ?= ../nelix-fedora-public
FEDORA_IMAGE ?= fedora:latest
FEDORA_PUBLIC_URL ?= https://example.invalid/nelix/fedora
LINTIAN ?= lintian
AUTOPKGTEST ?= autopkgtest
APT ?= apt
SUDO ?= sudo

NELISP ?= $(shell command -v nelisp 2>/dev/null || \
  { test -x ../nelisp/target/nelisp && \
    printf '%s\n' ../nelisp/target/nelisp; } || \
  { test -x ../nelisp.wt-mod-expt/target/nelisp && \
    printf '%s\n' ../nelisp.wt-mod-expt/target/nelisp; } || \
  { test -x ../nelisp/target/debug/nelisp && \
    printf '%s\n' ../nelisp/target/debug/nelisp; } || \
  printf '%s\n' nelisp)
NELISP_JSON_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-json/src/nelisp-json.el && \
    printf '%s\n' ../nelisp/packages/nelisp-json/src/nelisp-json.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-json/src/nelisp-json.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-json/src/nelisp-json.el; } || \
  printf '')
NELISP_TEXT_BUFFER_SRC ?= $(shell \
  { test -f ../nelisp/src/nelisp-text-buffer.el && \
    printf '%s\n' ../nelisp/src/nelisp-text-buffer.el; } || \
  { test -f ../nelisp.wt-mod-expt/src/nelisp-text-buffer.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/src/nelisp-text-buffer.el; } || \
  printf '')
NELISP_REGEX_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-regex/src/nelisp-regex.el && \
    printf '%s\n' ../nelisp/packages/nelisp-regex/src/nelisp-regex.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-regex/src/nelisp-regex.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-regex/src/nelisp-regex.el; } || \
  printf '')
NELISP_EMACS_COMPAT_SRC ?= $(shell \
  { test -f ../nelisp/src/nelisp-emacs-compat.el && \
    printf '%s\n' ../nelisp/src/nelisp-emacs-compat.el; } || \
  { test -f ../nelisp.wt-mod-expt/src/nelisp-emacs-compat.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/src/nelisp-emacs-compat.el; } || \
  printf '')
NELISP_ACTOR_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-actor/src/nelisp-actor.el && \
    printf '%s\n' ../nelisp/packages/nelisp-actor/src/nelisp-actor.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-actor/src/nelisp-actor.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-actor/src/nelisp-actor.el; } || \
  printf '')
NELISP_STDLIB_EVAL_SPECIAL_SRC ?= $(shell \
  { test -f ../nelisp/lisp/nelisp-stdlib-eval-special.el && \
    printf '%s\n' ../nelisp/lisp/nelisp-stdlib-eval-special.el; } || \
  { test -f ../nelisp.wt-mod-expt/lisp/nelisp-stdlib-eval-special.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/lisp/nelisp-stdlib-eval-special.el; } || \
  printf '')
NELISP_CL_MACROS_SRC ?= $(shell \
  { test -f ../nelisp/lisp/nelisp-cl-macros.el && \
    printf '%s\n' ../nelisp/lisp/nelisp-cl-macros.el; } || \
  { test -f ../nelisp.wt-mod-expt/lisp/nelisp-cl-macros.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/lisp/nelisp-cl-macros.el; } || \
  printf '')
NELISP_ERT_SHIM_SRC ?= scripts/anvil-pkg-nelisp-ert-shim.el
NELISP_PROCESS_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-process/src/nelisp-process.el && \
    printf '%s\n' ../nelisp/packages/nelisp-process/src/nelisp-process.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-process/src/nelisp-process.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-process/src/nelisp-process.el; } || \
  printf '')
NELISP_NETWORK_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-network/src/nelisp-network.el && \
    printf '%s\n' ../nelisp/packages/nelisp-network/src/nelisp-network.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-network/src/nelisp-network.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-network/src/nelisp-network.el; } || \
  printf '')
NELISP_HTTP_SRC ?= $(shell \
  { test -f ../nelisp/packages/nelisp-http/src/nelisp-http.el && \
    printf '%s\n' ../nelisp/packages/nelisp-http/src/nelisp-http.el; } || \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-http/src/nelisp-http.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-http/src/nelisp-http.el; } || \
  printf '')

NIX ?= $(shell command -v nix 2>/dev/null || \
  { test -x /nix/var/nix/profiles/default/bin/nix && \
    printf '%s\n' /nix/var/nix/profiles/default/bin/nix; } || \
  printf '%s\n' nix)
NIX_CONFIG ?= experimental-features = nix-command flakes
SMOKE_DIR ?= /tmp/anvil-pkg-smoke

# Examples whose source/cargo/vendor hashes are real (Phase 4-H).
# Format:  <example-file>:<nix-attr>
SMOKE_EVAL_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/rust-ripgrep.el:ripgrep \
  examples/python-black.el:black \
  examples/go-hugo.el:hugo

RENDER_EXAMPLES = $(sort $(wildcard examples/*.el))

# Subset of SMOKE_EVAL_PAIRS that are cheap enough to actually
# `nix build' on a developer machine (~5s + ~30s).  Rust / Go are
# excluded because cargo / go-mod cold pulls take 3-5min each.
SMOKE_BUILD_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/python-black.el:black

.PHONY: all check verify-local release-scope-audit release-scope-status release-scope-stage release-scope-stage-a release-scope-stage-b release-scope-stage-c release-scope-stage-d publication-local-gate publication-url-check publication-preflight publication-public-smoke deb-orig deb-source deb-source-lint deb-source-gate deb-build verify-deb-contents deb-lint deb-local-gate install-built-deb deb-release-gate deb-full-gate fix-debian-ownership apt-repo verify-apt-repo apt-repo-gate apt-sign-repo verify-signed-apt-repo apt-signed-repo-gate apt-publish-static verify-apt-public-tree apt-publication-preflight apt-http-smoke apt-http-gate apt-public-url-smoke fedora-source fedora-source-verify fedora-source-gate fedora-rpm-build fedora-rpm-lint fedora-repo fedora-publish-static verify-fedora-public-tree fedora-publication-preflight fedora-dnf-smoke fedora-local-gate fedora-container-gate fedora-public-url-smoke verify-user-manifest-dsl verify-installed-debian verify-installed-cli-gate verify-user-environment verify-user-init-migration autopkgtest-debian check-whitespace nix-check test compile compile-tests check-declare install install-elisp install-doc install-bin uninstall clean deb-clean distclean lint help smoke-render smoke-pairs-check smoke-eval-pairs-check smoke-build-pairs-check smoke-eval smoke-build smoke-nelisp smoke-nelix-nelisp smoke-nelix-cli-nelisp smoke-nelix-lock-plan-apply smoke-nelix-lock-plan-apply-nelisp smoke-nelix-native-cli smoke-nelix-aot-cache-cli smoke-nelix-aot-engine-nelisp smoke-nelix-aot-cache-fast-lane smoke-nelix-aot-artifact-nelisp smoke-nelix-aot-native-artifact-host smoke-nelix-cli-image-build smoke-nelix-cli-image smoke-nelisp-capabilities smoke-nelisp-suite-readiness smoke-nelisp-suite-loadability smoke-nelisp-suite smoke-nelisp-suite-image-build smoke-nelisp-suite-image smoke-nelisp-local smoke-clean

all: check

check: lint test smoke-pairs-check smoke-render smoke-nelix-native-cli smoke-nelix-aot-cache-cli

verify-local: check nix-check smoke-eval smoke-build smoke-nelisp-local check-whitespace

release-scope-audit:
	tools/nelix-release-scope-audit.sh

release-scope-status:
	tools/nelix-release-scope-stage.sh --status

release-scope-stage:
	tools/nelix-release-scope-stage.sh --dry-run

release-scope-stage-a:
	tools/nelix-release-scope-stage.sh --stage A

release-scope-stage-b:
	tools/nelix-release-scope-stage.sh --stage B

release-scope-stage-c:
	tools/nelix-release-scope-stage.sh --stage C

release-scope-stage-d:
	tools/nelix-release-scope-stage.sh --stage D

publication-local-gate: apt-http-gate fedora-source-gate

publication-url-check:
	packaging/verify-publication-urls.sh "$(APT_PUBLIC_URL)" "$(FEDORA_PUBLIC_URL)"

publication-preflight: publication-url-check apt-publication-preflight fedora-publication-preflight

publication-public-smoke: publication-url-check apt-public-url-smoke fedora-public-url-smoke

deb-orig: clean
	rm -f "$(DEB_ORIG)"
	tar -czf "$(DEB_ORIG)" \
	  --transform 's,^\.$$,nelix-$(DEB_UPSTREAM_VERSION),' \
	  --transform 's,^\./,nelix-$(DEB_UPSTREAM_VERSION)/,' \
	  --exclude-vcs \
	  --exclude='./.cache' \
	  --exclude='./.claude' \
	  --exclude='./.direnv' \
	  --exclude='./build' \
	  --exclude='./debian' \
	  --exclude='./dist' \
	  --exclude='./nelix-apt-public' \
	  --exclude='./nelix-apt-repo' \
	  --exclude='./nelix-apt-repo-gnupg-test' \
	  --exclude='./nelix-rpm-repo' \
	  --exclude='./nelix-rpmbuild' \
	  --exclude='./result' \
	  --exclude='./result-*' \
	  --exclude='*.elc' \
	  --exclude='*.log' \
	  .

deb-source: deb-orig
	dpkg-buildpackage -S -sa -us -uc

deb-source-lint:
	$(LINTIAN) "$(DEB_SOURCE_CHANGES)"

deb-source-gate: deb-source deb-source-lint

deb-build:
	dpkg-buildpackage -us -uc -b

verify-deb-contents:
	@test -f "$(DEB)" || { echo "missing Debian package: $(DEB)" >&2; exit 1; }
	sh -n debian/tests/load
	! grep -Eq '^Restrictions:.*(^|[[:space:],])superficial([[:space:],]|$$)' debian/tests/control
	grep -q 'sh /usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh' debian/tests/load
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/anvil-pkg.el | grep -q '"nelix/profile"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-debian.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-debian.sh | grep -Fq 'NELIX_USER_MANIFEST_LOCKED'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq 'nelix user manifest nelisp AOT read-only ok'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--runtime nelisp --json apply "$$manifest" --dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--runtime nelisp --json plan "$$manifest" --dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--runtime nelisp --json list'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--runtime nelisp --json lock-check "$$manifest"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--runtime nelisp --json upgrade-plan'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq '"fallback":":nelisp-aot-cache"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq 'NELIX_USER_MANIFEST_LOCKED'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq -- '--json apply "$$manifest" --locked --dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh | grep -Fq '"checked-by":":nelisp-aot-cache"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-aot-cache-gate.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-aot-cache-gate.sh | grep -Fq 'apply "$$manifest" --dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-aot-cache-gate.sh | grep -Fq '"status":"dry-run"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-user-environment.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-user-init-migration.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-init-migration.sh | grep -Fq 'my-nelix-audit is missing after init load'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-init-migration.sh | grep -Fq -- '--runtime nelisp --json list'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-user-init-migration.sh | grep -Fq -- '--runtime nelisp --json lock-check "$$manifest"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-extracted-nelix-debian.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/schema/nelix-lock-v2.schema.json'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/schema/nelix-lock-v2.schema.json | grep -Fq '"title": "Nelix lockfile schema v2"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-extracted-nelix-debian.sh | grep -Fq 'NELIX_USER_MANIFEST_LOCKED'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-publication-urls.sh'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/apt/verify-public-tree.sh | grep -Fq 'public APT Packages has stale elpa-nelix version'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/apt/verify-public-tree.sh | grep -Fq 'public APT payload native CLI gate is missing packaged ripgrep install smoke'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/apt/public-url-smoke.sh | grep -Fq 'public APT smoke downloaded stale elpa-nelix version'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/apt/public-url-smoke.sh | grep -Fq 'public APT smoke payload native CLI gate is missing packaged ripgrep install smoke'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/fedora/verify-public-tree.sh | grep -Fq 'public Fedora tree is missing expected-version RPM payload'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/fedora/verify-public-tree.sh | grep -Fq 'public Fedora emacs-nelix RPM is missing packaged registry recipe'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/fedora/public-url-smoke.sh | grep -Fq 'rpm -q --qf'
	test -x packaging/run-autopkgtest-debian.sh
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -q './usr/bin/nelix'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/bin/nelix | grep -q 'NELIX_NELISP_AOT:-auto'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/bin/nelix | grep -q 'NELIX_NELISP_AOT=0 to force the slower direct NeLisp path'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/bin/nelix | grep -q 'nelix_nelisp_validate_fast_lane'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/bin/nelix | grep -q 'command=apply-dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/bin/nelix | grep -q 'AOT lock-check failed'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -q './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'registry index ROOT OUTPUT'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'plan MANIFEST [--dry-run]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'lock-check MANIFEST'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'registry list [--system SYSTEM]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'native remove NAME [--profile PROFILE] [--system SYSTEM]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'native rollback [--profile PROFILE] [--generation GENERATION]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'schema [manifest-dsl-v1|lock-v2|all]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-cli.el | grep -Fq 'nelix-fast-validate-json'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-fast.el | grep -Fq '(defun nelix-fast-validate-json'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-registry.el | grep -Fq '(defun nelix-registry-list'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-registry.el | grep -Fq '(defun nelix-registry-write-index'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-store.el | grep -Fq '(defun nelix-store-write-entry-at'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-store.el | grep -Fq '(defun nelix-store--commit-entry-dir'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-builder.el | grep -Fq 'nelix-store--entry-temp-dir'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -q './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/nelix-aot-manifest-engine.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -q './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/anvil-pkg-nelisp-smoke.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -q './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/anvil-pkg-nelisp-ert-shim.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/ripgrep.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/git.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/curl.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/fd.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/jq.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -tf - | grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/tree.el'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'registry list --system x86_64-linux'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'packaged_install native install ripgrep'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'packaged-rg-ok --nelix-gate'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'native install fixture-archive --profile archive'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'fixture-archive-ok unpack'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'native install fixture-bad-hash --profile bad-hash'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'failed hash install created a profile generation'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'registry index "$$data/nelix/registry" "$$generated_index"'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'native remove fixture-extra'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh | grep -Fq 'apply "$$native_lock_manifest" --dry-run --locked'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'registry list [--system SYSTEM]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'packaged_registry'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'lock_check lock-check'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'plan "$$manifest" --dry-run'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'schema_manifest schema manifest-dsl-v1'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'native rollback [--profile PROFILE] [--generation GENERATION]'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh | grep -Fq 'locked_apply apply "$$manifest" --locked --allow-remove-count 1'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/README.org.gz | gzip -dc | grep -q 'make verify-user-environment'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/README.org.gz | gzip -dc | grep -q 'make verify-user-manifest-dsl'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/README.org.gz | gzip -dc | grep -q 'make verify-user-init-migration'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/README.org.gz | gzip -dc | grep -q ':nelisp-aot-cache'
	dpkg-deb --fsys-tarfile "$(DEB)" | tar -xO ./usr/share/doc/elpa-nelix/packaging/README.org.gz | gzip -dc | grep -q 'make publication-url-check'
	packaging/verify-extracted-nelix-debian.sh "$(DEB)" "$(DEB_VERSION)"

deb-lint:
	$(LINTIAN) "$(DEB)"

deb-local-gate: deb-build verify-deb-contents deb-lint

install-built-deb:
	@test -f "$(DEB)" || { echo "missing Debian package: $(DEB)" >&2; exit 1; }
	@if [ "$$(id -u)" = 0 ]; then \
	  $(APT) install -y --reinstall --no-install-recommends "$(DEB)"; \
	else \
	  $(SUDO) $(APT) install -y --reinstall --no-install-recommends "$(DEB)"; \
	fi

deb-release-gate: deb-local-gate install-built-deb verify-installed-debian verify-installed-cli-gate verify-user-environment

deb-full-gate:
	@test "$$(id -u)" != 0 || { echo "Do not run sudo make deb-full-gate; run: make deb-full-gate" >&2; exit 1; }
	$(MAKE) deb-release-gate
	$(MAKE) autopkgtest-debian

fix-debian-ownership:
	@if [ "$$(id -u)" = 0 ]; then \
	  chown -R "$${SUDO_USER:-root}:$$(id -gn "$${SUDO_USER:-root}" 2>/dev/null || printf '%s' "$${SUDO_USER:-root}")" debian; \
	else \
	  $(SUDO) chown -R "$$(id -un):$$(id -gn)" debian; \
	fi

apt-repo: deb-local-gate
	packaging/apt/make-repo.sh "$(DEB)" "$(APT_REPO_DIR)" "$(APT_SUITE)"

verify-apt-repo:
	packaging/apt/verify-repo.sh "$(APT_REPO_DIR)" "$(APT_SUITE)"

apt-repo-gate: apt-repo verify-apt-repo

apt-sign-repo: apt-repo
	packaging/apt/sign-repo.sh "$(APT_REPO_DIR)" "$(APT_SUITE)"

verify-signed-apt-repo:
	packaging/apt/verify-signed-repo.sh "$(APT_REPO_DIR)" "$(APT_SUITE)"

apt-signed-repo-gate: apt-repo
	@rm -rf "$(APT_TEST_GNUPGHOME)"
	@mkdir -p "$(APT_TEST_GNUPGHOME)"
	@chmod 700 "$(APT_TEST_GNUPGHOME)"
	@GNUPGHOME="$(APT_TEST_GNUPGHOME)" gpg --batch --passphrase '' \
	  --quick-generate-key "Nelix APT Test <nelix@example.invalid>" default default never >/dev/null 2>&1
	@keyid=$$(GNUPGHOME="$(APT_TEST_GNUPGHOME)" gpg --batch --list-secret-keys --with-colons | awk -F: '$$1 == "fpr" { print $$10; exit }'); \
	  GNUPGHOME="$(APT_TEST_GNUPGHOME)" packaging/apt/sign-repo.sh "$(APT_REPO_DIR)" "$(APT_SUITE)" "$$keyid"; \
	  packaging/apt/verify-signed-repo.sh "$(APT_REPO_DIR)" "$(APT_SUITE)" "$(APT_REPO_DIR)/nelix-archive-keyring.gpg"

apt-publish-static: apt-signed-repo-gate
	packaging/apt/publish-static.sh "$(APT_REPO_DIR)" "$(APT_PUBLISH_DIR)" "$(APT_PUBLIC_URL)" "$(APT_SUITE)"

verify-apt-public-tree:
	packaging/apt/verify-public-tree.sh "$(APT_PUBLISH_DIR)" "$(APT_PUBLIC_URL)" "$(APT_SUITE)" "$(DEB_VERSION)"

apt-publication-preflight: apt-publish-static verify-apt-public-tree

apt-http-smoke:
	packaging/apt/serve-and-smoke.sh "$(APT_PUBLISH_DIR)" "$(APT_SUITE)" "$(DEB_VERSION)"

apt-http-gate: apt-publish-static apt-http-smoke

apt-public-url-smoke:
	packaging/apt/public-url-smoke.sh "$(APT_PUBLIC_URL)" "$(APT_SUITE)" "$(DEB_VERSION)"

fedora-source:
	packaging/fedora/make-source.sh "$(FEDORA_VERSION)" "$(FEDORA_TOPDIR)/SOURCES/nelix-$(FEDORA_VERSION).tar.gz"

fedora-source-verify:
	packaging/fedora/verify-source.sh "$(FEDORA_TOPDIR)/SOURCES/nelix-$(FEDORA_VERSION).tar.gz" "$(FEDORA_VERSION)"

fedora-source-gate: fedora-source fedora-source-verify

fedora-rpm-build:
	packaging/fedora/build-rpm.sh "$(FEDORA_TOPDIR)" "$(FEDORA_VERSION)" packaging/fedora/nelix.spec

fedora-rpm-lint:
	packaging/fedora/rpmlint.sh "$(FEDORA_TOPDIR)" packaging/fedora/nelix.spec

fedora-repo: fedora-rpm-build
	packaging/fedora/make-repo.sh "$(FEDORA_TOPDIR)" "$(FEDORA_REPO_DIR)"

fedora-publish-static: fedora-repo
	packaging/fedora/publish-static.sh "$(FEDORA_REPO_DIR)" "$(FEDORA_PUBLISH_DIR)" "$(FEDORA_PUBLIC_URL)"

verify-fedora-public-tree:
	packaging/fedora/verify-public-tree.sh "$(FEDORA_PUBLISH_DIR)" "$(FEDORA_PUBLIC_URL)" "$(FEDORA_VERSION)"

fedora-publication-preflight: fedora-publish-static verify-fedora-public-tree

fedora-dnf-smoke:
	packaging/fedora/dnf-smoke.sh "$(FEDORA_REPO_DIR)" "$(FEDORA_VERSION)"

fedora-local-gate: fedora-rpm-build fedora-rpm-lint fedora-repo fedora-dnf-smoke

fedora-container-gate:
	packaging/fedora/container-gate.sh "$(FEDORA_IMAGE)"

fedora-public-url-smoke:
	packaging/fedora/public-url-smoke.sh "$(FEDORA_PUBLIC_URL)" "$(FEDORA_VERSION)"

verify-user-manifest-dsl:
	packaging/verify-nelix-user-manifest-dsl.sh

verify-installed-debian:
	packaging/verify-installed-nelix-debian.sh

verify-installed-cli-gate:
	packaging/verify-installed-nelix-cli-gate.sh

verify-user-environment:
	packaging/verify-nelix-user-environment.sh

verify-user-init-migration:
	packaging/verify-nelix-user-init-migration.sh

autopkgtest-debian:
	@test -f "$(DEB)" || { echo "missing Debian package: $(DEB)" >&2; exit 1; }
	AUTOPKGTEST="$(AUTOPKGTEST)" SUDO="$(SUDO)" packaging/run-autopkgtest-debian.sh "$(DEB)" .

help:
	@echo "make check        — run local no-Nix gate: lint + test + smoke metadata + render"
	@echo "make verify-local — run full local gate: check + repository flake + real Nix + NeLisp + whitespace"
	@echo "make release-scope-audit — dry-run git staging groups and verify ignored build outputs"
	@echo "make release-scope-status — show changed paths grouped by planned Nelix release commit"
	@echo "make release-scope-stage — preview git add groups for the Nelix release scope"
	@echo "make release-scope-stage-a — stage Commit A compatibility rename and shared tests"
	@echo "make release-scope-stage-b — stage Commit B Nelix manifest CLI and native store"
	@echo "make release-scope-stage-c — stage Commit C design docs"
	@echo "make release-scope-stage-d — stage Commit D Debian and repository publication"
	@echo "make publication-local-gate — run local APT HTTP publication smoke and Fedora source gate"
	@echo "make publication-url-check — reject placeholder or insecure public repository URLs"
	@echo "make publication-preflight — verify APT/Fedora static publication trees for real public URLs"
	@echo "make publication-public-smoke — verify published APT/Fedora URLs after upload"
	@echo "make deb-orig     — build $(DEB_ORIG) from the current upstream source tree"
	@echo "make deb-source   — build Debian source package $(DEB_SOURCE_CHANGES)"
	@echo "make deb-source-gate — build and lint the Debian source package"
	@echo "make deb-build    — build ../elpa-nelix_$(DEB_VERSION)_all.deb"
	@echo "make verify-deb-contents — inspect $(DEB) for Nelix Debian payload expectations"
	@echo "make deb-lint     — run lintian against $(DEB)"
	@echo "make deb-local-gate — build $(DEB), inspect contents, and run lintian"
	@echo "make install-built-deb — install freshly built $(DEB) with apt"
	@echo "make deb-release-gate — build, install, and run installed/user Debian gates"
	@echo "make deb-full-gate — run deb-release-gate + sudo autopkgtest Debian gate"
	@echo "make fix-debian-ownership — recover debian/ after accidental sudo make"
	@echo "make smoke-nelix-aot-engine-nelisp — verify portable Nelix AOT engine under standalone NeLisp"
	@echo "make smoke-nelix-aot-cache-cli — verify bin/nelix AOT cache CLI gate with fake nix/nelisp"
	@echo "make smoke-nelix-aot-cache-fast-lane — verify bin/nelix AOT cache fast lane with fake nix"
	@echo "make smoke-nelix-aot-artifact-nelisp — verify Nelix AOT engine through nelisp artifact CLI"
	@echo "make smoke-nelix-cli-image-build — build a NeLisp runtime-image probe at $(NELIX_CLI_IMAGE)"
	@echo "make smoke-nelix-cli-image — verify explicit NeLisp runtime-image CLI mode"
	@echo "make smoke-nelix-lock-plan-apply-nelisp — verify lock/plan/apply/rollback through standalone NeLisp"
	@echo "make smoke-nelix-native-cli — verify native store CLI install/list/profile/activate/gc with fixture registry"
	@echo "make apt-repo     — build a local APT repository at $(APT_REPO_DIR)"
	@echo "make verify-apt-repo — inspect generated APT repository metadata"
	@echo "make apt-repo-gate — run deb-local-gate + apt-repo + verify-apt-repo"
	@echo "make apt-sign-repo — sign $(APT_REPO_DIR) using the default GPG key or NELIX_APT_GPG_KEYID"
	@echo "make verify-signed-apt-repo — verify InRelease/Release.gpg for $(APT_REPO_DIR)"
	@echo "make apt-signed-repo-gate — generate local APT repo, sign with a temp key, and verify signatures"
	@echo "make apt-publish-static — copy a signed, sanitized APT repository to $(APT_PUBLISH_DIR)"
	@echo "make apt-publication-preflight — verify static APT tree for real APT_PUBLIC_URL=$(APT_PUBLIC_URL)"
	@echo "make apt-http-smoke — serve $(APT_PUBLISH_DIR) over local HTTP and verify apt can fetch elpa-nelix"
	@echo "make apt-http-gate — sign, publish static files, and run local HTTP apt smoke"
	@echo "make apt-public-url-smoke — verify apt can fetch elpa-nelix from APT_PUBLIC_URL=$(APT_PUBLIC_URL)"
	@echo "make fedora-source-gate — build and verify the Fedora source tarball"
	@echo "make fedora-rpm-build — build Fedora RPMs under $(FEDORA_TOPDIR)"
	@echo "make fedora-rpm-lint — run rpmlint against the Fedora spec and built RPMs"
	@echo "make fedora-repo — create a local dnf repository at $(FEDORA_REPO_DIR)"
	@echo "make fedora-publication-preflight — verify static Fedora tree for real FEDORA_PUBLIC_URL=$(FEDORA_PUBLIC_URL)"
	@echo "make fedora-dnf-smoke — install nelix/emacs-nelix from $(FEDORA_REPO_DIR) with dnf"
	@echo "make fedora-local-gate — run Fedora RPM build, lint, repository, and dnf smoke on Fedora"
	@echo "make fedora-container-gate — run fedora-local-gate inside $(FEDORA_IMAGE)"
	@echo "make fedora-public-url-smoke — install nelix/emacs-nelix from FEDORA_PUBLIC_URL=$(FEDORA_PUBLIC_URL)"
	@echo "make verify-user-manifest-dsl — verify ~/.emacs.d/nelix-package.el DSL v1 from the source tree"
	@echo "make verify-installed-debian — verify the installed elpa-nelix Debian package"
	@echo "make verify-installed-cli-gate — verify installed /usr/bin/nelix lock/plan/apply"
	@echo "make verify-user-environment — verify installed Debian package + personal Nelix config"
	@echo "make verify-user-init-migration — load personal early-init/init and run my-nelix-audit"
	@echo "make autopkgtest-debian — run autopkgtest against $(DEB) using sudo when needed"
	@echo "make nix-check    — run top-level 'nix flake check'"
	@echo "make test         — run ERT suite (no nix required, mocked)"
	@echo "make compile      — byte-compile runtime source/scripts, warnings-as-errors"
	@echo "make compile-tests — byte-compile $(TEST_SRC), warnings-as-errors"
	@echo "make check-declare — run check-declare over source/scripts/tests"
	@echo "make lint         — byte-compile source/scripts/tests + check-declare"
	@echo "make install      — install Nelix Elisp sources and docs under DESTDIR"
	@echo "                  bindir=$(bindir)"
	@echo "                  lispdir=$(lispdir)"
	@echo "                  docdir=$(docdir)"
	@echo "make uninstall    — remove files installed by make install"
	@echo "make clean        — remove .elc files"
	@echo "make deb-clean    — remove Debian build tree metadata"
	@echo "make distclean    — remove local build/cache/package repository outputs"
	@echo "make smoke-render — render every example to flake.nix (no nix required)"
	@echo "make smoke-pairs-check — validate smoke example pair lists (no nix required)"
	@echo "make smoke-eval   — render examples + 'nix flake check --no-build' (CI)"
	@echo "make smoke-build  — actually 'nix build' the cheap examples (local)"
	@echo "make smoke-nelisp — load compat layer with a local NeLisp binary"
	@echo "make smoke-nelix-nelisp — load Nelix public entry points with standalone NeLisp"
	@echo "make smoke-nelix-cli-nelisp — run bin/nelix through standalone NeLisp direct mode"
	@echo "make smoke-nelisp-capabilities — print local standalone NeLisp backend capabilities"
	@echo "make smoke-nelisp-suite-readiness — audit whether standalone NeLisp can run the full suite"
	@echo "make smoke-nelisp-suite-loadability — load each ERT file under standalone NeLisp"
	@echo "make smoke-nelisp-suite — run standalone-executable suite under standalone NeLisp"
	@echo "make smoke-nelisp-suite-image — run standalone suite through $(NELISP_SUITE_IMAGE)"
	@echo "make smoke-nelisp-local — run all local NeLisp smoke gates"
	@echo "                  NIX=$(NIX)"
	@echo "                  NIX_CONFIG='$(NIX_CONFIG)'"
	@echo "                  NELISP=$(NELISP)"
	@echo "                  NELISP_JSON_SRC=$(NELISP_JSON_SRC)"
	@echo "                  NELISP_STDLIB_EVAL_SPECIAL_SRC=$(NELISP_STDLIB_EVAL_SPECIAL_SRC)"
	@echo "                  NELISP_CL_MACROS_SRC=$(NELISP_CL_MACROS_SRC)"
	@echo "                  NELISP_ERT_SHIM_SRC=$(NELISP_ERT_SHIM_SRC)"
	@echo "                  NELISP_HTTP_SRC=$(NELISP_HTTP_SRC)"
	@echo "make smoke-clean  — rm -rf $(SMOKE_DIR)"

check-whitespace:
	git diff --check

nix-check:
	NIX_CONFIG="$(NIX_CONFIG)" $(NIX) flake check

test:
	$(EMACS_BATCH) -l ert \
	  $(foreach f,$(TEST_SRC),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC) $(SCRIPT_SRC)

compile-tests:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(TEST_SRC)

check-declare:
	$(EMACS_BATCH) \
	  $(foreach f,$(SRC),-l $(f)) \
	  $(foreach f,$(SCRIPT_SRC),-l $(f)) \
	  $(foreach f,$(SRC) $(SCRIPT_SRC) $(TEST_SRC),--eval "(check-declare-file \"$(f)\")")

lint: compile compile-tests check-declare

install: install-elisp install-doc install-bin

install-elisp:
	$(INSTALL_DIR) "$(DESTDIR)$(lispdir)"
	@for f in $(SRC) $(PKG_METADATA); do \
	  $(INSTALL_DATA) "$$f" "$(DESTDIR)$(lispdir)/$$f"; \
	done
	$(INSTALL_DIR) "$(DESTDIR)$(lispdir)/scripts"
	@for f in $(SCRIPT_SRC); do \
	  $(INSTALL_DATA) "$$f" "$(DESTDIR)$(lispdir)/$$f"; \
	done
	@for f in $(REGISTRY_SRC); do \
	  $(INSTALL_DIR) "$(DESTDIR)$(lispdir)/$$(dirname "$$f")"; \
	  $(INSTALL_DATA) "$$f" "$(DESTDIR)$(lispdir)/$$f"; \
	done

install-doc:
	$(INSTALL_DIR) "$(DESTDIR)$(docdir)"
	@for f in $(DOC_SRC) LICENSE; do \
	  if test -f "$$f"; then \
	    case "$$f" in */*) base=$$(printf '%s\n' "$$f" | tr / -) ;; *) base=$$(basename "$$f") ;; esac; \
	    $(INSTALL_DATA) "$$f" "$(DESTDIR)$(docdir)/$$base"; \
	  fi; \
	done

install-bin:
	$(INSTALL_DIR) "$(DESTDIR)$(bindir)"
	@for f in $(BIN_SRC); do \
	  $(INSTALL_PROGRAM) "$$f" "$(DESTDIR)$(bindir)/$$(basename "$$f")"; \
	done

uninstall:
	@for f in $(SRC) $(PKG_METADATA); do \
	  $(RM) "$(DESTDIR)$(lispdir)/$$f"; \
	done
	@for f in $(SCRIPT_SRC); do \
	  $(RM) "$(DESTDIR)$(lispdir)/$$f"; \
	done
	@for f in $(REGISTRY_SRC); do \
	  $(RM) "$(DESTDIR)$(lispdir)/$$f"; \
	done
	@for f in $(BIN_SRC); do \
	  $(RM) "$(DESTDIR)$(bindir)/$$(basename "$$f")"; \
	done
	@for f in $(DOC_SRC) LICENSE; do \
	  case "$$f" in */*) base=$$(printf '%s\n' "$$f" | tr / -) ;; *) base=$$(basename "$$f") ;; esac; \
	  $(RM) "$(DESTDIR)$(docdir)/$$base"; \
	done

clean:
	rm -f *.elc test/*.elc scripts/*.elc

deb-clean:
	rm -rf debian/.debhelper debian/elpa-nelix
	rm -f debian/debhelper-build-stamp debian/files debian/*.substvars debian/*.debhelper

distclean: clean smoke-clean deb-clean
	rm -rf "$(APT_REPO_DIR)" "$(APT_TEST_GNUPGHOME)" "$(APT_PUBLISH_DIR)"
	rm -rf "$(FEDORA_TOPDIR)" "$(FEDORA_REPO_DIR)"
	rm -f "$(DEB)" "$(DEB_ORIG)" "$(DEB_SOURCE_CHANGES)"
	rm -f ../nelix_$(DEB_VERSION).debian.tar.* ../nelix_$(DEB_VERSION).dsc
	rm -f ../nelix_$(DEB_VERSION)_*.buildinfo ../nelix_$(DEB_VERSION)_*.changes

smoke-clean:
	rm -rf $(SMOKE_DIR)
	rm -rf "$(NELISP_CACHE_DIR)"

# Render every examples/*.el recipe without invoking Nix.  This is the
# lightweight local check for example/DSL drift; `smoke-eval' adds the
# real Nix evaluator on top for the four real-hash examples.
smoke-render:
	@test -n "$(RENDER_EXAMPLES)" || { \
	  echo "error: no examples/*.el files found"; \
	  exit 1; \
	}
	@for ex in $(RENDER_EXAMPLES); do \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-render $$ex"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  test -s "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix was not written"; \
	    exit 1; \
	  }; \
	  grep -Fq "outputs = { self, nixpkgs }:" "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix does not look like an anvil-pkg flake"; \
	    exit 1; \
	  }; \
	  grep -Fq "packages.x86_64-linux" "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix does not expose packages for system"; \
	    exit 1; \
	  }; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-render: all $(words $(RENDER_EXAMPLES)) examples rendered"

smoke-pairs-check: smoke-eval-pairs-check smoke-build-pairs-check
	@echo "smoke-pairs-check: example pair lists are valid"

smoke-eval-pairs-check:
	@test -n "$(strip $(SMOKE_EVAL_PAIRS))" || { \
	  echo "error: no smoke-eval example pairs configured"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_EVAL_PAIRS); do \
	  case "$$pair" in \
	    *:*:*) echo "error: smoke-eval pair '$$pair' must contain exactly one ':'"; exit 1 ;; \
	    *:*) ;; \
	    *) echo "error: smoke-eval pair '$$pair' must use <example-file>:<nix-attr>"; exit 1 ;; \
	  esac; \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  test -n "$$ex" || { \
	    echo "error: smoke-eval pair '$$pair' has an empty example file"; \
	    exit 1; \
	  }; \
	  test -n "$$attr" || { \
	    echo "error: smoke-eval pair '$$pair' has an empty nix attr"; \
	    exit 1; \
	  }; \
	  test -f "$$ex" || { \
	    echo "error: smoke-eval pair '$$pair' references missing example file"; \
	    exit 1; \
	  }; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/pair-check/eval/$$name; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example-attr-batch \"$$ex\" \"$$attr\" \"$$out\")" \
	    || exit 1; \
	done

smoke-build-pairs-check:
	@test -n "$(strip $(SMOKE_BUILD_PAIRS))" || { \
	  echo "error: no smoke-build example pairs configured"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_BUILD_PAIRS); do \
	  case "$$pair" in \
	    *:*:*) echo "error: smoke-build pair '$$pair' must contain exactly one ':'"; exit 1 ;; \
	    *:*) ;; \
	    *) echo "error: smoke-build pair '$$pair' must use <example-file>:<nix-attr>"; exit 1 ;; \
	  esac; \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  test -n "$$ex" || { \
	    echo "error: smoke-build pair '$$pair' has an empty example file"; \
	    exit 1; \
	  }; \
	  test -n "$$attr" || { \
	    echo "error: smoke-build pair '$$pair' has an empty nix attr"; \
	    exit 1; \
	  }; \
	  test -f "$$ex" || { \
	    echo "error: smoke-build pair '$$pair' references missing example file"; \
	    exit 1; \
	  }; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/pair-check/build/$$name; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example-attr-batch \"$$ex\" \"$$attr\" \"$$out\")" \
	    || exit 1; \
	done

# Render each example to $(SMOKE_DIR)/<basename>/flake.nix, then run
# `nix flake check --no-build' to validate the renderer's output
# against a real Nix evaluator without paying for source fetches.
smoke-eval: smoke-eval-pairs-check
	@command -v $(NIX) >/dev/null 2>&1 || { \
	  echo "error: $(NIX) not on PATH (Phase 4-H needs Nix to smoke-test)"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_EVAL_PAIRS); do \
	  ex=$${pair%:*}; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-eval $$ex"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  NIX_CONFIG="$(NIX_CONFIG)" $(NIX) flake check --no-build "path:$$out" || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-eval: all $(words $(SMOKE_EVAL_PAIRS)) examples passed"

# Actually realise the cheap subset.  Local-only by default.
smoke-build: smoke-build-pairs-check
	@command -v $(NIX) >/dev/null 2>&1 || { \
	  echo "error: $(NIX) not on PATH"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_BUILD_PAIRS); do \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-build $$ex#$$attr"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  NIX_CONFIG="$(NIX_CONFIG)" $(NIX) build "path:$$out#$$attr" --no-link --print-out-paths || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-build: all $(words $(SMOKE_BUILD_PAIRS)) examples built"

# Narrow standalone-runtime smoke.  Current NeLisp CLI does not expose
# the full Emacs batch interface or complete file/env helpers, so this
# target proves only that the compat layer loads and the narrow helper
# surface available to this standalone image evaluates.  When local
# nelisp-json / nelisp-emacs-compat source files are available, it also
# proves compat dispatch through those real package-split backends.
# Native process / HTTP source probing lives in
# `smoke-nelisp-capabilities' because loading those definitions can
# expose functions before this standalone image has the lower runtime
# primitives needed to execute them.
smoke-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-text-buffer-source "$(NELISP_TEXT_BUFFER_SRC)") (setq anvil-pkg-nelisp-smoke-regex-source "$(NELISP_REGEX_SRC)") (setq anvil-pkg-nelisp-smoke-emacs-compat-source "$(NELISP_EMACS_COMPAT_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (load "anvil-pkg-compat.el") (list :smoke-ok (and (fboundp (quote anvil-pkg-compat-runtime)) (memq (anvil-pkg-compat-runtime) (quote (emacs nelisp))) (equal (anvil-pkg-compat-string-trim " ok ") "ok") (equal (anvil-pkg-compat-string-trim nil) "") (fboundp (quote anvil-pkg-compat-json-parse)) (fboundp (quote anvil-pkg-compat-json-serialize)) (anvil-pkg-nelisp-smoke--json-backend-ok-p) (anvil-pkg-nelisp-smoke--buffer-backend-ok-p) (anvil-pkg-nelisp-smoke--unsupported-branches-ok-p) (anvil-pkg-nelisp-smoke--explicit-hooks-ok-p))))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":smoke-ok t" || { \
	    echo "error: smoke-nelisp did not report :smoke-ok t"; \
	    exit 1; \
	  }
	@echo "smoke-nelisp: compat layer loaded under $(NELISP)"

smoke-nelix-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-public-entrypoints))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":nelix-load t" || { \
	    echo "error: smoke-nelix-nelisp could not load Nelix public entry points"; \
	    exit 1; \
	  }
	@echo "smoke-nelix-nelisp: public Nelix entry points loaded under $(NELISP)"

smoke-nelix-cli-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$(NELISP="$(NELISP)" NELIX_RUNTIME=nelisp bin/nelix --json version); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q '"status":"ok"' || { \
	    echo "error: bin/nelix did not report ok status through standalone NeLisp"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q '"version":"0.1.0"' || { \
	    echo "error: bin/nelix did not report expected version through standalone NeLisp"; \
	    exit 1; \
	  }
	@echo "smoke-nelix-cli-nelisp: bin/nelix direct mode ran under $(NELISP)"

smoke-nelix-lock-plan-apply:
	tools/nelix-lock-plan-apply-gate.sh

smoke-nelix-lock-plan-apply-nelisp:
	NELIX_RUNTIME=nelisp NELIX_NELISP_AOT=0 tools/nelix-lock-plan-apply-gate.sh

smoke-nelix-native-cli:
	NELIX_BIN="$(CURDIR)/bin/nelix" NELIX_LISPDIR="$(CURDIR)" packaging/verify-nelix-native-cli-gate.sh

smoke-nelix-aot-cache-cli:
	NELIX_BIN="$(CURDIR)/bin/nelix" NELIX_LISPDIR="$(CURDIR)" packaging/verify-nelix-aot-cache-gate.sh

smoke-nelix-aot-engine-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (load "scripts/nelix-aot-manifest-engine.el") (nelix-aot-audit "NELIX-AOT-MANIFEST-V1\nmanifest\t/tmp/manifest.el\nprofile\tdefault\nsystem\tx86_64-linux\ntarget\tmagit\tmagit\ntarget\tripgrep\tripgrep\npin\tripgrep\ninstalled\tmagit\ninstalled\tripgrep-1\ninstalled\tbat\nend\n"))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ':present ("magit" "ripgrep-1")' || { \
	    echo "error: Nelix AOT engine did not report expected present names under standalone NeLisp"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q ':extra ("bat")' || { \
	    echo "error: Nelix AOT engine did not report expected extra names under standalone NeLisp"; \
	    exit 1; \
	  }
	@id_out=$$("$(NELISP)" --eval '(progn (load "scripts/nelix-aot-manifest-engine.el") (nelix-aot-upgrade-plan "NELIX-AOT-MANIFEST-V1\nmanifest\t/tmp/manifest.el\nprofile\tdefault\nsystem\tx86_64-linux\nname-id\t1\tmagit\nname-id\t2\tripgrep\nname-id\t3\tfd\ntarget-id\t1\t1\ntarget-id\t2\t2\ntarget-id\t3\t3\npin-id\t2\ninstalled\tmagit\ninstalled-id\t1\ninstalled\tripgrep-1\ninstalled-id\t2\ninstalled\tbat\nend\n"))'); \
	  printf '%s\n' "$$id_out"; \
	  printf '%s\n' "$$id_out" | grep -q ':upgrade ("magit")' || { \
	    echo "error: Nelix AOT ID engine did not report expected upgrade names under standalone NeLisp"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$id_out" | grep -q ':pinned ("ripgrep-1")' || { \
	    echo "error: Nelix AOT ID engine did not report expected pinned names under standalone NeLisp"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$id_out" | grep -q ':missing ("fd")' || { \
	    echo "error: Nelix AOT ID engine did not report expected missing names under standalone NeLisp"; \
	    exit 1; \
	  }
	@echo "smoke-nelix-aot-engine-nelisp: portable AOT engine ran under $(NELISP)"

smoke-nelix-aot-cache-fast-lane:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@tmp=$$(mktemp -d); \
	  manifest="$$tmp/manifest.el"; \
	  cache="$$manifest.nelix-aot-targets"; \
	  fake_nix="$$tmp/nix"; \
	  fake_nelisp="$$tmp/nelisp"; \
	  profile="$$tmp/profile"; \
	  : > "$$manifest"; \
	  printf '%s\n' \
	    'NELIX-AOT-MANIFEST-V1' \
	    "manifest	$$manifest" \
	    "source-file	$$manifest" \
	    "profile	$$profile" \
	    'system	x86_64-linux' \
	    'target	magit	magit' \
	    'target	ripgrep	ripgrep' \
	    'target	fd	fd' \
	    'pin	ripgrep' \
	    'name-id	1	magit' \
	    'name-id	2	ripgrep' \
	    'name-id	3	fd' \
	    'target-id	1	1' \
	    'target-id	2	2' \
	    'target-id	3	3' \
	    'pin-id	2' \
	    > "$$cache"; \
	  manifest_digest=sha256-$$(sha256sum "$$manifest" | awk '{ print $$1 }'); \
	  printf '%s\n' \
	    ';;; manifest.el.nelix-lock --- generated Nelix lock file -*- lexical-binding: t; -*-' \
	    '(require (quote nelix-manifest))' \
	    '(nelix-lock' \
	    ' :schema "nelix-lock"' \
	    ' :schema-version 2' \
	    ' :version 2' \
	    " :format 'sexp" \
	    " :lock \"$$manifest.nelix-lock\"" \
	    " :manifest-digest \"$$manifest_digest\"" \
	    " :manifest-files '((:role manifest :path \"$$manifest\" :digest \"$$manifest_digest\"))" \
	    " :profile \"$$profile\"" \
	    " :backend 'nix" \
	    " :system 'x86_64-linux" \
	    ' :nix-channel "nixpkgs"' \
	    ' :packages ((:name "magit" :target magit :resolved-target magit :backend nix :system x86_64-linux)' \
	    '            (:name "ripgrep" :target ripgrep :resolved-target ripgrep :backend nix :system x86_64-linux)' \
	    '            (:name "fd" :target fd :resolved-target fd :backend nix :system x86_64-linux)))' \
	    > "$$manifest.nelix-lock"; \
	  printf '%s\n' \
	    '#!/bin/sh' \
	    "printf 'Name: magit\nName: ripgrep-1\nName: bat\n'" \
	    > "$$fake_nix"; \
	  chmod +x "$$fake_nix"; \
	  printf '%s\n' \
	    '#!/bin/sh' \
	    'echo "error: fallback nelisp engine should not run" >&2' \
	    'exit 77' \
	    > "$$fake_nelisp"; \
	  chmod +x "$$fake_nelisp"; \
	  common_env="NELIX_LISPDIR=$(CURDIR) NELIX_RUNTIME=nelisp NELIX_NELISP_AOT=1 NELIX_NIX_PROGRAM=$$fake_nix NELIX_PROFILE_DIR=$$profile NELISP=$$fake_nelisp NELISP_ROOT=$(NELISP_REPO)"; \
	  cache_cmd_manifest="$$tmp/cache-command-manifest.el"; \
	  printf '%s\n' \
	    '(require (quote nelix-manifest))' \
	    '(nelix-manifest :name "default" :emacs (quote (magit)) :linux (quote ("ripgrep")))' \
	    > "$$cache_cmd_manifest"; \
	  cache_cmd_out=$$(env $$common_env bin/nelix --runtime nelisp aot-cache "$$cache_cmd_manifest"); \
	  printf '%s\n' "$$cache_cmd_out"; \
	  test -f "$$cache_cmd_manifest.nelix-aot-targets" || { echo "error: --runtime nelisp aot-cache did not create cache"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$cache_cmd_out" | grep -q ':status ok' || { echo "error: --runtime nelisp aot-cache did not report ok"; rm -rf "$$tmp"; exit 1; }; \
	  audit_out=$$(env $$common_env bin/nelix audit "$$manifest"); \
	  printf '%s\n' "$$audit_out"; \
	  printf '%s\n' "$$audit_out" | grep -q '^present	magit$$' || { echo "error: AOT cache fast-lane audit missing magit"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$audit_out" | grep -q '^present	ripgrep-1$$' || { echo "error: AOT cache fast-lane audit missing ripgrep-1"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$audit_out" | grep -q '^missing	fd$$' || { echo "error: AOT cache fast-lane audit missing fd"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$audit_out" | grep -q '^extra	bat$$' || { echo "error: AOT cache fast-lane audit missing bat extra"; rm -rf "$$tmp"; exit 1; }; \
	  apply_dry_run_out=$$(env $$common_env bin/nelix apply "$$manifest" --dry-run); \
	  printf '%s\n' "$$apply_dry_run_out"; \
	  printf '%s\n' "$$apply_dry_run_out" | grep -q '^status	dry-run$$' || { echo "error: AOT cache fast-lane apply dry-run did not report dry-run"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_out" | grep -q '^install	fd$$' || { echo "error: AOT cache fast-lane apply dry-run missing fd install"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_out" | grep -q '^remove	bat$$' || { echo "error: AOT cache fast-lane apply dry-run missing bat remove"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_out" | grep -q '^fallback	:nelisp-aot-cache$$' || { echo "error: AOT cache fast-lane apply dry-run did not use cache"; rm -rf "$$tmp"; exit 1; }; \
	  plan_out=$$(env $$common_env bin/nelix upgrade-plan "$$manifest"); \
	  printf '%s\n' "$$plan_out"; \
	  printf '%s\n' "$$plan_out" | grep -q '^upgrade	magit$$' || { echo "error: AOT cache fast-lane upgrade-plan missing magit"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$plan_out" | grep -q '^pinned	ripgrep-1$$' || { echo "error: AOT cache fast-lane upgrade-plan missing pinned ripgrep-1"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$plan_out" | grep -q '^missing	fd$$' || { echo "error: AOT cache fast-lane upgrade-plan missing fd"; rm -rf "$$tmp"; exit 1; }; \
	  audit_json=$$(env $$common_env bin/nelix --json audit "$$manifest"); \
	  printf '%s\n' "$$audit_json"; \
	  printf '%s\n' "$$audit_json" | grep -q '"present":\["magit","ripgrep-1"\]' || { echo "error: AOT cache fast-lane JSON audit missing present names"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$audit_json" | grep -q '"extra":\["bat"\]' || { echo "error: AOT cache fast-lane JSON audit missing extra bat"; rm -rf "$$tmp"; exit 1; }; \
	  apply_dry_run_json=$$(env $$common_env bin/nelix --json apply "$$manifest" --dry-run); \
	  printf '%s\n' "$$apply_dry_run_json"; \
	  printf '%s\n' "$$apply_dry_run_json" | grep -q '"status":"dry-run"' || { echo "error: AOT cache fast-lane JSON apply dry-run did not report dry-run"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_json" | grep -q '"action":"install","name":"fd"' || { echo "error: AOT cache fast-lane JSON apply dry-run missing fd install"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_json" | grep -q '"action":"remove","name":"bat"' || { echo "error: AOT cache fast-lane JSON apply dry-run missing bat remove"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$apply_dry_run_json" | grep -q '"fallback":":nelisp-aot-cache"' || { echo "error: AOT cache fast-lane JSON apply dry-run did not use cache"; rm -rf "$$tmp"; exit 1; }; \
	  locked_apply_dry_run_json=$$(env $$common_env bin/nelix --json apply "$$manifest" --locked --dry-run); \
	  printf '%s\n' "$$locked_apply_dry_run_json"; \
	  printf '%s\n' "$$locked_apply_dry_run_json" | grep -q '"status":"dry-run"' || { echo "error: AOT cache fast-lane locked apply dry-run did not report dry-run"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$locked_apply_dry_run_json" | grep -q '"locked":true' || { echo "error: AOT cache fast-lane locked apply dry-run did not report locked"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$locked_apply_dry_run_json" | grep -q '"lock-enforced":true' || { echo "error: AOT cache fast-lane locked apply dry-run did not enforce lock"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$locked_apply_dry_run_json" | grep -q '"checked-by":":nelisp-aot-cache"' || { echo "error: AOT cache fast-lane locked apply dry-run did not use AOT lock check"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$locked_apply_dry_run_json" | grep -q '"fallback":":nelisp-aot-cache"' || { echo "error: AOT cache fast-lane locked apply dry-run did not use cache"; rm -rf "$$tmp"; exit 1; }; \
	  lock_check_json=$$(env $$common_env bin/nelix --json lock-check "$$manifest"); \
	  printf '%s\n' "$$lock_check_json"; \
	  printf '%s\n' "$$lock_check_json" | grep -q '"ok":true' || { echo "error: AOT cache fast-lane lock-check did not report ok"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$lock_check_json" | grep -q '"schema-version":2' || { echo "error: AOT cache fast-lane lock-check missing schema version"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$lock_check_json" | grep -q '"checked-by":":nelisp-aot-cache"' || { echo "error: AOT cache fast-lane lock-check did not use cache"; rm -rf "$$tmp"; exit 1; }; \
	  plan_json=$$(env $$common_env bin/nelix --json upgrade-plan "$$manifest"); \
	  printf '%s\n' "$$plan_json"; \
	  printf '%s\n' "$$plan_json" | grep -q '"upgrade":\["magit"\]' || { echo "error: AOT cache fast-lane JSON upgrade-plan missing magit"; rm -rf "$$tmp"; exit 1; }; \
	  printf '%s\n' "$$plan_json" | grep -q '"pinned":\["ripgrep-1"\]' || { echo "error: AOT cache fast-lane JSON upgrade-plan missing ripgrep-1"; rm -rf "$$tmp"; exit 1; }; \
	  sleep 1; \
	  touch "$$cache_cmd_manifest"; \
	  stale_json=$$(env $$common_env bin/nelix --json audit "$$cache_cmd_manifest"); \
	  printf '%s\n' "$$stale_json"; \
	  printf '%s\n' "$$stale_json" | grep -q '"present":\["magit","ripgrep-1"\]' || { echo "error: stale AOT cache was not auto-refreshed"; rm -rf "$$tmp"; exit 1; }; \
	  rm -f "$$cache_cmd_manifest.nelix-aot-targets"; \
	  missing_json=$$(env $$common_env bin/nelix --json audit "$$cache_cmd_manifest"); \
	  printf '%s\n' "$$missing_json"; \
	  printf '%s\n' "$$missing_json" | grep -q '"present":\["magit","ripgrep-1"\]' || { echo "error: missing AOT cache was not auto-created"; rm -rf "$$tmp"; exit 1; }; \
	  rm -rf "$$tmp"
	@echo "smoke-nelix-aot-cache-fast-lane: bin/nelix AOT cache shell lane passed without fallback nelisp"

smoke-nelix-aot-artifact-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@mkdir -p "$(NELISP_CACHE_DIR)"
	@artifact="$(NELISP_CACHE_DIR)/nelix-aot-manifest-engine.nelc"; \
	  source="$(NELISP_CACHE_DIR)/nelix-aot-manifest-engine-artifact-smoke.el"; \
	  rm -f "$$artifact" "$$artifact.manifest.el"; \
	  printf '%s\n' \
	    '(defun nelix-aot-artifact-smoke-audit (input)' \
	    '  (quote (:ok nil :manifest "/tmp/manifest.el" :profile "default" :system "x86_64-linux" :present ("magit" "ripgrep-1") :missing nil :extra ("bat"))))' \
	    > "$$source"; \
	  "$(NELISP)" compile-elisp-artifact --kind nelc \
	    --input "$$source" \
	    --output "$$artifact"; \
	  test -f "$$artifact" || { \
	    echo "error: artifact was not created: $$artifact"; \
	    exit 1; \
	  }; \
	  inspect=$$("$(NELISP)" inspect-elisp-artifact "$$artifact"); \
	  printf '%s\n' "$$inspect" | grep -q 'nelisp-elisp-artifact-manifest-v1' || { \
	    echo "error: artifact inspect did not report the canonical Nelisp artifact manifest"; \
	    printf '%s\n' "$$inspect"; \
	    exit 1; \
	  }; \
	  out=$$("$(NELISP)" eval-elisp-artifact "$$artifact" '(nelix-aot-artifact-smoke-audit "NELIX-AOT-MANIFEST-V1\nmanifest\t/tmp/manifest.el\nprofile\tdefault\nsystem\tx86_64-linux\ntarget\tmagit\tmagit\ntarget\tripgrep\tripgrep\npin\tripgrep\ninstalled\tmagit\ninstalled\tripgrep-1\ninstalled\tbat\nend\n")'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ':present ("magit" "ripgrep-1")' || { \
	    echo "error: Nelix AOT artifact did not report expected present names under standalone NeLisp"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q ':extra ("bat")' || { \
	    echo "error: Nelix AOT artifact did not report expected extra names under standalone NeLisp"; \
	    exit 1; \
	  }
	@echo "smoke-nelix-aot-artifact-nelisp: portable AOT artifact ran under $(NELISP)"

smoke-nelix-aot-native-artifact-host:
	@{ test -d "$(NELISP_REPO)/lisp" && test -d "$(NELISP_REPO)/src"; } || { \
	  echo "error: NELISP_REPO does not point at a NeLisp checkout: $(NELISP_REPO)"; \
	  exit 1; \
	}
	@{ command -v cc >/dev/null 2>&1 && command -v objcopy >/dev/null 2>&1; } || { \
	  echo "error: cc and objcopy are required for .neln host native exec proof"; \
	  exit 1; \
	}
	@mkdir -p "$(NELISP_CACHE_DIR)"
	@artifact="$(NELISP_CACHE_DIR)/nelix-aot-native-artifact-smoke.neln"; \
	  subset_artifact="$(NELISP_CACHE_DIR)/nelix-aot-native-subset.neln"; \
	  subset_cli_artifact="$(NELISP_CACHE_DIR)/nelix-aot-native-cli-proof.neln"; \
	  source="$(NELISP_CACHE_DIR)/nelix-aot-native-artifact-smoke.el"; \
	  rm -f "$$artifact" "$$artifact.manifest.el" "$$subset_artifact" "$$subset_artifact.manifest.el" "$$subset_cli_artifact" "$$subset_cli_artifact.manifest.el"; \
	  printf '%s\n' '(defun nelix-aot-native-artifact-inc1 (x) (1+ x))' > "$$source"; \
	  out=$$($(EMACS) -Q --batch \
	    -L "$(NELISP_REPO)/lisp" \
	    -L "$(NELISP_REPO)/src" \
	    --eval '(setq load-prefer-newer t)' \
	    --eval '(require (quote nelisp-artifact))' \
	    --eval "(progn (nelisp-artifact-compile-file \"$$source\" \"$$artifact\" nil nil nil nil nil (quote neln)) (native-exec-elisp-artifact (list \"native-exec-elisp-artifact\" \"$$artifact\" \"nelix-aot-native-artifact-inc1\" \"41\")))"); \
	  printf '%s\n' "$$out"; \
	  test "$$out" = "42" || { \
	    echo "error: .neln host native exec did not return 42"; \
	    exit 1; \
	  }; \
	  inspect=$$("$(NELISP)" inspect-elisp-artifact "$$artifact"); \
	  printf '%s\n' "$$inspect" | grep -q ':artifact-class native' || { \
	    echo "error: standalone NeLisp did not inspect .neln native manifest"; \
	    printf '%s\n' "$$inspect"; \
	    exit 1; \
	  }; \
	  fallback=$$("$(NELISP)" eval-elisp-artifact "$$artifact" '(nelix-aot-native-artifact-inc1 41)'); \
	  test "$$fallback" = "42" || { \
	    echo "error: standalone NeLisp .neln bytecode fallback returned $$fallback"; \
	    exit 1; \
	  }; \
	  standalone_native=$$("$(NELISP)" native-exec-elisp-artifact "$$artifact" nelix-aot-native-artifact-inc1 41); \
	  test "$$standalone_native" = "42" || { \
	    echo "error: standalone NeLisp .neln native exec returned $$standalone_native"; \
	    exit 1; \
	  }; \
	  subset_out=$$($(EMACS) -Q --batch \
	    -L "$(NELISP_REPO)/lisp" \
	    -L "$(NELISP_REPO)/src" \
	    --eval '(setq load-prefer-newer t)' \
	    --eval '(require (quote nelisp-artifact))' \
	    --eval "(progn (nelisp-artifact-compile-file \"scripts/nelix-aot-native-subset.el\" \"$$subset_artifact\" nil nil nil nil nil (quote neln)) (princ (let ((payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tmagit\\tmagit\\npin\\tripgrep\\ninstalled\\tmagit\\nend\") (candidate-payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tmagit\\tmagit\\tfd\\npin\\tripgrep\\ninstalled\\tmagit\\nend\")) (list :missing (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-missing-count8\" (list 3 1)) :extra (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-extra-count8\" (list 3 5)) :ok1 (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-ok-code8\" (list 3 3)) :ok0 (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-ok-code8\" (list 3 1)) :strlen (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-string-len\" (list \"abc\")) :first-byte (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-string-first-byte\" (list \"abc\")) :proto (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-protocol-prefix-code\" (list payload)) :target-tag (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-record-tag-code\" (list payload 22)) :pin-tag (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-record-tag-code\" (list payload 41)) :installed-tag (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-record-tag-code\" (list payload 53)) :end-tag (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-record-tag-code\" (list payload 69)) :lf-count (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-count-byte\" (list payload 10)) :target-count (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-count-tag\" (list payload 1)) :pin-count (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-count-tag\" (list payload 2)) :installed-count (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-count-tag\" (list payload 3)) :end-count (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-count-tag\" (list payload 4)) :target-tab (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-find-byte\" (list payload 9 22)) :target-field-end (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-field-end\" (list payload 29)) :magit-sum (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-field-byte-sum\" (list payload 29)) :ripgrep-sum (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-field-byte-sum\" (list payload 45)) :desired-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-desired-mask\" (list payload)) :installed-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-installed-mask\" (list payload)) :pin-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-pin-mask\" (list payload)) :mask-ok (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-mask-ok-code\" (list payload)) :mask-proof (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-mask-proof-code\" (list payload)) :target-candidate-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-target-candidate-mask\" (list payload)) :target-candidate-mask-fd (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-target-candidate-mask\" (list candidate-payload)) :audit-code (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-audit-code\" (list payload)) :upgrade-code (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-upgrade-plan-code\" (list candidate-payload)) :audit-output-ok (equal (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-audit-output-select\" (list payload \"ok-audit\" \"bad-audit\")) \"ok-audit\") :upgrade-output-ok (equal (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-upgrade-output-select\" (list candidate-payload \"ok-upgrade\" \"bad-upgrade\")) \"ok-upgrade\") :audit-lines-ok (equal (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-audit-lines-proof\" (list payload)) \"ok\\ttrue\\npresent\\tmagit\\nbackend\\tnix\\n\") :upgrade-lines-ok (equal (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-upgrade-lines-proof\" (list candidate-payload)) \"operation\\tupgrade\\nupgrade\\tmagit\\nmissing\\tfd\\nbackend\\tnix\\n\"))))))"); \
	  printf '%s\n' "$$subset_out"; \
	  printf '%s\n' "$$subset_out" | grep -q ':missing 1' || { \
	    echo "error: host subset native missing-count command failed"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$subset_out" | grep -q ':extra 1' || { \
	    echo "error: host subset native extra-count command failed"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$subset_out" | grep -q ':ok1 1' || { \
	    echo "error: host subset native ok-code equal command failed"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$subset_out" | grep -q ':ok0 0' || { \
	    echo "error: host subset native ok-code mismatch command failed"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$subset_out" | grep -q ':strlen 3' || { \
	    echo "error: host subset native string length command failed"; \
	    exit 1; \
	  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':first-byte 97' || { \
		    echo "error: host subset native string first-byte command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':proto 1' || { \
		    echo "error: host subset native protocol prefix command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':target-tag 1' || { \
		    echo "error: host subset native target tag command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':pin-tag 2' || { \
		    echo "error: host subset native pin tag command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':installed-tag 3' || { \
		    echo "error: host subset native installed tag command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':end-tag 4' || { \
		    echo "error: host subset native end tag command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':lf-count 4' || { \
		    echo "error: host subset native linefeed count command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':target-count 1' || { \
		    echo "error: host subset native target count command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':pin-count 1' || { \
		    echo "error: host subset native pin count command failed"; \
		    exit 1; \
		  }; \
		  printf '%s\n' "$$subset_out" | grep -q ':installed-count 1' || { \
		    echo "error: host subset native installed count command failed"; \
		    exit 1; \
		  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':end-count 1' || { \
			    echo "error: host subset native end count command failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':target-tab 28' || { \
			    echo "error: host subset native target tab search failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':target-field-end 34' || { \
			    echo "error: host subset native target field end failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':magit-sum 530' || { \
			    echo "error: host subset native magit field sum failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':ripgrep-sum 761' || { \
			    echo "error: host subset native ripgrep field sum failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':desired-mask 1' || { \
			    echo "error: host subset native desired mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':installed-mask 1' || { \
			    echo "error: host subset native installed mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':pin-mask 2' || { \
			    echo "error: host subset native pin mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':mask-ok 1' || { \
			    echo "error: host subset native mask ok failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':mask-proof 19' || { \
			    echo "error: host subset native mask proof failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':target-candidate-mask 1' || { \
			    echo "error: host subset native target candidate mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':target-candidate-mask-fd 5' || { \
			    echo "error: host subset native target candidate fd mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':audit-code 9' || { \
			    echo "error: host subset native compact audit code failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':upgrade-code 10' || { \
			    echo "error: host subset native compact upgrade-plan code failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':audit-output-ok t' || { \
			    echo "error: host subset native compact audit output select failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':upgrade-output-ok t' || { \
			    echo "error: host subset native compact upgrade-plan output select failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':audit-lines-ok t' || { \
			    echo "error: host subset native compact audit line fragment failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$subset_out" | grep -q ':upgrade-lines-ok t' || { \
			    echo "error: host subset native compact upgrade-plan line fragment failed"; \
			    exit 1; \
			  }; \
			  field_lines_out=$$($(EMACS) -Q --batch \
			    -L "$(NELISP_REPO)/lisp" \
			    -L "$(NELISP_REPO)/src" \
			    --eval '(setq load-prefer-newer t)' \
			    --eval '(require (quote nelisp-artifact))' \
			    --eval "(let* ((payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tmagit\\tmagit\\npin\\tripgrep\\ninstalled\\tmagit\\nend\") (missing-payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tfd\\tfd\\npin\\tripgrep\\ninstalled\\tmagit\\nend\") (candidate-payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tmagit\\tmagit\\tfd\\npin\\tripgrep\\ninstalled\\tmagit\\nend\") (multi-payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tmagit\\tmagit\\ntarget\\tfd\\tfd\\npin\\tripgrep\\ninstalled\\tmagit\\nend\") (present (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-audit-present-line-proof\" (list payload))) (missing (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-audit-missing-line-proof\" (list missing-payload))) (upgrade (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-upgrade-line-proof\" (list candidate-payload))) (audit-report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-audit-report-proof\" (list multi-payload))) (upgrade-report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-compact-upgrade-report-proof\" (list multi-payload))) (builder-report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-builder-audit-report-proof\" (list multi-payload \"\")))) (princ (list :present-line-ok (equal present \"present\\tmagit\\n\") :missing-line-ok (equal missing \"missing\\tfd\\n\") :upgrade-line-ok (equal upgrade \"upgrade\\tmagit\\n\") :audit-report-ok (equal audit-report \"ok\\tfalse\\npresent\\tmagit\\nmissing\\tfd\\nbackend\\tnix\\n\") :upgrade-report-ok (equal upgrade-report \"operation\\tupgrade\\nupgrade\\tmagit\\nmissing\\tfd\\nbackend\\tnix\\n\") :builder-audit-report-ok (equal builder-report \"ok\\tfalse\\npresent\\tmagit\\nmissing\\tfd\\nbackend\\tnix\\n\"))))"); \
			  printf '%s\n' "$$field_lines_out"; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':present-line-ok t' || { \
			    echo "error: host subset native field-derived present line failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':missing-line-ok t' || { \
			    echo "error: host subset native field-derived missing line failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':upgrade-line-ok t' || { \
			    echo "error: host subset native field-derived upgrade line failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':audit-report-ok t' || { \
			    echo "error: host subset native compact audit report failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':upgrade-report-ok t' || { \
			    echo "error: host subset native compact upgrade-plan report failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$field_lines_out" | grep -q ':builder-audit-report-ok t' || { \
			    echo "error: host subset native mut-str builder audit report failed"; \
			    exit 1; \
			  }; \
			  bit_dispatch_out=$$($(EMACS) -Q --batch \
			    -L "$(NELISP_REPO)/lisp" \
			    -L "$(NELISP_REPO)/src" \
			    --eval '(setq load-prefer-newer t)' \
			    --eval '(require (quote nelisp-artifact))' \
			    --eval "(let* ((payload \"NELIX-AOT-MANIFEST-V1\\ntarget\\tripgrep\\tripgrep\\ntarget\\tbat\\tbat\\npin\\tfd\\ninstalled\\tripgrep\\nend\") (report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-builder-audit-report-proof\" (list payload \"\")))) (princ (list :builder-bit-dispatch-ok (equal report \"ok\\tfalse\\npresent\\tripgrep\\nmissing\\tbat\\nbackend\\tnix\\n\"))))"); \
			  printf '%s\n' "$$bit_dispatch_out"; \
			  printf '%s\n' "$$bit_dispatch_out" | grep -q ':builder-bit-dispatch-ok t' || { \
			    echo "error: host subset native mut-str builder bit dispatch failed"; \
			    exit 1; \
			  }; \
			  id_dispatch_out=$$($(EMACS) -Q --batch \
			    -L "$(NELISP_REPO)/lisp" \
			    -L "$(NELISP_REPO)/src" \
			    --eval '(setq load-prefer-newer t)' \
			    --eval '(require (quote nelisp-artifact))' \
			    --eval "(let* ((payload \"NELIX-AOT-MANIFEST-V1\\ntarget-id\\t2\\t2\\ntarget-id\\t4\\t4\\npin-id\\t3\\ninstalled-id\\t2\\nend\") (report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-builder-audit-id-report-proof\" (list payload \"\")))) (princ (list :desired-id-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-desired-id-mask\" (list payload)) :installed-id-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-installed-id-mask\" (list payload)) :builder-id-dispatch-ok (equal report \"ok\\tfalse\\npresent\\tripgrep\\nmissing\\tbat\\nbackend\\tnix\\n\"))))"); \
			  printf '%s\n' "$$id_dispatch_out"; \
			  printf '%s\n' "$$id_dispatch_out" | grep -q ':desired-id-mask 10' || { \
			    echo "error: host subset native desired ID mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_dispatch_out" | grep -q ':installed-id-mask 2' || { \
			    echo "error: host subset native installed ID mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_dispatch_out" | grep -q ':builder-id-dispatch-ok t' || { \
			    echo "error: host subset native mut-str builder ID dispatch failed"; \
			    exit 1; \
			  }; \
			  id_upgrade_out=$$($(EMACS) -Q --batch \
			    -L "$(NELISP_REPO)/lisp" \
			    -L "$(NELISP_REPO)/src" \
			    --eval '(setq load-prefer-newer t)' \
			    --eval '(require (quote nelisp-artifact))' \
			    --eval "(let* ((payload \"NELIX-AOT-MANIFEST-V1\\ntarget-id\\t1\\t1\\ntarget-id\\t2\\t2\\ntarget-id\\t3\\t3\\npin-id\\t2\\ninstalled-id\\t1\\ninstalled-id\\t2\\nend\") (report (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-builder-upgrade-id-report-proof\" (list payload \"\")))) (princ (list :target-candidate-id-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-target-candidate-id-mask\" (list payload)) :pin-id-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-pin-id-mask\" (list payload)) :id-upgrade-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-id-upgrade-mask\" (list payload)) :id-pinned-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-id-pinned-mask\" (list payload)) :id-upgrade-missing-mask (nelisp-artifact-native-exec-general \"$$subset_artifact\" \"nelix-aot-native-id-upgrade-missing-mask\" (list payload)) :builder-id-upgrade-ok (equal report \"upgrade\\tmagit\\npinned\\tripgrep\\nmissing\\tfd\\nbackend\\tnix\\n\"))))"); \
			  printf '%s\n' "$$id_upgrade_out"; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':target-candidate-id-mask 7' || { \
			    echo "error: host subset native target candidate ID mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':pin-id-mask 2' || { \
			    echo "error: host subset native pin ID mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':id-upgrade-mask 1' || { \
			    echo "error: host subset native ID upgrade mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':id-pinned-mask 2' || { \
			    echo "error: host subset native ID pinned mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':id-upgrade-missing-mask 4' || { \
			    echo "error: host subset native ID upgrade missing mask failed"; \
			    exit 1; \
			  }; \
			  printf '%s\n' "$$id_upgrade_out" | grep -q ':builder-id-upgrade-ok t' || { \
			    echo "error: host subset native mut-str builder ID upgrade report failed"; \
			    exit 1; \
			  }; \
		  $(EMACS) -Q --batch \
		    -L "$(NELISP_REPO)/lisp" \
		    -L "$(NELISP_REPO)/src" \
		    --eval '(setq load-prefer-newer t)' \
		    --eval '(require (quote nelisp-artifact))' \
		    --eval "(nelisp-artifact-compile-file \"scripts/nelix-aot-native-cli-proof.el\" \"$$subset_cli_artifact\" nil nil nil nil nil (quote neln))"; \
		  line_payload=$$(printf 'NELIX-AOT-MANIFEST-V1\ntarget\tmagit\tmagit\npin\tripgrep\ninstalled\tmagit\nend\n'); \
		  subset_cli_proof=$$("$(NELISP)" native-exec-elisp-artifact "$$subset_cli_artifact" nelix-aot-native-cli-proof-code "$$line_payload"); \
		  test "$$subset_cli_proof" = "556" || { \
		    echo "error: standalone subset CLI proof returned $$subset_cli_proof"; \
		    exit 1; \
		  }; \
		  subset_cli_output=$$("$(NELISP)" native-exec-elisp-artifact "$$subset_cli_artifact" nelix-aot-native-cli-lines-proof "$$line_payload"); \
		  subset_cli_expected=$$(printf 'ok\ttrue\npresent\tmagit'); \
		  test "$$subset_cli_output" = "$$subset_cli_expected" || { \
		    echo "error: standalone subset CLI line fragment returned $$subset_cli_output"; \
		    exit 1; \
		  }; \
		  id_line_payload=$$(printf 'NELIX-AOT-MANIFEST-V1\ntarget-id\t1\t1\ntarget-id\t2\t2\ntarget-id\t3\t3\ninstalled-id\t1\ninstalled-id\t2\nend\n'); \
		  subset_cli_id_output=$$("$(NELISP)" native-exec-elisp-artifact "$$subset_cli_artifact" nelix-aot-native-cli-audit-id-lines-proof "$$id_line_payload"); \
		  subset_cli_id_expected=$$(printf 'ok\tfalse\npresent\tmagit\npresent\tripgrep\nmissing\tfd\nbackend\tnix'); \
		  test "$$subset_cli_id_output" = "$$subset_cli_id_expected" || { \
		    echo "error: standalone subset CLI ID audit line report returned $$subset_cli_id_output"; \
		    exit 1; \
		  }; \
		  id_upgrade_payload=$$(printf 'NELIX-AOT-MANIFEST-V1\ntarget-id\t1\t1\ntarget-id\t2\t2\ntarget-id\t3\t3\npin-id\t2\ninstalled-id\t1\ninstalled-id\t2\nend\n'); \
		  subset_cli_id_upgrade_output=$$("$(NELISP)" native-exec-elisp-artifact "$$subset_cli_artifact" nelix-aot-native-cli-upgrade-id-lines-proof "$$id_upgrade_payload"); \
		  subset_cli_id_upgrade_expected=$$(printf 'operation\tupgrade\nupgrade\tmagit\npinned\tripgrep\nmissing\tfd\nbackend\tnix'); \
		  test "$$subset_cli_id_upgrade_output" = "$$subset_cli_id_upgrade_expected" || { \
		    echo "error: standalone subset CLI ID upgrade line report returned $$subset_cli_id_upgrade_output"; \
		    exit 1; \
		  }
	@echo "smoke-nelix-aot-native-artifact-host: .neln native artifact host + standalone subset proofs passed"

$(NELIX_CLI_IMAGE): $(SRC) $(SCRIPT_SRC) $(BIN_SRC)
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@mkdir -p "$(dir $(NELIX_CLI_IMAGE))"
	@"$(NELISP)" dump-runtime-image "$(NELIX_CLI_IMAGE)" \
	  '(setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)")' \
	  '(load "scripts/anvil-pkg-nelisp-smoke.el")' \
	  '(anvil-pkg-nelisp-smoke-preload-suite-runtime)' \
	  '(load "scripts/nelix-cli.el")' >/dev/null

smoke-nelix-cli-image-build: $(NELIX_CLI_IMAGE)
	@echo "smoke-nelix-cli-image-build: wrote $(NELIX_CLI_IMAGE)"

smoke-nelix-cli-image: $(NELIX_CLI_IMAGE)
	@out=$$(NELISP="$(NELISP)" NELIX_RUNTIME=nelisp NELIX_NELISP_IMAGE="$(NELIX_CLI_IMAGE)" bin/nelix --json version); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q '"status":"ok"' || { \
	    echo "error: bin/nelix image mode did not report ok status"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q '"version":"0.1.0"' || { \
	    echo "error: bin/nelix image mode did not report expected version"; \
	    exit 1; \
	  }
	@echo "smoke-nelix-cli-image: bin/nelix explicit image mode ran under $(NELISP)"

smoke-nelisp-capabilities:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-text-buffer-source "$(NELISP_TEXT_BUFFER_SRC)") (setq anvil-pkg-nelisp-smoke-regex-source "$(NELISP_REGEX_SRC)") (setq anvil-pkg-nelisp-smoke-emacs-compat-source "$(NELISP_EMACS_COMPAT_SRC)") (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-capabilities))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":native-gap-accounted t" || { \
	    echo "error: smoke-nelisp-capabilities did not account for native backend gaps"; \
	    exit 1; \
	  }
	@marker=$$(mktemp /tmp/anvil-pkg-nelisp-call-process.XXXXXX); \
	  rm -f "$$marker"; \
	  "$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke--load-native-prereqs) (anvil-pkg-nelisp-smoke--load-optional anvil-pkg-nelisp-smoke-process-source) (when (fboundp (quote nelisp-call-process)) (nelisp-call-process "/bin/sh" nil nil nil "-c" "printf ok > '"$$marker"'"))) ' >/dev/null 2>&1 || true; \
	  if test -s "$$marker"; then \
	    echo ":nelisp-call-process-executes t"; \
	  else \
	    echo ":nelisp-call-process-executes nil"; \
	  fi; \
	  rm -f "$$marker"

smoke-nelisp-suite-readiness:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (prin1 (anvil-pkg-nelisp-smoke-suite-readiness)))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":readiness-audit-ok t" || { \
	    echo "error: smoke-nelisp-suite-readiness did not produce an actionable readiness audit"; \
	    exit 1; \
	  }

smoke-nelisp-suite-loadability:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@total=0; \
	for file in $(TEST_SRC); do \
	  echo "::group::smoke-nelisp-suite-loadability $$file"; \
	  result=$$(mktemp /tmp/anvil-pkg-nelisp-loadability.XXXXXX); \
	  "$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (setq anvil-pkg-nelisp-smoke-suite-test-files (list "'"$$file"'")) (write-region (format "%S" (anvil-pkg-nelisp-smoke-suite-loadability)) nil "'"$$result"'") 0)' >/dev/null; \
	  out=$$(cat "$$result"); \
	  rm -f "$$result"; \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":suite-loadable t" || { \
	    echo "error: smoke-nelisp-suite-loadability could not load $$file"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q ":runtime nelisp" || { \
	    echo "error: smoke-nelisp-suite-loadability did not run $$file in NeLisp runtime mode"; \
	    exit 1; \
	  }; \
	  count=$$(printf '%s\n' "$$out" | sed -n 's/.*:tests \([0-9][0-9]*\).*/\1/p'); \
	  test -n "$$count" || { \
	    echo "error: smoke-nelisp-suite-loadability did not report a test count for $$file"; \
	    exit 1; \
	  }; \
	  total=$$((total + count)); \
	  echo "::endgroup::"; \
	done; \
	test "$$total" -eq $(EXPECTED_ERT_TESTS) || { \
	  echo "error: smoke-nelisp-suite-loadability registered $$total tests, expected $(EXPECTED_ERT_TESTS)"; \
	  exit 1; \
	}; \
	echo "smoke-nelisp-suite-loadability: all $(words $(TEST_SRC)) ERT files loaded ($$total tests)"

smoke-nelisp-suite:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@total=0; \
	for file in $(NELISP_EXEC_TEST_SRC); do \
	  echo "::group::smoke-nelisp-suite $$file"; \
	  result=$$(mktemp /tmp/anvil-pkg-nelisp-suite.XXXXXX); \
	  "$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (setq anvil-pkg-nelisp-smoke-suite-test-files (list "'"$$file"'")) (write-region (format "%S" (anvil-pkg-nelisp-smoke-run-suite)) nil "'"$$result"'") 0)' >/dev/null; \
	  out=$$(cat "$$result"); \
	  rm -f "$$result"; \
	  printf '%s\n' "$$out"; \
	  if printf '%s\n' "$$out" | grep -q ":suite-run nil"; then \
	    echo "error: standalone NeLisp is not ready to run $$file"; \
	    exit 1; \
	  fi; \
	  if ! printf '%s\n' "$$out" | grep -q ":suite-run t"; then \
	    echo "error: standalone NeLisp suite did not report a successful run for $$file"; \
	    exit 1; \
	  fi; \
	  if printf '%s\n' "$$out" | grep -q ":failed [1-9]"; then \
	    echo "error: standalone NeLisp suite reported failing tests in $$file"; \
	    exit 1; \
	  fi; \
	  count=$$(printf '%s\n' "$$out" | sed -n 's/.*:tests \([0-9][0-9]*\).*/\1/p'); \
	  test -n "$$count" || { \
	    echo "error: standalone NeLisp suite did not report a test count for $$file"; \
	    exit 1; \
	  }; \
	  total=$$((total + count)); \
	  echo "::endgroup::"; \
	done; \
	test "$$total" -eq $(EXPECTED_NELISP_ERT_TESTS) || { \
	  echo "error: smoke-nelisp-suite ran $$total tests, expected $(EXPECTED_NELISP_ERT_TESTS)"; \
	  exit 1; \
	}; \
	echo "smoke-nelisp-suite: all $(words $(NELISP_EXEC_TEST_SRC)) standalone-executable ERT files passed ($$total tests)"

$(NELISP_SUITE_IMAGE): $(SRC) $(SCRIPT_SRC)
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@mkdir -p "$(NELISP_CACHE_DIR)"
	@printf '%s\n' \
	  ';;; nelisp-runtime-image source-v1' \
	  '(setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)")' \
	  '(setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)")' \
	  '(load "scripts/anvil-pkg-nelisp-smoke.el")' \
	  '(anvil-pkg-nelisp-smoke-preload-suite-runtime)' \
	  >"$@"

smoke-nelisp-suite-image-build: $(NELISP_SUITE_IMAGE)
	@echo "smoke-nelisp-suite-image-build: wrote $(NELISP_SUITE_IMAGE)"

smoke-nelisp-suite-image: $(NELISP_SUITE_IMAGE)
	@total=0; \
	for file in $(NELISP_EXEC_TEST_SRC); do \
	  echo "::group::smoke-nelisp-suite-image $$file"; \
	  result=$$(mktemp /tmp/anvil-pkg-nelisp-suite-image.XXXXXX); \
	  progress=$$(mktemp /tmp/anvil-pkg-nelisp-suite-image-progress.XXXXXX); \
	  "$(NELISP)" --eval '(progn (load "$(NELISP_SUITE_IMAGE)") (setq anvil-pkg-nelisp-smoke-progress-file "'"$$progress"'") (setq anvil-pkg-nelisp-smoke-ert-selector (let ((s "$(NELISP_ERT_SELECTOR)")) (if (equal s "") nil s))) (setq anvil-pkg-nelisp-smoke-suite-test-files (list "'"$$file"'")) (nelisp-process-call-process "/usr/bin/printf" nil "'"$$result"'" nil "%s" (format "%S" (anvil-pkg-nelisp-smoke-run-suite))))' >/dev/null; \
	  out=$$(cat "$$result"); \
	  if test ! -s "$$result"; then \
	    echo "error: standalone NeLisp image suite produced no result for $$file"; \
	    echo "last progress:"; \
	    cat "$$progress" 2>/dev/null || true; \
	    rm -f "$$result" "$$progress"; \
	    exit 1; \
	  fi; \
	  rm -f "$$result" "$$progress"; \
	  printf '%s\n' "$$out"; \
	  if printf '%s\n' "$$out" | grep -q ":suite-run nil"; then \
	    echo "error: standalone NeLisp image is not ready to run $$file"; \
	    exit 1; \
	  fi; \
	  if ! printf '%s\n' "$$out" | grep -q ":suite-run t"; then \
	    echo "error: standalone NeLisp image suite did not report a successful run for $$file"; \
	    exit 1; \
	  fi; \
	  if printf '%s\n' "$$out" | grep -q ":failed [1-9]"; then \
	    echo "error: standalone NeLisp image suite reported failing tests in $$file"; \
	    exit 1; \
	  fi; \
	  count=$$(printf '%s\n' "$$out" | sed -n 's/.*:tests \([0-9][0-9]*\).*/\1/p'); \
	  test -n "$$count" || { \
	    echo "error: standalone NeLisp image suite did not report a test count for $$file"; \
	    exit 1; \
	  }; \
	  total=$$((total + count)); \
	  echo "::endgroup::"; \
	done; \
	test "$$total" -eq $(EXPECTED_NELISP_ERT_TESTS) || { \
	  echo "error: smoke-nelisp-suite-image ran $$total tests, expected $(EXPECTED_NELISP_ERT_TESTS)"; \
	  exit 1; \
	}; \
	echo "smoke-nelisp-suite-image: all $(words $(NELISP_EXEC_TEST_SRC)) standalone-executable ERT files passed through $(NELISP_SUITE_IMAGE) ($$total tests)"

smoke-nelisp-local: smoke-nelisp smoke-nelix-nelisp smoke-nelix-cli-nelisp smoke-nelix-lock-plan-apply-nelisp smoke-nelix-aot-engine-nelisp smoke-nelix-aot-cache-fast-lane smoke-nelix-aot-artifact-nelisp smoke-nelix-aot-native-artifact-host smoke-nelisp-capabilities smoke-nelisp-suite-readiness smoke-nelisp-suite-loadability smoke-nelisp-suite
	@echo "smoke-nelisp-local: standalone NeLisp aggregate gate passed"
