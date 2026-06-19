#!/usr/bin/env bash
# Verify `nelix native ...' commands against an isolated local registry/store.
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
  echo "nelix native CLI gate: nelix binary not found" >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "nelix native CLI gate: sha256sum is required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

home="$tmp/home"
data="$tmp/data"
state="$tmp/state"
source_dir="$tmp/source"
registry="$data/nelix/registry/packages/local"
profile_root="$state/nelix/profiles"

mkdir -p "$home" "$data" "$state" "$source_dir" "$registry"

payload="$source_dir/fixture-tool"
cat >"$payload" <<'EOF'
#!/bin/sh
printf 'fixture-tool-ok'
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@"
fi
printf '\n'
EOF
chmod +x "$payload"

payload_extra="$source_dir/fixture-extra"
cat >"$payload_extra" <<'EOF'
#!/bin/sh
printf 'fixture-extra-ok'
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@"
fi
printf '\n'
EOF
chmod +x "$payload_extra"

payload_dep="$source_dir/fixture-dep"
cat >"$payload_dep" <<'EOF'
#!/bin/sh
printf 'fixture-dep-ok'
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@"
fi
printf '\n'
EOF
chmod +x "$payload_dep"

payload_dep_drift="$source_dir/fixture-dep-drift"
cat >"$payload_dep_drift" <<'EOF'
#!/bin/sh
printf 'fixture-dep-drift'
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@"
fi
printf '\n'
EOF
chmod +x "$payload_dep_drift"

payload_app="$source_dir/fixture-app"
cat >"$payload_app" <<'EOF'
#!/bin/sh
printf 'fixture-app-ok'
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@"
fi
printf '\n'
EOF
chmod +x "$payload_app"

sha256="sha256-$(sha256sum "$payload" | awk '{print $1}')"
sha256_extra="sha256-$(sha256sum "$payload_extra" | awk '{print $1}')"
sha256_dep="sha256-$(sha256sum "$payload_dep" | awk '{print $1}')"
sha256_dep_drift="sha256-$(sha256sum "$payload_dep_drift" | awk '{print $1}')"
sha256_app="sha256-$(sha256sum "$payload_app" | awk '{print $1}')"

quote_elisp_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'
}

cat >"$registry/fixture-tool.el" <<EOF
(require 'nelix-registry)
(nelix-package
 :name "fixture-tool"
 :version "1.0.0"
 :class 'system-tool
 :description "Local native CLI gate fixture"
 :systems
 '((x86_64-linux
    :source (:type local
             :path $(quote_elisp_string "$payload")
             :sha256 "$sha256")
    :install (:type copy
              :bin ("fixture-tool")))))
EOF

cat >"$registry/fixture-extra.el" <<EOF
(require 'nelix-registry)
(nelix-package
 :name "fixture-extra"
 :version "1.0.0"
 :class 'system-tool
 :description "Second local native CLI gate fixture"
 :systems
 '((x86_64-linux
    :source (:type local
             :path $(quote_elisp_string "$payload_extra")
             :sha256 "$sha256_extra")
    :install (:type copy
              :bin ("fixture-extra")))))
EOF

cat >"$registry/fixture-dep.el" <<EOF
(require 'nelix-registry)
(nelix-package
 :name "fixture-dep"
 :version "1.0.0"
 :class 'system-tool
 :description "Native dependency fixture"
 :systems
 '((x86_64-linux
    :source (:type local
             :path $(quote_elisp_string "$payload_dep")
             :sha256 "$sha256_dep")
    :install (:type copy
              :bin ("fixture-dep")))))
EOF

cat >"$registry/fixture-app.el" <<EOF
(require 'nelix-registry)
(nelix-package
 :name "fixture-app"
 :version "1.0.0"
 :class 'system-tool
 :description "Native dependent fixture"
 :systems
 '((x86_64-linux
    :dependencies ("fixture-dep")
    :source (:type local
             :path $(quote_elisp_string "$payload_app")
             :sha256 "$sha256_app")
    :install (:type copy
              :bin ("fixture-app")))))
EOF

env_args=(
  "HOME=$home"
  "XDG_DATA_HOME=$data"
  "XDG_STATE_HOME=$state"
)

if [ -n "${NELIX_LISPDIR:-}" ]; then
  env_args+=("NELIX_LISPDIR=$NELIX_LISPDIR")
