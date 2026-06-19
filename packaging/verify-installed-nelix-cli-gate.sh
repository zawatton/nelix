#!/usr/bin/env bash
# Verify an installed nelix CLI can run lock/plan/apply.
set -euo pipefail

nelix_bin=${NELIX_BIN:-/usr/bin/nelix}

if [ ! -x "$nelix_bin" ]; then
  echo "installed nelix CLI is missing: $nelix_bin" >&2
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
      "$nelix_bin" --json "$@" >"$out" 2>"$err"; then
    sed 's/^/nelix_installed_cli_stdout /' "$out" >&2
    sed 's/^/nelix_installed_cli_stderr /' "$err" >&2
    exit 1
  fi
}

run_failing_json() {
  label="$1"
  fail_target="$2"
  shift 2
  out="$tmp/$label.json"
  err="$tmp/$label.err"
  set +e
  env \
    "PATH=$tmp/bin:$PATH" \
    "HOME=$tmp/home" \
    "XDG_STATE_HOME=$tmp/state" \
    "NELIX_FAKE_NIX_LOG=$fake_log" \
    "NELIX_FAKE_NIX_FAIL_TARGET=$fail_target" \
    "$nelix_bin" --json "$@" >"$out" 2>"$err"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "nelix installed CLI gate expected failure but command succeeded: label=$label" >&2
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

lock_schema_file() {
  if [ -f "$script_dir/../schema/nelix-lock-v2.schema.json" ]; then
    printf '%s\n' "$script_dir/../schema/nelix-lock-v2.schema.json"
  elif [ -f "$script_dir/../docs/schema/nelix-lock-v2.schema.json" ]; then
    printf '%s\n' "$script_dir/../docs/schema/nelix-lock-v2.schema.json"
  else
    echo "nelix installed CLI gate: lock v2 JSON schema file is missing" >&2
    exit 1
  fi
}

manifest_dsl_schema_file() {
  if [ -f "$script_dir/../schema/nelix-manifest-dsl-v1.schema.json" ]; then
    printf '%s\n' "$script_dir/../schema/nelix-manifest-dsl-v1.schema.json"
  elif [ -f "$script_dir/../docs/schema/nelix-manifest-dsl-v1.schema.json" ]; then
    printf '%s\n' "$script_dir/../docs/schema/nelix-manifest-dsl-v1.schema.json"
  else
    echo "nelix installed CLI gate: manifest DSL v1 JSON schema file is missing" >&2
    exit 1
  fi
}

transaction_schema_file() {
  if [ -f "$script_dir/../schema/nelix-transaction-v1.schema.json" ]; then
    printf '%s\n' "$script_dir/../schema/nelix-transaction-v1.schema.json"
  elif [ -f "$script_dir/../docs/schema/nelix-transaction-v1.schema.json" ]; then
    printf '%s\n' "$script_dir/../docs/schema/nelix-transaction-v1.schema.json"
  else
    echo "nelix installed CLI gate: transaction v1 JSON schema file is missing" >&2
    exit 1
  fi
}

validate_lock_json_schema_smoke() {
  schema_file="$(lock_schema_file)"
  lock_json="$tmp/lock.json"
  emacs -Q --batch \
    --eval '(require (quote json))' \
    --eval '(let ((json-object-type (quote alist))
                  (json-array-type (quote list))
                  (json-key-type (quote string)))
              (let* ((args command-line-args-left)
                     (_ (when (equal (car args) "--")
                          (setq args (cdr args))))
                     (schema (json-read-file (car args)))
                     (lock (json-read-file (cadr args)))
                     (schema-properties (alist-get "properties" schema nil nil (function string=)))
                     (defs (alist-get "$defs" schema nil nil (function string=)))
                     (package-schema (alist-get "package" defs nil nil (function string=)))
                     (required (alist-get "required" schema nil nil (function string=)))
                     (package-required (alist-get "required" package-schema nil nil (function string=)))
                     (packages (alist-get "packages" lock nil nil (function string=))))
                (dolist (key required)
                  (unless (assoc key lock)
                    (error "lock JSON is missing schema-required key: %s" key)))
                (unless (equal (alist-get "const" (alist-get "schema" schema-properties nil nil (function string=)) nil nil (function string=))
                               (alist-get "schema" lock nil nil (function string=)))
                  (error "lock JSON schema const mismatch"))
                (unless (= (alist-get "const" (alist-get "schema-version" schema-properties nil nil (function string=)) nil nil (function string=))
                           (alist-get "schema-version" lock nil nil (function string=)))
                  (error "lock JSON schema-version const mismatch"))
                (unless (= (alist-get "const" (alist-get "version" schema-properties nil nil (function string=)) nil nil (function string=))
                           (alist-get "version" lock nil nil (function string=)))
                  (error "lock JSON version const mismatch"))
                (unless (equal (alist-get "const" (alist-get "format" schema-properties nil nil (function string=)) nil nil (function string=))
                               (alist-get "format" lock nil nil (function string=)))
                  (error "lock JSON format const mismatch"))
                (unless packages
                  (error "lock JSON packages must not be empty in installed CLI gate"))
                (dolist (package packages)
                  (dolist (key package-required)
                    (unless (assoc key package)
                      (error "lock JSON package is missing schema-required key: %s" key))))
                (princ "nelix installed CLI lock schema smoke ok\n")))' \
    -- "$schema_file" "$lock_json"
}

