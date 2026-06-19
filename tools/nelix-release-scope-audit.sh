#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

audit_group() {
  local name="$1"
  shift
  printf '== %s ==\n' "$name"
  git add -n -- "$@"
  printf '\n'
}

require_ignored() {
  local path
  for path in "$@"; do
    if ! git check-ignore -q -- "$path"; then
      printf 'release scope audit: expected ignored path is not ignored: %s\n' "$path" >&2
      exit 1
    fi
  done
}

require_executable() {
  local path
  for path in "$@"; do
    if [ ! -x "$path" ]; then
      printf 'release scope audit: expected executable script is not executable: %s\n' "$path" >&2
      exit 1
    fi
  done
}

path_in_release_scope() {
  case "$1" in
    .gitignore|\
    Makefile|\
    README.org|\
    anvil-pkg-compat.el|\
    anvil-pkg-dsl.el|\
    anvil-pkg-emacs.el|\
    anvil-pkg-state.el|\
    anvil-pkg.el|\
    docs/design/01-overview.org|\
    docs/design/07-phase4d.org|\
    docs/design/13-phase5.org|\
    docs/smoke-test.org|\
    examples/README.org|\
    scripts/anvil-pkg-nelisp-ert-shim.el|\
    scripts/anvil-pkg-nelisp-smoke.el|\
    test/anvil-pkg-compat-test.el|\
    test/anvil-pkg-doctor-test.el|\
    test/anvil-pkg-dsl-test.el|\
    test/anvil-pkg-emacs-test.el|\
    test/anvil-pkg-state-test.el|\
    test/anvil-pkg-test.el|\
    test/anvil-pkg-uninstall-test.el|\
    test/anvil-pkg-upgrade-test.el|\
    bin/nelix|\
    nelix.el|\
    nelix-backend.el|\
    nelix-builder.el|\
    nelix-dsl.el|\
    nelix-emacs.el|\
    nelix-fast.el|\
    nelix-fetch.el|\
    nelix-import.el|\
    nelix-manifest.el|\
    nelix-pkg.el|\
    nelix-registry.el|\
    nelix-store.el|\
    nelix-substitute.el|\
    registry/packages/system/curl.el|\
    registry/packages/system/fd.el|\
    registry/packages/system/git.el|\
    registry/packages/system/jq.el|\
    registry/packages/system/ripgrep.el|\
    registry/packages/system/tree.el|\
    docs/schema/nelix-lock-v2.schema.json|\
    scripts/nelix-aot-manifest-engine.el|\
    scripts/nelix-aot-native-cli-proof.el|\
    scripts/nelix-aot-native-subset.el|\
    scripts/nelix-cli.el|\
    test/fixtures/nelix-lock-v1-legacy.el|\
    test/fixtures/nelix-lock-v2-legacy.el|\
    test/fixtures/nelix-lock-v2-current.el|\
    test/fixtures/nelix-lock-v2-native-deps.el|\
    test/nelix-cli-test.el|\
    test/nelix-manifest-test.el|\
    test/nelix-store-test.el|\
    tools/nelix-lock-plan-apply-gate.sh|\
    tools/nelix-aot-native-cli-proof-gate.sh|\
    tools/nelix-release-scope-audit.sh|\
    tools/nelix-release-scope-stage.sh|\
    docs/design/20-nelix-package-store-system.org|\
    docs/design/21-nelix-manifest-operations.org|\
    docs/design/22-nelix-native-store.org|\
    docs/design/23-nelix-distro-publication.org|\
    docs/design/24-nelix-nelisp-fast-manifest-engine.org|\
    docs/design/25-nelix-native-aot-manifest-engine.org|\
    docs/design/26-nelix-lock-plan-apply.org|\
    docs/design/27-nelix-init-migration-workflow.org|\
    docs/design/28-nelix-apply-transaction-and-dsl-v1.org|\
    docs/design/29-nelix-release-worktree-scope.org|\
    debian/README.Debian|\
    debian/changelog|\
    debian/control|\
    debian/copyright|\
    debian/elpa-nelix.docs|\
    debian/elpa-nelix.elpa|\
    debian/elpa-nelix.examples|\
    debian/elpa-nelix.install|\
    debian/elpa-nelix.manpages|\
    debian/nelix.1|\
    debian/rules|\
    debian/source/format|\
    debian/source/options|\
    debian/tests/control|\
    debian/tests/load|\
    packaging/README.org|\
    packaging/apt/make-repo.sh|\
    packaging/apt/public-url-smoke.sh|\
    packaging/apt/publish-static.sh|\
    packaging/apt/serve-and-smoke.sh|\
    packaging/apt/sign-repo.sh|\
    packaging/apt/verify-public-tree.sh|\
    packaging/apt/verify-repo.sh|\
    packaging/apt/verify-signed-repo.sh|\
    packaging/verify-publication-urls.sh|\
    packaging/fedora/README.org|\
    packaging/fedora/build-rpm.sh|\
    packaging/fedora/container-gate.sh|\
    packaging/fedora/dnf-smoke.sh|\
    packaging/fedora/make-repo.sh|\
    packaging/fedora/make-source.sh|\
    packaging/fedora/nelix.spec|\
    packaging/fedora/publish-static.sh|\
    packaging/fedora/public-url-smoke.sh|\
    packaging/fedora/rpmlint.sh|\
    packaging/fedora/verify-public-tree.sh|\
    packaging/fedora/verify-source.sh|\
    packaging/run-autopkgtest-debian.sh|\
    packaging/verify-extracted-nelix-debian.sh|\
    packaging/verify-installed-nelix-cli-gate.sh|\
    packaging/verify-nelix-user-manifest-dsl.sh|\
    packaging/verify-nelix-user-init-migration.sh|\
    packaging/verify-nelix-aot-cache-gate.sh|\
    packaging/verify-nelix-native-cli-gate.sh|\
    packaging/verify-installed-nelix-debian.sh|\
    packaging/verify-nelix-user-environment.sh)
      return 0
      ;;
    test/fixtures/nelix-registry/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_all_changes_classified() {
  local path
  local uncovered=0
  while IFS= read -r -d '' path; do
    if ! path_in_release_scope "$path"; then
      printf 'release scope audit: changed path is not classified: %s\n' "$path" >&2
      uncovered=1
    fi
  done < <(git ls-files -z --modified --deleted --others --exclude-standard)
  if [ "$uncovered" -ne 0 ]; then
    exit 1
  fi
}

