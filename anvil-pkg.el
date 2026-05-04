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

(require 'anvil-pkg-compat)

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
  (expand-file-name
   "anvil-pkg/profile"
   (or (anvil-pkg-compat-getenv "XDG_STATE_HOME")
       (expand-file-name ".local/state"
                         (or (anvil-pkg-compat-getenv "HOME") "~"))))
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

;; Use the compat helper instead of `define-error' so the same install
;; runs on NeLisp standalone (which does not provide that macro).
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-error
                                      "anvil-pkg error")
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-nix-not-found
                                      "nix binary not found on PATH"
                                      'anvil-pkg-error)
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-nix-failed
                                      "nix command exited non-zero"
                                      'anvil-pkg-error)
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-async-not-supported
                                      "asynchronous install not supported on this runtime"
                                      'anvil-pkg-error)

;;;; --- backend abstraction ---------------------------------------------------

(defvar anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default
  "Function used to invoke `nix'.  Override in tests.

Called with one argument — a list of string ARGS for the `nix'
executable.  Must return a plist with the keys :exit (integer),
:stdout (string), :stderr (string).")

(defun anvil-pkg--call-nix-default (args)
  "Default `nix' invoker.  Synchronous, runtime-portable.

ARGS is a list of string arguments passed to the executable named
by `anvil-pkg-nix-program'.  Returns plist (:exit :stdout :stderr).

Implementation defers I/O to `anvil-pkg-compat-call-process' so
the same code runs on Emacs and on NeLisp standalone.  Phase 4
will introduce an async variant gated by `:async'."
  (anvil-pkg-compat-call-process anvil-pkg-nix-program args))

(defun anvil-pkg--call-nix (args)
  "Invoke `nix' with ARGS via `anvil-pkg--call-nix-fn'."
  (funcall anvil-pkg--call-nix-fn args))