validate_schema_summary_contract() {
  label="$1"
  schema_file="$(lock_schema_file)"
  schema_summary="$tmp/$label.json"
  emacs -Q --batch \
    --eval '(require (quote cl-lib))' \
    --eval '(require (quote json))' \
    --eval '(let ((json-object-type (quote alist))
                  (json-array-type (quote list))
                  (json-key-type (quote string)))
              (cl-labels ((jget (key object)
                            (alist-get key object nil nil (function string=)))
                          (sorted (items)
                            (sort (copy-sequence items) (function string<))))
                (let* ((args command-line-args-left)
                       (_ (when (equal (car args) "--")
                            (setq args (cdr args))))
                       (schema (json-read-file (car args)))
                       (summary (json-read-file (cadr args)))
                       (schema-properties (jget "properties" schema))
                       (defs (jget "$defs" schema))
                       (package-schema (jget "package" defs))
                       (schema-required (jget "required" schema))
                       (schema-package-required (jget "required" package-schema))
                       (summary-required (jget "required" summary))
                       (summary-package-required
                        (jget "package-required" summary)))
                  (unless (equal (jget "const" (jget "schema" schema-properties))
                                 (jget "schema" summary))
                    (error "schema summary name differs from JSON schema"))
                  (unless (= (jget "const" (jget "schema-version" schema-properties))
                             (jget "schema-version" summary))
                    (error "schema summary schema-version differs from JSON schema"))
                  (unless (= (jget "const" (jget "version" schema-properties))
                             (jget "version" summary))
                    (error "schema summary version differs from JSON schema"))
                  (unless (equal (jget "const" (jget "format" schema-properties))
                                 (jget "format" summary))
                    (error "schema summary format differs from JSON schema"))
                  (unless (equal (sorted schema-required)
                                 (sorted summary-required))
                    (error "schema summary required keys differ from JSON schema"))
                  (unless (equal (sorted schema-package-required)
                                 (sorted summary-package-required))
                    (error "schema summary package-required keys differ from JSON schema"))
                  (princ "nelix installed CLI schema summary matches JSON schema\n"))))' \
    -- "$schema_file" "$schema_summary"
}