elif [ -n "$repo_root" ] && [ "$nelix_bin" = "$repo_root/bin/nelix" ]; then
  env_args+=("NELIX_LISPDIR=$repo_root")
fi

run_json() {
  local label="$1"
  shift
  local out="$tmp/$label.json"
  local err="$tmp/$label.err"
  if ! env "${env_args[@]}" "$nelix_bin" --json "$@" >"$out" 2>"$err"; then
    sed 's/^/nelix_native_cli_stdout /' "$out" >&2
    sed 's/^/nelix_native_cli_stderr /' "$err" >&2
    exit 1
  fi
}

expect_json() {
  local label="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$tmp/$label.json"; then
    echo "nelix native CLI gate missing pattern: label=$label pattern=$pattern" >&2
    sed 's/^/nelix_native_cli_stdout /' "$tmp/$label.json" >&2
    sed 's/^/nelix_native_cli_stderr /' "$tmp/$label.err" >&2
    exit 1
  fi
}

reject_json() {
  local label="$1"
  local pattern="$2"
  if grep -Eq "$pattern" "$tmp/$label.json"; then
    echo "nelix native CLI gate unexpected pattern: label=$label pattern=$pattern" >&2
    sed 's/^/nelix_native_cli_stdout /' "$tmp/$label.json" >&2
    sed 's/^/nelix_native_cli_stderr /' "$tmp/$label.err" >&2
    exit 1
  fi
}

