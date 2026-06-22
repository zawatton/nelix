# nelix — Claude Code 作業ルール

> 旧名 `anvil-pkg`。2026-06 に `nelix` へ全面改名済（モジュール `nelix-core` / `nelix-compat` / `nelix-state` / `nelix-import` / `nelix-emacs` / `nelix-dsl` / `nelix-nelisp-smoke`、error contract は `nelix-error` 系、CLI は `bin/nelix`）。公開 API の `pkg-*` は不変。`anvil-pkg-*` 名は全廃（互換 alias は残していない）。

## このリポジトリの位置づけ

- `anvil.el` の sub-module。`anvil-http` / `anvil-state` / `anvil-defs` ... と並列。
- runtime は `anvil.el` (= NeLisp Stage D) に依存。
- backend は Nix (Phase 1-2) + Git-host fallback (Phase 3)。Nix は外部依存、`nelix` 自身は Nix を再実装しない。

## 設計 invariant

1. **DSL は Elisp、構文の説明は "Emacs Lisp" を使う** — NeLisp は runtime 詳細であり、ユーザーが書くのは Elisp。
2. **backend 抽象化を保つ** — Phase 4+ で独自 package server に移行する可能性があるため、`nix-` 直接呼び出しは `nelix-core--nix-*` (private) に閉じ込め、コア API には漏らさない。
3. **3-layer 命名規約**:
   - **project / brand**: `nelix` (repo / docs / commit message。旧 `anvil-pkg`)
   - **公開 Elisp API + DSL macro**: `pkg-` 短形 (`pkg-install` / `pkg-search` / `pkg-list` / `pkg-define`) — nelix が `pkg-` namespace を deliberate に claim、`package.el` (built-in) は `package-` で衝突なし。加えて `nelix-*` facade (`nelix-define` / `nelix-render-nix` / `nelix-environment` 等) も公開 API
   - **Elisp 内部実装**: `nelix-<module>--` (private double-dash、module 別: `nelix-core--` / `nelix-compat--` / `nelix-state--` …)
   - **MCP tool id**: `pkg-install` 等 (Elisp 公開 API と一致)
   - **DSL sub-form** (macro 内部): unprefixed Guix 風 — `(version "1.0") (source (url-fetch ...))`、macro consume のため global namespace 不汚染
   - **error contract**: `nelix-error` (親) / `nelix-nix-not-found` / `nelix-nix-failed` / `nelix-async-not-supported` / `nelix-http-not-supported` (旧 `anvil-pkg-error` 系)
   - **旧 `anvil-pkg-*` は全廃**: full rename 済 (2026-06)、互換 alias は残さない
4. **CLI は `nelix ...`** (`bin/nelix`) — 旧 `anvil pkg ...` サブコマンド形から改称。

## コーディング規約

- Elisp: `lexical-binding: t` 必須、autoload cookie を public API に付ける
- GPL-3.0-or-later (anvil.el / NeLisp と整合)
- ERT テスト: `test/nelix-*-test.el` (Phase 1 から)
- design doc: `docs/design/NN-<topic>.org` (anvil.el の慣習踏襲)

## Phase 0 → Phase 1 移行条件

- Nix daemon (>=2.18, flakes 有効) を要件として README に明記済 ✓
- `nelix-core.el` (旧 `anvil-pkg.el`) の 3 stub 関数 (`install` / `search` / `list`) を実装
- `nix profile install` / `nix search --json` / `nix profile list --json` の shell-out wrapper
- `nelix-core--nix-install` / `--nix-search` / `--nix-list-installed` (private helpers)
- ERT 6 (各関数の happy path + error path)
- MCP tool 3 本登録 (`pkg-install` / `pkg-search` / `pkg-list`)

## 参考になる anvil module

- `anvil-state.el` — Commentary block の API list 書式、`defcustom` group 構造
- `anvil-http.el` — shell-out 系 wrapper の error handling pattern
- `anvil-defs.el` — SQLite + index pattern (Phase 4 manifest 設計時の参考)

## async-installer の流用方針

- /home/madblack-21/.emacs.d/external-packages/async-installer/ にある 734 行の Git host 非同期 clone + commit pin + native-compile が参考実装
- Phase 3 の Git-host fallback で **「インスピレーション」として参考にする** が、コードは copy しない (nelix 流に書き直す)
- 特に `async-installer-git--make-clone-script` の commit pin + sentinel 連鎖は流用価値高