require_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    printf 'release scope audit: expected %s to contain %s\n' "$file" "$text" >&2
    exit 1
  fi
}

require_debian_version_consistency() {
  local makefile_version
  local changelog_version
  local deb_basename
  local deb
  local stale

  makefile_version="$(sed -n 's/^DEB_VERSION ?= //p' Makefile | head -n 1)"
  changelog_version="$(sed -n '1s/^nelix (\([^)]*\)).*/\1/p' debian/changelog)"

  if [ -z "$makefile_version" ]; then
    printf 'release scope audit: could not read DEB_VERSION from Makefile\n' >&2
    exit 1
  fi
  if [ "$makefile_version" != "$changelog_version" ]; then
    printf 'release scope audit: DEB_VERSION %s does not match changelog %s\n' \
      "$makefile_version" "$changelog_version" >&2
    exit 1
  fi

  deb_basename="elpa-nelix_${makefile_version}_all.deb"
  deb="../${deb_basename}"
  require_contains packaging/verify-extracted-nelix-debian.sh "$deb"
  require_contains packaging/verify-extracted-nelix-debian.sh "$makefile_version"
  require_contains packaging/verify-installed-nelix-debian.sh "$makefile_version"
  require_contains packaging/README.org "$deb"
  require_contains packaging/README.org "$makefile_version"
  require_contains docs/design/23-nelix-distro-publication.org "$deb_basename"
  require_contains docs/design/27-nelix-init-migration-workflow.org "$deb"
  require_contains docs/design/27-nelix-init-migration-workflow.org "$makefile_version"
  require_contains docs/design/29-nelix-release-worktree-scope.org "$deb"
  require_contains docs/design/29-nelix-release-worktree-scope.org "$makefile_version"

  stale="$(
    rg -n 'elpa-nelix_0\.1\.0-[0-9]+_all\.deb' \
      Makefile packaging docs/design 2>/dev/null |
      grep -Fv "$makefile_version" || true
  )"
  if [ -n "$stale" ]; then
    printf 'release scope audit: stale Debian artifact version reference found:\n%s\n' \
      "$stale" >&2
    exit 1
  fi
}

