#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
manifest="${NELIX_NATIVE_USER_MANIFEST:-$HOME/.emacs.d/nelix-package-native.el}"
notes_manifest_org="${NELIX_NATIVE_USER_MANIFEST_ORG:-$HOME/Cowork/Notes/capture/nelix-package-native.org}"
linux_org="${NELIX_NATIVE_LINUX_ORG:-$HOME/Cowork/Notes/capture/nelix-linux.org}"

if [ ! -f "$manifest" ]; then
  echo "nelix native user gate: manifest is missing: $manifest" >&2
  exit 1
fi

if [ ! -f "$notes_manifest_org" ]; then
  echo "nelix native user gate: source org is missing: $notes_manifest_org" >&2
  exit 1
fi

if [ ! -f "$linux_org" ]; then
  echo "nelix native user gate: Linux source org is missing: $linux_org" >&2
  exit 1
fi

if [ -n "${NELIX_BIN:-}" ]; then
  nelix_bin="$NELIX_BIN"
else
  nelix_bin="$repo_dir/bin/nelix"
fi

if [ -n "${NELIX_LISPDIR:-}" ]; then
  nelix_lispdir="$NELIX_LISPDIR"
else
  nelix_lispdir="$repo_dir"
fi

tmp="$(mktemp -d)"
cleanup() {
  if [ "${had_lock:-0}" -eq 1 ]; then
    cp -p "$lock_backup" "$lock_file"
  else
    rm -f "$lock_file"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fake_bin="$tmp/bin"
home="$tmp/home"
data="$tmp/data"
state="$tmp/state"
mkdir -p "$fake_bin" "$home" "$data" "$state"

make_fake_command() {
  name="$1"
  cat >"$fake_bin/$name" <<EOF
#!/bin/sh
printf '%s\\n' "$name native-user-gate \$*"
EOF
  chmod +x "$fake_bin/$name"
}

for command in git curl rg fd jq tree; do
  make_fake_command "$command"
done

cat >"$fake_bin/nix" <<'EOF'
#!/bin/sh
echo "nix is intentionally unavailable in nelix-native-user-gate" >&2
exit 127
EOF
chmod +x "$fake_bin/nix"

PATH="$fake_bin:${PATH:-}" nix --version >/dev/null 2>&1 && {
  echo "nelix native user gate: fake no-Nix PATH did not mask nix" >&2
  exit 1
}

lock_file="$manifest.nelix-lock"
lock_backup="$tmp/manifest.nelix-lock.backup"
had_lock=0
if [ -f "$lock_file" ]; then
  cp -p "$lock_file" "$lock_backup"
  had_lock=1
fi

run_nelix() {
  HOME="$home" \
  XDG_DATA_HOME="$data" \
  XDG_STATE_HOME="$state" \
  PATH="$fake_bin:${PATH:-}" \
  NELIX_LISPDIR="$nelix_lispdir" \
  NELIX_REGISTRY_INCLUDE_PACKAGED=1 \
  "$nelix_bin" "$@"
}

expect_json() {
  label="$1"
  file="$2"
  pattern="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "nelix native user gate: $label missing JSON pattern: $pattern" >&2
    sed -n '1,20p' "$file" >&2
    exit 1
  fi
}

reject_json() {
  label="$1"
  file="$2"
  pattern="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "nelix native user gate: $label unexpectedly matched JSON pattern: $pattern" >&2
    sed -n '1,20p' "$file" >&2
    exit 1
  fi
}

run_json() {
  label="$1"
  shift
  if ! run_nelix --json "$@" >"$tmp/$label.json" 2>"$tmp/$label.err"; then
    echo "nelix native user gate: command failed: $label $*" >&2
    sed -n '1,20p' "$tmp/$label.json" >&2
    sed -n '1,40p' "$tmp/$label.err" >&2
    exit 1
  fi
}

HOME="$home" \
XDG_DATA_HOME="$data" \
XDG_STATE_HOME="$state" \
PATH="$fake_bin:${PATH:-}" \
NELIX_REGISTRY_INCLUDE_PACKAGED=1 \
NELIX_USER_MANIFEST="$manifest" \
NELIX_USER_MANIFEST_LABEL="native-user" \
NELIX_USER_MANIFEST_NELISP="skip" \
NELIX_USER_MANIFEST_LOCKED="skip" \
NELIX_BIN="$nelix_bin" \
NELIX_LISPDIR="$nelix_lispdir" \
"$repo_dir/packaging/verify-nelix-user-manifest-dsl.sh"

NELIX_NATIVE_USER_MANIFEST="$manifest" \
emacs -Q --batch -L "$nelix_lispdir" \
  --eval '(require (quote nelix-manifest))' \
  --eval '(let* ((manifest (nelix-manifest-load (getenv "NELIX_NATIVE_USER_MANIFEST")))
                 (policy (nelix-manifest-backend-policy manifest (quote gnu/linux)))
                 (targets (nelix-manifest-targets manifest (quote nelix-native)))
                 (bootstrap (plist-get manifest :bootstrap-apt)))
            (unless (equal policy (quote (nelix-native)))
              (error "native policy is not nelix-native only: %S" policy))
            (unless (equal targets (quote ("git" "curl" "ripgrep" "fd" "jq" "tree")))
              (error "native targets differ: %S" targets))
            (when (memq (quote nix-bin) bootstrap)
              (error "native bootstrap still contains nix-bin: %S" bootstrap))
            (princ "nelix native user manifest policy ok\n"))'

