;;; python-black.el --- Python pyproject example for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Python package built via `pkgs.python3Packages.buildPythonPackage'.
;; Demonstrates:
;;
;;   - github-fetch source pinning
;;   - the python build-system's optional :format key
;;     (defaults to "setuptools"; "pyproject" / "wheel" available)
;;   - dependency on other python3Packages via :inputs
;;
;; black is psf's opinionated code formatter for Python.  It uses a
;; pyproject.toml so we set :format "pyproject" explicitly.
;;
;; Usage:
;;   M-: (load-file "/path/to/anvil-pkg/examples/python-black.el")
;;   M-: (pkg-install 'black)

;;; Code:

(require 'anvil-pkg-dsl)

(pkg-define black
  (version "24.10.0")
  (source (github-fetch :owner "psf" :repo "black"
                        :rev "24.10.0"
                        :sha256 "sha256-PLACEHOLDER-source-hash"))
  (build-system (python :format "pyproject"))
  (inputs (list python3Packages.click
                python3Packages.mypy-extensions
                python3Packages.packaging
                python3Packages.pathspec
                python3Packages.platformdirs))
  (native-inputs (list python3Packages.hatch-fancy-pypi-readme
                       python3Packages.hatch-vcs
                       python3Packages.hatchling))
  (description "The uncompromising Python code formatter.")
  (homepage "https://github.com/psf/black")
  (license mit))

;; Tip: :inputs / :native-inputs reference attribute paths inside
;; nixpkgs.  The renderer emits them verbatim into the Nix
;; expression — so any pkgs.* path works, not just python3Packages.

(provide 'python-black)
;;; python-black.el ends here
