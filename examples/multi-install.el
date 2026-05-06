;;; multi-install.el --- Multiple pkg-define forms in one file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Many users want to declare a bundle of packages in one place
;; (the "Brewfile" / "Packages.dhall" pattern).  anvil-pkg supports
;; this directly with Phase 4-F's multi-install dispatch:
;;
;;   (pkg-install '(ripgrep fd hyperfine))
;;
;; renders the flake once and invokes `nix profile install' once
;; with all three flakerefs.  Atomic — Nix either installs every
;; package as one new generation or none.
;;
;; Mixed lists work too:
;;
;;   (pkg-install '(ripgrep "jq"))   ; rust pkg-define + nixpkgs string
;;
;; To roll back the bulk: `pkg-rollback' (the entire generation
;; goes away).  To drop one of them while keeping the rest:
;; `(pkg-rollback-package 'fd)' (Phase 4-D).
;;
;; Usage:
;;   M-: (load-file "/path/to/anvil-pkg/examples/multi-install.el")
;;   M-: (pkg-install '(ripgrep fd hyperfine))

;;; Code:

(require 'anvil-pkg-dsl)

;; Cross-language bundle: rust CLI tools that share a common upstream
;; layout (single-binary, no deps beyond rustc / cargo).

(pkg-define ripgrep
  (version "14.1.0")
  (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
                        :rev "14.1.0"
                        :sha256 "sha256-PLACEHOLDER"))
  (build-system (rust :cargo-sha256 "sha256-PLACEHOLDER"))
  (description "Recursively search directories for a regex pattern.")
  (homepage "https://github.com/BurntSushi/ripgrep"))

(pkg-define fd
  (version "10.2.0")
  (source (github-fetch :owner "sharkdp" :repo "fd"
                        :rev "v10.2.0"
                        :sha256 "sha256-PLACEHOLDER"))
  (build-system (rust :cargo-sha256 "sha256-PLACEHOLDER"))
  (description "A simple, fast and user-friendly alternative to find.")
  (homepage "https://github.com/sharkdp/fd"))

(pkg-define hyperfine
  (version "1.18.0")
  (source (github-fetch :owner "sharkdp" :repo "hyperfine"
                        :rev "v1.18.0"
                        :sha256 "sha256-PLACEHOLDER"))
  (build-system (rust :cargo-sha256 "sha256-PLACEHOLDER"))
  (description "A command-line benchmarking tool.")
  (homepage "https://github.com/sharkdp/hyperfine"))

;; To install all three in one shot (Phase 4-F):
;;   (pkg-install '(ripgrep fd hyperfine))
;;
;; To roll back one package without losing the others (Phase 4-D):
;;   (pkg-rollback-package 'fd)
;;
;; To inspect what's currently installed:
;;   (pkg-list)

(provide 'multi-install)
;;; multi-install.el ends here
