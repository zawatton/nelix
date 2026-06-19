#!/usr/bin/env bash
# Verify the installed /usr/bin/nelix CLI can run lock/plan/apply.
set -euo pipefail

if [ ! -x /usr/bin/nelix ]; then
  echo "installed nelix CLI is missing: /usr/bin/nelix" >&2
  exit 1
fi

tmp="$(mktemp -d)"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/home" "$tmp/state"
manifest="$tmp/manifest.el"
fake_nix="$tmp/bin/nix"
fake_log="$tmp/fake-nix.log"

cat >"$manifest" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "installed-cli-gate"
 :linux '("magit" "ripgrep" "fd")
 :pins '("ripgrep"))
EOF

cat >"$fake_nix" <<'EOF'
#!/bin/sh
log=${NELIX_FAKE_NIX_LOG:?}
printf '%s\n' "$*" >>"$log"

case " $* " in
  *" --version "*)
    printf 'nix (Nix) 2.34.7\n'
    exit 0
    ;;
  *" profile list "*)
    case " $* " in
      *" --json "*)
        printf '%s\n' '{"elements":{"magit":{"attrPath":"legacyPackages.x86_64-linux.magit","originalUrl":"flake:nixpkgs","storePaths":["/nix/store/magit"]},"bat":{"attrPath":"legacyPackages.x86_64-linux.bat","originalUrl":"flake:nixpkgs","storePaths":["/nix/store/bat"]}}}'
        ;;
      *)
        printf 'Name: magit\nName: bat\n'
        ;;
    esac
    exit 0
    ;;
  *" profile history "*)
    printf '%s\n' '{"generations":[{"id":7,"date":"2026-06-19T00:00:00Z","packages":["magit","bat"],"active":true}]}'
    exit 0
    ;;
  *" profile install "*)
    if [ -n "${NELIX_FAKE_NIX_FAIL_TARGET:-}" ]; then
      case " $* " in
        *"$NELIX_FAKE_NIX_FAIL_TARGET"*)
          printf 'fake nix: requested install failure for %s\n' "$NELIX_FAKE_NIX_FAIL_TARGET" >&2
          exit 42
          ;;
      esac
    fi
    exit 0
    ;;
  *" profile remove "*)
    exit 0
    ;;
  *" profile rollback "*)
    exit 0
    ;;
esac

printf 'fake nix: unsupported %s\n' "$*" >&2
exit 2
EOF
chmod +x "$fake_nix"

run_json() {
  label="$1"
  shift
  out="$tmp/$label.json"
  err="$tmp/$label.err"
  if ! env \
      "PATH=$tmp/bin:$PATH" \
      "HOME=$tmp/home" \
      "XDG_STATE_HOME=$tmp/state" \
      "NELIX_FAKE_NIX_LOG=$fake_log" \
      /usr/bin/nelix --json "$@" >"$out" 2>"$err"; then
    sed 's/^/nelix_installed_cli_stdout /' "$out" >&2
    sed 's/^/nelix_installed_cli_stderr /' "$err" >&2
    exit 1
  fi
}

expect_json() {
  label="$1"
  pattern="$2"
  if ! grep -Eq "$pattern" "$tmp/$label.json"; then
    echo "nelix installed CLI gate missing pattern: label=$label pattern=$pattern" >&2
    sed 's/^/nelix_installed_cli_stdout /' "$tmp/$label.json" >&2
    sed 's/^/nelix_installed_cli_stderr /' "$tmp/$label.err" >&2
    exit 1
  fi
}

expect_log() {
  pattern="$1"
  if ! grep -Eq "$pattern" "$fake_log"; then
    echo "nelix installed CLI gate missing fake nix log pattern: $pattern" >&2
    sed 's/^/nelix_installed_cli_log /' "$fake_log" >&2
    exit 1
  fi
}

reject_log() {
  pattern="$1"
  if grep -Eq "$pattern" "$fake_log"; then
    echo "nelix installed CLI gate unexpected fake nix log pattern: $pattern" >&2
    sed 's/^/nelix_installed_cli_log /' "$fake_log" >&2
    exit 1
  fi
}

