# anvil-pkg — Claude Code 作業ルール

## このリポジトリの位置づけ

- `anvil.el` の sub-module。`anvil-http` / `anvil-state` / `anvil-defs` ... と並列。
- runtime は `anvil.el` (= NeLisp Stage D) に依存。
- backend は Nix (Phase 1-2) + Git-host fallback (Phase 3)。Nix は外部依存、`anvil-pkg` 自身は Nix を再実装しない。

## 設計 invariant

1. **DSL は Elisp、構文の説明は "Emacs Lisp" を使う** — NeLisp は runtime 詳細であり、ユーザーが書くのは Elisp。
2. **backend 抽象化を保つ** — Phase 4+ で独自 package server に移行する可能性があるため、`nix-` 直接呼び出しは `anvil-pkg-nix-*` に閉じ込め、コア API には漏らさない。
3. **anvil 命名規約準拠** — 関数 prefix `anvil-pkg-`, MCP tool prefix `anvil_pkg_`, defcustom group `anvil-pkg`。
4. **CLI は `anvil pkg ...` サブコマンド形** — `bin/anvil-pkg` 別 binary は作らない。bin/anvil dispatch は anvil.el 側 PR で実装。

## コーディング規約

- Elisp: `lexical-binding: t` 必須、autoload cookie を public API に付ける
- GPL-3.0-or-later (anvil.el / NeLisp と整合)
- ERT テスト: `test/anvil-pkg-*-test.el` (Phase 1 から)
- design doc: `docs/design/NN-<topic>.org` (anvil.el の慣習踏襲)

## Phase 0 → Phase 1 移行条件

- Nix daemon (>=2.18, flakes 有効) を要件として README に明記済 ✓
- `anvil-pkg.el` の 3 stub 関数 (`install` / `search` / `list`) を実装
- `nix profile install` / `nix search --json` / `nix profile list --json` の shell-out wrapper
- `anvil-pkg--nix-install` / `--nix-search` / `--nix-list-installed` (private helpers)
- ERT 6 (各関数の happy path + error path)
- MCP tool 3 本登録 (`anvil_pkg_install` / `_search` / `_list`)

## 参考になる anvil module

- `anvil-state.el` — Commentary block の API list 書式、`defcustom` group 構造
- `anvil-http.el` — shell-out 系 wrapper の error handling pattern
- `anvil-defs.el` — SQLite + index pattern (Phase 4 manifest 設計時の参考)

## async-installer の流用方針

- /home/madblack-21/.emacs.d/external-packages/async-installer/ にある 734 行の Git host 非同期 clone + commit pin + native-compile が参考実装
- Phase 3 の Git-host fallback で **「インスピレーション」として参考にする** が、コードは copy しない (anvil-pkg 流に書き直す)
- 特に `async-installer-git--make-clone-script` の commit pin + sentinel 連鎖は流用価値高
