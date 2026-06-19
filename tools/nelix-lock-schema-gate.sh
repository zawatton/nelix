#!/usr/bin/env bash
# Gate the lockfile schema contract against source-tree CLI output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EMACS_BIN="${EMACS:-emacs}"
TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/state"

MANIFEST="$TMP_DIR/manifest.el"
LEGACY_MANIFEST="$TMP_DIR/legacy-manifest.el"
FAKE_NIX="$TMP_DIR/bin/nix"
FAKE_LOG="$TMP_DIR/fake-nix.log"

cat >"$MANIFEST" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "default"
 :linux '("ripgrep" "fd")
 :pins '("ripgrep"))
EOF

cat >"$LEGACY_MANIFEST" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "default"
 :linux '("ripgrep"))
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
        printf '%s\n' '{"elements":{"ripgrep":{"attrPath":"legacyPackages.x86_64-linux.ripgrep","originalUrl":"flake:nixpkgs","storePaths":["/nix/store/ripgrep"]}}}'
        ;;
      *)
        printf 'Name: ripgrep\n'
        ;;
    esac
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
    "NELIX_RUNTIME=emacs" \
    "NELIX_LISPDIR=$REPO_ROOT" \
    "NELIX_FAKE_NIX_LOG=$FAKE_LOG" \
    "$REPO_ROOT/bin/nelix" --json "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  printf 'nelix_lock_schema_gate_result label=%s rc=%s\n' "$label" "$rc"
  if [ "$rc" -ne 0 ]; then
    sed 's/^/nelix_lock_schema_gate_stdout /' "$out_file" >&2
    sed 's/^/nelix_lock_schema_gate_stderr /' "$err_file" >&2
    exit "$rc"
  fi
}

expect_out() {
  local label="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$TMP_DIR/$label.out"; then
    echo "nelix_lock_schema_gate_fail label=$label reason=missing-output pattern=$pattern" >&2
    sed 's/^/nelix_lock_schema_gate_stdout /' "$TMP_DIR/$label.out" >&2
    sed 's/^/nelix_lock_schema_gate_stderr /' "$TMP_DIR/$label.err" >&2
    exit 1
  fi
}

run_nelix schema_lock schema lock-v2
run_nelix schema_all schema all
run_nelix lock lock "$MANIFEST"
run_nelix lock_validate lock validate "$MANIFEST"
run_nelix lock_diff lock diff "$MANIFEST"
run_nelix lock_migrate_clean lock migrate "$MANIFEST" --dry-run

LOCK_FILE="$MANIFEST.nelix-lock"
test -f "$LOCK_FILE" || {
  echo "nelix_lock_schema_gate_fail reason=missing-lock path=$LOCK_FILE" >&2
  exit 1
}
expect_out lock '"schema":"nelix-lock"'
expect_out lock '"schema-version":2'
expect_out lock_validate '"schema":"nelix-lock"'
expect_out lock_validate '"schema-version":2'
expect_out lock_diff '"status":"clean"'
expect_out lock_migrate_clean '"status":"current"'

lock_fingerprint_before="$(cksum "$LOCK_FILE")"
run_nelix lock_validate_readonly lock validate "$MANIFEST"
run_nelix lock_diff_readonly lock diff "$MANIFEST"
run_nelix lock_migrate_dry_run_readonly lock migrate "$MANIFEST" --dry-run
lock_fingerprint_after="$(cksum "$LOCK_FILE")"
test "$lock_fingerprint_before" = "$lock_fingerprint_after" || {
  echo "nelix_lock_schema_gate_fail reason=read-only-command-mutated-lock" >&2
  exit 1
}

cp test/fixtures/nelix-lock-v1-legacy.el "${LEGACY_MANIFEST%.el}.lock.el"
run_nelix legacy_migrate_dry_run lock migrate "$LEGACY_MANIFEST" --dry-run
expect_out legacy_migrate_dry_run '"from-schema-version":1'
expect_out legacy_migrate_dry_run '"to-schema-version":2'
test ! -f "$LEGACY_MANIFEST.nelix-lock" || {
  echo "nelix_lock_schema_gate_fail reason=legacy-dry-run-wrote-current-lock" >&2
  exit 1
}
run_nelix legacy_migrate_write lock migrate "$LEGACY_MANIFEST"
expect_out legacy_migrate_write '"status":"migrated"'
expect_out legacy_migrate_write '"written-schema-version":2'
test -f "$LEGACY_MANIFEST.nelix-lock" || {
  echo "nelix_lock_schema_gate_fail reason=legacy-migrate-missing-current-lock" >&2
  exit 1
}
run_nelix legacy_validate_after lock validate "$LEGACY_MANIFEST"
expect_out legacy_validate_after '"schema-version":2'

BAD_MANIFEST="$TMP_DIR/bad-lock-manifest.el"
cat >"$BAD_MANIFEST" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "bad-lock"
 :linux '("ripgrep"))
EOF
run_nelix bad_lock lock "$BAD_MANIFEST"
perl -0pi -e 's/[[:space:]]+:source nixpkgs//' "$BAD_MANIFEST.nelix-lock"
run_nelix bad_lock_validate lock validate "$BAD_MANIFEST"
run_nelix bad_lock_check lock-check "$BAD_MANIFEST"
expect_out bad_lock_validate '"ok":null'
expect_out bad_lock_validate '"shape-ok":null'
expect_out bad_lock_validate \
  'lock package row 1 is missing schema-required key :source'