/usr/bin/nelix --help | grep -Fq 'registry list [--system SYSTEM]' || {
  echo "nelix installed CLI gate: help omits registry list command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'native remove NAME [--profile PROFILE] [--system SYSTEM]' || {
  echo "nelix installed CLI gate: help omits native remove command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'native rollback [--profile PROFILE] [--generation GENERATION]' || {
  echo "nelix installed CLI gate: help omits native rollback command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'schema [manifest-dsl-v1|lock-v2|all]' || {
  echo "nelix installed CLI gate: help omits schema command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'lock-check MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock-check command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'lock validate MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock validate command" >&2
  exit 1
}
/usr/bin/nelix --help | grep -Fq 'lock diff MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock diff command" >&2
  exit 1
}

run_json schema_all schema
expect_json schema_all '"name":"manifest-dsl-v1"'
expect_json schema_all '"schema":"nelix-environment"'
expect_json schema_all '"schema-version":1'
expect_json schema_all '"name":"lock-v2"'
expect_json schema_all '"schema":"nelix-lock"'
expect_json schema_all '"schema-version":2'
expect_json schema_all '"required":\['

run_json schema_manifest schema manifest-dsl-v1
expect_json schema_manifest '"name":"manifest-dsl-v1"'
expect_json schema_manifest '"forms":\['
expect_json schema_manifest '"emacs-packages"'

run_json packaged_registry registry list --system x86_64-linux
expect_json packaged_registry '"operation":"registry-list"'
expect_json packaged_registry '"name":"curl"'
expect_json packaged_registry '"name":"fd"'
expect_json packaged_registry '"name":"git"'
expect_json packaged_registry '"name":"jq"'
expect_json packaged_registry '"name":"ripgrep"'
expect_json packaged_registry '"name":"tree"'

run_json validate validate "$manifest"
expect_json validate '"ok":true'

run_json lock lock "$manifest"
test -f "$manifest.nelix-lock" || {
  echo "nelix installed CLI gate did not create lock: $manifest.nelix-lock" >&2
  exit 1
}
expect_json lock '"lock":'
expect_json lock '"schema":"nelix-lock"'
expect_json lock '"schema-version":2'

run_json lock_validate lock validate "$manifest"
expect_json lock_validate '"ok":true'
expect_json lock_validate '"format":"sexp"'
expect_json lock_validate '"schema-version":2'

run_json lock_diff lock diff "$manifest"
expect_json lock_diff '"ok":true'
expect_json lock_diff '"status":"clean"'
expect_json lock_diff '"manifest-digest":'

run_json lock_check lock-check "$manifest"
expect_json lock_check '"ok":true'
expect_json lock_check '"schema-check":'
expect_json lock_check '"schema-version":2'

run_json plan plan "$manifest" --dry-run
expect_json plan '"status":"planned"'
expect_json plan '"action":"install"'
expect_json plan '"name":"ripgrep"'
expect_json plan '"action":"remove"'
expect_json plan '"name":"bat"'

run_json dry_run apply "$manifest" --dry-run
expect_json dry_run '"status":"dry-run"'
expect_json dry_run '"transaction":'
expect_json dry_run '"rollback-on-error":true'
reject_log 'profile install'
reject_log 'profile remove'

: >"$fake_log"
run_json locked_dry_run apply "$manifest" --locked --dry-run
expect_json locked_dry_run '"status":"dry-run"'
expect_json locked_dry_run '"locked":true'
expect_json locked_dry_run '"lock-enforced":true'
expect_json locked_dry_run '"lock-check":'
expect_json locked_dry_run '"locked-installed":'
reject_log 'profile install'
reject_log 'profile remove'

: >"$fake_log"
run_json locked_apply apply "$manifest" --locked --allow-remove-count 1
expect_json locked_apply '"status":"ok"'
expect_json locked_apply '"locked":true'
expect_json locked_apply '"lock-enforced":true'
expect_json locked_apply '"installed":\["ripgrep","fd"\]'
expect_json locked_apply '"removed":\["bat"\]'
expect_log 'profile install --profile .+nixpkgs#ripgrep'
expect_log 'profile install --profile .+nixpkgs#fd'
expect_log 'profile remove bat --profile '
expect_log 'profile history --json --profile '

NELIX_BIN=/usr/bin/nelix bash "$script_dir/verify-nelix-native-cli-gate.sh"
NELIX_BIN=/usr/bin/nelix bash "$script_dir/verify-nelix-aot-cache-gate.sh"

echo "nelix installed CLI gate ok"