require_autopkgtest_gate_strength() {
  if grep -Eq '^Restrictions:.*(^|[[:space:],])superficial([[:space:],]|$)' \
      debian/tests/control; then
    printf 'release scope audit: debian/tests/control must not use Restrictions: superficial\n' >&2
    exit 1
  fi
  require_contains debian/tests/control 'Tests: load'
  require_contains debian/tests/control 'Depends: @, emacs-nox | emacs'
  require_contains debian/tests/control 'Restrictions: allow-stderr'
  require_contains debian/tests/load '/usr/bin/nelix --help'
  require_contains debian/tests/load '/usr/bin/nelix --json version'
  require_contains debian/tests/load \
    'sh /usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh'
  require_contains Makefile \
    "! grep -Eq '^Restrictions:.*(^|[[:space:],])superficial([[:space:],]|"
  require_contains Makefile \
    "grep -q 'sh /usr/share/doc/elpa-nelix/packaging/verify-installed-nelix-cli-gate.sh' debian/tests/load"
  require_contains Makefile \
    "grep -Fxq './usr/share/doc/elpa-nelix/packaging/verify-nelix-user-manifest-dsl.sh'"
  require_contains Makefile \
    "grep -Fq 'registry list [--system SYSTEM]'"
  require_contains Makefile \
    "grep -Fq 'native remove NAME [--profile PROFILE] [--system SYSTEM]'"
  require_contains Makefile \
    "grep -Fq 'native rollback [--profile PROFILE] [--generation GENERATION]'"
  require_contains Makefile \
    "grep -Fq 'nelix-fast-validate-json'"
  require_contains Makefile \
    "grep -q 'command=apply-dry-run'"
  require_contains Makefile \
    "grep -Fq 'apply \"\$\$manifest\" --dry-run'"
  require_contains packaging/verify-nelix-aot-cache-gate.sh \
    'apply "$manifest" --dry-run'
  require_contains packaging/verify-nelix-aot-cache-gate.sh \
    '"status":"dry-run"'
  require_contains Makefile \
    "grep -Fq '(defun nelix-fast-validate-json'"
  require_contains Makefile \
    "grep -Fq '(defun nelix-registry-list'"
  require_contains Makefile \
    "grep -Fq '(defun nelix-registry-write-index'"
  require_contains Makefile \
    "grep -Fq '(defun nelix-store-write-entry-at'"
  require_contains Makefile \
    "grep -Fq '(defun nelix-store--commit-entry-dir'"
  require_contains Makefile \
    "grep -Fq 'nelix-store--entry-temp-dir'"
  require_contains Makefile \
    "grep -Fq 'registry list --system x86_64-linux'"
  require_contains Makefile \
    "grep -Fq 'packaged_install native install ripgrep'"
  require_contains Makefile \
    "grep -Fq 'packaged-rg-ok --nelix-gate'"
  require_contains Makefile \
    "grep -Fq 'native install fixture-archive --profile archive'"
  require_contains Makefile \
    "grep -Fq 'fixture-archive-ok unpack'"
  require_contains Makefile \
    "grep -Fq 'native install fixture-bad-hash --profile bad-hash'"
  require_contains Makefile \
    "grep -Fq 'failed hash install created a profile generation'"
  require_contains Makefile \
    "grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/ripgrep.el'"
  require_contains Makefile \
    "grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/fd.el'"
  require_contains Makefile \
    "grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/jq.el'"
  require_contains Makefile \
    "grep -Fxq './usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/tree.el'"
  require_contains Makefile \
    "grep -Fq 'packaged_registry'"
  require_contains Makefile \
    'registry index "$$data/nelix/registry" "$$generated_index"'
  require_contains Makefile \
    "grep -Fq 'native remove fixture-extra'"
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    "registry list [--system SYSTEM]"
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    "run_json packaged_registry registry list --system x86_64-linux"
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    "native remove NAME [--profile PROFILE] [--system SYSTEM]"
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    "native rollback [--profile PROFILE] [--generation GENERATION]"
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    'run_json transaction_show_ok transaction show "$ok_record"'
  require_contains packaging/verify-installed-nelix-cli-gate.sh \
    '"rollback-plan":'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "registry list --system x86_64-linux"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "run_json_packaged packaged_install native install ripgrep"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "packaged-rg-ok --nelix-gate"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "native install fixture-archive --profile archive"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "fixture-archive-ok unpack"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "native install fixture-bad-hash --profile bad-hash"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "failed hash install created a profile generation"
  require_contains packaging/fedora/verify-source.sh \
    "native install fixture-bad-hash --profile bad-hash"
  require_contains packaging/fedora/verify-source.sh \
    "failed hash install created a profile generation"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'registry index "$data/nelix/registry" "$generated_index"'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    "native remove fixture-extra"
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'apply "$native_lock_manifest" --dry-run --locked'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native apply --dry-run mutated lockgate profile'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint recipe-registry'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint fetch'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint hash-verify'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint unpack'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint profile-activation'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint rollback'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'mvp_checkpoint lockfile-recording'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'NELIX_REGISTRY_INCLUDE_PACKAGED=0'
  require_contains debian/elpa-nelix.elpa \
    'registry/packages/system/*.el registry/packages/system'
  require_contains Makefile \
    "grep -q 'make verify-user-manifest-dsl'"
  require_contains debian/source/options '.cache'
  require_contains debian/source/options 'nelix-apt-public'
  require_contains debian/source/options 'nelix-rpmbuild'
}

require_user_manifest_dsl_gate() {
  require_contains Makefile 'verify-user-manifest-dsl:'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    'nelix user manifest DSL v1 ok'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    'Nelix user manifest must use DSL v1, not top-level nelix-manifest'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '--runtime nelisp --json validate'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '--runtime nelisp --json audit'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '--runtime nelisp --json plan'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '--runtime nelisp --json apply "$manifest" --dry-run'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '--runtime nelisp --json upgrade-plan'
  require_contains Makefile \
    "grep -Fq -- '--runtime nelisp --json apply"
  require_contains bin/nelix \
    'command=apply-dry-run'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    '"fallback":":nelisp-aot-cache"'
  require_contains packaging/verify-nelix-user-manifest-dsl.sh \
    'nelix user manifest nelisp AOT read-only ok'
  require_contains packaging/verify-nelix-user-environment.sh \
    'nelix user manifest DSL v1 ok'
  require_contains packaging/verify-nelix-user-environment.sh \
    'nelix-environment'
  require_contains packaging/verify-nelix-user-environment.sh \
    'not top-level nelix-manifest'
  require_contains docs/design/27-nelix-init-migration-workflow.org \
    '(nelix-environment'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'uses =nelix-environment='
}

require_release_scope_stage_targets() {
  require_contains Makefile 'release-scope-stage-a:'
  require_contains Makefile 'release-scope-stage-b:'
  require_contains Makefile 'release-scope-stage-c:'
  require_contains Makefile 'release-scope-stage-d:'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-a'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-b'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-c'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-d'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'test/fixtures/nelix-lock-v2-native-deps.el'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'packaging/apt/verify-public-tree.sh'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'packaging/fedora/verify-public-tree.sh'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'packaging/verify-publication-urls.sh'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'packaging/verify-nelix-user-manifest-dsl.sh'
}

require_user_manifest_usage_doc_if_present() {
  local makefile_version
  local doc
  local found=0

  makefile_version="$(sed -n 's/^DEB_VERSION ?= //p' Makefile | head -n 1)"
  for doc in \
    "$HOME/Notes/capture/nelix-manifest-usage.org" \
    "$HOME/Cowork/Notes/capture/nelix-manifest-usage.org"
  do
    if [ -f "$doc" ]; then
      found=1
      require_contains "$doc" "elpa-nelix_${makefile_version}_all.deb"
      require_contains "$doc" "packaging/verify-installed-nelix-debian.sh ${makefile_version}"
      require_contains "$doc" '(nelix-environment'
      require_contains "$doc" 'make verify-installed-cli-gate'
      require_contains "$doc" 'make verify-user-manifest-dsl'
      require_contains "$doc" 'make deb-full-gate'
      require_contains "$doc" 'make smoke-nelix-aot-cache-cli'
      require_contains "$doc" 'make publication-url-check'
      require_contains "$doc" 'make apt-publication-preflight'
      require_contains "$doc" 'make apt-public-url-smoke'
      require_contains "$doc" 'make fedora-source-gate'
      require_contains "$doc" '=:nelisp-aot-cache='
      require_contains "$doc" 'nelix --runtime nelisp --json apply "$manifest" --dry-run'
      require_contains "$doc" 'list / audit / plan / apply --dry-run / upgrade-plan'
      require_contains "$doc" 'Native registry 操作'
      require_contains "$doc" 'Native store 操作'
    fi
  done

  if [ "$found" -eq 0 ]; then
    printf 'release scope audit: user manifest usage doc not present; skipping external doc freshness check\n' >&2
  fi
}

