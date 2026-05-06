;;; stdenv-hello.el --- Minimal stdenv example for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The smallest meaningful `pkg-define': fetch a release tarball,
;; build with the default `pkgs.stdenv.mkDerivation' wrapper.  No
;; language-specific build system, no auto-deps, no install hooks.
;;
;; GNU Hello prints "Hello, world!" and is the canonical "this
;; build system actually works" sanity check.
;;
;; Usage:
;;   M-: (load-file "/path/to/anvil-pkg/examples/stdenv-hello.el")
;;   M-: (pkg-install 'gnu-hello)
;;
;; Replace the sha256 placeholder before installing — see
;; examples/README.org for the workflow.

;;; Code:

(require 'anvil-pkg-dsl)

(pkg-define gnu-hello
  (version "2.12.1")
  (source (url-fetch "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"
                     :sha256 "sha256-PLACEHOLDER-fill-in-from-nix-prefetch-url"))
  (build-system (stdenv))
  (description "GNU Hello prints a friendly greeting.")
  (homepage "https://www.gnu.org/software/hello/")
  (license gpl3))

(provide 'stdenv-hello)
;;; stdenv-hello.el ends here