validate_manifest_dsl_schema_summary_contract() {
  schema_file="$(manifest_dsl_schema_file)"
  schema_summary="$tmp/schema_manifest.json"
  emacs -Q --batch \
    --eval '(require (quote cl-lib))' \
    --eval '(require (quote json))' \
    --eval '(let ((json-object-type (quote alist))
                  (json-array-type (quote list))
                  (json-key-type (quote string)))
              (cl-labels ((jget (key object)
                            (alist-get key object nil nil (function string=)))
                          (sorted (items)
                            (sort (copy-sequence items) (function string<))))
                (let* ((args command-line-args-left)
                       (_ (when (equal (car args) "--")
                            (setq args (cdr args))))
                       (schema (json-read-file (car args)))
                       (summary (json-read-file (cadr args)))
                       (schema-properties (jget "properties" schema))
                       (required (jget "required" schema)))
                  (unless (equal (jget "const" (jget "name" schema-properties))
                                 (jget "name" summary))
                    (error "manifest DSL schema summary name differs from JSON schema"))
                  (unless (equal (jget "const" (jget "schema" schema-properties))
                                 (jget "schema" summary))
                    (error "manifest DSL schema summary schema differs from JSON schema"))
                  (unless (= (jget "const" (jget "schema-version" schema-properties))
                             (jget "schema-version" summary))
                    (error "manifest DSL schema summary schema-version differs from JSON schema"))
                  (unless (equal (jget "const" (jget "entrypoint" schema-properties))
                                 (jget "entrypoint" summary))
                    (error "manifest DSL schema summary entrypoint differs from JSON schema"))
                  (unless (equal (jget "const" (jget "json-schema" schema-properties))
                                 (jget "json-schema" summary))
                    (error "manifest DSL schema summary json-schema differs from JSON schema"))
                  (dolist (key required)
                    (unless (assoc key summary)
                      (error "manifest DSL schema summary is missing required key: %s" key)))
                  (dolist (key (quote ("forms" "manifest-keys" "backends"
                                       "package-forms" "package-options"
                                       "remove-policy-values" "deferred-forms"
                                       "forbidden-forms")))
                    (let* ((property (jget key schema-properties))
                           (items (jget "items" property))
                           (expected (jget "enum" items))
                           (actual (jget key summary)))
                      (unless (equal (sorted expected) (sorted actual))
                        (error "manifest DSL schema summary differs for %s" key))))
                  (princ "nelix installed CLI manifest DSL schema summary matches JSON schema\n"))))' \
    -- "$schema_file" "$schema_summary"
}

validate_transaction_schema_summary_contract() {
  schema_file="$(transaction_schema_file)"
  schema_summary="$tmp/schema_transaction.json"
  emacs -Q --batch \
    --eval '(require (quote cl-lib))' \
    --eval '(require (quote json))' \
    --eval '(let ((json-object-type (quote alist))
                  (json-array-type (quote list))
                  (json-key-type (quote string)))
              (cl-labels ((jget (key object)
                            (alist-get key object nil nil (function string=)))
                          (sorted (items)
                            (sort (copy-sequence items) (function string<))))
                (let* ((args command-line-args-left)
                       (_ (when (equal (car args) "--")
                            (setq args (cdr args))))
                       (schema (json-read-file (car args)))
                       (summary (json-read-file (cadr args)))
                       (schema-properties (jget "properties" schema))
                       (required (jget "required" schema)))
                  (unless (equal (jget "const" (jget "name" schema-properties))
                                 (jget "name" summary))
                    (error "transaction schema summary name differs from JSON schema"))
                  (unless (equal (jget "const" (jget "schema" schema-properties))
                                 (jget "schema" summary))
                    (error "transaction schema summary schema differs from JSON schema"))
                  (unless (= (jget "const" (jget "schema-version" schema-properties))
                             (jget "schema-version" summary))
                    (error "transaction schema summary schema-version differs from JSON schema"))
                  (unless (equal (jget "const" (jget "format" schema-properties))
                                 (jget "format" summary))
                    (error "transaction schema summary format differs from JSON schema"))
                  (unless (equal (jget "const" (jget "json-schema" schema-properties))
                                 (jget "json-schema" summary))
                    (error "transaction schema summary json-schema differs from JSON schema"))
                  (dolist (key required)
                    (unless (assoc key summary)
                      (error "transaction schema summary is missing required key: %s" key)))
                  (dolist (key (quote ("required" "plan-required"
                                       "transaction-required"
                                       "rollback-plan-required"
                                       "rollback-plan-available-required"
                                       "status-values"
                                       "rollback-plan-unavailable-reasons"
                                       "rollback-result-keys"
                                       "executed-required")))
                    (let* ((property (jget key schema-properties))
                           (items (jget "items" property))
                           (expected (jget "enum" items))
                           (actual (jget key summary)))
                      (unless (equal (sorted expected) (sorted actual))
                        (error "transaction schema summary differs for %s" key))))
                  (unless (equal (jget "const" (jget "recovery" schema-properties))
                                 (jget "recovery" summary))
                    (error "transaction schema summary recovery differs from JSON schema"))
                  (princ "nelix installed CLI transaction schema summary matches JSON schema\n"))))' \
    -- "$schema_file" "$schema_summary"
}

