;;; anvil-pkg.el --- Elisp DSL package manager for anvil, backed by Nix store -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; Maintainer: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix

;; This file is part of anvil-pkg.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; anvil-pkg is a package manager configured in Emacs Lisp, backed by
;; the Nix store.  It is the Elisp counterpart of GNU Guix (Scheme +
;; Nix store), integrated as an `anvil.el' sub-module so AI agents can
;; install packages by emitting one Elisp form via MCP tools.
;;
;; Design doc: docs/design/01-overview.org.
;;
;; Phase 0 — only stubs exist.  No backend dispatch yet.
;;
;; Public Elisp API (Phase 1 target):
;;   (anvil-pkg-install NAME &key backend version)
;;   (anvil-pkg-search QUERY)
;;   (anvil-pkg-list)
;;
;; CLI (Phase 1 target, dispatched by bin/anvil):
;;   anvil pkg install <name>
;;   anvil pkg search  <query>
;;   anvil pkg list

;;; Code:

(defgroup anvil-pkg nil
  "Elisp DSL package manager backed by Nix store."
  :group 'anvil
  :prefix "anvil-pkg-")

(defcustom anvil-pkg-default-backend 'nix
  "Default backend used when `anvil-pkg-install' is called without :backend."
  :type '(choice (const :tag "Nix profile (nixpkgs)" nix)
                 (const :tag "Git-host fallback" git))
  :group 'anvil-pkg)

(defcustom anvil-pkg-nix-channel "nixpkgs"
  "Flake reference for the primary Nix channel.
Used by the Phase 1 `nix profile install <channel>#<name>' wrapper."
  :type 'string
  :group 'anvil-pkg)

(defun anvil-pkg-install (_name &rest _args)
  "Install package NAME.  Phase 0 stub.

Phase 1 will dispatch to `anvil-pkg--nix-install' or the Git-host
fallback based on :backend (defaulting to `anvil-pkg-default-backend').

Keyword args planned for Phase 1:
  :backend  — `nix' (default) or `git'
  :version  — version pin (Nix: flake input override; Git: commit/tag)"
  (error "anvil-pkg-install: not implemented (Phase 0 stub)"))

(defun anvil-pkg-search (_query)
  "Search for packages matching QUERY.  Phase 0 stub.

Phase 1 will wrap `nix search nixpkgs <query> --json' and return a
list of plists with :name :version :description."
  (error "anvil-pkg-search: not implemented (Phase 0 stub)"))

(defun anvil-pkg-list ()
  "List installed packages in the active anvil-pkg profile.  Phase 0 stub.

Phase 1 will wrap `nix profile list --json'."
  (error "anvil-pkg-list: not implemented (Phase 0 stub)"))

(provide 'anvil-pkg)
;;; anvil-pkg.el ends here
