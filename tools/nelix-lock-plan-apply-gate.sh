#!/usr/bin/env bash
# Gate for minimal Nelix lock -> plan -> apply flow using a fake Nix backend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/state" "$TMP_DIR/profile"

MANIFEST="$TMP_DIR/manifest.el"
FAKE_NIX="$TMP_DIR/bin/nix"
FAKE_LOG="$TMP_DIR/fake-nix.log"

cat >"$MANIFEST" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "default"
 :linux '("magit" "ripgrep" "fd")
 :pins '("ripgrep"))
EOF

cat >"$FAKE_NIX" <<'EOF'
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
chmod +x "$FAKE_NIX"

run_nelix() {
  local label="$1"
  shift
  local out_file="$TMP_DIR/$label.out"
  local err_file="$TMP_DIR/$label.err"
  set +e
  env \
    "PATH=$TMP_DIR/bin:$PATH" \
    "HOME=$TMP_DIR/home" \
    "XDG_STATE_HOME=$TMP_DIR/state" \
    "NELIX_LISPDIR=$REPO_ROOT" \
    "NELIX_FAKE_NIX_LOG=$FAKE_LOG" \
    "$REPO_ROOT/bin/nelix" "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  printf 'nelix_lock_gate_result label=%s rc=%s\n' "$label" "$rc"
  if [ "$rc" -ne 0 ]; then
    sed 's/^/nelix_lock_gate_stdout /' "$out_file" >&2
    sed 's/^/nelix_lock_gate_stderr /' "$err_file" >&2
    exit "$rc"
  fi
}

run_nelix_expect_fail() {
  local label="$1"
  shift
  local out_file="$TMP_DIR/$label.out"
  local err_file="$TMP_DIR/$label.err"
  set +e
  env \
    "PATH=$TMP_DIR/bin:$PATH" \
    "HOME=$TMP_DIR/home" \
    "XDG_STATE_HOME=$TMP_DIR/state" \
    "NELIX_LISPDIR=$REPO_ROOT" \
    "NELIX_FAKE_NIX_LOG=$FAKE_LOG" \
    "$REPO_ROOT/bin/nelix" "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  printf 'nelix_lock_gate_result label=%s rc=%s\n' "$label" "$rc"
  if [ "$rc" -eq 0 ]; then
    sed 's/^/nelix_lock_gate_stdout /' "$out_file" >&2
    sed 's/^/nelix_lock_gate_stderr /' "$err_file" >&2
    echo "nelix_lock_gate_fail label=$label reason=expected-failure" >&2
    exit 1
  fi
}

expect_out() {
  local label="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$TMP_DIR/$label.out"; then
    echo "nelix_lock_gate_fail label=$label reason=missing-output pattern=$pattern" >&2
    sed 's/^/nelix_lock_gate_stdout /' "$TMP_DIR/$label.out" >&2
    sed 's/^/nelix_lock_gate_stderr /' "$TMP_DIR/$label.err" >&2
    exit 1
  fi
}

expect_log() {
  local pattern="$1"
  if ! grep -Eq "$pattern" "$FAKE_LOG"; then
    echo "nelix_lock_gate_fail reason=missing-nix-log pattern=$pattern" >&2
    sed 's/^/nelix_lock_gate_log /' "$FAKE_LOG" >&2
    exit 1
  fi
}

reject_log() {
  local pattern="$1"
  if grep -Eq "$pattern" "$FAKE_LOG"; then
    echo "nelix_lock_gate_fail reason=unexpected-nix-log pattern=$pattern" >&2
    sed 's/^/nelix_lock_gate_log /' "$FAKE_LOG" >&2
    exit 1
  fi
}

run_nelix lock --json lock "$MANIFEST"
LOCK_FILE="$MANIFEST.nelix-lock"
test -f "$LOCK_FILE" || {
  echo "nelix_lock_gate_fail reason=missing-lock path=$LOCK_FILE" >&2
  exit 1
}
grep -q ':resolved-target "ripgrep"' "$LOCK_FILE"
grep -q ':installed-name "magit"' "$LOCK_FILE"
grep -q ':pinned t' "$LOCK_FILE"
expect_out lock '"lock":'
expect_out lock '"packages":'
expect_out lock '"schema":"nelix-lock"'
expect_out lock '"schema-version":2'

run_nelix plan --json plan "$MANIFEST"
expect_out plan '"status":"planned"'
expect_out plan '"lock-present":true'
expect_out plan '"action":"install"'
expect_out plan '"name":"ripgrep"'
expect_out plan '"name":"fd"'
expect_out plan '"action":"remove"'
expect_out plan '"name":"bat"'
expect_out plan '"profile","install","--profile"'
expect_out plan '"profile","remove","bat"'

: >"$FAKE_LOG"
run_nelix dry_run --json apply "$MANIFEST" --dry-run
expect_out dry_run '"status":"dry-run"'
expect_out dry_run '"name":"ripgrep"'
expect_out dry_run '"name":"bat"'
expect_out dry_run '"remove-safety":'
expect_out dry_run '"remove-count":1'
reject_log 'profile install'
reject_log 'profile remove'

: >"$FAKE_LOG"
run_nelix apply --json apply "$MANIFEST" --allow-remove-count 1
expect_out apply '"status":"ok"'
expect_out apply '"installed":\["ripgrep","fd"\]'
expect_out apply '"removed":\["bat"\]'
expect_log 'profile install --profile .+nixpkgs#ripgrep'
expect_log 'profile install --profile .+nixpkgs#fd'
expect_log 'profile remove bat --profile '
expect_log 'profile history --json --profile '

: >"$FAKE_LOG"
NELIX_FAKE_NIX_FAIL_TARGET='nixpkgs#fd' run_nelix_expect_fail rollback_on_failure --json apply "$MANIFEST" --allow-remove-count 1
expect_out rollback_on_failure '"status":"error"'
expect_out rollback_on_failure 'rollback=ok'
expect_log 'profile rollback --profile .+ --to-generation 7'

echo "nelix_lock_gate_result label=nelix_lock_plan_apply_gate rc=0"