validate_plan_apply_dry_run_equivalence() {
  plan_json="$tmp/plan.json"
  dry_run_json="$tmp/dry_run.json"
  emacs -Q --batch \
    --eval '(require (quote cl-lib))' \
    --eval '(require (quote json))' \
    --eval '(let ((json-object-type (quote alist))
                  (json-array-type (quote list))
                  (json-key-type (quote string)))
              (cl-labels ((jget (key object)
                            (alist-get key object nil nil (function string=))))
                (let* ((args command-line-args-left)
                       (_ (when (equal (car args) "--")
                            (setq args (cdr args))))
                       (plan (json-read-file (car args)))
                       (dry-run (json-read-file (cadr args))))
                  (dolist (key (quote ("install" "remove" "keep" "protected"
                                       "commands" "count" "empty")))
                    (unless (equal (jget key plan) (jget key dry-run))
                      (error "plan/apply dry-run mismatch for %s" key)))
                  (princ "nelix installed CLI plan/apply dry-run equivalence ok\n"))))' \
    -- "$plan_json" "$dry_run_json"
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

expect_json_any() {
  label="$1"
  shift
  for pattern in "$@"; do
    if grep -Eq "$pattern" "$tmp/$label.json"; then
      return 0
    fi
  done
  echo "nelix installed CLI gate missing any pattern: label=$label patterns=$*" >&2
  sed 's/^/nelix_installed_cli_stdout /' "$tmp/$label.json" >&2
  sed 's/^/nelix_installed_cli_stderr /' "$tmp/$label.err" >&2
  exit 1
}

latest_transaction_record() {
  txn_dir="$tmp/state/nelix/transactions"
  if ! ls -t "$txn_dir"/apply-*.el >/dev/null 2>&1; then
    echo "nelix installed CLI gate missing transaction record: $txn_dir" >&2
    exit 1
  fi
  ls -t "$txn_dir"/apply-*.el | head -n 1
}

"$nelix_bin" --help | grep -Fq 'registry list [--system SYSTEM]' || {
  echo "nelix installed CLI gate: help omits registry list command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'native remove NAME [--profile PROFILE] [--system SYSTEM]' || {
  echo "nelix installed CLI gate: help omits native remove command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'native rollback [--profile PROFILE] [--generation GENERATION]' || {
  echo "nelix installed CLI gate: help omits native rollback command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'schema [manifest-dsl-v1|lock-v2|transaction-v1|all]' || {
  echo "nelix installed CLI gate: help omits schema command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'lock-check MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock-check command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'lock validate MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock validate command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'lock diff MANIFEST' || {
  echo "nelix installed CLI gate: help omits lock diff command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'lock migrate MANIFEST [--dry-run]' || {
  echo "nelix installed CLI gate: help omits lock migrate command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'transaction list [--limit N]' || {
  echo "nelix installed CLI gate: help omits transaction list command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'transaction show ID|FILE' || {
  echo "nelix installed CLI gate: help omits transaction show command" >&2
  exit 1
}
"$nelix_bin" --help | grep -Fq 'transaction recover ID|FILE --dry-run' || {
  echo "nelix installed CLI gate: help omits transaction recover command" >&2
  exit 1
}