require_user_manifest_files_if_present() {
  local makefile_version
  local manifest
  local linux_file

  makefile_version="$(sed -n 's/^DEB_VERSION ?= //p' Makefile | head -n 1)"
  manifest="$HOME/.emacs.d/nelix-package.el"
  linux_file="$HOME/.emacs.d/custom-lisp/nelix-linux.el"

  if [ -f "$manifest" ]; then
    require_contains "$manifest" '(nelix-environment'
    if grep -Eq '^[[:space:]]*\(nelix-manifest([[:space:]]|$)' "$manifest"; then
      printf 'release scope audit: user manifest must not use top-level nelix-manifest: %s\n' \
        "$manifest" >&2
      exit 1
    fi
    require_contains "$manifest" 'custom-lisp/nelix-package-index.el'
    require_contains "$manifest" 'custom-lisp/nelix-linux.el'
  else
    printf 'release scope audit: user manifest not present; skipping actual manifest freshness check\n' >&2
  fi

  if [ -f "$linux_file" ]; then
    require_contains "$linux_file" "(elpa-nelix . \"${makefile_version}\")"
    require_contains "$linux_file" 'nelix-system-autopkgtest'
    require_contains "$linux_file" 'nelix-system-debhelper'
    require_contains "$linux_file" 'nelix-system-dh-elpa'
    require_contains "$linux_file" 'nelix-system-lintian'
    require_contains "$linux_file" '"ripgrep"'
  else
    printf 'release scope audit: user linux manifest not present; skipping actual linux manifest freshness check\n' >&2
  fi
}

