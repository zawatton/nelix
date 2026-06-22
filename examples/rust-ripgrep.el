;;; rust-ripgrep.el --- Rust example for nelix-core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Rust binary built via `pkgs.rustPlatform.buildRustPackage'.
;; Demonstrates:
;;
;;   - github-fetch source pinning (owner / repo / rev / sha256)
;;   - the rust build-system's required :cargo-sha256
;;     (the hash of the vendored Cargo dependency tree)
;;
;; ripgrep is BurntSushi's grep replacement.  It's a pure-Rust CLI
;; with no native deps beyond the Rust toolchain Nix provides.
;;
;; Usage:
;;   M-: (load-file "/path/to/nelix-core/examples/rust-ripgrep.el")
;;   M-: (pkg-install 'ripgrep)

;;; Code:

(require 'nelix-dsl)

(pkg-define ripgrep
  (version "14.1.0")
  (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
                        :rev "14.1.0"
                        :sha256 "sha256-CBU1GzgWMPTVsgaPMy39VRcENw5iWRUrRpjyuGiZpPI="))
  (build-system (rust :cargo-sha256 "sha256-mi7fPMI8tZRZdW8cDN5p4Q/2ieJ9DnrI+esfUMHiBFk="))
  (description "Recursively search directories for a regex pattern.")
  (homepage "https://github.com/BurntSushi/ripgrep")
  (license mit))

;; Phase 4-H: hashes above are *real*, prefetched 2026-05-06 with
;; `nix-prefetch-url --unpack' for the source and
;; `cargoHash = lib.fakeHash; nix build' for the cargo-deps hash.
;; The DSL keyword stays `:cargo-sha256' for backward compat,
;; but the renderer emits Nix's modern `cargoHash' attribute (>=23.11).

(provide 'rust-ripgrep)
;;; rust-ripgrep.el ends here