expect_out bad_lock_check '"ok":null'
expect_out bad_lock_check \
  'lock package row 1 is missing schema-required key :source'

perl -0pi -e 's/:schema-version 2/:schema-version 999/; s/:version 2/:version 999/' "$LOCK_FILE"
run_nelix future_schema_rejected lock validate "$MANIFEST"
expect_out future_schema_rejected '"ok":null'
expect_out future_schema_rejected '"schema-version":999'

"$EMACS_BIN" -Q --batch \
  --eval "(let ((repo-root \"$REPO_ROOT\")
                (schema-lock-json \"$TMP_DIR/schema_lock.out\")
                (schema-all-json \"$TMP_DIR/schema_all.out\")
                (lock-json \"$TMP_DIR/lock.out\"))
            (require 'cl-lib)
            (require 'json)
            (let ((json-object-type 'alist)
                  (json-array-type 'list)
                  (json-key-type 'string))
              (cl-labels
                  ((read-json-file (file)
                     (json-read-file file))
                   (jget (key object)
                     (alist-get key object nil nil #'string=))
                   (jhas (key object)
                     (cl-assoc key object :test #'string=))
                   (json-list (value)
                     (if (vectorp value) (append value nil) value))
                   (need (condition message)
                     (unless condition
                       (error \"%s\" message))))
                (let* ((schema (read-json-file
                                (expand-file-name
                                 \"docs/schema/nelix-lock-v2.schema.json\"
                                 repo-root)))
                       (summary (read-json-file schema-lock-json))
                       (schema-all (read-json-file schema-all-json))
                       (lock (read-json-file lock-json))
                       (properties (jget \"properties\" schema))
                       (summary-contract (jget \"x-nelix-summary\" schema))
                       (defs (jget \"\$defs\" schema))
                       (package-schema (jget \"package\" defs))
                       (required (json-list (jget \"required\" schema)))
                       (package-required
                        (json-list (jget \"required\" package-schema)))
                       (packages (json-list (jget \"packages\" lock)))
                       (package (car packages))
                       (commands (json-list (jget \"commands\" summary)))
                       (compatibility
                        (json-list (jget \"compatibility\" summary))))
                  (need (equal \"ok\" (jget \"status\" summary))
                        \"schema lock-v2 did not return ok\")
                  (need (equal \"lock-v2\" (jget \"name\" summary))
                        \"schema summary name drifted\")
                  (need (cl-find-if
                         (lambda (entry)
                           (and (equal \"lock-v2\" (jget \"name\" entry))
                                (= 2 (jget \"schema-version\" entry))))
                         (json-list (jget \"schemas\" schema-all)))
                        \"schema all omitted lock-v2\")
                  (need (equal (jget \"const\" (jget \"schema\" properties))
                               (jget \"schema\" summary))
                        \"summary schema differs from JSON schema\")
                  (need (= (jget \"const\" (jget \"schema-version\" properties))
                           (jget \"schema-version\" summary))
                        \"summary schema-version differs from JSON schema\")
                  (need (= (jget \"const\" (jget \"version\" properties))
                           (jget \"version\" summary))
                        \"summary version differs from JSON schema\")
                  (need (equal (jget \"const\" (jget \"format\" properties))
                               (jget \"format\" summary))
                        \"summary format differs from JSON schema\")
                  (need (equal required (json-list (jget \"required\" summary)))
                        \"summary required keys differ from JSON schema\")
                  (need (equal package-required
                               (json-list (jget \"package-required\" summary)))
                        \"summary package required keys differ from JSON schema\")
                  (dolist (key '(\"source-of-truth\" \"json-output\" \"commands\"
                                 \"compatibility\" \"migration\" \"validation\" \"diff\"))
                    (need (equal (jget \"const\" (jget key summary-contract))
                                 (json-list (jget key summary)))
                          (format \"summary %s differs from JSON schema\" key)))
                  (dolist (command '(\"lock\" \"lock validate\"
                                     \"lock diff\" \"lock migrate\"))
                    (need (member command commands)
                          (format \"summary commands omit %s\" command)))
                  (dolist (label '(\"legacy-v1-readable-migrate-required\"
                                   \"legacy-v2-readable\"
                                   \"future-version-rejected\"))
                    (need (member label compatibility)
                          (format \"summary compatibility omits %s\" label)))
                  (dolist (key required)
                    (need (jhas key lock)
                          (format \"lock JSON omits schema-required key %s\"
                                  key)))
                  (dolist (key package-required)
                    (need (jhas key package)
                          (format \"lock package omits schema-required key %s\"
                                  key)))
                  (need (equal \"nelix-lock\" (jget \"schema\" lock))
                        \"lock JSON schema drifted\")
                  (need (= 2 (jget \"schema-version\" lock))
                        \"lock JSON schema-version drifted\")
                  (need (= 2 (jget \"version\" lock))
                        \"lock JSON version drifted\")
                  (need (equal \"sexp\" (jget \"format\" lock))
                        \"lock JSON format drifted\")
                  (need (equal \"nix\" (jget \"backend\" lock))
                        \"lock JSON backend drifted\"))))))"

echo "nelix_lock_schema_gate_result label=nelix_lock_schema_gate rc=0"