require_publication_gate_docs() {
  local fedora_build_count

  require_contains Makefile 'publication-local-gate: apt-http-gate fedora-source-gate'
  require_contains Makefile 'publication-url-check:'
  require_contains Makefile 'publication-preflight: publication-url-check apt-publication-preflight fedora-publication-preflight'
  require_contains Makefile 'publication-public-smoke: publication-url-check apt-public-url-smoke fedora-public-url-smoke'
  require_contains Makefile 'apt-http-gate: apt-publish-static apt-http-smoke'
  require_contains Makefile 'verify-apt-public-tree:'
  require_contains Makefile 'packaging/apt/verify-public-tree.sh "$(APT_PUBLISH_DIR)" "$(APT_PUBLIC_URL)" "$(APT_SUITE)" "$(DEB_VERSION)"'
  require_contains Makefile 'public APT payload native CLI gate is missing packaged ripgrep install smoke'
  require_contains Makefile 'public APT smoke payload native CLI gate is missing packaged ripgrep install smoke'
  require_contains Makefile 'public Fedora emacs-nelix RPM is missing packaged registry recipe'
  require_contains Makefile 'apt-publication-preflight: apt-publish-static verify-apt-public-tree'
  require_contains Makefile 'apt-public-url-smoke:'
  require_contains Makefile 'packaging/apt/public-url-smoke.sh "$(APT_PUBLIC_URL)" "$(APT_SUITE)" "$(DEB_VERSION)"'
  require_contains Makefile 'packaging/apt/serve-and-smoke.sh "$(APT_PUBLISH_DIR)" "$(APT_SUITE)" "$(DEB_VERSION)"'
  require_contains Makefile 'fedora-source-gate: fedora-source fedora-source-verify'
  require_contains Makefile 'fedora-repo: fedora-rpm-build'
  require_contains Makefile 'packaging/fedora/verify-public-tree.sh "$(FEDORA_PUBLISH_DIR)" "$(FEDORA_PUBLIC_URL)" "$(FEDORA_VERSION)"'
  require_contains Makefile 'fedora-publication-preflight: fedora-publish-static verify-fedora-public-tree'
  require_contains Makefile 'fedora-container-gate:'
  require_contains Makefile 'packaging/fedora/dnf-smoke.sh "$(FEDORA_REPO_DIR)" "$(FEDORA_VERSION)"'
  require_contains Makefile 'fedora-public-url-smoke:'
  require_contains Makefile 'packaging/fedora/public-url-smoke.sh "$(FEDORA_PUBLIC_URL)" "$(FEDORA_VERSION)"'
  require_contains packaging/README.org 'make apt-http-gate'
  require_contains packaging/README.org 'make publication-preflight'
  require_contains packaging/README.org 'make publication-url-check'
  require_contains packaging/README.org 'make publication-public-smoke'
  require_contains README.org 'make publication-url-check'
  require_contains README.org 'make publication-preflight'
  require_contains README.org 'make publication-public-smoke'
  require_contains packaging/README.org 'make apt-publication-preflight'
  require_contains packaging/README.org 'make publication-local-gate'
  require_contains packaging/README.org 'make apt-public-url-smoke'
  require_contains packaging/README.org 'make fedora-source-gate'
  require_contains packaging/README.org 'make fedora-publication-preflight'
  require_contains packaging/fedora/README.org 'make fedora-publication-preflight'
  require_contains packaging/README.org 'make fedora-container-gate'
  require_contains packaging/README.org 'public tree and public URL smoke also inspect the downloaded =.deb= payload'
  require_contains packaging/apt/verify-public-tree.sh 'verify_deb_payload "$tree/$deb_path"'
  require_contains packaging/apt/verify-public-tree.sh 'packaged_install native install ripgrep'
  require_contains packaging/apt/verify-public-tree.sh 'native install fixture-archive --profile archive'
  require_contains packaging/apt/public-url-smoke.sh 'verify_deb_payload "$downloaded"'
  require_contains packaging/apt/public-url-smoke.sh 'packaged_install native install ripgrep'
  require_contains packaging/apt/public-url-smoke.sh 'native install fixture-archive --profile archive'
  require_contains packaging/fedora/verify-public-tree.sh 'verify_emacs_rpm_payload'
  require_contains packaging/fedora/verify-public-tree.sh 'registry/packages/system/$recipe.el'

  fedora_build_count="$(
    awk '
      /^fedora-rpm-build:/ { in_target = 1; next }
      /^[^[:space:]].*:/ { in_target = 0 }
      in_target && /packaging\/fedora\/build-rpm\.sh/ { count++ }
      END { print count + 0 }
    ' Makefile
  )"
  if [ "$fedora_build_count" -ne 1 ]; then
    printf 'release scope audit: fedora-rpm-build must call packaging/fedora/build-rpm.sh exactly once, got %s\n' \
      "$fedora_build_count" >&2
    exit 1
  fi

  require_contains docs/design/23-nelix-distro-publication.org \
    'make publication-local-gate'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make publication-url-check'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make publication-preflight'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make publication-public-smoke'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'public APT URL smoke repeats the same'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=emacs-nelix= RPM contains the packaged native registry recipes'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make apt-http-gate'
  require_contains docs/design/22-nelix-native-store.org \
    'nelix registry index ROOT OUTPUT'
  require_contains docs/design/22-nelix-native-store.org \
    'nelix-registry-write-index'
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    'nelix-fast-validate-json'
  require_contains docs/design/27-nelix-init-migration-workflow.org \
    'nelix-fast-validate-json'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make apt-publication-preflight'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make apt-public-url-smoke'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make fedora-container-gate'
  require_contains docs/design/23-nelix-distro-publication.org \
    'make fedora-publication-preflight'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Signed/static/HTTP APT gate passed: =make apt-http-gate='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Rootless local pre-publication gate passed: =make publication-local-gate='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Combined publication entry points: =make publication-url-check='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=make publication-preflight= runs that guard'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora source gate passed: =make fedora-source-gate='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora container gate passed: =make fedora-container-gate='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make apt-public-url-smoke'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'APT public preflight: =make apt-publication-preflight'
  require_contains packaging/apt/verify-public-tree.sh \
    'set APT_PUBLIC_URL to the real published APT repository URL'
  require_contains packaging/apt/verify-public-tree.sh \
    'public APT sources.list.https does not match APT_PUBLIC_URL/suite/component'
  require_contains packaging/apt/verify-public-tree.sh \
    'public APT Packages has stale elpa-nelix version'
  require_contains packaging/apt/public-url-smoke.sh \
    'public APT smoke downloaded stale elpa-nelix version'
  require_contains packaging/fedora/verify-public-tree.sh \
    'set FEDORA_PUBLIC_URL to the real published Fedora repository URL'
  require_contains packaging/fedora/verify-public-tree.sh \
    'public Fedora repo file does not match FEDORA_PUBLIC_URL'
  require_contains packaging/fedora/verify-public-tree.sh \
    'public Fedora tree is missing expected-version RPM payload'
  require_contains packaging/fedora/public-url-smoke.sh \
    'rpm -q --qf'
  require_contains packaging/fedora/dnf-smoke.sh \
    'rpm -q --qf'
  require_contains packaging/fedora/verify-source.sh \
    'Fedora source tarball public tree verifier is missing expected-version payload check'
  require_contains packaging/fedora/verify-source.sh \
    'Fedora source tarball public URL smoke is missing installed RPM version check'
  require_contains packaging/fedora/verify-source.sh \
    'Fedora source tarball local dnf smoke is missing installed RPM version check'
  require_contains packaging/fedora/verify-source.sh \
    'packaging/verify-publication-urls.sh'
  require_contains packaging/fedora/verify-source.sh \
    'set $name to the real published repository URL'
  require_contains packaging/fedora/verify-source.sh \
    'check_url FEDORA_PUBLIC_URL'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora public preflight: =make fedora-publication-preflight'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora local/container gate verifies that installed =nelix= and'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make fedora-public-url-smoke'
}

