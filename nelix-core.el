;;; nelix-core.el --- Elisp DSL package manager for anvil, backed by Nix store -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; Maintainer: zawatton
;; URL: https://github.com/zawatton/nelix-core
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix

;; This file is part of nelix-core.

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

;; nelix-core is a package manager configured in Emacs Lisp, backed by
;; the Nix store.  It is the Elisp counterpart of GNU Guix (Scheme +
;; Nix store), integrated as an `anvil.el' sub-module so AI agents can
;; install packages by emitting one Elisp form via MCP tools.
;;
;; Design doc: docs/design/01-overview.org.
;;
;; Phase 1 (this revision) ships the synchronous `nix profile' wrapper
;; for three core verbs: install, search, list.  Phase 2 adds a DSL
;; macro (`nelix-core-define'); Phase 3 a Git-host fallback; Phase 4
;; profile / generation management.
;;
;; Public Elisp API (pkg- short prefix; nelix-core owns the `pkg-'
;; namespace by deliberate ecosystem choice — see CLAUDE.md):
;;   (pkg-install NAME)
;;   (pkg-search QUERY)
;;   (pkg-list)
;;   (pkg-pin NAME)
;;   (pkg-unpin NAME)
;;   (pkg-pinned-p NAME)
;;   (pkg-list-pins)
;;   (pkg-uninstall NAME)
;;   (pkg-upgrade-plan &optional NAME)
;;   (pkg-upgrade &optional NAME)
;;   (pkg-info NAME)
;;   (pkg-doctor)
;;   (pkg-define NAME &rest BODY)   ; Phase 2
;;
;; Backwards-compatible long-form aliases (`nelix-core-install' etc.) are
;; provided via `defalias' for callers that prefer Emacs prefix style.
;;
;; MCP tools (registered by `nelix-core-enable'):
;;   pkg-install / pkg-search / pkg-list / pkg-uninstall / pkg-upgrade-plan / pkg-upgrade / pkg-info
;;   pkg-pin / pkg-unpin / pkg-list-pins / pkg-doctor
;;
;; CLI surface (out of scope for this repo; landed in anvil.el):
;;   anvil pkg install <name>
;;   anvil pkg search  <query>
;;   anvil pkg list
;;   anvil pkg pin <name>
;;   anvil pkg unpin <name>
;;   anvil pkg list-pins
;;   anvil pkg uninstall <name>
;;   anvil pkg upgrade-plan [name]
;;   anvil pkg upgrade [name]
;;   anvil pkg info <name>
;;   anvil pkg doctor

;;; Code:

(require 'nelix-compat)
(require 'nelix-state)

(defgroup nelix-core nil
  "Elisp DSL package manager backed by Nix store."
  :group 'anvil
  :prefix "nelix-core-")

(defconst nelix-core--server-id "emacs-eval"
  "MCP server id that nelix-core tools register under.
Shared with anvil-http / anvil-state / anvil-defs so a single
Claude Code MCP session sees one unified tool list.")

(defconst nelix-core--pins-namespace "pins"
  "`nelix-state' namespace for package pin state.")

(defvaralias 'nelix-default-backend 'nelix-core-default-backend)
(defvaralias 'nelix-nix-channel 'nelix-core-nix-channel)
(defvaralias 'nelix-profile-dir 'nelix-core-profile-dir)
(defvaralias 'nelix-nix-program 'nelix-core-nix-program)
(defvaralias 'nelix-nix-version-ttl-seconds
  'nelix-core-nix-version-ttl-seconds)

(defcustom nelix-core-default-backend 'nix
  "Default backend used when `nelix-core-install' is called without :backend.
Phase 1 only honours `nix'; `git' lands in Phase 3 (async-installer
derived fallback)."
  :type '(choice (const :tag "Nix profile (nixpkgs)" nix)
                 (const :tag "Git-host fallback" git))
  :group 'nelix-core)

(defcustom nelix-core-nix-channel "nixpkgs"
  "Flake reference for the primary Nix channel.
Used as `<channel>#<name>' when invoking `nix profile install'."
  :type 'string
  :group 'nelix-core)

(defcustom nelix-core-profile-dir
  (expand-file-name
   "nelix/profile"
   (or (nelix-compat-getenv "XDG_STATE_HOME")
       (expand-file-name ".local/state"
                         (or (nelix-compat-getenv "HOME") "~"))))
  "Directory for the Nelix Nix profile.
Isolated from `~/.nix-profile' so Nelix installs do not collide
with the user's other Nix profiles.  PATH augmentation is the
caller's responsibility (Phase 4 will add an `anvil pkg env'
helper)."
  :type 'directory
  :group 'nelix-core)

(defcustom nelix-core-nix-program "nix"
  "Name (or absolute path) of the `nix' executable."
  :type 'string
  :group 'nelix-core)

;;;; --- error symbols ---------------------------------------------------------

;; Use the compat helper instead of `define-error' so the same install
;; runs on NeLisp standalone (which does not provide that macro).
(nelix-compat-define-error-symbol 'nelix-error
                                      "nelix-core error")
(nelix-compat-define-error-symbol 'nelix-nix-not-found
                                      "nix binary not found on PATH"
                                      'nelix-error)
(nelix-compat-define-error-symbol 'nelix-nix-failed
                                      "nix command exited non-zero"
                                      'nelix-error)
(nelix-compat-define-error-symbol 'nelix-async-not-supported
                                      "asynchronous install not supported on this runtime"
                                      'nelix-error)

;;;; --- backend abstraction ---------------------------------------------------

(defvar nelix-core--call-nix-fn #'nelix-core--call-nix-default
  "Function used to invoke `nix'.  Override in tests.

Called with one argument — a list of string ARGS for the `nix'
executable.  Must return a plist with the keys :exit (integer),
:stdout (string), :stderr (string).")

(defun nelix-core--nix-credential-args ()
  "Return Nix CLI args injecting access tokens, or nil.

Phase 4-G L43: scans `nelix-compat-credential-env-alist'
and emits =--option extra-access-tokens \"host=tok ...\"= when
at least one env var resolves.  Nix accepts space-separated
=host=token= pairs; the option is silently ignored by
subcommands that do not fetch."
  (let ((pairs '()))
    (dolist (entry nelix-compat-credential-env-alist)
      (let* ((host (car entry))
             (vars (cdr entry))
             (token nil))
        (while (and vars (null token))
          (let ((v (nelix-compat-getenv (car vars))))
            (when (and v (> (length v) 0))
              (setq token v)))
          (setq vars (cdr vars)))
        (when token
          (push (format "%s=%s" host token) pairs))))
    (when pairs
      (list "--option"
            "extra-access-tokens"
            (mapconcat #'identity (nreverse pairs) " ")))))

(defun nelix-core--call-nix-default (args)
  "Default `nix' invoker.  Synchronous, runtime-portable.

ARGS is a list of string arguments passed to the executable named
by `nelix-core-nix-program'.  Returns plist (:exit :stdout :stderr).

Implementation defers I/O to `nelix-compat-call-process' so
the same code runs on Emacs and on NeLisp standalone.  Phase 4
will introduce an async variant gated by `:async'.

Phase 4-G L43: prepends `nelix-core--nix-credential-args' so
private fetchers reach private GitHub / GitLab repos when the
appropriate env var is set."
  (nelix-compat-call-process
   nelix-core-nix-program
   (append (nelix-core--nix-credential-args) args)))

(defun nelix-core--call-nix (args)
  "Invoke `nix' with ARGS via `nelix-core--call-nix-fn'."
  (funcall nelix-core--call-nix-fn args))

(defun nelix-core--ensure-nix ()
  "Signal `nelix-nix-not-found' if the nix binary is missing.
Q1 in design doc 01: loud failure at call site, not at load time.
Skipped in test mode (= when `nelix-core--call-nix-fn' is
overridden) because mock backends do not need nix on PATH."
  (unless (or (not (eq nelix-core--call-nix-fn #'nelix-core--call-nix-default))
              (nelix-compat-executable-find nelix-core-nix-program))
    (signal 'nelix-nix-not-found
            (list (format "%s not on PATH; install Nix 2.18+ with flakes"
                          nelix-core-nix-program)))))

(defun nelix-core--profile-args ()
  "Return the `--profile <dir>' fragment for nix-profile commands."
  (list "--profile" (expand-file-name nelix-core-profile-dir)))

;;;; --- JSON parsing helpers --------------------------------------------------

(defun nelix-core--json-parse (json-str)
  "Parse JSON-STR into nested alists/lists.  Empty string returns nil."
  (nelix-compat-json-parse json-str))

(defun nelix-core--string-find-char (string char start)
  "Return index of CHAR in STRING at or after START, or nil."
  (let ((i (or start 0))
        (n (length string))
        found)
    (while (and (< i n) (null found))
      (if (eq (aref string i) char)
          (setq found i)
        (setq i (1+ i))))
    found))

(defun nelix-core--string-find-substring (string needle start)
  "Return index of NEEDLE in STRING at or after START, or nil."
  (let ((i (or start 0))
        (n (length string))
        (m (length needle))
        found)
    (while (and (<= (+ i m) n) (null found))
      (if (string= (substring string i (+ i m)) needle)
          (setq found i)
        (setq i (1+ i))))
    found))

(defun nelix-core--json-skip-ws (string index)
  "Return first non-JSON-whitespace index in STRING at or after INDEX."
  (let ((i index)
        (n (length string)))
    (while (and (< i n)
                (let ((ch (aref string i)))
                  (or (eq ch ?\s) (eq ch ?\t)
                      (eq ch ?\n) (eq ch ?\r))))
      (setq i (1+ i)))
    i))

(defun nelix-core--json-read-simple-string (string index)
  "Read a JSON string in STRING starting at INDEX.
Return `(VALUE . NEXT-INDEX)'.  Handles the common escaped quote and
backslash forms needed for Nix profile element names."
  (let ((i (1+ index))
        (n (length string))
        (start (1+ index))
        (out "")
        (escaped nil)
        (done nil))
    (while (and (< i n) (not done))
      (let ((ch (aref string i)))
        (cond
         ((eq ch ?\\)
          (setq escaped t)
          (when (> i start)
            (setq out (concat out (substring string start i))))
          (setq i (1+ i))
          (when (< i n)
            (setq out (concat out (char-to-string (aref string i))))
            (setq i (1+ i))
            (setq start i)))
         ((eq ch ?\")
          (setq done t)
          (unless escaped
            (setq out (substring string start i)))
          (when (and escaped (> i start))
            (setq out (concat out (substring string start i))))
          (setq i (1+ i)))
         (t
          (setq i (1+ i))))))
    (cons out i)))

(defun nelix-core--json-skip-string (string index)
  "Return index just after the JSON string in STRING starting at INDEX."
  (let ((i (1+ index))
        (n (length string))
        (done nil))
    (while (and (< i n) (not done))
      (let ((ch (aref string i)))
        (cond
         ((eq ch ?\\)
          (setq i (+ i 2)))
         ((eq ch ?\")
          (setq done t)
          (setq i (1+ i)))
         (t
          (setq i (1+ i))))))
    i))

(defun nelix-core--parse-list-fast-element-names (json-str)
  "Parse Nix profile element names from JSON-STR without a full JSON parser.
This is a NeLisp fast path for `nix profile list --json', where the
generic JSON parser is too expensive for large profile output."
  (let* ((needle "\"elements\"")
         (elements-pos (nelix-core--string-find-substring json-str needle 0))
         (brace-pos (and elements-pos
                         (nelix-core--string-find-char
                          json-str ?{ (+ elements-pos (length needle)))))
         (i (and brace-pos (1+ brace-pos)))
         (n (length json-str))
         (depth 1)
         rows)
    (while (and i (< i n) (> depth 0))
      (let ((ch (aref json-str i)))
        (cond
         ((eq ch ?\")
          (if (= depth 1)
              (let* ((pair (nelix-core--json-read-simple-string json-str i))
                     (key (car pair))
                     (next (cdr pair))
                     (colon (nelix-core--json-skip-ws json-str next)))
                (when (and (< colon n)
                           (eq (aref json-str colon) ?:))
                  (push (list :name key
                              :attr-path nil
                              :original-url nil
                              :store-paths nil)
                        rows))
                (setq i next))
            (setq i (nelix-core--json-skip-string json-str i))))
         ((eq ch ?{)
          (setq depth (1+ depth))
          (setq i (1+ i)))
         ((eq ch ?})
          (setq depth (1- depth))
          (setq i (1+ i)))
         (t
          (setq i (1+ i))))))
    (nreverse rows)))

(defun nelix-core--parse-search (json-str)
  "Parse `nix search --json' output JSON-STR into list of plists.

Each plist carries :name :description :version :attrpath."
  (let ((data (nelix-core--json-parse json-str)))
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

(defun nelix-core--parse-list (json-str)
  "Parse `nix profile list --json' output JSON-STR into list of plists.

Each plist carries :name :attr-path :original-url :store-paths.
Accepts the modern Nix 2.18+ schema where `elements' is an object
keyed by package name."
  (if (nelix-compat--standalone-nelisp-p)
      (nelix-core--parse-list-fast-element-names json-str)
    (let* ((data (nelix-core--json-parse json-str))
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
                elements)))))

(defun nelix-core--parse-list-name-lines (text)
  "Parse newline-separated profile entry names from TEXT."
  (let ((lines (split-string (or text "") "\n" t))
        rows)
    (dolist (line lines)
      (push (list :name line
                  :attr-path nil
                  :original-url nil
                  :store-paths nil)
            rows))
    (nreverse rows)))

(defun nelix-core--list-via-text-names ()
  "List profile entries via text output reduced to names.
This is the standalone NeLisp fast path: parsing the full 70KB+
`nix profile list --json' output inside the interpreter is too slow,
so the child process reduces it to one package name per line first."
  (let* ((profile (expand-file-name nelix-core-profile-dir))
         (script
          "\"$1\" profile list --profile \"$2\" | sed -n 's/\\x1b\\[[0-9;]*m//g; s/^Name:[[:space:]]*//p'")
         (res (nelix-compat-call-process
               "sh"
               (list "-c" script "nelix-profile-list"
                     nelix-core-nix-program profile))))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-nix-failed
              (list (format "nix profile list failed (exit %s): %s"
                            (plist-get res :exit)
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (nelix-core--parse-list-name-lines (plist-get res :stdout))))

(defun nelix-core--find-name-row (name rows)
  "Return the first plist in ROWS whose :name equals NAME, or nil."
  (let ((rest rows)
        found)
    (while (and rest (null found))
      (let ((row (car rest)))
        (when (equal name (plist-get row :name))
          (setq found row))
        (setq rest (cdr rest))))
    found))

(declare-function nelix-core--registry-get "nelix-dsl")

(defun nelix-core--plist-has-key-p (plist key)
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

(defun nelix-core--registry-build-system-type (name)
  "Return registered build-system :type for symbol package NAME."
  (let ((ir (nelix-core--registry-get name)))
    (plist-get (plist-get ir :build-system) :type)))

(defvar nelix-core--registry) ; defined in nelix-dsl.el
(declare-function nelix-emacs-derive-deps "nelix-emacs")

(defun nelix-core--maybe-derive-deps (name no-auto-deps)
  "Phase 4-C L18 hook: pre-fetch `:depends-on' for NAME's IR.

When NAME's registered IR is an `emacs-package' build-system with
no explicit `:depends-on' and NO-AUTO-DEPS is nil, run
`nelix-emacs-derive-deps' against the IR and `puthash' the
augmented IR back into `nelix-core--registry'.  No-op otherwise.

The L8 invariant — explicit `(depends-on ...)` always wins — is
preserved by the `:depends-on' check below: if the user wrote
`(depends-on (list ...))` in their `pkg-define', we never
overwrite it.

Returns the (possibly augmented) IR for caller convenience."
  (require 'nelix-dsl)
  (let* ((ir (nelix-core--registry-get name))
         (build-type (plist-get (plist-get ir :build-system) :type))
         (existing-deps (plist-get ir :depends-on)))
    (when (and (eq build-type 'emacs-package)
               (null existing-deps)
               (not no-auto-deps))
      (require 'nelix-emacs)
      (let ((derived (nelix-emacs-derive-deps ir)))
        (when derived
          (let ((augmented (plist-put (copy-sequence ir)
                                      :depends-on derived)))
            (puthash name augmented nelix-core--registry)
            (setq ir augmented)))))
    ir))

(defun nelix-core--emacs-package-after-install (name)
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
         (ir (ignore-errors
               (nelix-core--registry-get name)))
         (bs (plist-get ir :build-system))
         (site-name (or (plist-get bs :pname)
                        pkg-name))
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
                           (format "share/emacs/site-lisp/%s" site-name)
                           store-path))
                 (flat    (expand-file-name "share/emacs/site-lisp"
                                            store-path))
                 (chosen
                  (cond
                   ;; per-package subdir wins when it exists
                   ((nelix-compat-file-exists-p per-pkg) per-pkg)
                   ;; elpa-style: pick the first elpa subdir starting with pname
                   ((let* ((elpa-dir (expand-file-name "elpa" flat))
                           (entries (and (nelix-compat-file-exists-p elpa-dir)
                                         (ignore-errors
                                           (directory-files elpa-dir t
                                                            (concat "\\`" (regexp-quote site-name) "-")))))
                           (hit (and entries (car entries))))
                      hit))
                   ;; flat layout: $out/share/emacs/site-lisp/<pname>.el
                   ((let ((flat-el (expand-file-name (concat site-name ".el") flat)))
                      (and (nelix-compat-file-exists-p flat-el) flat))))))
            (when chosen
              (add-to-list 'load-path chosen)
              (setq match-dir chosen))))))
    match-dir))

;;;; --- Nix version detection (L20) ------------------------------------------
;; Keep the version cache for diagnostics and future compatibility decisions.
;; The profile install path intentionally uses `nix profile install': Nix
;; 2.34.7 in Debian exposes `install' and rejects `add', so version-only
;; dispatch is not reliable enough for package installation.

(defconst nelix-core--nix-version-namespace "nelix-core:nix-version"
  "`nelix-state' namespace for the cached `nix --version' string.")

(defconst nelix-core--nix-version-key "default"
  "Single key under `nelix-core--nix-version-namespace'.

There is one Nix per profile so a constant key is sufficient.")

(defcustom nelix-core-nix-version-ttl-seconds (* 24 60 60)
  "TTL (seconds) for the cached `nix --version' lookup.

Default 1 day.  Re-detection on TTL expiry catches users upgrading
their Nix daemon mid-session without forcing them to clear the
cache manually."
  :type 'integer
  :group 'nelix-core)

(defun nelix-core--detect-nix-version ()
  "Return the Nix version string by calling `nix --version'.

Caches the result in `nelix-state' (namespace
`nelix-core--nix-version-namespace') with a 1-day TTL so subsequent
calls are free across Emacs restarts.  When the executable is
missing or the call fails this returns nil and the caller MUST
treat that as `< 2.34' for safety (= keep using the older `install'
subcommand)."
  (or (nelix-state-get nelix-core--nix-version-namespace
                           nelix-core--nix-version-key)
      (let ((res (condition-case _
                     (nelix-core--call-nix (list "--version"))
                   (error nil))))
        (when (and res (eq 0 (plist-get res :exit)))
          (let ((stdout (or (plist-get res :stdout) "")))
            (when (string-match "\\([0-9]+\\.[0-9]+\\(\\.[0-9]+\\)?\\)"
                                stdout)
              (let ((ver (match-string 1 stdout)))
                (nelix-state-put nelix-core--nix-version-namespace
                                     nelix-core--nix-version-key
                                     ver
                                     nelix-core-nix-version-ttl-seconds)
                ver)))))))

(defun nelix-core--nix-version-at-least-p (major minor)
  "Return non-nil when the cached Nix version is >= MAJOR.MINOR.

Operates on `nelix-core--detect-nix-version's cached value.  Only
the major and minor components are compared — patch-level
differences are irrelevant for the 2.34 install→add rename."
  (let ((ver (nelix-core--detect-nix-version)))
    (when (and ver (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)" ver))
      (let ((maj (string-to-number (match-string 1 ver)))
            (min (string-to-number (match-string 2 ver))))
        (or (> maj major)
            (and (= maj major) (>= min minor)))))))

(defun nelix-core--nix-install-subcommand ()
  "Return the right `nix profile' install subcommand for this Nix.

Always emits \"install\".  This is the subcommand present in the
current Nix CLI help on Debian with Nix 2.34.7, while \"add\" is
not recognised there.  Keeping one conservative spelling avoids a
version-only branch that can select an unsupported subcommand."
  "install")

;;;; --- public API ------------------------------------------------------------

(defun nelix-core--install-nixpkgs-args (name)
  "Return the `nix' argv list to install nixpkgs#NAME.
Shared between the synchronous path (`nelix-core--install-nixpkgs')
and the asynchronous `:async t' path so the two routes never
diverge on flag composition.  The install subcommand
(`install' vs `add') is resolved via
`nelix-core--nix-install-subcommand' for Nix 2.34 compatibility."
  (let ((flakeref (format "%s#%s" nelix-core-nix-channel name))
        (subcmd (nelix-core--nix-install-subcommand)))
    (append (list "profile" subcmd)
            (nelix-core--profile-args)
            (list flakeref))))

(defun nelix-core--install-nixpkgs (name)
  "Install nixpkgs#NAME via `nix profile install'.  String path.
Internal helper called by `pkg-install' when NAME is a string."
  (nelix-core--ensure-nix)
  (let* ((args (nelix-core--install-nixpkgs-args name))
         (res (nelix-core--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'nelix-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            name
                            (plist-get res :exit)
                            (nelix-compat-string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

(declare-function nelix-core--install-symbol "nelix-dsl")
(defvar nelix-core--write-flake-fn) ; defined in nelix-dsl.el

;;;; --- async install -------------------------------------------------------
;; Phase 4-B sub-task C (design doc 05 L16) introduced the :async path.
;; Phase 4-C sub-task D (design doc 06 L22) refactored the spawn through
;; `nelix-compat-make-process-async' so the runtime branch lives in
;; the compat layer; this file no longer touches `make-process' directly.

(defun nelix-core--async-stderr-string (proc)
  "Return the accumulated stderr string for PROC, or empty string."
  (let ((buf (nelix-compat-process-get proc 'nelix-core--stderr-buf)))
    (if (and buf (nelix-compat-buffer-live-p buf))
        (nelix-compat-buffer-string buf)
      "")))

(defun nelix-core--async-cleanup (proc)
  "Kill the stderr buffer attached to PROC, if any."
  (let ((buf (nelix-compat-process-get proc 'nelix-core--stderr-buf)))
    (when (and buf (nelix-compat-buffer-live-p buf))
      (nelix-compat-kill-buffer buf))))

(defun nelix-core--async-on-success (proc)
  "Sentinel happy path: post-install hook + :require + :on-success.

Phase 4-F: when the process was a multi-install (PROC's
`nelix-core--names' property is a list), iterate the post-install
load-path augment over every emacs-package symbol and surface
`:names NAMES' to the callback instead of `:name NAME'.
`:require' is rejected at dispatch for list NAME so we never need
to call `require' here in the multi case."
  (let* ((names       (nelix-compat-process-get proc 'nelix-core--names))
         (name        (nelix-compat-process-get proc 'nelix-core--name))
         (build-type  (nelix-compat-process-get proc 'nelix-core--build-system-type))
         (require-supplied (nelix-compat-process-get proc 'nelix-core--require-supplied))
         (require-sym (nelix-compat-process-get proc 'nelix-core--require-sym))
         (on-success  (nelix-compat-process-get proc 'nelix-core--on-success)))
    (cond
     (names
      ;; Multi-install: augment load-path for every emacs-package symbol.
      (nelix-core--multi-after-install names)
      (when on-success
        (condition-case err
            (funcall on-success (list :status :installed :names names))
          (error
           (lwarn 'nelix-core :error
                  "pkg-install :on-success raised: %S" err)))))
     (t
      (when (eq build-type 'emacs-package)
        (let ((load-path-dir (nelix-core--emacs-package-after-install name)))
          (when (and require-supplied load-path-dir)
            (require require-sym))))
      (when on-success
        (condition-case err
            (funcall on-success (list :status :installed :name name))
          (error
           (lwarn 'nelix-core :error
                  "pkg-install :on-success raised: %S" err))))))))

(defun nelix-core--async-on-error (proc exit)
  "Sentinel error path for PROC with non-zero EXIT.

Routes the failure to the user's :on-error if supplied; otherwise
defers a `lwarn' via `run-with-timer' so the message reaches
*Messages* without invoking `signal' from a sentinel (which Emacs
swallows silently).

Phase 4-F: multi-install errors surface `:names NAMES' instead of
`:name NAME'.  The error covers the whole bulk transaction since
Nix profile install is atomic."
  (let* ((names     (nelix-compat-process-get proc 'nelix-core--names))
         (name      (nelix-compat-process-get proc 'nelix-core--name))
         (stderr    (nelix-core--async-stderr-string proc))
         (on-error  (nelix-compat-process-get proc 'nelix-core--on-error))
         (err-plist (cond
                     (names (list :error 'nelix-nix-failed
                                  :exit  exit
                                  :stderr stderr
                                  :names names))
                     (t     (list :error 'nelix-nix-failed
                                  :exit  exit
                                  :stderr stderr
                                  :name  name)))))
    (cond
     (on-error
      (condition-case err
          (funcall on-error err-plist)
        (error
         (lwarn 'nelix-core :error
                "pkg-install :on-error raised: %S" err))))
     (t
      ;; No callback — surface async via run-with-timer so the
      ;; sentinel returns cleanly first.  Phase 4-B L16 contract.
      (run-with-timer
       0 nil
       (lambda ()
         (lwarn 'nelix-core :error
                "pkg-install %S failed (exit %s): %s"
                (or names name) exit
                (nelix-compat-string-trim (or stderr "")))))))))

(defun nelix-core--async-sentinel (proc event)
  "Sentinel for `nelix-core--spawn-nix-async'.

Dispatches to `nelix-core--async-on-success' on `finished' (exit
0) or `nelix-core--async-on-error' on any other terminal EVENT.
Always cleans up the stderr buffer once the process is no longer
live."
  (when (memq (nelix-compat-process-status proc) '(exit signal))
    (unwind-protect
        (let ((exit (nelix-compat-process-exit-status proc)))
          (cond
           ((and (stringp event)
                 (string-prefix-p "finished" event)
                 (eq 0 exit))
            (nelix-core--async-on-success proc))
           (t
            (nelix-core--async-on-error proc exit))))
      (nelix-core--async-cleanup proc))))

(defun nelix-core--spawn-nix-async (args name plist build-system-type)
  "Spawn `nix' with ARGS asynchronously and wire up the sentinel.

NAME, PLIST and BUILD-SYSTEM-TYPE are stashed on the process via
compat process properties so the sentinel can route post-install + user
callbacks without a closure (closures over PLIST are awkward to
mock).

Phase 4-F: NAME may also be a list of names (multi-install).  When
NAME is a list, the process records it under the `nelix-core--names'
property and sentinel callbacks surface `:names' instead of `:name'.
BUILD-SYSTEM-TYPE is unused in the multi case (each symbol's type is
re-resolved inside `nelix-core--multi-after-install')."
  (nelix-core--ensure-nix)
  (let* ((multi (and (consp name) (not (stringp name))))
         (process-label
          (cond (multi (format "multi-%d" (length name)))
                (t     (format "%s" name))))
         (stderr-buf
          (nelix-compat-generate-buffer " *nelix-core-async-stderr*"))
         (require-supplied (nelix-core--plist-has-key-p plist :require))
         (require-sym      (plist-get plist :require))
         (on-success       (plist-get plist :on-success))
         (on-error         (plist-get plist :on-error))
         ;; compat-make-process-async returns a real process object on
         ;; Emacs and can delegate to a NeLisp backend when one is
         ;; loaded; otherwise the NeLisp branch signals
         ;; `nelix-async-not-supported'.
         ;; Phase 4-G L43: prepend credential args so async installs
         ;; against private fetchers see the same access tokens as
         ;; the sync `nelix-core--call-nix-default' path.
         (cred-args (nelix-core--nix-credential-args))
         (proc (nelix-compat-make-process-async
                :name (format "nelix-core-install-%s" process-label)
                :buffer nil
                :command (cons nelix-core-nix-program
                               (append cred-args args))
                :connection-type 'pipe
                :noquery t
                :stderr stderr-buf
                :sentinel #'nelix-core--async-sentinel)))
    (nelix-compat-process-put proc 'nelix-core--stderr-buf stderr-buf)
    (cond
     (multi
      (nelix-compat-process-put proc 'nelix-core--names name))
     (t
      (nelix-compat-process-put proc 'nelix-core--name name)
      (nelix-compat-process-put proc 'nelix-core--build-system-type
                                    build-system-type)
      (nelix-compat-process-put proc 'nelix-core--require-supplied
                                    require-supplied)
      (nelix-compat-process-put proc 'nelix-core--require-sym require-sym)))
    (nelix-compat-process-put proc 'nelix-core--on-success on-success)
    (nelix-compat-process-put proc 'nelix-core--on-error on-error)
    proc))

;;;; --- multi-install helpers (Phase 4-F L29-L34) ---------------------------

(defun nelix-core--validate-multi-names (names)
  "Validate a multi-install NAMES list.  Signal `nelix-error' on bad shape.

NAMES must be a non-empty list of (string | symbol) elements."
  (unless (and (consp names) (not (stringp names)))
    (signal 'nelix-error
            (list (format "pkg-install: NAMES must be a non-empty list, got %S"
                          names))))
  (when (null names)
    (signal 'nelix-error
            (list "pkg-install: NAMES list must be non-empty")))
  (dolist (n names)
    (unless (or (stringp n) (symbolp n))
      (signal 'nelix-error
              (list (format "pkg-install: NAMES element must be string or symbol, got %S"
                            n))))))

(defun nelix-core--multi-install-flakerefs (names flake-dir)
  "Return flakeref strings for NAMES.

Symbols become `path:FLAKE-DIR#sym'; strings become
`<channel>#name'.  Order in NAMES is preserved."
  (mapcar (lambda (n)
            (cond
             ((stringp n) (format "%s#%s" nelix-core-nix-channel n))
             ((symbolp n) (format "path:%s#%s" flake-dir n))))
          names))

(defun nelix-core--multi-after-install (names)
  "Iterate `nelix-core--emacs-package-after-install' over emacs-package
symbols in NAMES (skipping strings and non-emacs-package symbols).

Used by the multi-install async sentinel to augment `load-path' for
every newly-installed Emacs package."
  (dolist (n names)
    (when (symbolp n)
      (let ((build-type (nelix-core--registry-build-system-type n)))
        (when (eq build-type 'emacs-package)
          (nelix-core--emacs-package-after-install n))))))

(defun nelix-core--multi-install-prepare (names plist)
  "Common pre-flight for multi-install: validate, derive deps, render flake.

Signals on bad NAMES, on `:require' supplied, on undefined symbols.
Returns a plist `(:flakerefs LIST :flake-dir DIR)' suitable for
both sync and async install paths.  Skips the flake render entirely
when NAMES contains only strings (no IR to render)."
  (nelix-core--validate-multi-names names)
  (when (nelix-core--plist-has-key-p plist :require)
    (signal 'nelix-error
            (list "pkg-install: :require is not supported with a NAMES list (ambiguous; install one at a time)")))
  (nelix-core--ensure-nix)
  (let* ((symbols (delq nil (mapcar (lambda (n) (and (symbolp n) n))
                                    names)))
         (no-auto-deps (plist-get plist :no-auto-deps)))
    (when symbols
      (require 'nelix-dsl)
      ;; Validate every symbol exists in the registry up front (so we
      ;; do not invoke nix on a half-broken bulk).
      (dolist (sym symbols)
        (nelix-core--registry-get sym))
      ;; Derive deps per-symbol before the single render pass.
      (dolist (sym symbols)
        (nelix-core--maybe-derive-deps sym no-auto-deps)))
    (let* ((flake-path (when symbols (funcall nelix-core--write-flake-fn)))
           (flake-dir  (and flake-path
                            (directory-file-name
                             (file-name-directory flake-path))))
           (flakerefs (nelix-core--multi-install-flakerefs names flake-dir)))
      (list :flakerefs flakerefs :flake-dir flake-dir))))

(defun nelix-core--multi-install-args (flakerefs)
  "Build the `nix profile install ...' args for FLAKEREFS."
  (let ((subcmd (nelix-core--nix-install-subcommand)))
    (append (list "profile" subcmd)
            (nelix-core--profile-args)
            flakerefs)))

;;;###autoload
(defun pkg-install (name &rest plist)
  "Install package NAME.

NAME is one of:
  - a string nixpkgs attribute path (e.g. \"ripgrep\", \"nodejs_20\")
    → installs nixpkgs#NAME directly;
  - a symbol previously declared via `pkg-define' (Phase 2)
    → looks up the local registry, regenerates flake.nix under
    `nelix-core-profile-dir's parent, and installs from that flake.
  - a list of any mix of the above (Phase 4-F L29)
    → a single `nix profile install' invocation with all
    flakerefs.  Atomic: success or none.  `:require' is rejected
    in this mode; on-success/on-error callbacks receive `:names
    NAMES' instead of `:name NAME'.

Recognised PLIST keys:
  :require SYMBOL
    After a successful `emacs-package' symbol install, augment
    `load-path' and call `(require SYMBOL)'.
  :async BOOL
    When non-nil, spawn `nix profile install' asynchronously and
    return the process object immediately.  Emacs uses
    `make-process'; NeLisp can provide a native backend through
    `nelix-compat'.  If no NeLisp backend is available, signals
    `nelix-async-not-supported'.  Phase 4-B sub-task C +
    Phase 5 compat groundwork.
  :on-success FN
    Called as (FN (:status :installed :name NAME)) after a
    successful async install (post-install hook + :require run
    first).  Ignored — with a one-shot warning — when :async is
    not supplied.
  :on-error FN
    Called as (FN (:error \\='nelix-nix-failed :exit N :stderr
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
process object.  Signals `nelix-nix-failed' /
`nelix-nix-not-found' / `nelix-async-not-supported' /
`nelix-undefined-package' as appropriate."
  (let ((async (plist-get plist :async))
        (multi (and (consp name) (not (stringp name)))))
    ;; Phase 4-B L16 reject list: warn (don't error) when callbacks
    ;; are supplied without :async — keeps the synchronous path
    ;; backwards-compatible.
    (when (and (not async)
               (or (nelix-core--plist-has-key-p plist :on-success)
                   (nelix-core--plist-has-key-p plist :on-error)))
      (lwarn 'nelix-core :warning
             "pkg-install: :on-success/:on-error ignored without :async t"))
    (cond
     ((null name)
      (signal 'nelix-error
              (list (format "pkg-install: NAME must be string, symbol, or non-empty list, got %S"
                            name))))
     ;; Phase 4-F: list dispatch.
     (multi
      (let* ((prep (nelix-core--multi-install-prepare name plist))
             (flakerefs (plist-get prep :flakerefs))
             (args (nelix-core--multi-install-args flakerefs)))
        (cond
         (async
          (nelix-core--spawn-nix-async args name plist nil))
         (t
          (let ((res (nelix-core--call-nix args)))
            (cond
             ((eq 0 (plist-get res :exit))
              (nelix-core--multi-after-install name)
              t)
             (t
              (signal 'nelix-nix-failed
                      (list (format "nix profile install %S failed (exit %s): %s"
                                    name
                                    (plist-get res :exit)
                                    (nelix-compat-string-trim (or (plist-get res :stderr) "")))
                            :stderr (plist-get res :stderr))))))))))
     (async
      (cond
       ((stringp name)
        (nelix-core--ensure-nix)
        (let ((args (nelix-core--install-nixpkgs-args name)))
          (nelix-core--spawn-nix-async args name plist nil)))
       ((symbolp name)
        (require 'nelix-dsl)
        (nelix-core--ensure-nix)
        (nelix-core--registry-get name)
        ;; Phase 4-C L18: derive :depends-on from the upstream
        ;; `Package-Requires' header before flake render so the
        ;; resulting derivation has the correct `packageRequires'.
        (nelix-core--maybe-derive-deps name (plist-get plist :no-auto-deps))
        (let* ((flake-path (funcall nelix-core--write-flake-fn))
               (flake-dir  (directory-file-name (file-name-directory flake-path)))
               (flakeref   (format "path:%s#%s" flake-dir name))
               (subcmd     (nelix-core--nix-install-subcommand))
               (args       (append (list "profile" subcmd)
                                   (nelix-core--profile-args)
                                   (list flakeref)))
               (build-system-type (nelix-core--registry-build-system-type name)))
          (nelix-core--spawn-nix-async args name plist build-system-type)))
       (t (signal 'nelix-error
                  (list (format "pkg-install: NAME must be string, symbol, or non-empty list, got %S"
                                name))))))
     (t
      (cond
       ((stringp name) (nelix-core--install-nixpkgs name))
       ((symbolp name)
        (require 'nelix-dsl)
        ;; Phase 4-C L18: pre-fetch + IR augmentation BEFORE
        ;; `nelix-core--install-symbol' so the rendered flake.nix
        ;; carries the derived `packageRequires'.
        (nelix-core--maybe-derive-deps name (plist-get plist :no-auto-deps))
        (let* ((require-supplied (nelix-core--plist-has-key-p plist :require))
               (require-sym (plist-get plist :require))
               (build-system-type (nelix-core--registry-build-system-type name))
               (installed (nelix-core--install-symbol name)))
          (when (eq build-system-type 'emacs-package)
            (let ((load-path-dir (nelix-core--emacs-package-after-install name)))
              (when (and require-supplied (null load-path-dir))
                (signal 'nelix-error
                        (list (format "pkg-install: could not locate load-path directory for %s"
                                      name))))
              (when require-supplied
                (require require-sym))))
          installed))
       (t (signal 'nelix-error
                  (list (format "pkg-install: NAME must be string, symbol, or non-empty list, got %S"
                                name)))))))))

;;;###autoload
(defun pkg-search (query)
  "Search nixpkgs for packages matching QUERY.

QUERY is a free-form regex passed to `nix search'.  Returns a list
of plists carrying :name :description :version :attrpath, or nil
when no packages match."
  (nelix-core--ensure-nix)
  (let* ((args (list "search" nelix-core-nix-channel query "--json"))
         (res (nelix-core--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-nix-failed
              (list (format "nix search %s failed (exit %s): %s"
                            query
                            (plist-get res :exit)
                            (nelix-compat-string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (nelix-core--parse-search (plist-get res :stdout))))

;;;###autoload
(defun pkg-list ()
  "List packages installed in the nelix-core Nix profile.

Returns a list of plists carrying :name :attr-path :original-url
:store-paths, or nil for an empty profile."
  (nelix-core--ensure-nix)
  (if (and (nelix-compat--standalone-nelisp-p)
           (eq nelix-core--call-nix-fn #'nelix-core--call-nix-default))
      (nelix-core--list-via-text-names)
    (let* ((args (append (list "profile" "list" "--json")
                         (nelix-core--profile-args)))
           (res (nelix-core--call-nix args)))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-nix-failed
                (list (format "nix profile list failed (exit %s): %s"
                              (plist-get res :exit)
                              (nelix-compat-string-trim (or (plist-get res :stderr) "")))
                      :stderr (plist-get res :stderr))))
      (nelix-core--parse-list (plist-get res :stdout)))))

(defun nelix-core--normalize-pin-name (caller name)
  "Return NAME as a non-empty string for CALLER, or signal an error."
  (cond
   ((stringp name)
    (let ((trimmed (nelix-compat-string-trim name)))
      (if (zerop (length trimmed))
          (signal 'nelix-error
                  (list (format "%s: NAME must be non-empty string or symbol, got %S"
                                caller name)))
        trimmed)))
   ((symbolp name) (symbol-name name))
   (t (signal 'nelix-error
              (list (format "%s: NAME must be non-empty string or symbol, got %S"
                            caller name))))))

;;;; --- package pinning (Phase 7-A) ------------------------------------------

;;;###autoload
(defun pkg-pin (name)
  "Record NAME as pinned in persistent nelix-core state.

NAME must be a non-empty string or symbol.  Symbols are coerced
via `symbol-name'.  Returns t."
  (nelix-state-put nelix-core--pins-namespace
                       (nelix-core--normalize-pin-name "pkg-pin" name)
                       t)
  t)

;;;###autoload
(defun pkg-unpin (name)
  "Remove NAME from persistent nelix-core pin state.

NAME must be a non-empty string or symbol.  Symbols are coerced
via `symbol-name'.  Returns t."
  (nelix-state-delete nelix-core--pins-namespace
                          (nelix-core--normalize-pin-name "pkg-unpin" name))
  t)

;;;###autoload
(defun pkg-pinned-p (name)
  "Return non-nil when NAME is pinned in persistent nelix-core state.

NAME must be a non-empty string or symbol.  Symbols are coerced
via `symbol-name'."
  (and (nelix-state-get nelix-core--pins-namespace
                            (nelix-core--normalize-pin-name "pkg-pinned-p" name))
       t))

;;;###autoload
(defun pkg-list-pins ()
  "Return the list of pinned package names as strings."
  (nelix-state-keys nelix-core--pins-namespace))

(defun nelix-core--normalize-upgrade-name (caller name &optional blank-is-nil)
  "Return NAME as a string for CALLER, or nil for all packages.
When BLANK-IS-NIL is non-nil, blank strings also mean all
packages.  Otherwise blank strings signal `nelix-error'."
  (cond
   ((null name) nil)
   ((symbolp name) (symbol-name name))
   ((stringp name)
    (let ((trimmed (nelix-compat-string-trim name)))
      (cond
       ((and (zerop (length trimmed)) blank-is-nil) nil)
       ((zerop (length trimmed))
        (signal 'nelix-error
                (list (format "%s: NAME must be non-empty string or symbol, got %S"
                              caller name))))
       (t trimmed))))
   (t
    (signal 'nelix-error
            (list (format "%s: NAME must be string, symbol, or nil, got %S"
                          caller name))))))

(defun nelix-core--installed-entry-by-name (name installed)
  "Return the row in INSTALLED whose `:name' is NAME, or nil."
  (let (found)
    (dolist (entry installed found)
      (when (and (null found)
                 (equal (plist-get entry :name) name))
        (setq found entry)))))

(defun nelix-core--partition-installed-by-pins (installed pins)
  "Split INSTALLED into upgrade and pinned rows using PINS.
Return `(:upgrade ROWS :pinned ROWS :stale-pins NAMES)'."
  (let ((upgrade nil)
        (pinned nil)
        (seen-pins nil))
    (dolist (entry installed)
      (let ((name (plist-get entry :name)))
        (if (member name pins)
            (progn
              (push entry pinned)
              (push name seen-pins))
          (push entry upgrade))))
    (list :upgrade (nreverse upgrade)
          :pinned (nreverse pinned)
          :stale-pins
          (let (stale)
            (dolist (pin pins (nreverse stale))
              (unless (member pin seen-pins)
                (push pin stale)))))))

;;;###autoload
(defun pkg-upgrade-plan (&optional name)
  "Return a read-only plan for `pkg-upgrade'.

When NAME is nil, reports every currently installed profile
element that would be included in a bulk upgrade and separates
pinned entries that would be skipped.  When NAME is a string or
symbol, reports whether that single entry is installed, pinned, or
missing.

This function does not call `nix profile upgrade', refresh
generations, or replay Emacs package hooks.  The return value is a
plist with at least:
  :operation  `upgrade'
  :name       `:all' or the target name string
  :count      number of entries that would be upgraded
  :upgrade    list of installed profile entry plists
  :pinned     list of installed pinned profile entry plists
  :blocked    nil or a reason symbol
  :empty      non-nil when no profile entry would be upgraded."
  (interactive)
  (nelix-core--ensure-nix)
  (let* ((target (nelix-core--normalize-upgrade-name
                  "pkg-upgrade-plan" name))
         (pins (pkg-list-pins))
         (installed (pkg-list)))
    (if target
        (let* ((entry (nelix-core--installed-entry-by-name target installed))
               (pinned (member target pins))
               (blocked (cond
                         (pinned :pinned)
                         ((null entry) :missing)
                         (t nil)))
               (upgrade (if blocked nil (list entry))))
          (list :operation 'upgrade
                :name target
                :count (length upgrade)
                :upgrade upgrade
                :pinned (if (and pinned entry) (list entry) nil)
                :pinned-names pins
                :missing (and (null entry) target)
                :blocked blocked
                :empty (null upgrade)))
      (let* ((partition (nelix-core--partition-installed-by-pins
                         installed pins))
             (upgrade (plist-get partition :upgrade))
             (pinned (plist-get partition :pinned)))
        (list :operation 'upgrade
              :name :all
              :count (length upgrade)
              :upgrade upgrade
              :pinned pinned
              :pinned-names pins
              :stale-pins (plist-get partition :stale-pins)
              :blocked nil
              :empty (null upgrade))))))

;;;###autoload
(defun pkg-uninstall (name)
  "Uninstall NAME from the nelix-core Nix profile.

NAME is a string or symbol naming an installed profile element as
reported by `pkg-list'.  Returns t on success.  Signals
`nelix-error' when NAME is not installed in the nelix-core
profile, and `nelix-nix-failed' on a non-zero `nix profile
remove' exit."
  (nelix-core--ensure-nix)
  (let ((name-str (cond
                   ((stringp name) name)
                   ((symbolp name) (symbol-name name))
                   (t (signal 'nelix-error
                              (list (format "pkg-uninstall: NAME must be string or symbol, got %S"
                                            name)))))))
    (unless (let (installed)
              (dolist (entry (pkg-list))
                (when (and (null installed)
                           (equal (plist-get entry :name) name-str))
                  (setq installed t)))
              installed)
      (signal 'nelix-error
              (list (format "pkg-uninstall: %s is not installed in the nelix-core profile"
                            name-str))))
    (let* ((args (append (list "profile" "remove" name-str)
                         (nelix-core--profile-args)))
           (res (nelix-core--call-nix args)))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-nix-failed
                (list (format "nix profile remove %s failed (exit %s): %s"
                              name-str
                              (plist-get res :exit)
                              (nelix-compat-string-trim
                               (or (plist-get res :stderr) "")))
                      :stderr (plist-get res :stderr))))
      (condition-case _ (pkg-list-generations) (error nil))
      (nelix-core--rollback-replay-emacs-hooks)
      t)))

;;;###autoload
(defun pkg-upgrade (&optional name)
  "Upgrade packages in the nelix-core Nix profile.

When NAME is nil upgrades every installed package by passing the
portable \".*\" matcher to `nix profile upgrade'.  Otherwise NAME
must be a string or symbol naming the single profile element to
upgrade.  Pinned packages are skipped during upgrade-all, and a
pinned NAME must be unpinned before upgrading it directly.

Returns t on success.  Signals `nelix-nix-failed' on a
non-zero `nix profile upgrade' exit."
  (nelix-core--ensure-nix)
  (let* ((pins (pkg-list-pins))
         (matchers
          (cond
           ((null name)
            (if (null pins)
                '(".*")
              (delq nil
                    (mapcar
                     (lambda (entry)
                       (let ((entry-name (plist-get entry :name)))
                         (when (and (stringp entry-name)
                                    (not (member entry-name pins)))
                           entry-name)))
                     (pkg-list)))))
           ((stringp name)
            (let ((trimmed (nelix-compat-string-trim name)))
              (if (zerop (length trimmed))
                  (signal 'nelix-error
                          (list (format "pkg-upgrade: NAME must be non-empty string or symbol, got %S"
                                        name)))
                (when (member trimmed pins)
                  (signal 'nelix-error
                          (list (format "pkg-upgrade: %s is pinned; run pkg-unpin first"
                                        trimmed))))
                (list name))))
           ((symbolp name)
            (let ((name-str (symbol-name name)))
              (when (member name-str pins)
                (signal 'nelix-error
                        (list (format "pkg-upgrade: %s is pinned; run pkg-unpin first"
                                      name-str))))
              (list name-str)))
           (t (signal 'nelix-error
                      (list (format "pkg-upgrade: NAME must be string, symbol, or nil, got %S"
                                    name))))))
         (display-name (mapconcat #'identity matchers " ")))
    (if (null matchers)
        t
      (let* ((args (append (append (list "profile" "upgrade") matchers)
                           (nelix-core--profile-args)))
             (res (nelix-core--call-nix args)))
        (unless (eq 0 (plist-get res :exit))
          (signal 'nelix-nix-failed
                  (list (format "nix profile upgrade %s failed (exit %s): %s"
                                display-name
                                (plist-get res :exit)
                                (nelix-compat-string-trim
                                 (or (plist-get res :stderr) "")))
                        :stderr (plist-get res :stderr))))
        (condition-case _ (pkg-list-generations) (error nil))
        (nelix-core--rollback-replay-emacs-hooks)
        t))))

;;;###autoload
(defun pkg-info (name)
  "Return merged installed/profile and nixpkgs metadata for NAME.

NAME must be a string or symbol naming a package.  Returns a
plist carrying :name :installed :version :description :attr-path
:original-url :store-paths, or nil when NAME is found neither in
the current profile nor in `nix search'."
  (nelix-core--ensure-nix)
  (let* ((name-str (cond
                    ((stringp name) name)
                    ((symbolp name) (symbol-name name))
                    (t (signal 'nelix-error
                               (list (format "pkg-info: NAME must be string or symbol, got %S"
                                             name))))))
         (installed (nelix-core--find-name-row name-str (pkg-list)))
         (search-hit
          (condition-case _
              (let* ((rows (pkg-search name-str))
                     (exact (nelix-core--find-name-row name-str rows)))
                (or exact (car rows)))
            (error nil))))
    (when (or installed search-hit)
      (list :name name-str
            :installed (and installed t)
            :version (plist-get search-hit :version)
            :description (plist-get search-hit :description)
            :attr-path (or (plist-get installed :attr-path)
                           (plist-get search-hit :attrpath))
            :original-url (plist-get installed :original-url)
            :store-paths (plist-get installed :store-paths)))))

;;;; --- environment health report (Phase 7-B) -------------------------------

(defun nelix-core--doctor-check (check thunk &optional on-error-status)
  "Run THUNK for CHECK and degrade errors into a report row.

CHECK is the symbol identifying the health probe.  THUNK must
return a plist carrying at least :status and :detail.  When THUNK
signals, return `(:check CHECK :status STATUS :detail STRING)'
instead of aborting the whole doctor report.  ON-ERROR-STATUS
defaults to `:error'."
  (condition-case err
      (let ((row (funcall thunk)))
        (list :check check
              :status (plist-get row :status)
              :detail (plist-get row :detail)))
    (error
     (list :check check
           :status (or on-error-status :error)
           :detail (format "%s check failed: %s"
                           check
                           (error-message-string err))))))

(defun nelix-core--doctor-nix-version-check ()
  "Return the nix-version row for `pkg-doctor'."
  (let ((version (nelix-core--detect-nix-version)))
    (cond
     ((null version)
      (list :status :error
            :detail (format "Could not detect %s version; install Nix 2.18+ with flakes"
                            nelix-core-nix-program)))
     ((nelix-core--nix-version-at-least-p 2 18)
      (list :status :ok
            :detail (format "Detected Nix %s (meets >= 2.18)"
                            version)))
     (t
      (list :status :warn
            :detail (format "Detected Nix %s; nelix-core expects >= 2.18"
                            version))))))

(defun nelix-core--doctor-profile-dir-check ()
  "Return the profile-dir row for `pkg-doctor'."
  (let* ((profile-dir (expand-file-name nelix-core-profile-dir))
         (parent (file-name-directory (directory-file-name profile-dir))))
    (cond
     ((not (nelix-compat-file-exists-p parent))
      (list :status :warn
            :detail (format "Profile parent %s does not exist"
                            parent)))
     ((and (fboundp 'file-writable-p)
           (file-writable-p parent))
      (list :status :ok
            :detail (format "Profile parent %s exists and is writable"
                            parent)))
     (t
      (list :status :warn
            :detail (format "Profile parent %s exists but is not writable"
                            parent))))))

(defun nelix-core--doctor-installed-count-check ()
  "Return the installed-count row for `pkg-doctor'."
  (let ((rows (pkg-list)))
    (list :status :info
          :detail (format "%d package(s) installed in the nelix-core profile"
                          (length rows)))))

(defun nelix-core--doctor-anvil-server-check ()
  "Return the anvil-server row for `pkg-doctor'."
  (if (or (featurep 'anvil-server)
          (let ((features-symbol (intern "features")))
            (and (boundp features-symbol)
                 (memq 'anvil-server (symbol-value features-symbol)))))
      (list :status :info
            :detail "Feature anvil-server is loaded")
    (list :status :warn
          :detail "Feature anvil-server is not loaded")))

(defun nelix-core--doctor-state-file-check ()
  "Return the state-file row for `pkg-doctor'."
  (if (nelix-compat-file-exists-p nelix-state-file)
      (list :status :info
            :detail (format "State file exists at %s"
                            nelix-state-file))
    (list :status :info
          :detail (format "State file not created yet: %s"
                          nelix-state-file))))

;;;###autoload
(defun pkg-doctor ()
  "Return a read-only environment health report for nelix-core.

The return value is a list of check plists of the form
`(:check SYMBOL :status STATUS :detail STRING)', where STATUS is
one of `:ok', `:warn', `:error', or `:info'.

This report is read-only: it does not mutate the profile, refresh
generations, or replay post-install hooks."
  (list
   (nelix-core--doctor-check 'nix-version
                            #'nelix-core--doctor-nix-version-check)
   (nelix-core--doctor-check 'profile-dir
                            #'nelix-core--doctor-profile-dir-check
                            :warn)
   (nelix-core--doctor-check 'installed-count
                            #'nelix-core--doctor-installed-count-check)
   (nelix-core--doctor-check 'anvil-server
                            #'nelix-core--doctor-anvil-server-check
                            :warn)
   (nelix-core--doctor-check 'state-file
                            #'nelix-core--doctor-state-file-check)))

;;;; --- profile generation rollback (L19) ------------------------------------
;; Phase 4-C sub-task B: wrap `nix profile history --json' / `nix profile
;; rollback' so users can recover from a regressing install.  The local
;; mirror is a per-Emacs-session defvar; persistent storage is deferred
;; to Phase 4-D when anvil-state integration lands.

(defconst nelix-core--generations-namespace "nelix-core:generations"
  "`nelix-state' namespace for the profile generations mirror.")

(defconst nelix-core--generations-key "mirror"
  "Single key under `nelix-core--generations-namespace' holding the full list.

The mirror is small enough (one entry per generation, ≤ tens of KiB
in practice) that a single blob is cheaper than per-id rows.")

(defun nelix-core--generations-cache-get ()
  "Return the cached generations list from `nelix-state'."
  (nelix-state-get nelix-core--generations-namespace
                       nelix-core--generations-key))

(defun nelix-core--generations-cache-put (generations)
  "Persist GENERATIONS as the mirror in `nelix-state'.

No TTL: the mirror is refreshed on every install / list / rollback
so staleness is bounded by the time between user-driven calls."
  (nelix-state-put nelix-core--generations-namespace
                       nelix-core--generations-key
                       generations))

(defun nelix-core--parse-history (json-str)
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
  (let* ((data (nelix-core--json-parse json-str))
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
  "List Nix profile generations for the nelix-core profile.

Returns a list of plists carrying :id, :date, :packages,
:active.  Generations are sorted by :id ascending so
`(car (last (pkg-list-generations)))' is the latest.

Side effects: refreshes the persistent generations mirror in
`nelix-state' so `pkg-history' has fresh data without an extra
shell-out, surviving Emacs restarts.

Signals `nelix-nix-failed' on a non-zero `nix profile history'
exit (e.g. corrupt profile)."
  (nelix-core--ensure-nix)
  (let* ((args (append (list "profile" "history" "--json")
                       (nelix-core--profile-args)))
         (res (nelix-core--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-nix-failed
              (list (format "nix profile history failed (exit %s): %s"
                            (plist-get res :exit)
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (let ((generations (nelix-core--parse-history
                        (or (plist-get res :stdout) ""))))
      (nelix-core--generations-cache-put generations)
      generations)))

(defun nelix-core--rollback-replay-emacs-hooks ()
  "Re-run `nelix-core--emacs-package-after-install' for the active generation.

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
              (nelix-core--emacs-package-after-install (intern name))
            (error nil)))))))

(defun nelix-core--generation-id-known-p (id)
  "Return non-nil when ID matches a generation in the cache."
  (let (found)
    (dolist (gen (nelix-core--generations-cache-get))
      (when (and (not found) (eq (plist-get gen :id) id))
        (setq found t)))
    found))

;;;###autoload
(defun pkg-rollback (&optional generation-id)
  "Roll the nelix-core Nix profile back to GENERATION-ID.

When GENERATION-ID is nil rolls back one step (= the previous
generation).  When supplied as an integer, jumps directly to that
generation; signals `nelix-error' if it is not in the local
generations mirror (after a refresh).

After a successful rollback the in-process generations cache is
refreshed and the post-install hook is replayed for every
emacs-package in the now-active generation so `load-path' stays
in sync.

Returns t on success.  Signals `nelix-nix-failed' on a
non-zero `nix profile rollback' exit."
  (nelix-core--ensure-nix)
  ;; If a specific id was requested, ensure it exists.  Refresh the
  ;; cache once before signalling so concurrent installs that bumped
  ;; the generation count don't trigger a false negative.
  (when generation-id
    (unless (integerp generation-id)
      (signal 'nelix-error
              (list (format "pkg-rollback: GENERATION-ID must be integer, got %S"
                            generation-id))))
    (unless (nelix-core--generation-id-known-p generation-id)
      (pkg-list-generations)
      (unless (nelix-core--generation-id-known-p generation-id)
        (signal 'nelix-error
                (list (format "pkg-rollback: generation %d not found in profile history"
                              generation-id))))))
  (let* ((base-args (append (list "profile" "rollback")
                            (nelix-core--profile-args)))
         (args (if generation-id
                   (append base-args
                           (list "--to-generation"
                                 (number-to-string generation-id)))
                 base-args))
         (res (nelix-core--call-nix args)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-nix-failed
              (list (format "nix profile rollback failed (exit %s): %s"
                            (plist-get res :exit)
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    ;; Refresh the cache + replay emacs-package hooks.  Both are
    ;; condition-case-wrapped so a refresh failure doesn't mask a
    ;; successful rollback.
    (condition-case _ (pkg-list-generations) (error nil))
    (nelix-core--rollback-replay-emacs-hooks)
    t))

(defun nelix-core--active-generation ()
  "Return the active generation plist from the mirror.
Refreshes via `pkg-list-generations' when the mirror is empty.
Returns nil when no generation has `:active' t (= no profile yet)."
  (let ((mirror (nelix-core--generations-cache-get)))
    (unless mirror
      (setq mirror (pkg-list-generations)))
    (let (active)
      (dolist (gen mirror)
        (when (and (not active) (plist-get gen :active))
          (setq active gen)))
      active)))

;;;###autoload
(defun pkg-rollback-package (pkg-name)
  "Roll back a single package PKG-NAME from the nelix-core Nix profile.
PKG-NAME is a symbol previously installed via `pkg-define' /
`pkg-install'.  Synthesises a NEW generation containing every
package currently installed EXCEPT PKG-NAME, re-rendering
flake.nix from each remaining package's IR in
`nelix-core--registry' and dispatching `nix profile install' against
the freshly-written flake.  Nix records this as a new
generation (not as a rollback) — that is the documented L25
contract.

Signals `nelix-error' when:
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
    (signal 'nelix-error
            (list (format "pkg-rollback-package: PKG-NAME must be symbol, got %S"
                          pkg-name))))
  (require 'nelix-dsl)
  (nelix-core--ensure-nix)
  (let* ((active (nelix-core--active-generation))
         (current-pkgs (and active (plist-get active :packages))))
    (unless active
      (signal 'nelix-error
              (list "pkg-rollback-package: no active generation found in profile history")))
    (unless (memq pkg-name current-pkgs)
      (signal 'nelix-error
              (list (format "pkg-rollback-package: %s is not currently installed in the active generation"
                            pkg-name))))
    (let ((remaining (delq pkg-name (copy-sequence current-pkgs))))
      ;; Verify every remaining package has IR in the registry.  Without
      ;; an IR we cannot re-render its derivation in the new flake.nix,
      ;; so refuse loudly with a pointer to whole-profile rollback.
      (dolist (sym remaining)
        (unless (gethash sym nelix-core--registry)
          (signal 'nelix-error
                  (list (format "pkg-rollback-package: %s has no IR in the registry (installed by name only); use pkg-rollback for whole-profile rollback instead"
                                sym)))))
      ;; Re-render the flake from a temporary registry containing only
      ;; the remaining IRs so `nelix-core--render-flake' (which walks the
      ;; registry hash) produces a flake without PKG-NAME.
      (let* ((scoped-registry (make-hash-table :test 'eq))
             (flake-path nil)
             (flake-dir nil))
        (dolist (sym remaining)
          (puthash sym (gethash sym nelix-core--registry) scoped-registry))
        (let ((saved-registry nelix-core--registry))
          (unwind-protect
              (progn
                (setq nelix-core--registry scoped-registry)
                (setq flake-path (funcall nelix-core--write-flake-fn)))
            (setq nelix-core--registry saved-registry)))
        (setq flake-dir (directory-file-name (file-name-directory flake-path)))
        (let* ((subcmd (nelix-core--nix-install-subcommand))
               (flakerefs (mapcar (lambda (sym)
                                    (format "path:%s#%s" flake-dir sym))
                                  remaining))
               (args (append (list "profile" subcmd)
                             (nelix-core--profile-args)
                             flakerefs))
               (res (nelix-core--call-nix args)))
          (unless (eq 0 (plist-get res :exit))
            (signal 'nelix-nix-failed
                    (list (format "nix profile %s (rollback-package %s) failed (exit %s): %s"
                                  subcmd pkg-name
                                  (plist-get res :exit)
                                  (nelix-compat-string-trim
                                   (or (plist-get res :stderr) "")))
                          :stderr (plist-get res :stderr)))))
        ;; Refresh mirror + replay emacs-package hooks.  Both wrapped so
        ;; a refresh failure does not mask a successful per-package
        ;; rollback.
        (condition-case _ (pkg-list-generations) (error nil))
        (nelix-core--rollback-replay-emacs-hooks)
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

Reads from the persistent generations mirror in `nelix-state';
if the mirror is empty, calls `pkg-list-generations' once to
populate it.  Pass a fresh generations list by calling
`pkg-list-generations' explicitly beforehand."
  (unless (symbolp pkg-name)
    (signal 'nelix-error
            (list (format "pkg-history: PKG-NAME must be symbol, got %S"
                          pkg-name))))
  (when (null (nelix-core--generations-cache-get))
    (pkg-list-generations))
  (let ((events nil)
        (prev-pkgs nil)
        (prev-set-initialised nil))
    (dolist (gen (nelix-core--generations-cache-get))
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

;; Forward declaration for the byte-compiler — nelix-emacs is loaded
;; lazily so the constant is not in scope at top-level compile time.
(defvar nelix-emacs--deps-namespace)

;;;###autoload
(defun pkg-clear-cache (&optional scope)
  "Drop persistent caches under `nelix-state'.

SCOPE selects which namespaces to clear:
- nil or `all'    — every nelix-core cache
- `deps'          — Phase 4-C Package-Requires lookup cache
- `nix-version'   — `nix --version' detection cache
- `generations'   — profile generations mirror

Returns t.  Signals `nelix-error' on an unknown SCOPE so users
notice typos rather than silently clearing the wrong namespace."
  (interactive)
  ;; Lazy-require for the deps namespace constant (nelix-emacs is
  ;; loaded on demand from `pkg-install', so a fresh session that calls
  ;; `pkg-clear-cache' first would otherwise hit a void-variable error).
  (when (memq (or scope 'all) '(all deps))
    (require 'nelix-emacs))
  (pcase (or scope 'all)
    ('all
     (nelix-state-clear nelix-emacs--deps-namespace)
     (nelix-state-clear nelix-core--nix-version-namespace)
     (nelix-state-clear nelix-core--generations-namespace))
    ('deps
     (nelix-state-clear nelix-emacs--deps-namespace))
    ('nix-version
     (nelix-state-clear nelix-core--nix-version-namespace))
    ('generations
     (nelix-state-clear nelix-core--generations-namespace))
    (_
     (signal 'nelix-error
             (list (format "pkg-clear-cache: unknown SCOPE %S (expected one of all / deps / nix-version / generations)"
                           scope)))))
  t)

;;;; --- backwards-compatible long-form aliases -------------------------------
;; nelix-core owns the `pkg-' namespace as its public DSL surface; the
;; long-form `nelix-core-' aliases below remain available so callers
;; using strict Emacs-prefix style still work.

;;;###autoload
(defalias 'nelix-core-install #'pkg-install)
;;;###autoload
(defalias 'nelix-core-search #'pkg-search)
;;;###autoload
(defalias 'nelix-core-list #'pkg-list)
;;;###autoload
(defalias 'nelix-core-pin #'pkg-pin)
;;;###autoload
(defalias 'nelix-core-unpin #'pkg-unpin)
;;;###autoload
(defalias 'nelix-core-pinned-p #'pkg-pinned-p)
;;;###autoload
(defalias 'nelix-core-list-pins #'pkg-list-pins)
;;;###autoload
(defalias 'nelix-core-uninstall #'pkg-uninstall)
;;;###autoload
(defalias 'nelix-core-upgrade-plan #'pkg-upgrade-plan)
;;;###autoload
(defalias 'nelix-core-upgrade #'pkg-upgrade)
;;;###autoload
(defalias 'nelix-core-info #'pkg-info)
;;;###autoload
(defalias 'nelix-core-doctor #'pkg-doctor)
;;;###autoload
(defalias 'nelix-core-list-generations #'pkg-list-generations)
;;;###autoload
(defalias 'nelix-core-rollback #'pkg-rollback)
;;;###autoload
(defalias 'nelix-core-rollback-package #'pkg-rollback-package)
;;;###autoload
(defalias 'nelix-core-history #'pkg-history)
;;;###autoload
(defalias 'nelix-core-clear-cache #'pkg-clear-cache)

;;;; --- Nelix public aliases --------------------------------------------------
;; Nelix is the public project name.  The implementation still lives in the
;; original nelix-core modules during the compatibility transition.

;;;###autoload
(defalias 'nelix-install #'pkg-install)
;;;###autoload
(defalias 'nelix-search #'pkg-search)
;;;###autoload
(defalias 'nelix-list #'pkg-list)
;;;###autoload
(defalias 'nelix-pin #'pkg-pin)
;;;###autoload
(defalias 'nelix-unpin #'pkg-unpin)
;;;###autoload
(defalias 'nelix-pinned-p #'pkg-pinned-p)
;;;###autoload
(defalias 'nelix-list-pins #'pkg-list-pins)
;;;###autoload
(defalias 'nelix-uninstall #'pkg-uninstall)
;;;###autoload
(defalias 'nelix-upgrade-plan #'pkg-upgrade-plan)
;;;###autoload
(defalias 'nelix-upgrade #'pkg-upgrade)
;;;###autoload
(defalias 'nelix-info #'pkg-info)
;;;###autoload
(defalias 'nelix-doctor #'pkg-doctor)
;;;###autoload
(defalias 'nelix-list-generations #'pkg-list-generations)
;;;###autoload
(defalias 'nelix-rollback #'pkg-rollback)
;;;###autoload
(defalias 'nelix-rollback-package #'pkg-rollback-package)
;;;###autoload
(defalias 'nelix-history #'pkg-history)
;;;###autoload
(defalias 'nelix-clear-cache #'pkg-clear-cache)

;;;; --- MCP tool surface ------------------------------------------------------

(declare-function anvil-server-register-tool "ext:anvil-server")
(declare-function anvil-server-unregister-tool "ext:anvil-server")

(defun nelix-core--tool-install (name)
  "MCP wrapper around `pkg-install'.

MCP Parameters:
  name - nixpkgs attribute path to install (e.g. \"ripgrep\")."
  (pkg-install name)
  (list :status "ok" :name name))

(defun nelix-core--tool-search (query)
  "MCP wrapper around `pkg-search'.

MCP Parameters:
  query - free-form search regex passed to `nix search'."
  (let ((rows (pkg-search query)))
    (list :count (length rows)
          :results (or rows []))))

(defun nelix-core--tool-list ()
  "MCP wrapper around `pkg-list'.

MCP Parameters: (none)."
  (let ((rows (pkg-list)))
    (list :count (length rows)
          :installed (or rows []))))

(defun nelix-core--tool-pin (name)
  "MCP wrapper around `pkg-pin'.

MCP Parameters:
  name - package name to pin (string or symbol)."
  (let ((name-str (nelix-core--normalize-pin-name "pkg-pin" name)))
    (pkg-pin name-str)
    (list :status "ok" :name name-str)))

(defun nelix-core--tool-unpin (name)
  "MCP wrapper around `pkg-unpin'.

MCP Parameters:
  name - package name to unpin (string or symbol)."
  (let ((name-str (nelix-core--normalize-pin-name "pkg-unpin" name)))
    (pkg-unpin name-str)
    (list :status "ok" :name name-str)))

(defun nelix-core--tool-list-pins ()
  "MCP wrapper around `pkg-list-pins'.

MCP Parameters: (none)."
  (let ((pins (pkg-list-pins)))
    (list :count (length pins)
          :pins (or pins []))))

(defun nelix-core--tool-uninstall (name)
  "MCP wrapper around `pkg-uninstall'.

MCP Parameters:
  name - installed profile element name (string or symbol)."
  (pkg-uninstall name)
  (list :status "ok" :name name))

(defun nelix-core--tool-upgrade (name)
  "MCP wrapper around `pkg-upgrade'.

MCP Parameters:
  name - package name to upgrade, or nil / empty / whitespace to
    upgrade every installed package."
  (let* ((normalized
          (cond
           ((null name) nil)
           ((symbolp name) (symbol-name name))
           ((stringp name)
            (let ((trimmed (nelix-compat-string-trim name)))
              (if (zerop (length trimmed))
                  nil
                trimmed)))
           (t (signal 'nelix-error
                      (list (format "pkg-upgrade: NAME must be string, symbol, or nil, got %S"
                                    name)))))))
    (pkg-upgrade normalized)
    (list :status "ok"
          :name (or normalized :all))))

(defun nelix-core--tool-upgrade-plan (name)
  "MCP wrapper around `pkg-upgrade-plan'.

MCP Parameters:
  name - package name to inspect, or nil / empty / whitespace to
    inspect every installed package."
  (let ((normalized (nelix-core--normalize-upgrade-name
                     "pkg-upgrade-plan" name t)))
    (append (pkg-upgrade-plan normalized)
            (list :status "ok"))))

(defun nelix-core--tool-info (name)
  "MCP wrapper around `pkg-info'.

MCP Parameters:
  name - package name (string or symbol)."
  (let* ((name-str (cond
                    ((stringp name) name)
                    ((symbolp name) (symbol-name name))
                    (t (signal 'nelix-error
                               (list (format "pkg-info: NAME must be string or symbol, got %S"
                                             name))))))
         (info (pkg-info name-str)))
    (if info
        (append info (list :found t))
      (list :found nil :name name-str))))

(defun nelix-core--doctor-status-count (checks status)
  "Count rows in CHECKS whose :status equals STATUS."
  (let ((count 0))
    (dolist (row checks count)
      (when (eq (plist-get row :status) status)
        (setq count (1+ count))))))

(defun nelix-core--tool-doctor ()
  "MCP wrapper around `pkg-doctor'.

MCP Parameters: (none)."
  (let ((checks (pkg-doctor)))
    (list :checks checks
          :ok (nelix-core--doctor-status-count checks :ok)
          :warn (nelix-core--doctor-status-count checks :warn)
          :error (nelix-core--doctor-status-count checks :error)
          :info (nelix-core--doctor-status-count checks :info))))

(defun nelix-core--tool-list-generations ()
  "MCP wrapper around `pkg-list-generations'.

MCP Parameters: (none)."
  (let ((rows (pkg-list-generations)))
    (list :count (length rows)
          :generations (or rows []))))

(defun nelix-core--tool-rollback (generation-id)
  "MCP wrapper around `pkg-rollback'.

MCP Parameters:
  generation-id - integer generation id to roll back to,
    or nil / 0 to roll back one step (= the previous generation)."
  (let* ((gid (cond
               ((null generation-id) nil)
               ((integerp generation-id)
                (if (zerop generation-id) nil generation-id))
               ((stringp generation-id)
                (let ((trimmed (nelix-compat-string-trim generation-id)))
                  (if (zerop (length trimmed))
                      nil
                    (string-to-number trimmed))))
               (t generation-id))))
    (pkg-rollback gid)
    (list :status "ok"
          :generation-id (or gid :previous))))

(defun nelix-core--tool-history (pkg-name)
  "MCP wrapper around `pkg-history'.

MCP Parameters:
  pkg-name - package name (string or symbol)."
  (let* ((sym (cond
               ((symbolp pkg-name) pkg-name)
               ((stringp pkg-name) (intern pkg-name))
               (t (signal 'nelix-error
                          (list (format "pkg-history: name must be string or symbol, got %S"
                                        pkg-name))))))
         (events (pkg-history sym)))
    (list :name (symbol-name sym)
          :count (length events)
          :events (or events []))))

(defun nelix-core--register-tools ()
  "Register pkg-* MCP tools under `nelix-core--server-id'."
  (anvil-server-register-tool
   #'nelix-core--tool-install
   :id "pkg-install"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Install a package by name into the nelix-core Nix profile.
Wraps `nix profile install <channel>#<name>' with a profile
isolated from ~/.nix-profile.  Returns :status \"ok\" on success;
signals an error carrying nix stderr on failure.")

  (anvil-server-register-tool
   #'nelix-core--tool-search
   :id "pkg-search"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Search nixpkgs for packages matching QUERY.  Returns :count and
:results (list of plists carrying name, description, version,
attrpath).  Read-only — does not modify the profile."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-list
   :id "pkg-list"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "List packages currently installed in the nelix-core Nix profile.
Returns :count and :installed (list of plists with name, attr-path,
original-url, store-paths).  Read-only."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-pin
   :id "pkg-pin"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Record a package name as pinned in persistent nelix-core state.
Pinned packages are excluded from upgrade-all, and direct upgrades
of a pinned package are rejected until the package is unpinned.")

  (anvil-server-register-tool
   #'nelix-core--tool-unpin
   :id "pkg-unpin"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Remove a package name from persistent nelix-core pin state.
Once unpinned, pkg-upgrade may target that package directly or
include it again in upgrade-all operations.")

  (anvil-server-register-tool
   #'nelix-core--tool-list-pins
   :id "pkg-list-pins"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "List pinned package names stored in persistent nelix-core state.
Returns :count and :pins (list of strings).  Read-only."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-uninstall
   :id "pkg-uninstall"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Remove an installed package from the nelix-core Nix profile by
name.  Wraps `nix profile remove <name>' against the isolated
nelix-core profile, refreshes the generations mirror, and replays
emacs-package hooks so load-path stays in sync.")

  (anvil-server-register-tool
   #'nelix-core--tool-upgrade-plan
   :id "pkg-upgrade-plan"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Return the read-only upgrade plan for the nelix-core Nix profile.
When name is nil or blank, reports installed packages that would
be included in a bulk upgrade and pinned packages that would be
skipped.  When name is provided, reports whether that package is
installed, pinned, or missing.  Does not modify the profile."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-upgrade
   :id "pkg-upgrade"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Upgrade packages already installed in the nelix-core Nix profile.
When name is nil or blank upgrades every installed package;
otherwise upgrades the single matching profile element.  Returns
:status \"ok\" and :name (string or :all).")

  (anvil-server-register-tool
   #'nelix-core--tool-info
   :id "pkg-info"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Return merged package metadata for a NAME from the current
nelix-core Nix profile and nixpkgs search results.  Returns the
package plist plus :found t on success, or :found nil and :name
when no installed or searchable package matches.  Read-only."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-doctor
   :id "pkg-doctor"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Run a read-only environment health check for nelix-core.
Returns :checks (list of plists with check, status, detail) plus
tallies for :ok, :warn, :error, and :info.  Does not mutate the
profile, refresh generations, or replay hooks."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-list-generations
   :id "pkg-list-generations"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "List Nix profile generations for the nelix-core profile.
Wraps `nix profile history --json' and returns :count and
:generations (list of plists with id, date, packages, active).
Refreshes the in-process generations mirror used by pkg-history.
Read-only."
   :read-only t)

  (anvil-server-register-tool
   #'nelix-core--tool-rollback
   :id "pkg-rollback"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Roll the nelix-core Nix profile back to a previous generation.
generation-id may be an integer generation id, or nil / 0 to roll
back one step.  Replays the post-install hook for emacs packages
in the now-active generation so load-path stays in sync.")

  (anvil-server-register-tool
   #'nelix-core--tool-history
   :id "pkg-history"
   :intent '(packages)
   :layer 'io
   :server-id nelix-core--server-id
   :description
   "Return install / remove events for a package across the
nelix-core profile generations.  Reads from the in-process mirror;
call pkg-list-generations first for fresh data.  Read-only."
   :read-only t))

(defun nelix-core--unregister-tools ()
  "Remove every pkg-* MCP tool from the shared anvil server."
  (dolist (id '("pkg-install" "pkg-search" "pkg-list"
                "pkg-pin" "pkg-unpin" "pkg-list-pins"
                "pkg-uninstall" "pkg-upgrade-plan" "pkg-upgrade" "pkg-info" "pkg-doctor"
                "pkg-list-generations" "pkg-rollback" "pkg-history"))
    (anvil-server-unregister-tool id nelix-core--server-id)))

;;;###autoload
(defun nelix-core-enable ()
  "Register the pkg-* MCP tool surface.
Requires `anvil-server' (loaded with anvil.el).  Safe to call
repeatedly — re-registers idempotently."
  (interactive)
  (require 'anvil-server)
  (nelix-core--register-tools)
  (message "nelix: enabled (14 MCP tools, profile = %s)"
           nelix-core-profile-dir))

(defun nelix-core-disable ()
  "Unregister the pkg-* MCP tool surface."
  (interactive)
  (require 'anvil-server)
  (nelix-core--unregister-tools))

(provide 'nelix-core)
;;; nelix-core.el ends here
