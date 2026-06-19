#!/usr/bin/env bash
# Stage or preview the planned Nelix release commit groups.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

commit_a=(
  .gitignore
  Makefile
  README.org
  anvil-pkg-compat.el
  anvil-pkg-dsl.el
  anvil-pkg-emacs.el
  anvil-pkg-state.el
  anvil-pkg.el
  docs/design/01-overview.org
  docs/design/07-phase4d.org
  docs/design/13-phase5.org
  docs/smoke-test.org
  examples/README.org
  scripts/anvil-pkg-nelisp-ert-shim.el
  scripts/anvil-pkg-nelisp-smoke.el
  test/anvil-pkg-compat-test.el
  test/anvil-pkg-doctor-test.el
  test/anvil-pkg-dsl-test.el
  test/anvil-pkg-emacs-test.el
  test/anvil-pkg-state-test.el
  test/anvil-pkg-test.el
  test/anvil-pkg-uninstall-test.el
  test/anvil-pkg-upgrade-test.el
)

commit_b=(
  bin/nelix
  nelix.el
  nelix-backend.el
  nelix-builder.el
  nelix-dsl.el
  nelix-emacs.el
  nelix-fast.el
  nelix-fetch.el
  nelix-import.el
  nelix-manifest.el
  nelix-pkg.el
  nelix-registry.el
  nelix-store.el
  nelix-substitute.el
  scripts/nelix-aot-manifest-engine.el
  scripts/nelix-aot-native-cli-proof.el
  scripts/nelix-aot-native-subset.el
  scripts/nelix-cli.el
  test/fixtures/nelix-lock-v1-legacy.el
  test/fixtures/nelix-lock-v2-legacy.el
  test/fixtures/nelix-lock-v2-current.el
  test/fixtures/nelix-lock-v2-native-deps.el
  test/fixtures/nelix-registry
  test/nelix-cli-test.el
  test/nelix-manifest-test.el
  test/nelix-store-test.el
  tools/nelix-lock-plan-apply-gate.sh
  tools/nelix-release-scope-audit.sh
  tools/nelix-release-scope-stage.sh
)

commit_c=(
  docs/design/20-nelix-package-store-system.org
  docs/design/21-nelix-manifest-operations.org
  docs/design/22-nelix-native-store.org
  docs/design/23-nelix-distro-publication.org
  docs/design/24-nelix-nelisp-fast-manifest-engine.org
  docs/design/25-nelix-native-aot-manifest-engine.org
  docs/design/26-nelix-lock-plan-apply.org
  docs/design/27-nelix-init-migration-workflow.org
  docs/design/28-nelix-apply-transaction-and-dsl-v1.org
  docs/design/29-nelix-release-worktree-scope.org
)

commit_d=(
  debian/README.Debian
  debian/changelog
  debian/control
  debian/copyright
  debian/elpa-nelix.docs
  debian/elpa-nelix.elpa
  debian/elpa-nelix.examples
  debian/elpa-nelix.install
  debian/elpa-nelix.manpages
  debian/nelix.1
  debian/rules
  debian/source/format
  debian/source/options
  debian/tests/control
  debian/tests/load
  packaging/README.org
  packaging/apt/make-repo.sh
  packaging/apt/public-url-smoke.sh
  packaging/apt/publish-static.sh
  packaging/apt/serve-and-smoke.sh
  packaging/apt/sign-repo.sh
  packaging/apt/verify-public-tree.sh
  packaging/apt/verify-repo.sh
  packaging/apt/verify-signed-repo.sh
  packaging/verify-publication-urls.sh
  packaging/fedora/README.org
  packaging/fedora/build-rpm.sh
  packaging/fedora/container-gate.sh
  packaging/fedora/dnf-smoke.sh
  packaging/fedora/make-repo.sh
  packaging/fedora/make-source.sh
  packaging/fedora/nelix.spec
  packaging/fedora/publish-static.sh
  packaging/fedora/public-url-smoke.sh
  packaging/fedora/rpmlint.sh
  packaging/fedora/verify-public-tree.sh
  packaging/fedora/verify-source.sh
  packaging/run-autopkgtest-debian.sh
  packaging/verify-extracted-nelix-debian.sh
  packaging/verify-installed-nelix-cli-gate.sh
  packaging/verify-installed-nelix-debian.sh
  packaging/verify-nelix-user-manifest-dsl.sh
  packaging/verify-nelix-aot-cache-gate.sh
  packaging/verify-nelix-native-cli-gate.sh
  packaging/verify-nelix-user-environment.sh
)

