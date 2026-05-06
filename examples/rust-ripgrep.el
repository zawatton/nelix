;;; rust-ripgrep.el --- Rust example for anvil-pkg -*- lexical-binding: t; -*-

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
;;   M-: (load-file "/path/to/anvil-pkg/examples/rust-ripgrep.el")
;;   M-: (pkg-install 'ripgrep)

;;; Code:

(require 'anvil-pkg-dsl)

(pkg-define ripgrep
  (version "14.1.0")
  (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
                        :rev "14.1.0"
                        :sha256 "sha256-PLACEHOLDER-source-hash"))
  (build-system (rust :cargo-sha256 "sha256-PLACEHOLDER-cargo-deps-hash"))
  (description "Recursively search directories for a regex pattern.")
  (homepage "https://github.com/BurntSushi/ripgrep")
  (license mit))

;; Tip: To get the real :cargo-sha256, install once with a
;; placeholder.  Nix prints both the source hash and the cargo
;; deps hash on mismatch.

(provide 'rust-ripgrep)
;;; rust-ripgrep.el ends here
