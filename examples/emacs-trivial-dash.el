;;; emacs-trivial-dash.el --- emacs-package trivial example -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An Emacs Lisp library built via `pkgs.emacsPackages.trivialBuild'.
;; Demonstrates:
;;
;;   - emacs-package build-system with :format "trivial"
;;     (the simpler of the two builders; for single-root .el
;;     packages without a MELPA recipe / dir / .info)
;;   - the Phase 4-A :require keyword on pkg-install — after the
;;     Nix store path lands, anvil-pkg adds it to load-path and
;;     calls (require 'dash).
;;   - automatic :depends-on derivation (Phase 4-C/4-D L18) — the
;;     Package-Requires header is read from raw.githubusercontent.com
;;     at install time and cached in anvil-pkg-state.
;;
;; dash.el is a single-file functional library with no further deps.
;;
;; Usage:
;;   M-: (load-file "/path/to/anvil-pkg/examples/emacs-trivial-dash.el")
;;   M-: (pkg-install 'dash :require t)

;;; Code:

(require 'anvil-pkg-dsl)

(pkg-define dash
  (version "2.20.0")
  (source (github-fetch :owner "magnars" :repo "dash.el"
                        :rev "2.20.0"
                        :sha256 "sha256-PLACEHOLDER-fill-in-from-nix"))
  (build-system (emacs-package :format "trivial"))
  (description "A modern list library for Emacs.")
  (homepage "https://github.com/magnars/dash.el")
  (license gpl3))

;; Variant with native compilation (Phase 4-B :native-comp t):
;;
;; (pkg-define dash-native
;;   (version "2.20.0")
;;   (source (github-fetch :owner "magnars" :repo "dash.el"
;;                         :rev "2.20.0" :sha256 "sha256-..."))
;;   (build-system (emacs-package :format "trivial" :native-comp t)))
;;
;; The renderer wraps in (pkgs.emacsPackagesFor pkgs.emacs) so the
;; resulting .elc / .eln files match the running Emacs version.

(provide 'emacs-trivial-dash)
;;; emacs-trivial-dash.el ends here