usage() {
  cat <<'EOF'
usage: tools/nelix-release-scope-stage.sh [--dry-run|--stage|--status] [GROUP...]

Groups:
  A, compat      compatibility rename and shared tests
  B, nelix       Nelix manifest, lock, native store, and CLI
  C, docs        design docs
  D, debian      Debian and repository publication
  all            all groups

Default mode is --dry-run.  --stage runs git add for the selected groups and
refuses to run when the index already contains staged changes, unless
NELIX_RELEASE_SCOPE_ALLOW_DIRTY_INDEX=1 is set.  --status prints the current
modified/untracked paths by commit group without touching the index.
EOF
}

paths_for_group() {
  case "$1" in
    A|a|compat) printf '%s\0' "${commit_a[@]}" ;;
    B|b|nelix) printf '%s\0' "${commit_b[@]}" ;;
    C|c|docs) printf '%s\0' "${commit_c[@]}" ;;
    D|d|debian|packaging) printf '%s\0' "${commit_d[@]}" ;;
    *)
      printf 'nelix release scope stage: unknown group: %s\n' "$1" >&2
      exit 64
      ;;
  esac
}

label_for_group() {
  case "$1" in
    A|a|compat) printf 'Commit A - compatibility rename and shared tests' ;;
    B|b|nelix) printf 'Commit B - Nelix manifest, native store, and CLI' ;;
    C|c|docs) printf 'Commit C - design docs' ;;
    D|d|debian|packaging) printf 'Commit D - Debian and repository publication' ;;
  esac
}

run_group() {
  local group="$1"
  local label
  local -a paths=()
  label="$(label_for_group "$group")"
  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < <(paths_for_group "$group")

  printf '== %s ==\n' "$label"
  if [ "$mode" = stage ]; then
    git add -- "${paths[@]}"
    git diff --cached --name-status -- "${paths[@]}"
  else
    git add -n -- "${paths[@]}"
  fi
  printf '\n'
}

ensure_stage_index_is_clean() {
  if [ "${NELIX_RELEASE_SCOPE_ALLOW_DIRTY_INDEX:-0}" = 1 ]; then
    return 0
  fi
  if ! git diff --cached --quiet --exit-code; then
    printf 'nelix release scope stage: index already has staged changes; commit, unstage, or set NELIX_RELEASE_SCOPE_ALLOW_DIRTY_INDEX=1\n' >&2
    git diff --cached --name-status >&2
    exit 65
  fi
}

group_key() {
  case "$1" in
    A|a|compat) printf 'A' ;;
    B|b|nelix) printf 'B' ;;
    C|c|docs) printf 'C' ;;
    D|d|debian|packaging) printf 'D' ;;
    *)
      printf 'nelix release scope stage: unknown group: %s\n' "$1" >&2
      exit 64
      ;;
  esac
}