(defvar anvil-pkg--make-process-fn #'make-process
  "Function used to spawn the async `nix' process.  Override in tests.

Mirrors the test-mock pattern of `anvil-pkg--call-nix-fn'.  Called
with the exact keyword arguments accepted by `make-process' and
must return a process object (or a fake object whose sentinel can
be invoked by the test).  Only consulted from the `:async t'
branch of `pkg-install'; the synchronous path continues to use
`anvil-pkg-compat-call-process'.")

(defun anvil-pkg--ensure-nix ()
  "Signal `anvil-pkg-nix-not-found' if the nix binary is missing.
Q1 in design doc 01: loud failure at call site, not at load time.
Skipped in test mode (= when `anvil-pkg--call-nix-fn' is
overridden) because mock backends do not need nix on PATH."
  (unless (or (not (eq anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default))
              (anvil-pkg-compat-executable-find anvil-pkg-nix-program))
    (signal 'anvil-pkg-nix-not-found
            (list (format "%s not on PATH; install Nix 2.18+ with flakes"
                          anvil-pkg-nix-program)))))

(defun anvil-pkg--profile-args ()
  "Return the `--profile <dir>' fragment for nix-profile commands."
  (list "--profile" (expand-file-name anvil-pkg-profile-dir)))

;;;; --- JSON parsing helpers --------------------------------------------------

(defun anvil-pkg--json-parse (json-str)
  "Parse JSON-STR into nested alists/lists.  Empty string returns nil."
  (anvil-pkg-compat-json-parse json-str))

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

(declare-function anvil-pkg--registry-get "anvil-pkg-dsl")

(defun anvil-pkg--plist-has-key-p (plist key)
  "Return non-nil when PLIST contains KEY."
  (let ((rest plist)
        found)
    (while rest
      (when (eq (car rest) key)
        (setq found t
              rest nil))
      (when rest
        (setq rest (cddr rest))))
    found))

(defun anvil-pkg--registry-build-system-type (name)
  "Return registered build-system :type for symbol package NAME."
  (let ((ir (anvil-pkg--registry-get name)))
    (plist-get (plist-get ir :build-system) :type)))

(defvar anvil-pkg--registry) ; defined in anvil-pkg-dsl.el
(declare-function anvil-pkg-emacs-derive-deps "anvil-pkg-emacs")

(defun anvil-pkg--maybe-derive-deps (name no-auto-deps)
  "Phase 4-C L18 hook: pre-fetch `:depends-on' for NAME's IR.

When NAME's registered IR is an `emacs-package' build-system with
no explicit `:depends-on' and NO-AUTO-DEPS is nil, run
`anvil-pkg-emacs-derive-deps' against the IR and `puthash' the
augmented IR back into `anvil-pkg--registry'.  No-op otherwise.

The L8 invariant — explicit `(depends-on ...)` always wins — is
preserved by the `:depends-on' check below: if the user wrote
`(depends-on (list ...))` in their `pkg-define', we never
overwrite it.

Returns the (possibly augmented) IR for caller convenience."
  (require 'anvil-pkg-dsl)
  (let* ((ir (anvil-pkg--registry-get name))
         (build-type (plist-get (plist-get ir :build-system) :type))
         (existing-deps (plist-get ir :depends-on)))
    (when (and (eq build-type 'emacs-package)
               (null existing-deps)
               (not no-auto-deps))
      (require 'anvil-pkg-emacs)
      (let ((derived (anvil-pkg-emacs-derive-deps ir)))
        (when derived
          (let ((augmented (plist-put (copy-sequence ir)
                                      :depends-on derived)))
            (puthash name augmented anvil-pkg--registry)
            (setq ir augmented)))))
    ir))

(defun anvil-pkg--emacs-package-after-install (name)
  "Augment `load-path' for installed Emacs package NAME.

Looks up NAME in `pkg-list', then searches its `:store-paths' for
the first existing site-lisp directory.  nixpkgs Emacs builders
emit one of two layouts:

  - flat        :  $out/share/emacs/site-lisp/             (trivialBuild)
  - per-package :  $out/share/emacs/site-lisp/<pname>/     (some recipes)
  - elpa-style  :  $out/share/emacs/site-lisp/elpa/<pname>-<ver>/  (melpaBuild)

We try the per-package, elpa, then flat candidate in turn and add
the first hit to `load-path'.  Returns the directory path on
success or nil when no profile element / no site-lisp dir
exists."
  (let* ((pkg-name (symbol-name name))
         (entries (pkg-list))
         entry
         match-dir)
    (dolist (item entries)
      (when (and (null entry)
                 (equal (plist-get item :name) pkg-name))
        (setq entry item)))
    (when entry
      (dolist (store-path (plist-get entry :store-paths))
        (when (null match-dir)
          (let* ((per-pkg (expand-file-name
                           (format "share/emacs/site-lisp/%s" pkg-name)
                           store-path))
                 (flat    (expand-file-name "share/emacs/site-lisp"
                                            store-path))
                 (chosen
                  (cond
                   ;; per-package subdir wins when it exists
                   ((anvil-pkg-compat-file-exists-p per-pkg) per-pkg)
                   ;; elpa-style: pick the first elpa subdir starting with pname
                   ((let* ((elpa-dir (expand-file-name "elpa" flat))
                           (entries (and (anvil-pkg-compat-file-exists-p elpa-dir)
                                         (ignore-errors
                                           (directory-files elpa-dir t
                                                            (concat "\\`" (regexp-quote pkg-name) "-")))))
                           (hit (and entries (car entries))))
                      hit))
                   ;; flat layout: $out/share/emacs/site-lisp/<pname>.el
                   ((let ((flat-el (expand-file-name (concat pkg-name ".el") flat)))
                      (and (anvil-pkg-compat-file-exists-p flat-el) flat))))))
            (when chosen
              (add-to-list 'load-path chosen)
              (setq match-dir chosen))))))
    match-dir))

;;;; --- public API ------------------------------------------------------------