native_lock_manifest="$tmp/native-lock-manifest.el"
cat >"$native_lock_manifest" <<'EOF'
(require 'nelix-manifest)
(nelix-manifest
 :name "native-lockgate"
 :profile "lockgate"
 :linux '("fixture-app")
 :backend-policy '(nelix-native))
EOF

run_json native_lock lock "$native_lock_manifest"
test -f "$native_lock_manifest.nelix-lock" || {
  echo "nelix native CLI gate: native lock file missing" >&2
  exit 1
}
expect_json native_lock '"schema":"nelix-lock"'
expect_json native_lock '"name":"fixture-app"'
expect_json native_lock '"name":"fixture-dep"'
grep -q ':recipe-dependencies' "$native_lock_manifest.nelix-lock" || {
  echo "nelix native CLI gate: native lock omitted recipe dependencies" >&2
  exit 1
}

run_json registry_list registry list --system x86_64-linux
expect_json registry_list '"operation":"registry-list"'
expect_json registry_list '"count":4'
expect_json registry_list '"name":"fixture-app"'
expect_json registry_list '"name":"fixture-dep"'
expect_json registry_list '"name":"fixture-extra"'
expect_json registry_list '"name":"fixture-tool"'

generated_index="$tmp/generated-registry-index.el"
run_json registry_index registry index "$data/nelix/registry" "$generated_index"
expect_json registry_index '"operation":"registry-index"'
expect_json registry_index '"count":4'
expect_json registry_index '"output":'
test -f "$generated_index" || {
  echo "nelix native CLI gate: generated registry index missing: $generated_index" >&2
  exit 1
}
grep -q '(nelix-registry-index' "$generated_index" || {
  echo "nelix native CLI gate: generated registry index form missing" >&2
  exit 1
}
grep -q ':path "packages/local/fixture-tool.el"' "$generated_index" || {
  echo "nelix native CLI gate: generated registry index omitted fixture-tool path" >&2
  exit 1
}

run_json audit native audit
expect_json audit '"operation":"native-audit"'
expect_json audit '"backend":"nelix-native"'
expect_json audit '"nix-required":null'

run_json native_plan plan "$native_lock_manifest"
expect_json native_plan '"operation":"apply"'
expect_json native_plan '"status":"planned"'
expect_json native_plan '"backend":"nelix-native"'
expect_json native_plan '"source":"registry"'
expect_json native_plan '"recipe-version":"1.0.0"'
expect_json native_plan '"name":"fixture-app"'
reject_json native_plan '"status":"ok"'

run_json native_dry_run apply "$native_lock_manifest" --dry-run --locked
expect_json native_dry_run '"operation":"apply"'
expect_json native_dry_run '"status":"dry-run"'
expect_json native_dry_run '"backend":"nelix-native"'
expect_json native_dry_run '"lock-enforced":true'
expect_json native_dry_run '"name":"fixture-app"'
expect_json native_dry_run '"name":"fixture-dep"'
test ! -e "$profile_root/lockgate/generations/1/profile.el" || {
  echo "nelix native CLI gate: native apply --dry-run mutated lockgate profile" >&2
  exit 1
}

run_json install native install fixture-tool --profile default --system x86_64-linux
expect_json install '"operation":"native-install"'
expect_json install '"status":"ok"'
expect_json install '"count":1'
expect_json install '"name":"fixture-tool"'
expect_json install '"runtime-bins":\["fixture-tool"\]'

store_path="$data/nelix/store/$sha256-fixture-tool-1.0.0"
test -x "$store_path/fixture-tool" || {
  echo "nelix native CLI gate: installed runtime file missing: $store_path/fixture-tool" >&2
  exit 1
}
test -f "$store_path/.nelix/store-entry.el" || {
  echo "nelix native CLI gate: store metadata missing: $store_path/.nelix/store-entry.el" >&2
  exit 1
}
test -f "$profile_root/default/generations/1/profile.el" || {
  echo "nelix native CLI gate: profile generation missing" >&2
  exit 1
}

run_json list native list
expect_json list '"operation":"native-list"'
expect_json list '"name":"fixture-tool"'

run_json profile native profile --profile default
expect_json profile '"operation":"native-profile"'
expect_json profile '"generation":1'
expect_json profile '"name":"fixture-tool"'

run_json activate native activate --profile default
expect_json activate '"operation":"native-activate"'
expect_json activate '"generation":1'
expect_json activate '"command":"fixture-tool"'

shim="$profile_root/default/active/bin/fixture-tool"
test -x "$shim" || {
  echo "nelix native CLI gate: activation shim missing: $shim" >&2
  exit 1
}
test -f "$profile_root/default/active/path.sh" || {
  echo "nelix native CLI gate: activation path fragment missing" >&2
  exit 1
}
profile_link="$profile_root/default/active/profile/fixture-tool"
test -x "$profile_link" || {
  echo "nelix native CLI gate: activation profile tree file missing: $profile_link" >&2
  exit 1
}
shim_output="$("$shim" smoke)"
test "$shim_output" = "fixture-tool-ok smoke" || {
  echo "nelix native CLI gate: activation shim output mismatch: $shim_output" >&2
  exit 1
}
profile_link_output="$("$profile_link" smoke)"
test "$profile_link_output" = "fixture-tool-ok smoke" || {
  echo "nelix native CLI gate: activation profile tree output mismatch: $profile_link_output" >&2
  exit 1
}

run_json install_extra native install fixture-extra --profile default --system x86_64-linux
expect_json install_extra '"operation":"native-install"'
expect_json install_extra '"status":"ok"'
expect_json install_extra '"name":"fixture-extra"'
expect_json install_extra '"generation":2'

run_json remove_extra native remove fixture-extra --profile default --system x86_64-linux
expect_json remove_extra '"operation":"native-remove"'
expect_json remove_extra '"status":"ok"'
expect_json remove_extra '"changed":true'
expect_json remove_extra '"count":1'
expect_json remove_extra '"name":"fixture-extra"'
expect_json remove_extra '"generation":3'

run_json profile_after_remove native profile --profile default
expect_json profile_after_remove '"operation":"native-profile"'
expect_json profile_after_remove '"generation":3'
expect_json profile_after_remove '"name":"fixture-tool"'
reject_json profile_after_remove '"name":"fixture-extra"'

run_json rollback native rollback --profile default --generation 1
expect_json rollback '"operation":"native-rollback"'
expect_json rollback '"generation":1'
expect_json rollback '"command":"fixture-tool"'

rollback_shim="$profile_root/default/active/bin/fixture-tool"
test -x "$rollback_shim" || {
  echo "nelix native CLI gate: rollback activation shim missing: $rollback_shim" >&2
  exit 1
}
test ! -e "$profile_root/default/active/bin/fixture-extra" || {
  echo "nelix native CLI gate: rollback left extra activation shim behind" >&2
  exit 1
}
rollback_output="$("$rollback_shim" rollback)"
test "$rollback_output" = "fixture-tool-ok rollback" || {
  echo "nelix native CLI gate: rollback activation output mismatch: $rollback_output" >&2
  exit 1
}

run_json install_app native install fixture-app --profile default --system x86_64-linux
expect_json install_app '"operation":"native-install"'
expect_json install_app '"status":"ok"'
expect_json install_app '"name":"fixture-app"'
expect_json install_app '"name":"fixture-dep"'
expect_json install_app '"dependencies":\['
expect_json install_app '"generation":5'

run_json profile_after_dependency native profile --profile default
expect_json profile_after_dependency '"operation":"native-profile"'
expect_json profile_after_dependency '"generation":5'
expect_json profile_after_dependency '"name":"fixture-tool"'
expect_json profile_after_dependency '"name":"fixture-dep"'
expect_json profile_after_dependency '"name":"fixture-app"'

run_json activate_after_dependency native activate --profile default
expect_json activate_after_dependency '"operation":"native-activate"'
expect_json activate_after_dependency '"generation":5'
expect_json activate_after_dependency '"command":"fixture-dep"'
expect_json activate_after_dependency '"command":"fixture-app"'

dep_shim="$profile_root/default/active/bin/fixture-dep"
app_shim="$profile_root/default/active/bin/fixture-app"
test -x "$dep_shim" || {
  echo "nelix native CLI gate: dependency activation shim missing: $dep_shim" >&2
  exit 1
}
test -x "$app_shim" || {
  echo "nelix native CLI gate: dependent activation shim missing: $app_shim" >&2
  exit 1
}
dep_output="$("$dep_shim" dep)"
test "$dep_output" = "fixture-dep-ok dep" || {
  echo "nelix native CLI gate: dependency activation output mismatch: $dep_output" >&2
  exit 1
}
app_output="$("$app_shim" app)"
test "$app_output" = "fixture-app-ok app" || {
  echo "nelix native CLI gate: dependent activation output mismatch: $app_output" >&2
  exit 1
}

cat >"$registry/fixture-dep.el" <<EOF
(require 'nelix-registry)
(nelix-package
 :name "fixture-dep"
 :version "9.9.9"
 :class 'system-tool
 :description "Drifted native dependency fixture"
 :systems
 '((x86_64-linux
    :source (:type local
             :path $(quote_elisp_string "$payload_dep_drift")
             :sha256 "$sha256_dep_drift")
    :install (:type copy
              :bin ("fixture-dep-drift")))))
EOF

run_json native_locked_apply apply "$native_lock_manifest" --locked
expect_json native_locked_apply '"status":"ok"'
expect_json native_locked_apply '"lock-enforced":true'
expect_json native_locked_apply '"name":"fixture-app"'
expect_json native_locked_apply '"name":"fixture-dep"'

run_json native_locked_profile native profile --profile lockgate
expect_json native_locked_profile '"operation":"native-profile"'
expect_json native_locked_profile '"generation":2'
expect_json native_locked_profile '"name":"fixture-dep"'
expect_json native_locked_profile '"name":"fixture-app"'

run_json native_locked_activate native activate --profile lockgate
expect_json native_locked_activate '"operation":"native-activate"'
expect_json native_locked_activate '"generation":2'
expect_json native_locked_activate '"command":"fixture-dep"'
expect_json native_locked_activate '"command":"fixture-app"'

locked_dep_shim="$profile_root/lockgate/active/bin/fixture-dep"
locked_app_shim="$profile_root/lockgate/active/bin/fixture-app"
test -x "$locked_dep_shim" || {
  echo "nelix native CLI gate: locked dependency shim missing: $locked_dep_shim" >&2
  exit 1
}
test -x "$locked_app_shim" || {
  echo "nelix native CLI gate: locked app shim missing: $locked_app_shim" >&2
  exit 1
}
test ! -e "$profile_root/lockgate/active/bin/fixture-dep-drift" || {
  echo "nelix native CLI gate: locked apply used drifted dependency recipe" >&2
  exit 1
}
locked_dep_output="$("$locked_dep_shim" locked)"
test "$locked_dep_output" = "fixture-dep-ok locked" || {
  echo "nelix native CLI gate: locked dependency output mismatch: $locked_dep_output" >&2
  exit 1
}
locked_app_output="$("$locked_app_shim" locked)"
test "$locked_app_output" = "fixture-app-ok locked" || {
  echo "nelix native CLI gate: locked app output mismatch: $locked_app_output" >&2
  exit 1
}

run_json gc native gc --dry-run --profile default
expect_json gc '"operation":"native-gc"'
expect_json gc '"dry-run":true'
expect_json gc '"removed":null'

echo "nelix native CLI gate ok"