path_in_array() {
  local needle="$1"
  shift
  local path
  for path in "$@"; do
    if [ "$path" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

group_for_path() {
  local path="$1"
  if path_in_array "$path" "${commit_a[@]}"; then
    printf 'A'
  elif path_in_array "$path" "${commit_b[@]}"; then
    printf 'B'
  else
    case "$path" in
      test/fixtures/nelix-registry/*)
        printf 'B'
        return 0
        ;;
    esac
    if path_in_array "$path" "${commit_c[@]}"; then
      printf 'C'
    elif path_in_array "$path" "${commit_d[@]}"; then
      printf 'D'
    else
      printf '?'
    fi
  fi
}

status_selected() {
  local key="$1"
  shift
  local selected
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  for selected in "$@"; do
    if [ "$(group_key "$selected")" = "$key" ]; then
      return 0
    fi
  done
  return 1
}

print_status_group() {
  local title="$1"
  local file="$2"
  local count
  count="$(wc -l <"$file" | tr -d ' ')"
  printf '== %s ==\n' "$title"
  printf 'count: %s\n' "$count"
  if [ "$count" -gt 0 ]; then
    sed 's/^/  /' "$file"
  fi
  printf '\n'
}

run_status() {
  local tmp
  local path
  local group
  local classified_count
  local ignored_count
  local staged_count
  local unclassified_count

  tmp="$(mktemp -d)"
  : >"$tmp/A"
  : >"$tmp/B"
  : >"$tmp/C"
  : >"$tmp/D"
  : >"$tmp/staged"
  : >"$tmp/ignored"
  : >"$tmp/unclassified"

  while IFS= read -r -d '' path; do
    group="$(group_for_path "$path")"
    case "$group" in
      A|B|C|D)
        if status_selected "$group" "$@"; then
          printf '%s\n' "$path" >>"$tmp/$group"
        fi
        ;;
      *)
        printf '%s\n' "$path" >>"$tmp/unclassified"
        ;;
    esac
  done < <(git ls-files -z --modified --deleted --others --exclude-standard)

  while IFS= read -r -d '' path; do
    printf '%s\n' "$path" >>"$tmp/staged"
  done < <(git diff --cached --name-only -z)

  while IFS= read -r -d '' path; do
    printf '%s\n' "$path" >>"$tmp/ignored"
  done < <(git ls-files -z --others -i --exclude-standard)

  for group in A B C D staged ignored unclassified; do
    sort -o "$tmp/$group" "$tmp/$group"
  done

  if status_selected A "$@"; then
    print_status_group "Commit A - compatibility rename and shared tests" "$tmp/A"
  fi
  if status_selected B "$@"; then
    print_status_group "Commit B - Nelix manifest, native store, and CLI" "$tmp/B"
  fi
  if status_selected C "$@"; then
    print_status_group "Commit C - design docs" "$tmp/C"
  fi
  if status_selected D "$@"; then
    print_status_group "Commit D - Debian and repository publication" "$tmp/D"
  fi

  classified_count="$(( $(wc -l <"$tmp/A") + $(wc -l <"$tmp/B") + $(wc -l <"$tmp/C") + $(wc -l <"$tmp/D") ))"
  ignored_count="$(wc -l <"$tmp/ignored" | tr -d ' ')"
  staged_count="$(wc -l <"$tmp/staged" | tr -d ' ')"
  unclassified_count="$(wc -l <"$tmp/unclassified" | tr -d ' ')"

  printf '== Summary ==\n'
  printf 'classified-changed: %s\n' "$classified_count"
  printf 'unclassified-changed: %s\n' "$unclassified_count"
  printf 'staged: %s\n' "$staged_count"
  printf 'ignored-untracked: %s\n' "$ignored_count"

  if [ "$unclassified_count" -gt 0 ]; then
    printf '\n== Unclassified ==\n'
    sed 's/^/  /' "$tmp/unclassified"
  fi
  if [ "$staged_count" -gt 0 ]; then
    printf '\n== Staged ==\n'
    sed 's/^/  /' "$tmp/staged"
  fi

  rm -rf "$tmp"
}

mode=dry-run
groups=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n)
      mode=dry-run
      ;;
    --stage)
      mode=stage
      ;;
    --status)
      mode=status
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    all|--all)
      groups=(A B C D)
      ;;
    *)
      groups+=("$1")
      ;;
  esac
  shift
done

if [ "${#groups[@]}" -eq 0 ]; then
  groups=(A B C D)
fi

if [ "$mode" = status ]; then
  run_status "${groups[@]}"
  exit 0
fi

if [ "$mode" = stage ]; then
  ensure_stage_index_is_clean
fi

for group in "${groups[@]}"; do
  run_group "$group"
done
