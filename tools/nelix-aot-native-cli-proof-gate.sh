#!/usr/bin/env bash
# Gate the public standalone `.neln' native execution path used by Nelix AOT.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

EMACS="${EMACS:-emacs}"
NELISP_REPO="${NELISP_REPO:-$(cd ../nelisp 2>/dev/null && pwd || printf '%s\n' ../nelisp)}"
NELISP_CACHE_DIR="${NELISP_CACHE_DIR:-.cache/nelisp}"
NELISP="${NELISP:-$(command -v nelisp 2>/dev/null || true)}"

if [ -z "$NELISP" ]; then
  if [ -x ../nelisp/target/nelisp ]; then
    NELISP=../nelisp/target/nelisp
  elif [ -x ../nelisp/target/debug/nelisp ]; then
    NELISP=../nelisp/target/debug/nelisp
  else
    NELISP=nelisp
  fi
fi

{ test -d "$NELISP_REPO/lisp" && test -d "$NELISP_REPO/src"; } || {
  echo "error: NELISP_REPO does not point at a NeLisp checkout: $NELISP_REPO" >&2
  exit 1
}

{ test -x "$NELISP" || command -v "$NELISP" >/dev/null 2>&1; } || {
  echo "error: nelisp executable not found: $NELISP" >&2
  exit 1
}

{ command -v cc >/dev/null 2>&1 && command -v objcopy >/dev/null 2>&1; } || {
  echo "error: cc and objcopy are required for .neln standalone native proof" >&2
  exit 1
}

mkdir -p "$NELISP_CACHE_DIR"
artifact="$NELISP_CACHE_DIR/nelix-aot-native-cli-proof.neln"
rm -f "$artifact" "$artifact.manifest.el"

"$EMACS" -Q --batch \
  -L "$NELISP_REPO/lisp" \
  -L "$NELISP_REPO/src" \
  --eval '(setq load-prefer-newer t)' \
  --eval '(require (quote nelisp-artifact))' \
  --eval "(nelisp-artifact-compile-file \"scripts/nelix-aot-native-cli-proof.el\" \"$artifact\" nil nil nil nil nil (quote neln))"

line_payload="$(printf 'NELIX-AOT-MANIFEST-V1\ntarget\tmagit\tmagit\npin\tripgrep\ninstalled\tmagit\nend\n')"
subset_cli_proof="$("$NELISP" native-exec-elisp-artifact "$artifact" nelix-aot-native-cli-proof-code "$line_payload")"
test "$subset_cli_proof" = "556" || {
  echo "error: standalone subset CLI proof returned $subset_cli_proof" >&2
  exit 1
}

subset_cli_output="$("$NELISP" native-exec-elisp-artifact "$artifact" nelix-aot-native-cli-lines-proof "$line_payload")"
subset_cli_expected="$(printf 'ok\ttrue\npresent\tmagit')"
subset_cli_expected_lisp='"ok\ttrue\npresent\tmagit\n"'
{ test "$subset_cli_output" = "$subset_cli_expected" ||
  test "$subset_cli_output" = "$subset_cli_expected_lisp"; } || {
  echo "error: standalone subset CLI line fragment returned $subset_cli_output" >&2
  exit 1
}

id_line_payload="$(printf 'NELIX-AOT-MANIFEST-V1\ntarget-id\t1\t1\ntarget-id\t2\t2\ntarget-id\t3\t3\ninstalled-id\t1\ninstalled-id\t2\nend\n')"
subset_cli_id_output="$("$NELISP" native-exec-elisp-artifact "$artifact" nelix-aot-native-cli-audit-id-lines-proof "$id_line_payload")"
subset_cli_id_expected="$(printf 'ok\tfalse\npresent\tmagit\npresent\tripgrep\nmissing\tfd\nbackend\tnix')"
subset_cli_id_expected_lisp='"ok\tfalse\npresent\tmagit\npresent\tripgrep\nmissing\tfd\nbackend\tnix\n"'
{ test "$subset_cli_id_output" = "$subset_cli_id_expected" ||
  test "$subset_cli_id_output" = "$subset_cli_id_expected_lisp"; } || {
  echo "error: standalone subset CLI ID audit line report returned $subset_cli_id_output" >&2
  exit 1
}

id_upgrade_payload="$(printf 'NELIX-AOT-MANIFEST-V1\ntarget-id\t1\t1\ntarget-id\t2\t2\ntarget-id\t3\t3\npin-id\t2\ninstalled-id\t1\ninstalled-id\t2\nend\n')"
subset_cli_id_upgrade_output="$("$NELISP" native-exec-elisp-artifact "$artifact" nelix-aot-native-cli-upgrade-id-lines-proof "$id_upgrade_payload")"
subset_cli_id_upgrade_expected="$(printf 'operation\tupgrade\nupgrade\tmagit\npinned\tripgrep\nmissing\tfd\nbackend\tnix')"
subset_cli_id_upgrade_expected_lisp='"operation\tupgrade\nupgrade\tmagit\npinned\tripgrep\nmissing\tfd\nbackend\tnix\n"'
{ test "$subset_cli_id_upgrade_output" = "$subset_cli_id_upgrade_expected" ||
  test "$subset_cli_id_upgrade_output" = "$subset_cli_id_upgrade_expected_lisp"; } || {
  echo "error: standalone subset CLI ID upgrade line report returned $subset_cli_id_upgrade_output" >&2
  exit 1
}

large_id_payload="$(
  {
    printf 'NELIX-AOT-MANIFEST-V1\n'
    i=1
    while [ "$i" -le 204 ]; do
      id=$(( (i - 1) % 4 + 1 ))
      printf 'target-id\t%s\t%s\n' "$id" "$id"
      i=$(( i + 1 ))
    done
    printf 'pin-id\t2\ninstalled-id\t1\ninstalled-id\t2\nend\n'
  }
)"
large_id_scan_proof="$("$NELISP" native-exec-elisp-artifact "$artifact" nelix-aot-native-cli-large-id-scan-proof "$large_id_payload")"
test "$large_id_scan_proof" = "206" || {
  echo "error: standalone large ID scan proof returned $large_id_scan_proof" >&2
  exit 1
}

echo "nelix-aot-native-cli-proof-gate: standalone .neln CLI proof passed"
