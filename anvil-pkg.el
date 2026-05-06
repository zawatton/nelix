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
(require 'anvil-pkg-state)

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

(defun anvil-pkg--nix-credential-args ()
  "Return Nix CLI args injecting access tokens, or nil.

Phase 4-G L43: scans `anvil-pkg-compat-credential-env-alist'
and emits =--option extra-access-tokens \"host=tok ...\"= when
at least one env var resolves.  Nix accepts space-separated
=host=token= pairs; the option is silently ignored by
subcommands that do not fetch."
  (let ((pairs '()))
    (dolist (entry anvil-pkg-compat-credential-env-alist)
      (let* ((host (car entry))
             (vars (cdr entry))
             (token nil))
        (while (and vars (null token))
          (let ((v (anvil-pkg-compat-getenv (car vars))))
            (when (and v (> (length v) 0))
              (setq token v)))
          (setq vars (cdr vars)))
        (when token
          (push (format "%s=%s" host token) pairs))))
    (when pairs
      (list "--option"
            "extra-access-tokens"
            (mapconcat #'identity (nreverse pairs) " ")))))

(defun anvil-pkg--call-nix-default (args)
  "Default `nix' invoker.  Synchronous, runtime-portable.

ARGS is a list of string arguments passed to the executable named
by `anvil-pkg-nix-program'.  Returns plist (:exit :stdout :stderr).

Implementation defers I/O to `anvil-pkg-compat-call-process' so
the same code runs on Emacs and on NeLisp standalone.  Phase 4
will introduce an async variant gated by `:async'.

Phase 4-G L43: prepends `anvil-pkg--nix-credential-args' so
private fetchers reach private GitHub / GitLab repos when the
appropriate env var is set."
  (anvil-pkg-compat-call-process
   anvil-pkg-nix-program
   (append (anvil-pkg--nix-credential-args) args)))

(defun anvil-pkg--call-nix (args)
  "Invoke `nix' with ARGS via `anvil-pkg--call-nix-fn'."
  (funcall anvil-pkg--call-nix-fn args))

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

;;;; --- Nix version detection (L20) ------------------------------------------
;; Nix 2.34 deprecated `nix profile install' in favour of `nix profile add'.
;; Both subcommands take identical arguments and exit semantics.  Detect the
;; runtime version once per Emacs session and dispatch the right subcommand
;; so >= 2.34 stops emitting the deprecation warning.

(defconst anvil-pkg--nix-version-namespace "anvil-pkg:nix-version"
  "`anvil-pkg-state' namespace for the cached `nix --version' string.")

(defconst anvil-pkg--nix-version-key "default"
  "Single key under `anvil-pkg--nix-version-namespace'.

There is one Nix per profile so a constant key is sufficient.")

(defcustom anvil-pkg-nix-version-ttl-seconds (* 24 60 60)
  "TTL (seconds) for the cached `nix --version' lookup.

Default 1 day.  Re-detection on TTL expiry catches users upgrading
their Nix daemon mid-session without forcing them to clear the
cache manually."
  :type 'integer
  :group 'anvil-pkg)

(defun anvil-pkg--detect-nix-version ()
  "Return the Nix version string by calling `nix --version'.

Caches the result in `anvil-pkg-state' (namespace
`anvil-pkg--nix-version-namespace') with a 1-day TTL so subsequent
calls are free across Emacs restarts.  When the executable is
missing or the call fails this returns nil and the caller MUST
treat that as `< 2.34' for safety (= keep using the older `install'
subcommand)."
  (or (anvil-pkg-state-get anvil-pkg--nix-version-namespace
                           anvil-pkg--nix-version-key)
      (let ((res (condition-case _
                     (anvil-pkg--call-nix (list "--version"))
                   (error nil))))
        (when (and res (eq 0 (plist-get res :exit)))
          (let ((stdout (or (plist-get res :stdout) "")))
            (when (string-match "\\([0-9]+\\.[0-9]+\\(?:\\.[0-9]+\\)?\\)"
                                stdout)
              (let ((ver (match-string 1 stdout)))
                (anvil-pkg-state-put anvil-pkg--nix-version-namespace
                                     anvil-pkg--nix-version-key
                                     ver
                                     anvil-pkg-nix-version-ttl-seconds)
                ver)))))))

(defun anvil-pkg--nix-version-at-least-p (major minor)
  "Return non-nil when the cached Nix version is >= MAJOR.MINOR.

Operates on `anvil-pkg--detect-nix-version's cached value.  Only
the major and minor components are compared — patch-level
differences are irrelevant for the 2.34 install→add rename."
  (let ((ver (anvil-pkg--detect-nix-version)))
    (when (and ver (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)" ver))
      (let ((maj (string-to-number (match-string 1 ver)))
            (min (string-to-number (match-string 2 ver))))
        (or (> maj major)
            (and (= maj major) (>= min minor)))))))

(defun anvil-pkg--nix-install-subcommand ()
  "Return the right `nix profile' install subcommand for this Nix.

Emits \"add\" on Nix >= 2.34 (= the new spelling, no deprecation
warning) and \"install\" otherwise.  Detection failure falls back
to \"install\" — older Nix accepts the legacy spelling and 2.34+
still understands it (with a warning) so degrading to the safer
default never breaks the install."
  (if (anvil-pkg--nix-version-at-least-p 2 34)
      "add"
    "install"))

;;;; --- public API ------------------------------------------------------------

(defun anvil-pkg--install-nixpkgs-args (name)
  "Return the `nix' argv list to install nixpkgs#NAME.
Shared between the synchronous path (`anvil-pkg--install-nixpkgs')
and the asynchronous `:async t' path so the two routes never
diverge on flag composition.  The install subcommand
(`install' vs `add') is resolved via
`anvil-pkg--nix-install-subcommand' for Nix 2.34 compatibility."
  (let ((flakeref (format "%s#%s" anvil-pkg-nix-channel name))
        (subcmd (anvil-pkg--nix-install-subcommand)))
    (append (list "profile" subcmd)
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
;; Phase 4-B sub-task C (design doc 05 L16) introduced the :async path.
;; Phase 4-C sub-task D (design doc 06 L22) refactored the spawn through
;; `anvil-pkg-compat-make-process-async' so the runtime branch lives in
;; the compat layer; this file no longer touches `make-process' directly.

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
  "Sentinel happy path: post-install hook + :require + :on-success.

Phase 4-F: when the process was a multi-install (PROC's
`anvil-pkg--names' property is a list), iterate the post-install
load-path augment over every emacs-package symbol and surface
`:names NAMES' to the callback instead of `:name NAME'.
`:require' is rejected at dispatch for list NAME so we never need
to call `require' here in the multi case."
  (let* ((names       (process-get proc 'anvil-pkg--names))
         (name        (process-get proc 'anvil-pkg--name))
         (build-type  (process-get proc 'anvil-pkg--build-system-type))
         (require-supplied (process-get proc 'anvil-pkg--require-supplied))
         (require-sym (process-get proc 'anvil-pkg--require-sym))
         (on-success  (process-get proc 'anvil-pkg--on-success)))
    (cond
     (names
      ;; Multi-install: augment load-path for every emacs-package symbol.
      (anvil-pkg--multi-after-install names)
      (when on-success
        (condition-case err
            (funcall on-success (list :status :installed :names names))
          (error
           (lwarn 'anvil-pkg :error
                  "pkg-install :on-success raised: %S" err)))))
     (t
      (when (eq build-type 'emacs-package)
        (let ((load-path-dir (anvil-pkg--emacs-package-after-install name)))
          (when (and require-supplied load-path-dir)
            (require require-sym))))
      (when on-success
        (condition-case err
            (funcall on-success (list :status :installed :name name))
          (error
           (lwarn 'anvil-pkg :error
                  "pkg-install :on-success raised: %S" err))))))))

(defun anvil-pkg--async-on-error (proc exit)
  "Sentinel error path for PROC with non-zero EXIT.

Routes the failure to the user's :on-error if supplied; otherwise
defers a `lwarn' via `run-with-timer' so the message reaches
*Messages* without invoking `signal' from a sentinel (which Emacs
swallows silently).

Phase 4-F: multi-install errors surface `:names NAMES' instead of
`:name NAME'.  The error covers the whole bulk transaction since
Nix profile install/add is atomic."
  (let* ((names     (process-get proc 'anvil-pkg--names))
         (name      (process-get proc 'anvil-pkg--name))
         (stderr    (anvil-pkg--async-stderr-string proc))
         (on-error  (process-get proc 'anvil-pkg--on-error))
         (err-plist (cond
                     (names (list :error 'anvil-pkg-nix-failed
                                  :exit  exit
                                  :stderr stderr
                                  :names names))
                     (t     (list :error 'anvil-pkg-nix-failed
                                  :exit  exit
                                  :stderr stderr
                                  :name  name)))))
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
                (or names name) exit
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
mock).

Phase 4-F: NAME may also be a list of names (multi-install).  When
NAME is a list, the process records it under the `anvil-pkg--names'
property and sentinel callbacks surface `:names' instead of `:name'.
BUILD-SYSTEM-TYPE is unused in the multi case (each symbol's type is
re-resolved inside `anvil-pkg--multi-after-install')."
  (anvil-pkg--ensure-nix)
  (let* ((multi (and (consp name) (not (stringp name))))
         (process-label
          (cond (multi (format "multi-%d" (length name)))
                (t     (format "%s" name))))
         (stderr-buf (generate-new-buffer " *anvil-pkg-async-stderr*"))
         (require-supplied (anvil-pkg--plist-has-key-p plist :require))
         (require-sym      (plist-get plist :require))
         (on-success       (plist-get plist :on-success))
         (on-error         (plist-get plist :on-error))
         ;; compat-make-process-async signals
         ;; `anvil-pkg-async-not-supported' on NeLisp; Emacs gets a real
         ;; process object back from `make-process'.
         ;; Phase 4-G L43: prepend credential args so async installs
         ;; against private fetchers see the same access tokens as
         ;; the sync `anvil-pkg--call-nix-default' path.
         (cred-args (anvil-pkg--nix-credential-args))
         (proc (anvil-pkg-compat-make-process-async
                :name (format "anvil-pkg-install-%s" process-label)
                :buffer nil
                :command (cons anvil-pkg-nix-program
                               (append cred-args args))
                :connection-type 'pipe
                :noquery t
                :stderr stderr-buf
                :sentinel #'anvil-pkg--async-sentinel)))
    (process-put proc 'anvil-pkg--stderr-buf       stderr-buf)
    (cond
     (multi
      (process-put proc 'anvil-pkg--names name))
     (t
      (process-put proc 'anvil-pkg--name name)
      (process-put proc 'anvil-pkg--build-system-type build-system-type)
      (process-put proc 'anvil-pkg--require-supplied require-supplied)
      (process-put proc 'anvil-pkg--require-sym      require-sym)))
    (process-put proc 'anvil-pkg--on-success       on-success)
    (process-put proc 'anvil-pkg--on-error         on-error)
    proc))

;;;; --- multi-install helpers (Phase 4-F L29-L34) ---------------------------

(defun anvil-pkg--validate-multi-names (names)
  "Validate a multi-install NAMES list.  Signal `anvil-pkg-error' on bad shape.

NAMES must be a non-empty list of (string | symbol) elements."
  (unless (and (consp names) (not (stringp names)))
    (signal 'anvil-pkg-error
            (list (format "pkg-install: NAMES must be a non-empty list, got %S"
                          names))))
  (when (null names)
    (signal 'anvil-pkg-error
            (list "pkg-install: NAMES list must be non-empty")))
  (dolist (n names)
    (unless (or (stringp n) (symbolp n))
      (signal 'anvil-pkg-error
              (list (format "pkg-install: NAMES element must be string or symbol, got %S"
                            n))))))

(defun anvil-pkg--multi-install-flakerefs (names flake-dir)
  "Return flakeref strings for NAMES.

Symbols become `path:FLAKE-DIR#sym'; strings become
`<channel>#name'.  Order in NAMES is preserved."
  (mapcar (lambda (n)
            (cond
             ((stringp n) (format "%s#%s" anvil-pkg-nix-channel n))
             ((symbolp n) (format "path:%s#%s" flake-dir n))))
          names))

(defun anvil-pkg--multi-after-install (names)
  "Iterate `anvil-pkg--emacs-package-after-install' over emacs-package
symbols in NAMES (skipping strings and non-emacs-package symbols).

Used by the multi-install async sentinel to augment `load-path' for
every newly-installed Emacs package."
  (dolist (n names)
    (when (symbolp n)
      (let ((build-type (anvil-pkg--registry-build-system-type n)))
        (when (eq build-type 'emacs-package)
          (anvil-pkg--emacs-package-after-install n))))))

(defun anvil-pkg--multi-install-prepare (names plist)
  "Common pre-flight for multi-install: validate, derive deps, render flake.

Signals on bad NAMES, on `:require' supplied, on undefined symbols.
Returns a plist `(:flakerefs LIST :flake-dir DIR)' suitable for
both sync and async install paths.  Skips the flake render entirely
when NAMES contains only strings (no IR to render)."
  (anvil-pkg--validate-multi-names names)
  (when (anvil-pkg--plist-has-key-p plist :require)
    (signal 'anvil-pkg-error
            (list "pkg-install: :require is not supported with a NAMES list (ambiguous; install one at a time)")))
  (anvil-pkg--ensure-nix)
  (let* ((symbols (delq nil (mapcar (lambda (n) (and (symbolp n) n))
                                    names)))
         (no-auto-deps (plist-get plist :no-auto-deps)))
    (when symbols
      (require 'anvil-pkg-dsl)
      ;; Validate every symbol exists in the registry up front (so we
      ;; do not invoke nix on a half-broken bulk).
      (dolist (sym symbols)
        (anvil-pkg--registry-get sym))
      ;; Derive deps per-symbol before the single render pass.
      (dolist (sym symbols)
        (anvil-pkg--maybe-derive-deps sym no-auto-deps)))
    (let* ((flake-path (when symbols (funcall anvil-pkg--write-flake-fn)))
           (flake-dir  (and flake-path
                            (directory-file-name
                             (file-name-directory flake-path))))
           (flakerefs (anvil-pkg--multi-install-flakerefs names flake-dir)))
      (list :flakerefs flakerefs :flake-dir flake-dir))))

(defun anvil-pkg--multi-install-args (flakerefs)
  "Build the `nix profile install/add ...' args for FLAKEREFS."
  (let ((subcmd (anvil-pkg--nix-install-subcommand)))
    (append (list "profile" subcmd)
            (anvil-pkg--profile-args)
            flakerefs)))

;;;###autoload
(defun pkg-install (name &rest plist)
  "Install package NAME.

NAME is one of:
  - a string nixpkgs attribute path (e.g. \"ripgrep\", \"nodejs_20\")
    → installs nixpkgs#NAME directly;
  - a symbol previously declared via `pkg-define' (Phase 2)
    → looks up the local registry, regenerates flake.nix under
    `anvil-pkg-profile-dir's parent, and installs from that flake.
  - a list of any mix of the above (Phase 4-F L29)
    → a single `nix profile install/add' invocation with all
    flakerefs.  Atomic: success or none.  `:require' is rejected
    in this mode; on-success/on-error callbacks receive `:names
    NAMES' instead of `:name NAME'.

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
  (let ((async (plist-get plist :async))
        (multi (and (consp name) (not (stringp name)))))
    ;; Phase 4-B L16 reject list: warn (don't error) when callbacks
    ;; are supplied without :async — keeps the synchronous path
    ;; backwards-compatible.
    (when (and (not async)
               (or (anvil-pkg--plist-has-key-p plist :on-success)
                   (anvil-pkg--plist-has-key-p plist :on-error)))
      (lwarn 'anvil-pkg :warning
             "pkg-install: :on-success/:on-error ignored without :async t"))
    (cond
     ;; Phase 4-F: list dispatch.
     (multi
      (let* ((prep (anvil-pkg--multi-install-prepare name plist))
             (flakerefs (plist-get prep :flakerefs))
             (args (anvil-pkg--multi-install-args flakerefs)))
        (cond
         (async
          (anvil-pkg--spawn-nix-async args name plist nil))
         (t
          (let ((res (anvil-pkg--call-nix args)))
            (cond
             ((eq 0 (plist-get res :exit))
              (anvil-pkg--multi-after-install name)
              t)
             (t
              (signal 'anvil-pkg-nix-failed
                      (list (format "nix profile install %S failed (exit %s): %s"
                                    name
                                    (plist-get res :exit)
                                    (anvil-pkg-compat-string-trim (or (plist-get res :stderr) "")))
                            :stderr (plist-get res :stderr))))))))))
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
               (subcmd     (anvil-pkg--nix-install-subcommand))
               (args       (append (list "profile" subcmd)
                                   (anvil-pkg--profile-args)
                                   (list flakeref)))
               (build-system-type (anvil-pkg--registry-build-system-type name)))
          (anvil-pkg--spawn-nix-async args name plist build-system-type)))
       (t (signal 'anvil-pkg-error
                  (list (format "pkg-install: NAME must be string, symbol, or non-empty list, got %S"
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
                  (list (format "pkg-install: NAME must be string, symbol, or non-empty list, got %S"
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

;;;; --- profile generation rollback (L19) ------------------------------------
;; Phase 4-C sub-task B: wrap `nix profile history --json' / `nix profile
;; rollback' so users can recover from a regressing install.  The local
;; mirror is a per-Emacs-session defvar; persistent storage is deferred
;; to Phase 4-D when anvil-state integration lands.

(defconst anvil-pkg--generations-namespace "anvil-pkg:generations"
  "`anvil-pkg-state' namespace for the profile generations mirror.")

(defconst anvil-pkg--generations-key "mirror"
  "Single key under `anvil-pkg--generations-namespace' holding the full list.

The mirror is small enough (one entry per generation, ≤ tens of KiB
in practice) that a single blob is cheaper than per-id rows.")

(defun anvil-pkg--generations-cache-get ()
  "Return the cached generations list from `anvil-pkg-state'."
  (anvil-pkg-state-get anvil-pkg--generations-namespace
                       anvil-pkg--generations-key))

(defun anvil-pkg--generations-cache-put (generations)
  "Persist GENERATIONS as the mirror in `anvil-pkg-state'.

No TTL: the mirror is refreshed on every install / list / rollback
so staleness is bounded by the time between user-driven calls."
  (anvil-pkg-state-put anvil-pkg--generations-namespace
                       anvil-pkg--generations-key
                       generations))

(defun anvil-pkg--parse-history (json-str)
  "Parse `nix profile history --json' output JSON-STR into list of plists.

Each plist carries :id (integer), :date (ISO string), :packages
(list of symbols), :active (boolean).  Sorted by :id ascending so
the most recent generation lands at the tail.

Targets the Nix 2.18+ schema where the top-level object has a
`generations' array of objects with `id' / `date' /
`packages' (or `elements') and an optional `active' flag.  When
`packages' is absent we fall back to the keys of `elements' (the
Nix 2.18 `nix profile list --json' shape Nix's history endpoint
inherits)."
  (let* ((data (anvil-pkg--json-parse json-str))
         (generations (alist-get 'generations data)))
    (when (and generations (listp generations))
      (let ((parsed
             (mapcar
              (lambda (entry)
                (let* ((id (alist-get 'id entry))
                       (date (alist-get 'date entry))
                       (active (alist-get 'active entry))
                       (pkgs-raw (or (alist-get 'packages entry)
                                     (let ((els (alist-get 'elements entry)))
                                       (cond
                                        ((null els) nil)
                                        ;; elements as alist (= JSON
                                        ;; object with name keys): take
                                        ;; the keys.
                                        ((and (consp els)
                                              (consp (car els)))
                                         (mapcar #'car els))
                                        ;; elements as plain list of
                                        ;; names (newer Nix shape).
                                        (t els)))))
                       (pkgs (mapcar
                              (lambda (p)
                                (cond
                                 ((symbolp p) p)
                                 ((stringp p) (intern p))
                                 (t (intern (format "%s" p)))))
                              (or pkgs-raw '()))))
                  (list :id (if (numberp id) id 0)
                        :date (or date "")
                        :packages pkgs
                        :active (and active t))))
              generations)))
        (sort parsed (lambda (a b) (< (plist-get a :id)
                                      (plist-get b :id))))))))

;;;###autoload
(defun pkg-list-generations ()
  "List Nix profile generations for the anvil-pkg profile.

Returns a list of plists carrying :id, :date, :packages,
:active.  Generations are sorted by :id ascending so
`(car (last (pkg-list-generations)))' is the latest.

Side effects: refreshes the persistent generations mirror in
`anvil-pkg-state' so `pkg-history' has fresh data without an extra
shell-out, surviving Emacs restarts.

Signals `anvil-pkg-nix-failed' on a non-zero `nix profile history'
exit (e.g. corrupt profile)."
  (anvil-pkg--ensure-nix)
  (let* ((args (append (list "profile" "history" "--json")
                       (anvil-pkg--profile-args)))
         (res (anvil-pkg--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile history failed (exit %s): %s"
                            (plist-get res :exit)
                            (anvil-pkg-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (let ((generations (anvil-pkg--parse-history
                        (or (plist-get res :stdout) ""))))
      (anvil-pkg--generations-cache-put generations)
      generations)))

(defun anvil-pkg--rollback-replay-emacs-hooks ()
  "Re-run `anvil-pkg--emacs-package-after-install' for the active generation.

After `nix profile rollback' switches generations the user's
`load-path' may be pointing at store paths that no longer match
the live profile — replay the post-install hook for every emacs
package in the now-active generation so `load-path' is correct
again.  The hook is idempotent (`add-to-list')."
  (let ((entries (condition-case _ (pkg-list) (error nil))))
    (dolist (entry entries)
      (let ((name (plist-get entry :name)))
        (when (stringp name)
          (condition-case _
              (anvil-pkg--emacs-package-after-install (intern name))
            (error nil)))))))

(defun anvil-pkg--generation-id-known-p (id)
  "Return non-nil when ID matches a generation in the cache."
  (let (found)
    (dolist (gen (anvil-pkg--generations-cache-get))
      (when (and (not found) (eq (plist-get gen :id) id))
        (setq found t)))
    found))

;;;###autoload
(defun pkg-rollback (&optional generation-id)
  "Roll the anvil-pkg Nix profile back to GENERATION-ID.

When GENERATION-ID is nil rolls back one step (= the previous
generation).  When supplied as an integer, jumps directly to that
generation; signals `anvil-pkg-error' if it is not in the local
generations mirror (after a refresh).

After a successful rollback the in-process generations cache is
refreshed and the post-install hook is replayed for every
emacs-package in the now-active generation so `load-path' stays
in sync.

Returns t on success.  Signals `anvil-pkg-nix-failed' on a
non-zero `nix profile rollback' exit."
  (anvil-pkg--ensure-nix)
  ;; If a specific id was requested, ensure it exists.  Refresh the
  ;; cache once before signalling so concurrent installs that bumped
  ;; the generation count don't trigger a false negative.
  (when generation-id
    (unless (integerp generation-id)
      (signal 'anvil-pkg-error
              (list (format "pkg-rollback: GENERATION-ID must be integer, got %S"
                            generation-id))))
    (unless (anvil-pkg--generation-id-known-p generation-id)
      (pkg-list-generations)
      (unless (anvil-pkg--generation-id-known-p generation-id)
        (signal 'anvil-pkg-error
                (list (format "pkg-rollback: generation %d not found in profile history"
                              generation-id))))))
  (let* ((base-args (append (list "profile" "rollback")
                            (anvil-pkg--profile-args)))
         (args (if generation-id
                   (append base-args
                           (list "--to-generation"
                                 (number-to-string generation-id)))
                 base-args))
         (res (anvil-pkg--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile rollback failed (exit %s): %s"
                            (plist-get res :exit)
                            (anvil-pkg-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    ;; Refresh the cache + replay emacs-package hooks.  Both are
    ;; condition-case-wrapped so a refresh failure doesn't mask a
    ;; successful rollback.
    (condition-case _ (pkg-list-generations) (error nil))
    (anvil-pkg--rollback-replay-emacs-hooks)
    t))

(defun anvil-pkg--active-generation ()
  "Return the active generation plist from the mirror.
Refreshes via `pkg-list-generations' when the mirror is empty.
Returns nil when no generation has `:active' t (= no profile yet)."
  (let ((mirror (anvil-pkg--generations-cache-get)))
    (unless mirror
      (setq mirror (pkg-list-generations)))
    (let (active)
      (dolist (gen mirror)
        (when (and (not active) (plist-get gen :active))
          (setq active gen)))
      active)))

;;;###autoload
(defun pkg-rollback-package (pkg-name)
  "Roll back a single package PKG-NAME from the anvil-pkg Nix profile.
PKG-NAME is a symbol previously installed via `pkg-define' /
`pkg-install'.  Synthesises a NEW generation containing every
package currently installed EXCEPT PKG-NAME, re-rendering
flake.nix from each remaining package's IR in
`anvil-pkg--registry' and dispatching `nix profile add' against
the freshly-written flake.  Nix records this as a new
generation (not as a rollback) — that is the documented L25
contract.

Signals `anvil-pkg-error' when:
  - PKG-NAME is not installed in the active generation,
  - any remaining package has no IR in the registry (= installed
    via raw nixpkgs name lookup, not via `pkg-define').  The
    suggestion in the error message points to the whole-profile
    `pkg-rollback' as a fallback.

Returns t on success.  Side effects: refreshes the generations
mirror and replays the post-install hook for emacs-package
entries in the now-active generation so `load-path' stays
consistent.  Phase 4-D L25."
  (unless (symbolp pkg-name)
    (signal 'anvil-pkg-error
            (list (format "pkg-rollback-package: PKG-NAME must be symbol, got %S"
                          pkg-name))))
  (require 'anvil-pkg-dsl)
  (anvil-pkg--ensure-nix)
  (let* ((active (anvil-pkg--active-generation))
         (current-pkgs (and active (plist-get active :packages))))
    (unless active
      (signal 'anvil-pkg-error
              (list "pkg-rollback-package: no active generation found in profile history")))
    (unless (memq pkg-name current-pkgs)
      (signal 'anvil-pkg-error
              (list (format "pkg-rollback-package: %s is not currently installed in the active generation"
                            pkg-name))))
    (let ((remaining (delq pkg-name (copy-sequence current-pkgs))))
      ;; Verify every remaining package has IR in the registry.  Without
      ;; an IR we cannot re-render its derivation in the new flake.nix,
      ;; so refuse loudly with a pointer to whole-profile rollback.
      (dolist (sym remaining)
        (unless (gethash sym anvil-pkg--registry)
          (signal 'anvil-pkg-error
                  (list (format "pkg-rollback-package: %s has no IR in the registry (installed by name only); use pkg-rollback for whole-profile rollback instead"
                                sym)))))
      ;; Re-render the flake from a temporary registry containing only
      ;; the remaining IRs so `anvil-pkg--render-flake' (which walks the
      ;; registry hash) produces a flake without PKG-NAME.
      (let* ((scoped-registry (make-hash-table :test 'eq))
             (flake-path nil)
             (flake-dir nil))
        (dolist (sym remaining)
          (puthash sym (gethash sym anvil-pkg--registry) scoped-registry))
        (let ((anvil-pkg--registry scoped-registry))
          (setq flake-path (funcall anvil-pkg--write-flake-fn)))
        (setq flake-dir (directory-file-name (file-name-directory flake-path)))
        (let* ((subcmd (anvil-pkg--nix-install-subcommand))
               (flakerefs (mapcar (lambda (sym)
                                    (format "path:%s#%s" flake-dir sym))
                                  remaining))
               (args (append (list "profile" subcmd)
                             (anvil-pkg--profile-args)
                             flakerefs))
               (res (anvil-pkg--call-nix args)))
          (unless (eq 0 (plist-get res :exit))
            (signal 'anvil-pkg-nix-failed
                    (list (format "nix profile %s (rollback-package %s) failed (exit %s): %s"
                                  subcmd pkg-name
                                  (plist-get res :exit)
                                  (anvil-pkg-compat-string-trim
                                   (or (plist-get res :stderr) "")))
                          :stderr (plist-get res :stderr)))))
        ;; Refresh mirror + replay emacs-package hooks.  Both wrapped so
        ;; a refresh failure does not mask a successful per-package
        ;; rollback.
        (condition-case _ (pkg-list-generations) (error nil))
        (anvil-pkg--rollback-replay-emacs-hooks)
        t))))

;;;###autoload
(defun pkg-history (pkg-name)
  "Return install / remove events for PKG-NAME (a symbol).

Result is a list of plists carrying :generation, :event, :date.
Event is one of `:installed' / `:removed' (cross-generation
diffing detects the upgrade / downgrade case as a paired
remove + install on adjacent generations; Phase 4-C does not
attempt to coalesce these into `:upgraded' / `:downgraded' — that
needs version metadata the history endpoint does not surface).

Reads from the persistent generations mirror in `anvil-pkg-state';
if the mirror is empty, calls `pkg-list-generations' once to
populate it.  Pass a fresh generations list by calling
`pkg-list-generations' explicitly beforehand."
  (unless (symbolp pkg-name)
    (signal 'anvil-pkg-error
            (list (format "pkg-history: PKG-NAME must be symbol, got %S"
                          pkg-name))))
  (when (null (anvil-pkg--generations-cache-get))
    (pkg-list-generations))
  (let ((events nil)
        (prev-pkgs nil)
        (prev-set-initialised nil))
    (dolist (gen (anvil-pkg--generations-cache-get))
      (let* ((id (plist-get gen :id))
             (date (plist-get gen :date))
             (pkgs (plist-get gen :packages))
             (in-prev (and prev-set-initialised (memq pkg-name prev-pkgs)))
             (in-now  (memq pkg-name pkgs)))
        (cond
         ;; First generation we look at — anything present counts as
         ;; an :installed event so the user can see the package's
         ;; lineage even when we don't have an empty pre-state.
         ((and (not prev-set-initialised) in-now)
          (push (list :generation id :event :installed :date date) events))
         ((and in-now (not in-prev))
          (push (list :generation id :event :installed :date date) events))
         ((and (not in-now) in-prev)
          (push (list :generation id :event :removed :date date) events)))
        (setq prev-pkgs pkgs
              prev-set-initialised t)))
    (nreverse events)))

;;;; --- cache control (Phase 4-D L26) ---------------------------------------

;; Forward declaration for the byte-compiler — anvil-pkg-emacs is loaded
;; lazily so the constant is not in scope at top-level compile time.
(defvar anvil-pkg-emacs--deps-namespace)

;;;###autoload
(defun pkg-clear-cache (&optional scope)
  "Drop persistent caches under `anvil-pkg-state'.

SCOPE selects which namespaces to clear:
- nil or `all'    — every anvil-pkg cache
- `deps'          — Phase 4-C Package-Requires lookup cache
- `nix-version'   — `nix --version' detection cache
- `generations'   — profile generations mirror

Returns t.  Signals `anvil-pkg-error' on an unknown SCOPE so users
notice typos rather than silently clearing the wrong namespace."
  (interactive)
  ;; Lazy-require for the deps namespace constant (anvil-pkg-emacs is
  ;; loaded on demand from `pkg-install', so a fresh session that calls
  ;; `pkg-clear-cache' first would otherwise hit a void-variable error).
  (when (memq (or scope 'all) '(all deps))
    (require 'anvil-pkg-emacs))
  (pcase (or scope 'all)
    ('all
     (anvil-pkg-state-clear anvil-pkg-emacs--deps-namespace)
     (anvil-pkg-state-clear anvil-pkg--nix-version-namespace)
     (anvil-pkg-state-clear anvil-pkg--generations-namespace))
    ('deps
     (anvil-pkg-state-clear anvil-pkg-emacs--deps-namespace))
    ('nix-version
     (anvil-pkg-state-clear anvil-pkg--nix-version-namespace))
    ('generations
     (anvil-pkg-state-clear anvil-pkg--generations-namespace))
    (_
     (signal 'anvil-pkg-error
             (list (format "pkg-clear-cache: unknown SCOPE %S (expected one of all / deps / nix-version / generations)"
                           scope)))))
  t)

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
;;;###autoload
(defalias 'anvil-pkg-list-generations #'pkg-list-generations)
;;;###autoload
(defalias 'anvil-pkg-rollback #'pkg-rollback)
;;;###autoload
(defalias 'anvil-pkg-rollback-package #'pkg-rollback-package)
;;;###autoload
(defalias 'anvil-pkg-history #'pkg-history)
;;;###autoload
(defalias 'anvil-pkg-clear-cache #'pkg-clear-cache)

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

(defun anvil-pkg--tool-list-generations ()
  "MCP wrapper around `pkg-list-generations'.

MCP Parameters: (none)."
  (let ((rows (pkg-list-generations)))
    (list :count (length rows)
          :generations (or rows []))))

(defun anvil-pkg--tool-rollback (generation-id)
  "MCP wrapper around `pkg-rollback'.

MCP Parameters:
  generation-id - integer generation id to roll back to,
    or nil / 0 to roll back one step (= the previous generation)."
  (let* ((gid (cond
               ((null generation-id) nil)
               ((integerp generation-id)
                (if (zerop generation-id) nil generation-id))
               ((stringp generation-id)
                (let ((trimmed (anvil-pkg-compat-string-trim generation-id)))
                  (if (zerop (length trimmed))
                      nil
                    (string-to-number trimmed))))
               (t generation-id))))
    (pkg-rollback gid)
    (list :status "ok"
          :generation-id (or gid :previous))))

(defun anvil-pkg--tool-history (pkg-name)
  "MCP wrapper around `pkg-history'.

MCP Parameters:
  pkg-name - package name (string or symbol)."
  (let* ((sym (cond
               ((symbolp pkg-name) pkg-name)
               ((stringp pkg-name) (intern pkg-name))
               (t (signal 'anvil-pkg-error
                          (list (format "pkg-history: name must be string or symbol, got %S"
                                        pkg-name))))))
         (events (pkg-history sym)))
    (list :name (symbol-name sym)
          :count (length events)
          :events (or events []))))

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
   :read-only t)

  (anvil-server-register-tool
   #'anvil-pkg--tool-list-generations
   :id "pkg-list-generations"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "List Nix profile generations for the anvil-pkg profile.
Wraps `nix profile history --json' and returns :count and
:generations (list of plists with id, date, packages, active).
Refreshes the in-process generations mirror used by pkg-history.
Read-only."
   :read-only t)

  (anvil-server-register-tool
   #'anvil-pkg--tool-rollback
   :id "pkg-rollback"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "Roll the anvil-pkg Nix profile back to a previous generation.
generation-id may be an integer generation id, or nil / 0 to roll
back one step.  Replays the post-install hook for emacs packages
in the now-active generation so load-path stays in sync.")

  (anvil-server-register-tool
   #'anvil-pkg--tool-history
   :id "pkg-history"
   :intent '(packages)
   :layer 'io
   :server-id anvil-pkg--server-id
   :description
   "Return install / remove events for a package across the
anvil-pkg profile generations.  Reads from the in-process mirror;
call pkg-list-generations first for fresh data.  Read-only."
   :read-only t))

(defun anvil-pkg--unregister-tools ()
  "Remove every pkg-* MCP tool from the shared anvil server."
  (dolist (id '("pkg-install" "pkg-search" "pkg-list"
                "pkg-list-generations" "pkg-rollback" "pkg-history"))
    (anvil-server-unregister-tool id anvil-pkg--server-id)))

;;;###autoload
(defun anvil-pkg-enable ()
  "Register the pkg-* MCP tool surface.
Requires `anvil-server' (loaded with anvil.el).  Safe to call
repeatedly — re-registers idempotently."
  (interactive)
  (require 'anvil-server)
  (anvil-pkg--register-tools)
  (message "anvil-pkg: enabled (6 MCP tools, profile = %s)"
           anvil-pkg-profile-dir))

(defun anvil-pkg-disable ()
  "Unregister the pkg-* MCP tool surface."
  (interactive)
  (require 'anvil-server)
  (anvil-pkg--unregister-tools))

(provide 'anvil-pkg)
;;; anvil-pkg.el ends here