emacs -Q --batch -L "$nelix_lispdir" \
  -l "$HOME/.emacs.d/custom-lisp/nelix-linux.el" \
  --eval '(require (quote subr-x))' \
  --eval '(princ (concat "nelix native fallback packages: "
                         (string-join nelix-linux-native-fallback-packages ",")
                         "\n"))'

run_json validate validate "$manifest"
expect_json validate "$tmp/validate.json" '"ok":true'
expect_json validate "$tmp/validate.json" '"profile":"native-test"'

run_json audit audit "$manifest"
expect_json audit "$tmp/audit.json" '"backend":"nelix-native"'
expect_json audit "$tmp/audit.json" '"nix-required":null'
expect_json audit "$tmp/audit.json" '"name":"git"'
expect_json audit "$tmp/audit.json" '"name":"tree"'

run_json plan plan "$manifest" --dry-run
expect_json plan "$tmp/plan.json" '"status":"planned"'
expect_json plan "$tmp/plan.json" '"backend":"nelix-native"'
expect_json plan "$tmp/plan.json" '"name":"ripgrep"'
reject_json plan "$tmp/plan.json" '"backend":"nix"'

run_json lock lock "$manifest"
expect_json lock "$tmp/lock.json" '"schema":"nelix-lock"'
expect_json lock "$tmp/lock.json" '"backend":"nelix-native"'
expect_json lock "$tmp/lock.json" '"name":"fd"'
test -f "$lock_file" || {
  echo "nelix native user gate: lock file was not created: $lock_file" >&2
  exit 1
}

run_json locked_dry_run apply "$manifest" --locked --dry-run
expect_json locked_dry_run "$tmp/locked_dry_run.json" '"status":"dry-run"'
expect_json locked_dry_run "$tmp/locked_dry_run.json" '"locked":true'
expect_json locked_dry_run "$tmp/locked_dry_run.json" '"lock-enforced":true'
expect_json locked_dry_run "$tmp/locked_dry_run.json" '"name":"jq"'
reject_json locked_dry_run "$tmp/locked_dry_run.json" '"backend":"nix"'

run_json seed native install git --profile native-test --system x86_64-linux
expect_json seed "$tmp/seed.json" '"generation":1'

run_json locked_apply apply "$manifest" --locked
expect_json locked_apply "$tmp/locked_apply.json" '"status":"ok"'
expect_json locked_apply "$tmp/locked_apply.json" '"backend":"nelix-native"'
expect_json locked_apply "$tmp/locked_apply.json" '"locked":true'

run_json activate native activate --profile native-test
expect_json activate "$tmp/activate.json" '"operation":"native-activate"'
expect_json activate "$tmp/activate.json" '"command":"rg"'
expect_json activate "$tmp/activate.json" '"command":"tree"'

profile_bin="$state/nelix/profiles/native-test/active/bin"
test -x "$profile_bin/rg" || {
  echo "nelix native user gate: activated rg shim missing" >&2
  exit 1
}
test -x "$profile_bin/tree" || {
  echo "nelix native user gate: activated tree shim missing" >&2
  exit 1
}

shim_output="$(PATH="$fake_bin:${PATH:-}" "$profile_bin/rg" --gate)"
test "$shim_output" = "rg native-user-gate --gate" || {
  echo "nelix native user gate: activated rg shim output mismatch: $shim_output" >&2
  exit 1
}

run_json rollback native rollback --profile native-test --generation 1
expect_json rollback "$tmp/rollback.json" '"operation":"native-rollback"'
expect_json rollback "$tmp/rollback.json" '"generation":1'

printf 'nelix native user gate ok: manifest=%s profile=native-test no-nix-path=true\n' "$manifest"