(defun anvil-pkg--install-nixpkgs-args (name)
  "Return the `nix' argv list to install nixpkgs#NAME.
Shared between the synchronous path (`anvil-pkg--install-nixpkgs')
and the asynchronous `:async t' path so the two routes never
diverge on flag composition."
  (let ((flakeref (format "%s#%s" anvil-pkg-nix-channel name)))
    (append (list "profile" "install")
            (anvil-pkg--profile-args)
            (list flakeref))))

(defun anvil-pkg--install-nixpkgs (name)
  "Install nixpkgs#NAME via `nix profile install'.  String path.
Internal helper called by `pkg-install' when NAME is a string."
  (anvil-pkg--ensure-nix)
  (let* ((args (anvil-pkg--install-nixpkgs-args name))
         (res (anvil-pkg--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            name
                            (plist-get res :exit)
                            (anvil-pkg-compat-string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

(declare-function anvil-pkg--install-symbol "anvil-pkg-dsl")
(defvar anvil-pkg--write-flake-fn) ; defined in anvil-pkg-dsl.el

;;;; --- async install -------------------------------------------------------
;; Phase 4-B sub-task C (design doc 05 L16).  Spawns `nix profile install'
;; via `make-process' (Emacs only — NeLisp standalone gets a clear error)
;; and routes the post-install hook + user callbacks through a sentinel.

(defun anvil-pkg--async-stderr-string (proc)
  "Return the accumulated stderr string for PROC, or empty string."
  (let ((buf (process-get proc 'anvil-pkg--stderr-buf)))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf (buffer-string))
      "")))

(defun anvil-pkg--async-cleanup (proc)
  "Kill the stderr buffer attached to PROC, if any."
  (let ((buf (process-get proc 'anvil-pkg--stderr-buf)))
    (when (and buf (buffer-live-p buf))
      (kill-buffer buf))))

(defun anvil-pkg--async-on-success (proc)
  "Sentinel happy path: post-install hook + :require + :on-success."
  (let* ((name        (process-get proc 'anvil-pkg--name))
         (build-type  (process-get proc 'anvil-pkg--build-system-type))
         (require-supplied (process-get proc 'anvil-pkg--require-supplied))
         (require-sym (process-get proc 'anvil-pkg--require-sym))
         (on-success  (process-get proc 'anvil-pkg--on-success)))
    (when (eq build-type 'emacs-package)
      (let ((load-path-dir (anvil-pkg--emacs-package-after-install name)))
        (when (and require-supplied load-path-dir)
          (require require-sym))))
    (when on-success
      (condition-case err
          (funcall on-success (list :status :installed :name name))
        (error
         (lwarn 'anvil-pkg :error
                "pkg-install :on-success raised: %S" err))))))

(defun anvil-pkg--async-on-error (proc exit)
  "Sentinel error path for PROC with non-zero EXIT.

Routes the failure to the user's :on-error if supplied; otherwise
defers a `lwarn' via `run-with-timer' so the message reaches
*Messages* without invoking `signal' from a sentinel (which Emacs
swallows silently)."
  (let* ((name      (process-get proc 'anvil-pkg--name))
         (stderr    (anvil-pkg--async-stderr-string proc))
         (on-error  (process-get proc 'anvil-pkg--on-error))
         (err-plist (list :error 'anvil-pkg-nix-failed
                          :exit  exit
                          :stderr stderr
                          :name  name)))
    (cond
     (on-error
      (condition-case err
          (funcall on-error err-plist)
        (error
         (lwarn 'anvil-pkg :error
                "pkg-install :on-error raised: %S" err))))
     (t
      ;; No callback — surface async via run-with-timer so the
      ;; sentinel returns cleanly first.  Phase 4-B L16 contract.
      (run-with-timer
       0 nil
       (lambda ()
         (lwarn 'anvil-pkg :error
                "pkg-install %S failed (exit %s): %s"
                name exit
                (anvil-pkg-compat-string-trim (or stderr "")))))))))

(defun anvil-pkg--async-sentinel (proc event)
  "Sentinel for `anvil-pkg--spawn-nix-async'.

Dispatches to `anvil-pkg--async-on-success' on `finished' (exit
0) or `anvil-pkg--async-on-error' on any other terminal EVENT.
Always cleans up the stderr buffer once the process is no longer
live."
  (when (memq (process-status proc) '(exit signal))
    (unwind-protect
        (let ((exit (process-exit-status proc)))
          (cond
           ((and (stringp event)
                 (string-prefix-p "finished" event)
                 (eq 0 exit))
            (anvil-pkg--async-on-success proc))
           (t
            (anvil-pkg--async-on-error proc exit))))
      (anvil-pkg--async-cleanup proc))))

(defun anvil-pkg--spawn-nix-async (args name plist build-system-type)
  "Spawn `nix' with ARGS asynchronously and wire up the sentinel.

NAME, PLIST and BUILD-SYSTEM-TYPE are stashed on the process via
`process-put' so the sentinel can route post-install + user
callbacks without a closure (closures over PLIST are awkward to
mock)."
  (anvil-pkg--ensure-nix)
  (unless (eq (anvil-pkg-compat-runtime) 'emacs)
    (signal 'anvil-pkg-async-not-supported
            (list (format "pkg-install :async t requires Emacs runtime; got %S"
                          (anvil-pkg-compat-runtime)))))
  (let* ((stderr-buf (generate-new-buffer " *anvil-pkg-async-stderr*"))
         (require-supplied (anvil-pkg--plist-has-key-p plist :require))
         (require-sym      (plist-get plist :require))
         (on-success       (plist-get plist :on-success))
         (on-error         (plist-get plist :on-error))
         (proc (funcall anvil-pkg--make-process-fn
                        :name (format "anvil-pkg-install-%s" name)
                        :buffer nil
                        :command (cons anvil-pkg-nix-program args)
                        :connection-type 'pipe
                        :noquery t
                        :stderr stderr-buf
                        :sentinel #'anvil-pkg--async-sentinel)))
    (process-put proc 'anvil-pkg--stderr-buf       stderr-buf)
    (process-put proc 'anvil-pkg--name             name)
    (process-put proc 'anvil-pkg--build-system-type build-system-type)
    (process-put proc 'anvil-pkg--require-supplied require-supplied)
    (process-put proc 'anvil-pkg--require-sym      require-sym)
    (process-put proc 'anvil-pkg--on-success       on-success)
    (process-put proc 'anvil-pkg--on-error         on-error)
    proc))

;;;###autoload
(defun pkg-install (name &rest plist)
  "Install package NAME.

NAME is one of:
  - a string nixpkgs attribute path (e.g. \"ripgrep\", \"nodejs_20\")
    → installs nixpkgs#NAME directly;
  - a symbol previously declared via `pkg-define' (Phase 2)
    → looks up the local registry, regenerates flake.nix under
    `anvil-pkg-profile-dir's parent, and installs from that flake.

Recognised PLIST keys:
  :require SYMBOL
    After a successful `emacs-package' symbol install, augment
    `load-path' and call `(require SYMBOL)'.
  :async BOOL
    When non-nil, spawn `nix profile install' via `make-process'
    and return the process object immediately (Emacs runtime
    only).  NeLisp standalone signals
    `anvil-pkg-async-not-supported'.  Phase 4-B sub-task C.
  :on-success FN
    Called as (FN (:status :installed :name NAME)) after a
    successful async install (post-install hook + :require run
    first).  Ignored — with a one-shot warning — when :async is
    not supplied.
  :on-error FN
    Called as (FN (:error \\='anvil-pkg-nix-failed :exit N :stderr
    STR :name NAME)) on a non-zero async exit.  When omitted, the
    failure surfaces via `lwarn' on a 0-delay timer (sentinels
    must not call `signal' directly).  Ignored — with a one-shot
    warning — when :async is not supplied.
  :no-auto-deps BOOL
    Phase 4-C L18 opt-out.  When non-nil, skip the
    `Package-Requires' pre-fetch for `emacs-package' symbol installs
    that have no explicit `:depends-on'.  Default nil: a single
    HTTP GET against raw.githubusercontent.com derives deps from
    `<pname>-pkg.el' or the `Package-Requires' header (only for
    `github-fetch' sources).  Explicit `:depends-on' on the
    `pkg-define' form ALWAYS wins regardless of this flag (L8
    invariant).

Synchronous return value: t on success.  Async return value: the
process object.  Signals `anvil-pkg-nix-failed' /
`anvil-pkg-nix-not-found' / `anvil-pkg-async-not-supported' /
`anvil-pkg-undefined-package' as appropriate."
  (let ((async (plist-get plist :async)))
    ;; Phase 4-B L16 reject list: warn (don't error) when callbacks
    ;; are supplied without :async — keeps the synchronous path
    ;; backwards-compatible.
    (when (and (not async)
               (or (anvil-pkg--plist-has-key-p plist :on-success)
                   (anvil-pkg--plist-has-key-p plist :on-error)))
      (lwarn 'anvil-pkg :warning
             "pkg-install: :on-success/:on-error ignored without :async t"))
    (cond
     (async
      (cond
       ((stringp name)
        (anvil-pkg--ensure-nix)
        (let ((args (anvil-pkg--install-nixpkgs-args name)))
          (anvil-pkg--spawn-nix-async args name plist nil)))
       ((symbolp name)
        (require 'anvil-pkg-dsl)
        (anvil-pkg--ensure-nix)
        (anvil-pkg--registry-get name)
        ;; Phase 4-C L18: derive :depends-on from the upstream
        ;; `Package-Requires' header before flake render so the
        ;; resulting derivation has the correct `packageRequires'.
        (anvil-pkg--maybe-derive-deps name (plist-get plist :no-auto-deps))
        (let* ((flake-path (funcall anvil-pkg--write-flake-fn))
               (flake-dir  (directory-file-name (file-name-directory flake-path)))
               (flakeref   (format "path:%s#%s" flake-dir name))
               (args       (append (list "profile" "install")
                                   (anvil-pkg--profile-args)
                                   (list flakeref)))
               (build-system-type (anvil-pkg--registry-build-system-type name)))
          (anvil-pkg--spawn-nix-async args name plist build-system-type)))
       (t (signal 'anvil-pkg-error
                  (list (format "pkg-install: NAME must be string or symbol, got %S"
                                name))))))
     (t
      (cond
       ((stringp name) (anvil-pkg--install-nixpkgs name))
       ((symbolp name)
        (require 'anvil-pkg-dsl)
        ;; Phase 4-C L18: pre-fetch + IR augmentation BEFORE
        ;; `anvil-pkg--install-symbol' so the rendered flake.nix
        ;; carries the derived `packageRequires'.
        (anvil-pkg--maybe-derive-deps name (plist-get plist :no-auto-deps))
        (let* ((require-supplied (anvil-pkg--plist-has-key-p plist :require))
               (require-sym (plist-get plist :require))
               (build-system-type (anvil-pkg--registry-build-system-type name))
               (installed (anvil-pkg--install-symbol name)))
          (when (eq build-system-type 'emacs-package)
            (let ((load-path-dir (anvil-pkg--emacs-package-after-install name)))
              (when (and require-supplied (null load-path-dir))
                (signal 'anvil-pkg-error
                        (list (format "pkg-install: could not locate load-path directory for %s"
                                      name))))
              (when require-supplied
                (require require-sym))))
          installed))
       (t (signal 'anvil-pkg-error
                  (list (format "pkg-install: NAME must be string or symbol, got %S"
                                name)))))))))

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
                            (anvil-pkg-compat-string-trim (or (plist-get res :stderr) "")))
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
                            (anvil-pkg-compat-string-trim (or (plist-get res :stderr) "")))
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