run_json schema_all schema
expect_json schema_all '"name":"manifest-dsl-v1"'
expect_json schema_all '"schema":"nelix-environment"'
expect_json schema_all '"schema-version":1'
expect_json schema_all '"name":"lock-v2"'
expect_json schema_all '"schema":"nelix-lock"'
expect_json schema_all '"schema-version":2'
expect_json schema_all '"name":"transaction-v1"'
expect_json schema_all '"schema":"nelix-apply-transaction"'
expect_json schema_all '"schema-version":1'
expect_json schema_all '"required":\['

run_json schema_lock schema lock-v2
expect_json schema_lock '"name":"lock-v2"'
expect_json schema_lock '"schema":"nelix-lock"'
expect_json schema_lock '"schema-version":2'
expect_json schema_lock '"source-of-truth":"MANIFEST.nelix-lock"'
expect_json schema_lock '"json-output":"nelix --json lock MANIFEST"'
expect_json schema_lock '"commands":\['
expect_json schema_lock '"lock migrate"'
expect_json schema_lock '"compatibility":\['
expect_json schema_lock '"legacy-v1-readable-migrate-required"'
expect_json schema_lock '"future-version-rejected"'
expect_json schema_lock '"validation":"nelix lock validate MANIFEST"'
expect_json schema_lock '"diff":"nelix lock diff MANIFEST"'
expect_json schema_lock '"package-required":\['
validate_schema_summary_contract schema_lock

run_json schema_manifest schema manifest-dsl-v1
expect_json schema_manifest '"name":"manifest-dsl-v1"'
expect_json schema_manifest '"json-schema":"docs/schema/nelix-manifest-dsl-v1.schema.json"'
expect_json schema_manifest '"forms":\['
expect_json schema_manifest '"emacs-packages"'
expect_json schema_manifest '"package"'
expect_json schema_manifest '"linux-package"'
expect_json schema_manifest '"version-pin"'
expect_json schema_manifest '"form-map":\['
expect_json schema_manifest '"form":"linux-packages"'
expect_json schema_manifest '"manifest-key":"linux"'
expect_json schema_manifest '"backends":\['
expect_json schema_manifest '"dnf"'
expect_json schema_manifest '"nelix-native"'
expect_json schema_manifest '"backend-policy":"backend-symbols-or-os-rows"'
expect_json schema_manifest '"package-forms":\['
expect_json schema_manifest '"package-options":\['
expect_json schema_manifest '":backend"'
expect_json schema_manifest '":platform"'
expect_json schema_manifest '"package-row-semantics":"metadata-plus-target-list"'
expect_json schema_manifest '"version-pin":"metadata-plus-pin-name"'
expect_json schema_manifest '"remove-policy-values":\['
expect_json schema_manifest '"confirm"'
expect_json schema_manifest '"deferred-forms":\['
expect_json schema_manifest '"group"'
expect_json schema_manifest '"platform"'
expect_json schema_manifest '"forbidden-forms":\['
expect_json schema_manifest '"private-repo"'
expect_json schema_manifest '"secret"'
expect_json schema_manifest '"remove-policy":"manifest-declares-cli-still-confirms"'
expect_json schema_manifest '"classification":"package-options-group-feature"'
expect_json schema_manifest '"platform-conditions":"package-option-platform-metadata"'
expect_json schema_manifest '"private-data":"forbidden"'
validate_manifest_dsl_schema_summary_contract

