#!/usr/bin/env bash
# Verify the `nelix --runtime nelisp' AOT cache fast lane.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." 2>/dev/null && pwd || printf '%s\n' "")"

if [ -n "${NELIX_BIN:-}" ]; then
  nelix_bin="$NELIX_BIN"
elif [ -n "$repo_root" ] && [ -x "$repo_root/bin/nelix" ]; then
  nelix_bin="$repo_root/bin/nelix"
elif [ -x /usr/bin/nelix ]; then
  nelix_bin=/usr/bin/nelix
else
  echo "nelix AOT cache gate: nelix binary not found" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
  "$tmp/bin" \
  "$tmp/home" \
  "$tmp/state" \
  "$tmp/profile" \
  "$tmp/nelisp-root/lisp" \
  "$tmp/nelisp-root/packages/nelisp-json/src" \
  "$tmp/nelisp-root/packages/nelisp-actor/src" \
  "$tmp/nelisp-root/packages/nelisp-process/src"

manifest="$tmp/manifest.el"
fake_nix="$tmp/bin/nix"
fake_nelisp="$tmp/bin/nelisp"

cat >"$manifest" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "aot-cache-gate"
 :profile "default"
 :linux '("magit" "ripgrep" "fd")
 :pins '("ripgrep"))
EOF

cat >"$fake_nix" <<'EOF'
#!/bin/sh
case " $* " in
  *" profile list "*)
    printf 'Name: magit\nName: ripgrep-1\nName: bat\n'
    ;;
  *)
    printf 'fake nix: unsupported %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_nix"

cat >"$fake_nelisp" <<'EOF'
#!/bin/sh
echo "error: fallback nelisp engine should not run" >&2
exit 77
EOF
chmod +x "$fake_nelisp"

touch \
  "$tmp/nelisp-root/lisp/nelisp-stdlib-eval-special.el" \
  "$tmp/nelisp-root/lisp/nelisp-cl-macros.el" \
  "$tmp/nelisp-root/packages/nelisp-json/src/nelisp-json.el" \
  "$tmp/nelisp-root/packages/nelisp-actor/src/nelisp-actor.el" \
  "$tmp/nelisp-root/packages/nelisp-process/src/nelisp-process.el"

env_args=(
  "PATH=$tmp/bin:$PATH"
  "HOME=$tmp/home"
  "XDG_STATE_HOME=$tmp/state"
  "NELIX_RUNTIME=nelisp"
  "NELIX_NIX_PROGRAM=$fake_nix"
  "NELIX_PROFILE_DIR=$tmp/profile"
  "NELISP=$fake_nelisp"
  "NELISP_ROOT=$tmp/nelisp-root"
)

if [ -n "${NELIX_LISPDIR:-}" ]; then
  env_args+=("NELIX_LISPDIR=$NELIX_LISPDIR")
elif [ -n "$repo_root" ] && [ "$nelix_bin" = "$repo_root/bin/nelix" ]; then
  env_args+=("NELIX_LISPDIR=$repo_root")
fi

run_capture() {
  local label="$1"
  shift
  local out="$tmp/$label.out"
  local err="$tmp/$label.err"
  if ! env "${env_args[@]}" "$nelix_bin" "$@" >"$out" 2>"$err"; then
    sed 's/^/nelix_aot_cache_stdout /' "$out" >&2
    sed 's/^/nelix_aot_cache_stderr /' "$err" >&2
    exit 1
  fi
}

expect_output() {
  local label="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$tmp/$label.out"; then
    echo "nelix AOT cache gate missing pattern: label=$label pattern=$pattern" >&2
    sed 's/^/nelix_aot_cache_stdout /' "$tmp/$label.out" >&2
    sed 's/^/nelix_aot_cache_stderr /' "$tmp/$label.err" >&2
    exit 1
  fi
}