require_native_store_gate_docs() {
  require_contains scripts/nelix-cli.el \
    'native rollback [--profile PROFILE] [--generation GENERATION]'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-unpack-installs-zip-with-strip-components'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-substitute-materialize-zip-payload-with-strip'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-fetch-source-github-release-base-url'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-github-release-mirror-zip-install'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-script-shim-installs-posix-shim'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-script-shim-require-target'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-packaged-registry-root-defaults-and-opt-out'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-script-shim-installs-windows-cmd'
  require_contains nelix-builder.el \
    'nelix-builder--require-script-shim-target'
  require_contains nelix-registry.el \
    'nelix-registry-include-packaged-root'
  require_contains nelix-registry.el \
    'NELIX_REGISTRY_INCLUDE_PACKAGED'
  require_contains registry/packages/system/ripgrep.el \
    ':require-target t'
  require_contains registry/packages/system/git.el \
    ':require-target t'
  require_contains registry/packages/system/curl.el \
    ':require-target t'
  require_contains registry/packages/system/fd.el \
    ':require-target t'
  require_contains registry/packages/system/jq.el \
    ':require-target t'
  require_contains registry/packages/system/tree.el \
    ':require-target t'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-lock-package-replays-script-shim'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-lock-package-replays-dependencies'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-lock-package-requires-dependency-row'
  require_contains test/nelix-manifest-test.el \
    'nelix-manifest-test-lock-schema-check-accepts-native-deps-fixture'
  require_contains test/nelix-manifest-test.el \
    'nelix-manifest-test-apply-locked-replays-native-script-shim-lock'
  require_contains test/nelix-manifest-test.el \
    'nelix-manifest-test-lock-writes-native-dependency-closure'
  require_contains test/nelix-cli-test.el \
    'nelix-cli-test-lock-json-round-trips-native-dependencies'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-preserves-profile-entries'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-installs-registry-dependencies'
  require_contains test/nelix-store-test.el \
    'nelix-store-test-native-install-rejects-dependency-cycle'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native rollback --profile default --generation 1'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'rollback activation output mismatch'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native install fixture-app --profile default --system x86_64-linux'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native install fixture-archive --profile archive --system x86_64-linux'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'archive activation output mismatch'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'dependency activation output mismatch'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'locked apply used drifted dependency recipe'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native lock omitted recipe dependencies'
  require_contains packaging/verify-nelix-native-cli-gate.sh \
    'native apply --dry-run mutated lockgate profile'
  require_contains docs/design/22-nelix-native-store.org \
    'nelix native rollback [--profile PROFILE] [--generation GENERATION]'
  require_contains docs/design/22-nelix-native-store.org \
    'CLI native rollback dispatch with runtime reactivation'
  require_contains docs/design/22-nelix-native-store.org \
    'Portable zip substitutes also honor'
  require_contains docs/design/22-nelix-native-store.org \
    'accept =:base-url= for GitHub-compatible mirrors'
  require_contains docs/design/22-nelix-native-store.org \
    'Install fetch-free =script-shim= packages into the native store.'
  require_contains docs/design/22-nelix-native-store.org \
    'Packaged registry root under the installed Nelix Lisp directory.'
  require_contains docs/design/22-nelix-native-store.org \
    '=curl=, =fd=,'
  require_contains docs/design/22-nelix-native-store.org \
    'installs the packaged =ripgrep= recipe'
  require_contains docs/design/22-nelix-native-store.org \
    'Failed fetch/verify/unpack/copy/script-shim installs do'
  require_contains docs/design/22-nelix-native-store.org \
    'Commit native store entries from temporary build directories'
  require_contains docs/design/22-nelix-native-store.org \
    'source-free native =script-shim= lock replay'
  require_contains docs/design/22-nelix-native-store.org \
    'native dependency closure lock replay without trusting current registry state'
  require_contains docs/design/22-nelix-native-store.org \
    'install registry =:dependencies='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native CLI: =nelix native audit/install/list/profile/activate/rollback/gc='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'native rollback with'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native archive install: =nelix-native= unpack and substitute materialization'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native GitHub release mirrors: =github-release= sources accept =:base-url='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native script shims: =script-shim= recipes create fetch-free'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native packaged registry:'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=curl=, =fd=,'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'packaged =ripgrep= install/activation'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Source-free =script-shim= lock rows replay'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'native dependency closure fixture coverage'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Native dependencies: native installs now create additive profile generations'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'replay native dependency'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'registry dependency install through =nelix native install='
  require_contains packaging/README.org \
    'packaged registry root through'
  require_contains packaging/README.org \
    'built-in system command'
  require_contains packaging/README.org \
    '=git=, =curl=, =fd=, =jq=, =tree=, =ca-certificates='
  require_contains packaging/README.org \
    'installs and activates the'
}