run_json schema_transaction schema transaction-v1
expect_json schema_transaction '"name":"transaction-v1"'
expect_json schema_transaction '"schema":"nelix-apply-transaction"'
expect_json schema_transaction '"schema-version":1'
expect_json schema_transaction '"json-schema":"docs/schema/nelix-transaction-v1.schema.json"'
expect_json schema_transaction '"required":\['
expect_json schema_transaction '"rollback-plan"'
expect_json schema_transaction '"executed"'
expect_json schema_transaction '"plan-required":\['
expect_json schema_transaction '"commands"'
expect_json schema_transaction '"transaction-required":\['
expect_json schema_transaction '"before-generation"'
expect_json schema_transaction '"rollback-plan-required":\['
expect_json schema_transaction '"available"'
expect_json schema_transaction '"rollback-plan-available-required":\['
expect_json schema_transaction '"argv"'
expect_json schema_transaction '"status-values":\['
expect_json schema_transaction '"started"'
expect_json schema_transaction '"running"'
expect_json schema_transaction '"ok"'
expect_json schema_transaction '"error"'
expect_json schema_transaction '"rollback-plan-unavailable-reasons":\['
expect_json schema_transaction '"rollback-disabled"'
expect_json schema_transaction '"before-generation-missing"'
expect_json schema_transaction '"rollback-result-keys":\['
expect_json schema_transaction '"verified"'
expect_json schema_transaction '"recovery":"nelix transaction recover ID|FILE --dry-run"'
expect_json schema_transaction '"executed-required":\['
expect_json schema_transaction '"action"'
validate_transaction_schema_summary_contract

run_json packaged_registry registry list --system x86_64-linux
expect_json packaged_registry '"operation":"registry-list"'
expect_json packaged_registry '"name":"curl"'
expect_json packaged_registry '"name":"fd"'
expect_json packaged_registry '"name":"git"'
expect_json packaged_registry '"name":"jq"'
expect_json packaged_registry '"name":"ripgrep"'
expect_json packaged_registry '"name":"tree"'