run_capture aot_cache aot-cache "$manifest"
test -f "$manifest.nelix-aot-targets" || {
  echo "nelix AOT cache gate did not create cache: $manifest.nelix-aot-targets" >&2
  exit 1
}
expect_output aot_cache ':status ok'

run_capture list list
expect_output list '^magit$'
expect_output list '^ripgrep-1$'
expect_output list '^bat$'

run_capture audit audit "$manifest"
expect_output audit '^present[[:space:]]+magit$'
expect_output audit '^present[[:space:]]+ripgrep-1$'
expect_output audit '^missing[[:space:]]+fd$'
expect_output audit '^extra[[:space:]]+bat$'
expect_output audit '^fallback[[:space:]]+:nelisp-aot-cache$'

run_capture apply_plan plan "$manifest" --dry-run
expect_output apply_plan '^status[[:space:]]+planned$'
expect_output apply_plan '^install[[:space:]]+fd$'
expect_output apply_plan '^remove[[:space:]]+bat$'
expect_output apply_plan '^keep[[:space:]]+magit$'
expect_output apply_plan '^keep[[:space:]]+ripgrep$'
expect_output apply_plan '^count[[:space:]]+2$'
expect_output apply_plan '^fallback[[:space:]]+:nelisp-aot-cache$'

run_capture apply_dry_run apply "$manifest" --dry-run
expect_output apply_dry_run '^status[[:space:]]+dry-run$'
expect_output apply_dry_run '^install[[:space:]]+fd$'
expect_output apply_dry_run '^remove[[:space:]]+bat$'
expect_output apply_dry_run '^keep[[:space:]]+magit$'
expect_output apply_dry_run '^keep[[:space:]]+ripgrep$'
expect_output apply_dry_run '^count[[:space:]]+2$'
expect_output apply_dry_run '^fallback[[:space:]]+:nelisp-aot-cache$'

run_capture plan upgrade-plan "$manifest"
expect_output plan '^upgrade[[:space:]]+magit$'
expect_output plan '^pinned[[:space:]]+ripgrep-1$'
expect_output plan '^missing[[:space:]]+fd$'
expect_output plan '^fallback[[:space:]]+:nelisp-aot-cache$'

run_capture audit_json --json audit "$manifest"
expect_output audit_json '"present":\["magit","ripgrep-1"\]'
expect_output audit_json '"missing":\["fd"\]'
expect_output audit_json '"extra":\["bat"\]'
expect_output audit_json '"fallback":":nelisp-aot-cache"'

run_capture apply_plan_json --json plan "$manifest" --dry-run
expect_output apply_plan_json '"status":"planned"'
expect_output apply_plan_json '"action":"install","name":"fd"'
expect_output apply_plan_json '"action":"remove","name":"bat"'
expect_output apply_plan_json '"action":"keep","name":"magit"'
expect_output apply_plan_json '"action":"keep","name":"ripgrep"'
expect_output apply_plan_json '"count":2'
expect_output apply_plan_json '"fallback":":nelisp-aot-cache"'

run_capture apply_dry_run_json --json apply "$manifest" --dry-run
expect_output apply_dry_run_json '"status":"dry-run"'
expect_output apply_dry_run_json '"action":"install","name":"fd"'
expect_output apply_dry_run_json '"action":"remove","name":"bat"'
expect_output apply_dry_run_json '"action":"keep","name":"magit"'
expect_output apply_dry_run_json '"action":"keep","name":"ripgrep"'
expect_output apply_dry_run_json '"count":2'
expect_output apply_dry_run_json '"fallback":":nelisp-aot-cache"'

run_capture plan_json --json upgrade-plan "$manifest"
expect_output plan_json '"upgrade":\["magit"\]'
expect_output plan_json '"pinned":\["ripgrep-1"\]'
expect_output plan_json '"missing":\["fd"\]'
expect_output plan_json '"fallback":":nelisp-aot-cache"'

echo "nelix AOT cache gate ok"
