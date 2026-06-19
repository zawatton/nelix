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

run_nelix_runtime() {
  local label="$1"
  local runtime="$2"
  shift 2
  local out_file="$TMP_DIR/$label.out"
  local err_file="$TMP_DIR/$label.err"
  set +e
  env \
    "PATH=$TMP_DIR/bin:$PATH" \
    "HOME=$TMP_DIR/home" \
    "XDG_STATE_HOME=$TMP_DIR/state" \
    "NELIX_LISPDIR=$REPO_ROOT" \
    "NELIX_RUNTIME=$runtime" \
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

expect_out_any() {
  local label="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -Eq "$pattern" "$TMP_DIR/$label.out"; then
      return 0
    fi
  done
  echo "nelix_lock_gate_fail label=$label reason=missing-output-any patterns=$*" >&2
  sed 's/^/nelix_lock_gate_stdout /' "$TMP_DIR/$label.out" >&2
  sed 's/^/nelix_lock_gate_stderr /' "$TMP_DIR/$label.err" >&2
  exit 1
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

latest_transaction_record() {
  local txn_dir="$TMP_DIR/state/nelix/transactions"
  if ! ls -t "$txn_dir"/apply-*.el >/dev/null 2>&1; then
    echo "nelix_lock_gate_fail reason=missing-transaction-record dir=$txn_dir" >&2
    exit 1
  fi
  ls -t "$txn_dir"/apply-*.el | head -n 1
}

transaction_record_count() {
  local txn_dir="$TMP_DIR/state/nelix/transactions"
  if [ ! -d "$txn_dir" ]; then
    printf '0\n'
  else
    find "$txn_dir" -maxdepth 1 -type f -name 'apply-*.el' | wc -l
  fi
}

assert_transaction_record_count() {
  local label="$1"
  local expected="$2"
  local actual
  actual="$(transaction_record_count)"
  if [ "$actual" -ne "$expected" ]; then
    echo "nelix_lock_gate_fail label=$label reason=transaction-record-count expected=$expected actual=$actual" >&2
    find "$TMP_DIR/state/nelix/transactions" -maxdepth 1 -type f -name 'apply-*.el' -print 2>/dev/null >&2 || true
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

dry_run_record_count_before="$(transaction_record_count)"
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
assert_transaction_record_count plan "$dry_run_record_count_before"

: >"$FAKE_LOG"
run_nelix dry_run --json apply "$MANIFEST" --dry-run
expect_out dry_run '"status":"dry-run"'
expect_out dry_run '"name":"ripgrep"'
expect_out dry_run '"name":"bat"'
expect_out dry_run '"remove-safety":'
expect_out dry_run '"remove-count":1'
reject_log 'profile install'
reject_log 'profile remove'
assert_transaction_record_count apply-dry-run "$dry_run_record_count_before"

: >"$FAKE_LOG"
run_nelix locked_dry_run --json apply "$MANIFEST" --locked --dry-run
expect_out locked_dry_run '"status":"dry-run"'
expect_out locked_dry_run '"locked":true'
expect_out locked_dry_run '"lock-enforced":true'
expect_out locked_dry_run '"lock-check":'
expect_out locked_dry_run '"locked-installed":'
reject_log 'profile install'
reject_log 'profile remove'
assert_transaction_record_count locked-apply-dry-run "$dry_run_record_count_before"

: >"$FAKE_LOG"
run_nelix locked_apply --json apply "$MANIFEST" --locked --allow-remove-count 1
expect_out locked_apply '"status":"ok"'
expect_out locked_apply '"locked":true'
expect_out locked_apply '"lock-enforced":true'
expect_out locked_apply '"installed":\["ripgrep","fd"\]'
expect_out locked_apply '"removed":\["bat"\]'
expect_log 'profile install --profile .+nixpkgs#ripgrep'
expect_log 'profile install --profile .+nixpkgs#fd'
expect_log 'profile remove bat --profile '
expect_log 'profile history --json --profile '

ok_record="$(latest_transaction_record)"
run_nelix transaction_list --json transaction list --limit 5
expect_out transaction_list '"operation":"transaction-list"'
expect_out transaction_list '"rollback-available":true'
expect_out transaction_list '"status":"ok"'
expect_out transaction_list '"command-count":3'
expect_out transaction_list '"executed-count":3'
run_nelix transaction_show_ok --json transaction show "$ok_record"
expect_out transaction_show_ok '"operation":"transaction-show"'
expect_out transaction_show_ok '"schema":"nelix-apply-transaction"'
expect_out transaction_show_ok '"schema-version":1'
expect_out transaction_show_ok '"status":"ok"'
expect_out transaction_show_ok '"rollback-plan":'
expect_out transaction_show_ok '"available":true'
expect_out transaction_show_ok '"executed":'
expect_out_any transaction_show_ok \
  '"action":"install","name":"ripgrep"' \
  '"name":"ripgrep","action":"install"'
expect_out_any transaction_show_ok \
  '"action":"remove","name":"bat"' \
  '"name":"bat","action":"remove"'
run_nelix_runtime transaction_show_ok_emacs emacs --json transaction show "$ok_record"
expect_out transaction_show_ok_emacs '"operation":"transaction-show"'
expect_out transaction_show_ok_emacs '"schema":"nelix-apply-transaction"'
expect_out transaction_show_ok_emacs '"schema-version":1'
expect_out transaction_show_ok_emacs '"status":"ok"'

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
expect_out_any rollback_on_failure '"status":"error"' '^nelix: nelix-apply: command failed'
expect_out rollback_on_failure 'rollback=ok'
expect_log 'profile rollback --profile .+ --to-generation 7'

error_record="$(latest_transaction_record)"
run_nelix transaction_show_error --json transaction show "$error_record"
expect_out transaction_show_error '"operation":"transaction-show"'
expect_out transaction_show_error '"schema":"nelix-apply-transaction"'
expect_out transaction_show_error '"status":"error"'
expect_out transaction_show_error '"executed":'
expect_out_any transaction_show_error \
  '"action":"install","name":"ripgrep"' \
  '"name":"ripgrep","action":"install"'
expect_out transaction_show_error '"rollback":'
expect_out transaction_show_error '"attempted":true'
expect_out transaction_show_error '"ok":true'
expect_out transaction_show_error '"verified":true'
expect_out transaction_show_error '"rollback-plan":'
expect_out transaction_show_error '"generation":7'
run_nelix_runtime transaction_show_error_emacs emacs --json transaction show "$error_record"
expect_out transaction_show_error_emacs '"operation":"transaction-show"'
expect_out transaction_show_error_emacs '"schema":"nelix-apply-transaction"'
expect_out transaction_show_error_emacs '"status":"error"'
run_nelix transaction_recover_error --json transaction recover "$error_record" --dry-run
expect_out transaction_recover_error '"operation":"transaction-recover"'
expect_out transaction_recover_error '"dry-run":true'
expect_out transaction_recover_error '"record-status":"error"'
expect_out transaction_recover_error '"generation":7'
expect_out transaction_recover_error '"manual-command":\["rollback","7"\]'
run_nelix_runtime transaction_recover_error_emacs emacs --json transaction recover "$error_record" --dry-run
expect_out transaction_recover_error_emacs '"operation":"transaction-recover"'
expect_out transaction_recover_error_emacs '"record-status":"error"'
expect_out transaction_recover_error_emacs '"manual-command":\["rollback","7"\]'

: >"$FAKE_LOG"
run_nelix transaction_recover_execute --json transaction recover "$error_record" --execute
expect_out transaction_recover_execute '"operation":"transaction-recover"'
expect_out transaction_recover_execute '"execute":true'
expect_out transaction_recover_execute '"record-status":"error"'
expect_out transaction_recover_execute '"rollback":'
expect_out transaction_recover_execute '"attempted":true'
expect_out transaction_recover_execute '"ok":true'
expect_out transaction_recover_execute '"verified":true'
expect_log 'profile rollback --profile .+ --to-generation 7'

run_nelix_expect_fail transaction_recover_ok_execute --json transaction recover "$ok_record" --execute
expect_out_any transaction_recover_ok_execute '"status":"error"' '^nelix:'
expect_out transaction_recover_ok_execute 'refusing to rollback successful transaction'

echo "nelix_lock_gate_result label=nelix_lock_plan_apply_gate rc=0"