dsl_packages="$tmp/dsl-packages.el"
dsl_manifest="$tmp/dsl-manifest.el"
cat >"$dsl_packages" <<'EOF'
(setq nelix-installed-cli-emacs-packages '(magit))
(setq nelix-installed-cli-linux-packages '("ripgrep" "fd"))
EOF
cat >"$dsl_manifest" <<'EOF'
(require 'nelix-dsl)
(nelix-environment
 (name "installed-cli-dsl-gate")
 (profile "default")
 (nix-channel "nixpkgs")
 (imports "dsl-packages.el")
 (backend-policy (gnu/linux nix nelix-native dnf)
                 (darwin nix homebrew)
                 (windows-nt winget scoop))
 (emacs-packages nelix-installed-cli-emacs-packages)
 (linux-packages nelix-installed-cli-linux-packages)
 (bootstrap-apt-packages build-essential devscripts)
 (package vertico :backend elpa :pin t :group editor :feature completion)
 (linux-package jq :backend nix :pin t :platform gnu/linux)
 (version-pin fd "10.2.0")
 (remove-policy confirm))
EOF
run_json dsl_validate validate "$dsl_manifest"
expect_json dsl_validate '"ok":true'
expect_json dsl_validate '"name":"installed-cli-dsl-gate"'
expect_json dsl_validate '"profile":"default"'
expect_json dsl_validate '"emacs":2'
expect_json dsl_validate '"linux":3'
expect_json dsl_validate '"pins":3'

run_json dsl_plan plan "$dsl_manifest" --dry-run
expect_json dsl_plan '"status":"planned"'
expect_json dsl_plan '"backend":"nix"'
expect_json dsl_plan '"action":"install"'
expect_json dsl_plan '"name":"ripgrep"'
expect_json dsl_plan '"name":"fd"'
expect_json dsl_plan '"action":"remove"'
expect_json dsl_plan '"name":"bat"'
reject_log 'profile install'
reject_log 'profile remove'

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
validate_lock_json_schema_smoke
lock_fingerprint_before="$(cksum "$manifest.nelix-lock")"

run_json lock_validate lock validate "$manifest"
expect_json lock_validate '"ok":true'
expect_json lock_validate '"format":"sexp"'
expect_json lock_validate '"schema-version":2'

run_json lock_diff lock diff "$manifest"
expect_json lock_diff '"ok":true'
expect_json lock_diff '"status":"clean"'
expect_json lock_diff '"manifest-digest":'

run_json lock_migrate_dry_run lock migrate "$manifest" --dry-run
expect_json lock_migrate_dry_run '"ok":true'
expect_json lock_migrate_dry_run '"status":"current"'
expect_json lock_migrate_dry_run '"needed":null'
expect_json lock_migrate_dry_run '"dry-run":true'

legacy_manifest="$tmp/legacy-manifest.el"
legacy_lock="$tmp/legacy-manifest.lock.el"
cat >"$legacy_manifest" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "installed-cli-legacy-lock"
 :linux '("ripgrep"))
EOF
cat >"$legacy_lock" <<'EOF'
;;; legacy nelix lock fixture generated by installed CLI gate -*- lexical-binding: t; -*-

(require 'nelix-manifest)

(nelix-lock
 :version 1
 :format 'sexp
 :lock "legacy-manifest.lock.el"
 :manifest-digest "sha256-installed-cli-legacy-fixture"
 :manifest-files nil
 :profile "default"
 :backend 'nix
 :system 'x86_64-linux
 :nix-channel "nixpkgs"
 :nix-version "2.34.7"
 :generated-at "2026-06-19T00:00:00+0900")
EOF
run_json lock_migrate_legacy_dry_run lock migrate "$legacy_manifest" --dry-run
expect_json lock_migrate_legacy_dry_run '"ok":true'
expect_json lock_migrate_legacy_dry_run '"status":"migration-needed"'
expect_json lock_migrate_legacy_dry_run '"needed":true'
expect_json lock_migrate_legacy_dry_run '"dry-run":true'
expect_json lock_migrate_legacy_dry_run '"from-schema-version":1'
expect_json lock_migrate_legacy_dry_run '"to-schema-version":2'
test ! -f "$legacy_manifest.nelix-lock" || {
  echo "nelix installed CLI gate legacy migrate dry-run wrote current lock" >&2
  exit 1
}

run_json lock_migrate_legacy_write lock migrate "$legacy_manifest"
expect_json lock_migrate_legacy_write '"ok":true'
expect_json lock_migrate_legacy_write '"status":"migrated"'
expect_json lock_migrate_legacy_write '"written-schema-version":2'
test -f "$legacy_manifest.nelix-lock" || {
  echo "nelix installed CLI gate legacy migrate did not write current lock: $legacy_manifest.nelix-lock" >&2
  exit 1
}

run_json lock_validate_legacy_after lock validate "$legacy_manifest"
expect_json lock_validate_legacy_after '"ok":true'
expect_json lock_validate_legacy_after '"format":"sexp"'
expect_json lock_validate_legacy_after '"schema-version":2'

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
validate_plan_apply_dry_run_equivalence
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
run_failing_json no_rollback_failed_apply fd apply "$manifest" --locked --allow-remove-count 1 --no-rollback
expect_log 'profile install --profile .+nixpkgs#ripgrep'
expect_log 'profile install --profile .+nixpkgs#fd'
reject_log 'profile rollback'
reject_log 'profile remove'
no_rollback_record="$(latest_transaction_record)"
run_json transaction_show_no_rollback_error transaction show "$no_rollback_record"
expect_json transaction_show_no_rollback_error '"operation":"transaction-show"'
expect_json transaction_show_no_rollback_error '"record":'
expect_json transaction_show_no_rollback_error '"schema":"nelix-apply-transaction"'
expect_json transaction_show_no_rollback_error '"status":"error"'
expect_json transaction_show_no_rollback_error '"record-status":"error"'
expect_json transaction_show_no_rollback_error '"rollback-on-error":null'
expect_json transaction_show_no_rollback_error '"rollback-plan":'
expect_json transaction_show_no_rollback_error '"available":null'
expect_json transaction_show_no_rollback_error '"reason":"rollback-disabled"'
expect_json transaction_show_no_rollback_error '"rollback":'
expect_json transaction_show_no_rollback_error '"attempted":null'
expect_json_any transaction_show_no_rollback_error \
  '"action":"install","name":"ripgrep"' \
  '"name":"ripgrep","action":"install"'

: >"$fake_log"
run_failing_json failed_apply fd apply "$manifest" --locked --allow-remove-count 1
expect_log 'profile install --profile .+nixpkgs#ripgrep'
expect_log 'profile install --profile .+nixpkgs#fd'
expect_log 'profile rollback --profile '
reject_log 'profile remove'
failed_record="$(latest_transaction_record)"
run_json transaction_show_error transaction show "$failed_record"
expect_json transaction_show_error '"operation":"transaction-show"'
expect_json transaction_show_error '"record":'
expect_json transaction_show_error '"schema":"nelix-apply-transaction"'
expect_json transaction_show_error '"status":"error"'
expect_json transaction_show_error '"record-status":"error"'
expect_json transaction_show_error '"rollback-plan":'
expect_json transaction_show_error '"rollback":'
expect_json transaction_show_error '"verified":true'
expect_json_any transaction_show_error \
  '"action":"install","name":"ripgrep"' \
  '"name":"ripgrep","action":"install"'
run_json transaction_recover_error transaction recover "$failed_record" --dry-run
expect_json transaction_recover_error '"operation":"transaction-recover"'
expect_json transaction_recover_error '"dry-run":true'
expect_json transaction_recover_error '"record-status":"error"'
expect_json transaction_recover_error '"generation":7'
expect_json transaction_recover_error '"manual-command":\["rollback","7"\]'

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
lock_fingerprint_after="$(cksum "$manifest.nelix-lock")"
if [ "$lock_fingerprint_before" != "$lock_fingerprint_after" ]; then
  echo "nelix installed CLI gate: locked apply rewrote lock file" >&2
  exit 1
fi

ok_record="$(latest_transaction_record)"
run_json transaction_list transaction list --limit 5
expect_json transaction_list '"operation":"transaction-list"'
expect_json transaction_list '"rollback-available":true'
expect_json transaction_list '"status":"ok"'
expect_json transaction_list '"command-count":3'
expect_json transaction_list '"executed-count":3'
run_json transaction_show_ok transaction show "$ok_record"
expect_json transaction_show_ok '"operation":"transaction-show"'
expect_json transaction_show_ok '"record":'
expect_json transaction_show_ok '"schema":"nelix-apply-transaction"'
expect_json transaction_show_ok '"schema-version":1'
expect_json transaction_show_ok '"status":"ok"'
expect_json transaction_show_ok '"plan":'
expect_json transaction_show_ok '"transaction":'
expect_json transaction_show_ok '"rollback-on-error":true'
expect_json transaction_show_ok '"generation-captured":true'
expect_json transaction_show_ok '"before-generation":7'
expect_json transaction_show_ok '"record-status":"ok"'
expect_json transaction_show_ok '"rollback-plan":'
expect_json transaction_show_ok '"available":true'
expect_json transaction_show_ok '"executed":'
expect_json_any transaction_show_ok \
  '"action":"install","name":"ripgrep"' \
  '"name":"ripgrep","action":"install"'
expect_json_any transaction_show_ok \
  '"action":"remove","name":"bat"' \
  '"name":"bat","action":"remove"'

NELIX_BIN="$nelix_bin" bash "$script_dir/verify-nelix-native-cli-gate.sh"
NELIX_BIN="$nelix_bin" bash "$script_dir/verify-nelix-aot-cache-gate.sh"

echo "nelix installed CLI gate ok"