require_aot_plan_gate_docs() {
  require_contains bin/nelix \
    'nelix_nelisp_aot_cache_enabled'
  require_contains bin/nelix \
    'NELIX_NELISP_AOT:-auto'
  require_contains bin/nelix \
    'nelix_nelisp_validate_fast_lane'
  require_contains bin/nelix \
    'command == "plan"'
  require_contains packaging/verify-nelix-aot-cache-gate.sh \
    'NELIX_RUNTIME=nelisp'
  if grep -q 'NELIX_NELISP_AOT=1' packaging/verify-nelix-aot-cache-gate.sh; then
    printf 'release scope audit: AOT cache gate should exercise default nelisp AOT mode, not require NELIX_NELISP_AOT=1\n' >&2
    exit 1
  fi
  require_contains packaging/verify-nelix-aot-cache-gate.sh \
    'run_capture apply_plan plan "$manifest"'
  require_contains packaging/verify-nelix-aot-cache-gate.sh \
    'run_capture apply_plan_json --json plan "$manifest"'
  require_contains README.org \
    'use the AOT cache fast lane by default under =--runtime nelisp='
  require_contains packaging/README.org \
    'cache shell lane is the default for supported =--runtime nelisp= manifest'
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    '=plan MANIFEST=, =apply MANIFEST --dry-run=, and their JSON variants'
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    '=nelix --runtime nelisp apply MANIFEST --dry-run='
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    '=apply --dry-run= reports =status dry-run='
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    '=make smoke-nelix-aot-native-cli-proof='
  require_contains docs/design/25-nelix-native-aot-manifest-engine.org \
    '=NELIX_NELISP_AOT=0='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=plan=, =apply --dry-run=, =upgrade-plan=, and their JSON variants'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'read-only AOT cache fast lane for =audit=, =plan=,'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Debian payload gate: =make deb-local-gate= verifies'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=NELIX_NELISP_AOT:-auto='
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    '=make smoke-nelix-aot-native-cli-proof='
  require_contains Makefile \
    'smoke-nelix-aot-native-cli-proof:'
  require_contains Makefile \
    'tools/nelix-aot-native-cli-proof-gate.sh'
  require_contains Makefile \
    "tar -xO ./usr/bin/nelix | grep -q 'NELIX_NELISP_AOT:-auto'"
  require_contains Makefile \
    "tar -xO ./usr/bin/nelix | grep -q 'nelix_nelisp_validate_fast_lane'"
  require_contains Makefile \
    "tar -xO ./usr/share/doc/elpa-nelix/packaging/apt/verify-public-tree.sh | grep -Fq 'public APT Packages has stale elpa-nelix version'"
  require_contains Makefile \
    "tar -xO ./usr/share/doc/elpa-nelix/packaging/fedora/verify-public-tree.sh | grep -Fq 'public Fedora tree is missing expected-version RPM payload'"
  require_contains packaging/fedora/verify-source.sh \
    'Fedora source tarball bin/nelix is missing default AOT cache mode'
  require_contains packaging/fedora/verify-source.sh \
    'registry/packages/system/ripgrep.el'
  require_contains packaging/fedora/verify-source.sh \
    'registry/packages/system/fd.el'
  require_contains packaging/fedora/verify-source.sh \
    'registry/packages/system/jq.el'
  require_contains packaging/fedora/verify-source.sh \
    'registry/packages/system/tree.el'
  require_contains packaging/fedora/verify-source.sh \
    'packaging/verify-nelix-native-cli-gate.sh'
  require_contains packaging/fedora/verify-source.sh \
    'packaging/verify-nelix-aot-cache-gate.sh'
  require_contains packaging/fedora/verify-source.sh \
    'command=apply-dry-run'
  require_contains packaging/fedora/verify-source.sh \
    'apply "$manifest" --dry-run'
  require_contains packaging/fedora/verify-source.sh \
    'native install fixture-archive --profile archive'
  require_contains packaging/fedora/verify-source.sh \
    'fixture-archive-ok unpack'
  require_contains packaging/fedora/verify-source.sh \
    'NELIX_LISPDIR="$PWD" bin/nelix --json version'
  require_contains packaging/fedora/verify-source.sh \
    'NELIX_BIN="$PWD/bin/nelix" NELIX_LISPDIR="$PWD" packaging/verify-nelix-native-cli-gate.sh'
  require_contains packaging/fedora/nelix.spec \
    'NELIX_LISPDIR="$PWD" bin/nelix --json version'
  require_contains packaging/fedora/nelix.spec \
    'NELIX_BIN="$PWD/bin/nelix" NELIX_LISPDIR="$PWD" packaging/verify-nelix-native-cli-gate.sh'
  require_contains packaging/fedora/README.org \
    'native CLI gate can install and'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora source/RPM gate: =make fedora-source-gate= verifies'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Fedora RPM =%check= runs the native CLI gate'
}

require_commit_execution_checklist() {
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Commit execution checklist:'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-a'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-b'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-c'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-stage-d'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'make release-scope-status'
  require_contains Makefile \
    'release-scope-status:'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'git commit -m "Add Nelix manifest CLI and native store"'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Do not run the audit and staging helpers concurrently.'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'NELIX_RELEASE_SCOPE_ALLOW_DIRTY_INDEX=1'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Do not run source tarball gates concurrently with compile/test targets.'
  require_contains docs/design/29-nelix-release-worktree-scope.org \
    'Run =make clean= before source-package gates.'
  require_contains tools/nelix-release-scope-stage.sh \
    'modified/untracked paths by commit group without touching the index'
  require_contains tools/nelix-release-scope-stage.sh \
    'index already has staged changes'
  require_contains tools/nelix-release-scope-stage.sh \
    'classified-changed:'
  require_contains tools/nelix-release-scope-stage.sh \
    'unclassified-changed:'
}

audit_group "Commit A - compatibility rename and shared tests" \
  .gitignore \
  Makefile \
  README.org \
  anvil-pkg-compat.el \
  anvil-pkg-dsl.el \
  anvil-pkg-emacs.el \
  anvil-pkg-state.el \
  anvil-pkg.el \
  docs/design/01-overview.org \
  docs/design/07-phase4d.org \
  docs/design/13-phase5.org \
  docs/smoke-test.org \
  examples/README.org \
  scripts/anvil-pkg-nelisp-ert-shim.el \
  scripts/anvil-pkg-nelisp-smoke.el \
  test/anvil-pkg-compat-test.el \
  test/anvil-pkg-doctor-test.el \
  test/anvil-pkg-dsl-test.el \
  test/anvil-pkg-emacs-test.el \
  test/anvil-pkg-state-test.el \
  test/anvil-pkg-test.el \
  test/anvil-pkg-uninstall-test.el \
  test/anvil-pkg-upgrade-test.el

audit_group "Commit B - Nelix manifest, native store, and CLI" \
  bin/nelix \
  nelix.el \
  nelix-backend.el \
  nelix-builder.el \
  nelix-dsl.el \
  nelix-emacs.el \
  nelix-fast.el \
  nelix-fetch.el \
  nelix-import.el \
  nelix-manifest.el \
  nelix-pkg.el \
  nelix-registry.el \
  nelix-store.el \
  nelix-substitute.el \
  registry/packages/system \
  scripts/nelix-aot-manifest-engine.el \
  scripts/nelix-aot-native-cli-proof.el \
  scripts/nelix-aot-native-subset.el \
  scripts/nelix-cli.el \
  test/fixtures/nelix-lock-v1-legacy.el \
  test/fixtures/nelix-lock-v2-legacy.el \
  test/fixtures/nelix-lock-v2-current.el \
  test/fixtures/nelix-lock-v2-native-deps.el \
  test/fixtures/nelix-registry \
  test/nelix-cli-test.el \
  test/nelix-manifest-test.el \
  test/nelix-store-test.el \
  tools/nelix-lock-plan-apply-gate.sh \
  tools/nelix-release-scope-audit.sh \
  tools/nelix-release-scope-stage.sh

