;;; anvil-pkg.el --- Elisp DSL package manager for anvil, backed by Nix store -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; Maintainer: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.1.0
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
;; Phase 1 (this revision) ships the synchronous `nix profile' wrapper
;; for three core verbs: install, search, list.  Phase 2 adds a DSL
;; macro (`anvil-pkg-define'); Phase 3 a Git-host fallback; Phase 4
;; profile / generation management.
;;
;; Public Elisp API (pkg- short prefix; anvil-pkg owns the `pkg-'
;; namespace by deliberate ecosystem choice — see CLAUDE.md):
;;   (pkg-install NAME)
;;   (pkg-search QUERY)
;;   (pkg-list)
;;   (pkg-define NAME &rest BODY)   ; Phase 2
;;
;; Backwards-compatible long-form aliases (`anvil-pkg-install' etc.) are
;; provided via `defalias' for callers that prefer Emacs prefix style.
;;
;; MCP tools (registered by `anvil-pkg-enable'):
;;   pkg-install / pkg-search / pkg-list
;;
;; CLI surface (out of scope for this repo; landed in anvil.el):
;;   anvil pkg install <name>
;;   anvil pkg search  <query>
;;   anvil pkg list

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup anvil-pkg nil
  "Elisp DSL package manager backed by Nix store."
  :group 'anvil
  :prefix "anvil-pkg-")

(defconst anvil-pkg--server-id "emacs-eval"
  "MCP server id that anvil-pkg tools register under.
Shared with anvil-http / anvil-state / anvil-defs so a single
Claude Code MCP session sees one unified tool list.")

(defcustom anvil-pkg-default-backend 'nix
  "Default backend used when `anvil-pkg-install' is called without :backend.
Phase 1 only honours `nix'; `git' lands in Phase 3 (async-installer
derived fallback)."
  :type '(choice (const :tag "Nix profile (nixpkgs)" nix)
                 (const :tag "Git-host fallback" git))
  :group 'anvil-pkg)

(defcustom anvil-pkg-nix-channel "nixpkgs"
  "Flake reference for the primary Nix channel.
Used as `<channel>#<name>' when invoking `nix profile install'."
  :type 'string
  :group 'anvil-pkg)

(defcustom anvil-pkg-profile-dir
  (expand-file-name "anvil-pkg/profile"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state"
                                          (or (getenv "HOME") "~"))))
  "Directory for the anvil-pkg Nix profile.
Isolated from `~/.nix-profile' so anvil-pkg installs do not collide
with the user's other Nix profiles.  PATH augmentation is the
caller's responsibility (Phase 4 will add an `anvil pkg env'
helper)."
  :type 'directory
  :group 'anvil-pkg)