audit_group "Commit C - design docs" \
  docs/design/20-nelix-package-store-system.org \
  docs/design/21-nelix-manifest-operations.org \
  docs/design/22-nelix-native-store.org \
  docs/design/23-nelix-distro-publication.org \
  docs/design/24-nelix-nelisp-fast-manifest-engine.org \
  docs/design/25-nelix-native-aot-manifest-engine.org \
  docs/design/26-nelix-lock-plan-apply.org \
  docs/design/27-nelix-init-migration-workflow.org \
  docs/design/28-nelix-apply-transaction-and-dsl-v1.org \
  docs/design/29-nelix-release-worktree-scope.org

audit_group "Commit D - Debian and repository publication" \
  debian/README.Debian \
  debian/changelog \
  debian/control \
  debian/copyright \
  debian/elpa-nelix.docs \
  debian/elpa-nelix.elpa \
  debian/elpa-nelix.examples \
  debian/elpa-nelix.install \
  debian/elpa-nelix.manpages \
  debian/nelix.1 \
  debian/rules \
  debian/source/format \
  debian/source/options \
  debian/tests/control \
  debian/tests/load \
  packaging/README.org \
  packaging/apt/make-repo.sh \
  packaging/apt/public-url-smoke.sh \
  packaging/apt/publish-static.sh \
  packaging/apt/serve-and-smoke.sh \
  packaging/apt/sign-repo.sh \
  packaging/apt/verify-public-tree.sh \
  packaging/apt/verify-repo.sh \
  packaging/apt/verify-signed-repo.sh \
  packaging/verify-publication-urls.sh \
  packaging/fedora/README.org \
  packaging/fedora/build-rpm.sh \
  packaging/fedora/container-gate.sh \
  packaging/fedora/dnf-smoke.sh \
  packaging/fedora/make-repo.sh \
  packaging/fedora/make-source.sh \
  packaging/fedora/nelix.spec \
  packaging/fedora/publish-static.sh \
  packaging/fedora/public-url-smoke.sh \
  packaging/fedora/rpmlint.sh \
  packaging/fedora/verify-public-tree.sh \
  packaging/fedora/verify-source.sh \
  packaging/run-autopkgtest-debian.sh \
  packaging/verify-extracted-nelix-debian.sh \
  packaging/verify-installed-nelix-cli-gate.sh \
  packaging/verify-nelix-user-manifest-dsl.sh \
  packaging/verify-nelix-aot-cache-gate.sh \
  packaging/verify-nelix-native-cli-gate.sh \
  packaging/verify-installed-nelix-debian.sh \
  packaging/verify-nelix-user-environment.sh

require_ignored \
  .cache/sentinel \
  debian/.debhelper/sentinel \
  debian/debhelper-build-stamp \
  debian/elpa-nelix/sentinel \
  debian/files \
  debian/elpa-nelix.substvars \
  debian/elpa-nelix.debhelper \
  nelix-apt-repo/sentinel \
  nelix-apt-repo-gnupg-test/sentinel \
  nelix-apt-public/sentinel \
  nelix-rpmbuild/sentinel \
  nelix-rpm-repo/sentinel

require_executable \
  bin/nelix \
  packaging/apt/make-repo.sh \
  packaging/apt/public-url-smoke.sh \
  packaging/apt/publish-static.sh \
  packaging/apt/serve-and-smoke.sh \
  packaging/apt/sign-repo.sh \
  packaging/apt/verify-public-tree.sh \
  packaging/apt/verify-repo.sh \
  packaging/apt/verify-signed-repo.sh \
  packaging/verify-publication-urls.sh \
  packaging/fedora/build-rpm.sh \
  packaging/fedora/container-gate.sh \
  packaging/fedora/dnf-smoke.sh \
  packaging/fedora/make-repo.sh \
  packaging/fedora/make-source.sh \
  packaging/fedora/publish-static.sh \
  packaging/fedora/public-url-smoke.sh \
  packaging/fedora/rpmlint.sh \
  packaging/fedora/verify-public-tree.sh \
  packaging/fedora/verify-source.sh \
  packaging/run-autopkgtest-debian.sh \
  packaging/verify-extracted-nelix-debian.sh \
  packaging/verify-installed-nelix-cli-gate.sh \
  packaging/verify-nelix-user-manifest-dsl.sh \
  packaging/verify-nelix-aot-cache-gate.sh \
  packaging/verify-nelix-native-cli-gate.sh \
  packaging/verify-installed-nelix-debian.sh \
  packaging/verify-nelix-user-environment.sh \
  tools/nelix-aot-native-cli-proof-gate.sh \
  tools/nelix-lock-plan-apply-gate.sh \
  tools/nelix-release-scope-audit.sh \
  tools/nelix-release-scope-stage.sh

require_all_changes_classified
require_debian_version_consistency
require_autopkgtest_gate_strength
require_user_manifest_dsl_gate
require_release_scope_stage_targets
require_user_manifest_usage_doc_if_present
require_user_manifest_files_if_present
require_publication_gate_docs
require_native_store_gate_docs
require_aot_plan_gate_docs
require_commit_execution_checklist

printf 'release scope audit ok\n'