(defcustom anvil-pkg-nix-program "nix"
  "Name (or absolute path) of the `nix' executable."
  :type 'string
  :group 'anvil-pkg)

;;;; --- error symbols ---------------------------------------------------------

(define-error 'anvil-pkg-error "anvil-pkg error")
(define-error 'anvil-pkg-nix-not-found
              "nix binary not found on PATH"
              'anvil-pkg-error)
(define-error 'anvil-pkg-nix-failed
              "nix command exited non-zero"
              'anvil-pkg-error)

;;;; --- backend abstraction ---------------------------------------------------

(defvar anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default
  "Function used to invoke `nix'.  Override in tests.

Called with one argument — a list of string ARGS for the `nix'
executable.  Must return a plist with the keys :exit (integer),
:stdout (string), :stderr (string).")

(defun anvil-pkg--call-nix-default (args)
  "Default `nix' invoker.  Run synchronously via `call-process'.

ARGS is a list of string arguments passed to the executable named
by `anvil-pkg-nix-program'.  Stdout is captured to a buffer,
stderr to a temp file (so the two streams stay separate even when
nix interleaves them).  Returns plist (:exit :stdout :stderr).

Phase 4 will introduce an async variant gated by `:async'; for now
install / search / list block the daemon while nix runs.  This is
acceptable for PoC because search is fast (<1s warm cache) and
install is a user-initiated action."
  (let ((stdout-buf (generate-new-buffer " *anvil-pkg-nix-stdout*"))
        (stderr-file (make-temp-file "anvil-pkg-nix-stderr-")))
    (unwind-protect
        (let ((exit (apply #'call-process
                           anvil-pkg-nix-program
                           nil
                           (list stdout-buf stderr-file)
                           nil
                           args)))
          (list :exit (if (numberp exit) exit -1)
                :stdout (with-current-buffer stdout-buf
                          (buffer-string))
                :stderr (with-temp-buffer
                          (insert-file-contents stderr-file)
                          (buffer-string))))
      (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf))
      (when (file-exists-p stderr-file) (delete-file stderr-file)))))

(defun anvil-pkg--call-nix (args)
  "Invoke `nix' with ARGS via `anvil-pkg--call-nix-fn'."
  (funcall anvil-pkg--call-nix-fn args))

(defun anvil-pkg--ensure-nix ()
  "Signal `anvil-pkg-nix-not-found' if the nix binary is missing.
Q1 in design doc 01: loud failure at call site, not at load time."
  (unless (or (not (eq anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default))
              (executable-find anvil-pkg-nix-program))
    (signal 'anvil-pkg-nix-not-found
            (list (format "%s not on PATH; install Nix 2.18+ with flakes"
                          anvil-pkg-nix-program)))))

(defun anvil-pkg--profile-args ()
  "Return the `--profile <dir>' fragment for nix-profile commands."
  (list "--profile" (expand-file-name anvil-pkg-profile-dir)))

;;;; --- JSON parsing helpers --------------------------------------------------

(defun anvil-pkg--json-parse (json-str)
  "Parse JSON-STR into nested alists/lists.  Empty string returns nil."
  (when (and json-str (> (length (string-trim json-str)) 0))
    (json-parse-string json-str
                       :object-type 'alist
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun anvil-pkg--parse-search (json-str)
  "Parse `nix search --json' output JSON-STR into list of plists.

Each plist carries :name :description :version :attrpath."
  (let ((data (anvil-pkg--json-parse json-str)))
    (when data
      (mapcar (lambda (entry)
                (let* ((attr (car entry))
                       (info (cdr entry))
                       (attr-str (if (symbolp attr)
                                     (symbol-name attr)
                                   (format "%s" attr))))
                  (list :name (or (alist-get 'pname info)
                                  (car (last (split-string attr-str "\\."))))
                        :description (alist-get 'description info)
                        :version (alist-get 'version info)
                        :attrpath attr-str)))
              data))))

(defun anvil-pkg--parse-list (json-str)
  "Parse `nix profile list --json' output JSON-STR into list of plists.

Each plist carries :name :attr-path :original-url :store-paths.
Accepts the modern Nix 2.18+ schema where `elements' is an object
keyed by package name."
  (let* ((data (anvil-pkg--json-parse json-str))
         (elements (alist-get 'elements data)))
    (when (and elements (consp elements))
      (mapcar (lambda (entry)
                (let* ((name (car entry))
                       (info (cdr entry))
                       (name-str (if (symbolp name)
                                     (symbol-name name)
                                   (format "%s" name))))
                  (list :name name-str
                        :attr-path (alist-get 'attrPath info)
                        :original-url (alist-get 'originalUrl info)
                        :store-paths (alist-get 'storePaths info))))
              elements))))

;;;; --- public API ------------------------------------------------------------

(defun anvil-pkg--install-nixpkgs (name)
  "Install nixpkgs#NAME via `nix profile install'.  String path.
Internal helper called by `pkg-install' when NAME is a string."
  (anvil-pkg--ensure-nix)
  (let* ((flakeref (format "%s#%s" anvil-pkg-nix-channel name))
         (args (append (list "profile" "install")
                       (anvil-pkg--profile-args)
                       (list flakeref)))
         (res (anvil-pkg--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            name
                            (plist-get res :exit)
                            (string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

(declare-function anvil-pkg--install-symbol "anvil-pkg-dsl")

;;;###autoload
(defun pkg-install (name)
  "Install package NAME.

NAME is one of:
  - a string nixpkgs attribute path (e.g. \"ripgrep\", \"nodejs_20\")
    → installs nixpkgs#NAME directly;
  - a symbol previously declared via `pkg-define' (Phase 2)
    → looks up the local registry, regenerates flake.nix under
    `anvil-pkg-profile-dir's parent, and installs from that flake.

Returns t on success.  Signals `anvil-pkg-nix-failed' /
`anvil-pkg-nix-not-found' / `anvil-pkg-undefined-package' as
appropriate."
  (cond
   ((stringp name) (anvil-pkg--install-nixpkgs name))
   ((symbolp name)
    (require 'anvil-pkg-dsl)
    (anvil-pkg--install-symbol name))
   (t (signal 'anvil-pkg-error
              (list (format "pkg-install: NAME must be string or symbol, got %S"
                            name))))))

;;;###autoload
(defun pkg-search (query)
  "Search nixpkgs for packages matching QUERY.

QUERY is a free-form regex passed to `nix search'.  Returns a list
of plists carrying :name :description :version :attrpath, or nil
when no packages match."
  (anvil-pkg--ensure-nix)
  (let* ((args (list "search" anvil-pkg-nix-channel query "--json"))
         (res (anvil-pkg--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-nix-failed
              (list (format "nix search %s failed (exit %s): %s"
                            query
                            (plist-get res :exit)
                            (string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (anvil-pkg--parse-search (plist-get res :stdout))))

;;;###autoload
(defun pkg-list ()
  "List packages installed in the anvil-pkg Nix profile.

Returns a list of plists carrying :name :attr-path :original-url
:store-paths, or nil for an empty profile."
  (anvil-pkg--ensure-nix)
  (let* ((args (append (list "profile" "list" "--json")
                       (anvil-pkg--profile-args)))
         (res (anvil-pkg--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile list failed (exit %s): %s"
                            (plist-get res :exit)
                            (string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (anvil-pkg--parse-list (plist-get res :stdout))))

;;;; --- backwards-compatible long-form aliases -------------------------------
;; anvil-pkg owns the `pkg-' namespace as its public DSL surface; the
;; long-form `anvil-pkg-' aliases below remain available so callers
;; using strict Emacs-prefix style still work.

;;;###autoload
(defalias 'anvil-pkg-install #'pkg-install)
;;;###autoload
(defalias 'anvil-pkg-search #'pkg-search)
;;;###autoload
(defalias 'anvil-pkg-list #'pkg-list)

;;;; --- MCP tool surface ------------------------------------------------------

(declare-function anvil-server-register-tool "anvil-server")
(declare-function anvil-server-unregister-tool "anvil-server")

(defun anvil-pkg--tool-install (name)
  "MCP wrapper around `pkg-install'.

MCP Parameters:
  name - nixpkgs attribute path to install (e.g. \"ripgrep\")."
  (pkg-install name)
  (list :status "ok" :name name))

(defun anvil-pkg--tool-search (query)
  "MCP wrapper around `pkg-search'.

MCP Parameters:
  query - free-form search regex passed to `nix search'."
  (let ((rows (pkg-search query)))
    (list :count (length rows)
          :results (or rows []))))

(defun anvil-pkg--tool-list ()
  "MCP wrapper around `pkg-list'.

MCP Parameters: (none)."
  (let ((rows (pkg-list)))
    (list :count (length rows)
          :installed (or rows []))))

(defun anvil-pkg--register-tools ()
  "Register pkg-* MCP tools under `anvil-pkg--server-id'."
  (anvil-server-register-tool
   #'anvil-pkg--tool-install
   :id "pkg-install"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "Install a package by name into the anvil-pkg Nix profile.
Wraps `nix profile install <channel>#<name>' with a profile
isolated from ~/.nix-profile.  Returns :status \"ok\" on success;
signals an error carrying nix stderr on failure.")

  (anvil-server-register-tool
   #'anvil-pkg--tool-search
   :id "pkg-search"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "Search nixpkgs for packages matching QUERY.  Returns :count and
:results (list of plists carrying name, description, version,
attrpath).  Read-only — does not modify the profile."
   :read-only t)

  (anvil-server-register-tool
   #'anvil-pkg--tool-list
   :id "pkg-list"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "List packages currently installed in the anvil-pkg Nix profile.
Returns :count and :installed (list of plists with name, attr-path,
original-url, store-paths).  Read-only."
   :read-only t))

(defun anvil-pkg--unregister-tools ()
  "Remove every pkg-* MCP tool from the shared anvil server."
  (dolist (id '("pkg-install" "pkg-search" "pkg-list"))
    (anvil-server-unregister-tool id anvil-pkg--server-id)))

;;;###autoload
(defun anvil-pkg-enable ()
  "Register the pkg-* MCP tool surface.
Requires `anvil-server' (loaded with anvil.el).  Safe to call
repeatedly — re-registers idempotently."
  (interactive)
  (require 'anvil-server)
  (anvil-pkg--register-tools)
  (message "anvil-pkg: enabled (3 MCP tools, profile = %s)"
           anvil-pkg-profile-dir))

(defun anvil-pkg-disable ()
  "Unregister the pkg-* MCP tool surface."
  (interactive)
  (require 'anvil-server)
  (anvil-pkg--unregister-tools))

(provide 'anvil-pkg)
;;; anvil-pkg.el ends here
