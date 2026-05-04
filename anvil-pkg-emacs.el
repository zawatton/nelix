;;; anvil-pkg-emacs.el --- Package-Requires HTTP scraper for emacs-package -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix, emacs

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

;; Phase 4-C sub-task A (L18) — auto-derive `:depends-on` for
;; `emacs-package' build-system entries by fetching either
;; `<pname>-pkg.el' (which contains a `define-package' sexp) or the
;; `Package-Requires:' header on `<pname>.el' from
;; raw.githubusercontent.com at install time.
;;
;; Lookup order (single GET each):
;;   1. https://raw.githubusercontent.com/<owner>/<repo>/<rev>/<pname>-pkg.el
;;      → parse the `define-package' sexp's deps argument.
;;   2. https://raw.githubusercontent.com/<owner>/<repo>/<rev>/<pname>.el
;;      → first 4 KiB, regex match `;; Package-Requires:' header.
;;   3. miss → return nil; install proceeds with empty packageRequires.
;;
;; Failure semantics — never signals:
;;   - Network errors / timeouts / 4xx / 5xx → lwarn, status :error,
;;     return nil.
;;   - 200 with no parseable header → status :miss, return nil.
;;   - Non-`github-fetch' source → return nil immediately.
;;   - Explicit `:depends-on' set on IR → return nil immediately
;;     (L8 invariant; the caller should also check, this is a defensive
;;     guard).
;;
;; Cache:
;;   - In-process defvar hash, keyed by "<owner>/<repo>@<rev>".
;;   - TTL `anvil-pkg-emacs-cache-ttl-seconds' (default 30 days).
;;   - Status entries cached too — `:miss' / `:error' avoid hammering
;;     raw.githubusercontent.com on repeated installs.
;;   - Phase 4-C ships an in-process cache only; Phase 4-D promotes to
;;     an `anvil-pkg-state' SQLite namespace once `anvil-pkg' grows a
;;     hard dependency on `anvil-pkg-state'.
;;
;; Public surface:
;;   anvil-pkg-emacs-derive-deps           — IR  -> (SYM ...) | nil
;;   anvil-pkg-emacs-derive-deps-from-dir  — DIR -> (SYM ...) | nil
;;     (used by anvil-pkg-import.el for L21 local-clone scrape)
;;   anvil-pkg-emacs-clear-cache           — drop all cached entries
;;
;; Design doc: docs/design/06-phase4c.org section L18 + L21.

;;; Code:

(require 'anvil-pkg-compat)

;; `url' is loaded lazily by `anvil-pkg-compat-http-get'; declare so
;; byte-compile keeps quiet.
(declare-function url-retrieve-synchronously "url" t t)

;;;; --- defcustoms / defvars -------------------------------------------------

(defgroup anvil-pkg-emacs nil
  "Package-Requires auto-derive for emacs-package builds."
  :group 'anvil-pkg
  :prefix "anvil-pkg-emacs-")

(defcustom anvil-pkg-emacs-cache-ttl-seconds (* 30 24 60 60)
  "TTL (seconds) for cached Package-Requires lookups.

Default 30 days.  Cache is in-process (per-session) in Phase 4-C;
Phase 4-D will promote to SQLite-backed `anvil-pkg-state'."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-http-timeout 5
  "Seconds before an HTTP fetch against raw.githubusercontent.com aborts.

Per-lookup timeout; the lookup chain (`<pname>-pkg.el' →
`<pname>.el') performs at most two GETs so worst-case wall time is
2 * this value."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defvar anvil-pkg-emacs--deps-cache (make-hash-table :test 'equal)
  "In-process cache for Package-Requires lookups.

Key = \"<owner>/<repo>@<rev>\" (string).
Value = plist (:deps (SYM ...) :cached-at TIME :status SYM) where
status ∈ (:hit-pkg-el :hit-header :miss :error).

Phase 4-C ships a per-session defvar cache rather than a persistent
SQLite namespace because anvil-pkg-state is not yet a dependency
of anvil-pkg.  Phase 4-D can promote when anvil-state integration
lands.")

;;;; --- parsers --------------------------------------------------------------

(defun anvil-pkg-emacs--parse-define-package (sexp-string)
  "Read SEXP-STRING and extract deps from a `define-package' form.

Returns a list of SYMBOLS — the car of each entry in the
4th argument of the `define-package' sexp, e.g.

  (define-package \"foo\" \"1.0\" \"d\" \\='((dash \"2.0\") (s \"1.0\")))
  => (dash s)

Returns nil if SEXP-STRING does not parse, does not start with
`define-package', has no deps, or its deps argument is unreadable."
  (when (and (stringp sexp-string) (> (length sexp-string) 0))
    (condition-case _err
        (let* ((form (car (read-from-string sexp-string)))
               (deps-arg (and (consp form)
                              (eq (car-safe form) 'define-package)
                              (nth 4 form))))
          ;; deps-arg is typically (quote ((dash "2.0") (s "1.0"))) or
          ;; the bare alist literal '((dash "2.0") ...) which `read'
          ;; returns as (quote (...)).
          (let ((alist
                 (cond
                  ((and (consp deps-arg) (eq (car deps-arg) 'quote))
                   (cadr deps-arg))
                  ((listp deps-arg) deps-arg)
                  (t nil))))
            (when (listp alist)
              (delq nil
                    (mapcar (lambda (e)
                              (when (and (consp e) (symbolp (car e)))
                                (car e)))
                            alist)))))
      (error nil))))

(defun anvil-pkg-emacs--parse-package-requires-header (file-content)
  "Find `;; Package-Requires: ((dep version) ...)' in FILE-CONTENT.

Returns list of SYMBOLS or nil.  Only scans the first 4 KiB of
FILE-CONTENT to mimic `package.el's bounded header read."
  (when (and (stringp file-content) (> (length file-content) 0))
    (let* ((window (substring file-content 0
                              (min 4096 (length file-content))))
           (case-fold-search t))
      (when (string-match
             "^;;[ \t]*Package-Requires:[ \t]*\\(.+\\)$" window)
        (let ((spec (match-string 1 window)))
          (condition-case _err
              (let* ((parsed (car (read-from-string spec)))
                     (alist (cond
                             ((and (consp parsed) (eq (car parsed) 'quote))
                              (cadr parsed))
                             ((listp parsed) parsed)
                             (t nil))))
                (when (listp alist)
                  (delq nil
                        (mapcar (lambda (e)
                                  (when (and (consp e) (symbolp (car e)))
                                    (car e)))
                                alist))))
            (error nil)))))))

;;;; --- HTTP lookups ---------------------------------------------------------

(defun anvil-pkg-emacs--raw-url (owner repo rev path)
  "Build a raw.githubusercontent.com URL for OWNER/REPO at REV/PATH."
  (format "https://raw.githubusercontent.com/%s/%s/%s/%s"
          owner repo rev path))

(defun anvil-pkg-emacs--http-fetch (url)
  "Synchronously GET URL with anvil-pkg's compat HTTP helper.

Returns plist (:status INT :body STRING).  Wraps
`anvil-pkg-compat-http-get' to centralise the timeout knob."
  (anvil-pkg-compat-http-get url anvil-pkg-emacs-http-timeout))

(defun anvil-pkg-emacs--lookup-pkg-el (owner repo rev pname)
  "Try PNAME-pkg.el on raw.githubusercontent.com.  Return SYM list or nil."
  (let* ((url (anvil-pkg-emacs--raw-url owner repo rev
                                        (format "%s-pkg.el" pname)))
         (resp (anvil-pkg-emacs--http-fetch url)))
    (when (eq 200 (plist-get resp :status))
      (anvil-pkg-emacs--parse-define-package
       (plist-get resp :body)))))

(defun anvil-pkg-emacs--lookup-header (owner repo rev pname)
  "Try PNAME.el header on raw.githubusercontent.com.  Return SYM list or nil."
  (let* ((url (anvil-pkg-emacs--raw-url owner repo rev
                                        (format "%s.el" pname)))
         (resp (anvil-pkg-emacs--http-fetch url)))
    (when (eq 200 (plist-get resp :status))
      (anvil-pkg-emacs--parse-package-requires-header
       (plist-get resp :body)))))

;;;; --- cache ---------------------------------------------------------------

(defun anvil-pkg-emacs--cache-key (owner repo rev)
  "Build the cache key string for OWNER REPO REV."
  (format "%s/%s@%s" owner repo rev))

(defun anvil-pkg-emacs--cache-fresh-p (entry)
  "Non-nil when ENTRY's :cached-at is within
`anvil-pkg-emacs-cache-ttl-seconds' of `current-time'."
  (let ((cached-at (plist-get entry :cached-at)))
    (and cached-at
         (< (float-time (time-subtract (current-time) cached-at))
            anvil-pkg-emacs-cache-ttl-seconds))))

(defun anvil-pkg-emacs--cache-put (key deps status)
  "Store DEPS + STATUS under KEY in the cache."
  (puthash key
           (list :deps deps
                 :cached-at (current-time)
                 :status status)
           anvil-pkg-emacs--deps-cache))

;;;; --- public API ----------------------------------------------------------

(defun anvil-pkg-emacs-clear-cache ()
  "Clear the in-process Package-Requires cache."
  (interactive)
  (clrhash anvil-pkg-emacs--deps-cache))

(defun anvil-pkg-emacs-derive-deps (ir)
  "Return derived `:depends-on' list of SYMBOLS for an emacs-package IR.

IR is the plist registered by `pkg-define' (see anvil-pkg-dsl.el).

Returns nil when:
- :source is not `github-fetch' (only github-fetch supports
  auto-derive in Phase 4-C);
- explicit :depends-on is already set on IR (the L8 invariant — the
  caller should check before calling this; we guard defensively too);
- HTTP lookup fails / package has no Package-Requires header /
  cache says :miss;
- the cache says :error within TTL.

Cache hit avoids HTTP entirely.  Logs warnings via
`lwarn' on errors but never signals (failure → empty list, install
proceeds)."
  (let* ((source (plist-get ir :source))
         (source-type (plist-get source :type))
         (explicit-deps (plist-get ir :depends-on)))
    (cond
     ;; L8 defensive guard: explicit deps win.
     (explicit-deps nil)
     ;; Phase 4-C scope: only github-fetch sources.
     ((not (eq source-type 'github-fetch)) nil)
     (t
      (let* ((owner (plist-get source :owner))
             (repo  (plist-get source :repo))
             (rev   (plist-get source :rev))
             ;; pname for the lookup is the package symbol name.
             (name  (plist-get ir :name))
             (pname (if (symbolp name) (symbol-name name)
                      (format "%s" name)))
             (key   (anvil-pkg-emacs--cache-key owner repo rev))
             (cached (gethash key anvil-pkg-emacs--deps-cache)))
        (cond
         ;; Cache hit (within TTL): return cached deps (which may be
         ;; nil for :miss / :error statuses).
         ((and cached (anvil-pkg-emacs--cache-fresh-p cached))
          (plist-get cached :deps))
         (t
          (anvil-pkg-emacs--lookup-and-cache owner repo rev pname key))))))))

(defun anvil-pkg-emacs--lookup-and-cache (owner repo rev pname key)
  "Run the lookup chain, store result under KEY, return deps or nil."
  (condition-case err
      (let ((pkg-el-deps (anvil-pkg-emacs--lookup-pkg-el
                          owner repo rev pname)))
        (cond
         (pkg-el-deps
          (anvil-pkg-emacs--cache-put key pkg-el-deps :hit-pkg-el)
          pkg-el-deps)
         (t
          (let ((header-deps (anvil-pkg-emacs--lookup-header
                              owner repo rev pname)))
            (cond
             (header-deps
              (anvil-pkg-emacs--cache-put key header-deps :hit-header)
              header-deps)
             (t
              ;; Both lookups failed to return parseable deps.
              ;; Distinguish :miss (got responses but no parse) vs
              ;; :error (network issue) by re-checking — but for
              ;; simplicity we treat any failure-to-parse as :miss.
              (anvil-pkg-emacs--cache-put key nil :miss)
              nil))))))
    (error
     (lwarn 'anvil-pkg :warning
            "anvil-pkg-emacs-derive-deps: lookup failed for %s: %S"
            key err)
     (anvil-pkg-emacs--cache-put key nil :error)
     nil)))

(defun anvil-pkg-emacs-derive-deps-from-dir (dir pname)
  "Read deps from local DIR for package PNAME.

Mirrors the lookup order of `anvil-pkg-emacs-derive-deps' but
against on-disk files instead of HTTP:
  1. <DIR>/<pname>-pkg.el → parse define-package sexp.
  2. <DIR>/<pname>.el     → parse Package-Requires header.

Returns list of SYMBOLS or nil.  Used by anvil-pkg-import.el for
L21 local-clone scrape (so the importer can populate
`(depends-on ...)` without requiring network access when the
user already has the package cloned locally)."
  (when (and (stringp dir)
             (anvil-pkg-compat-file-exists-p dir)
             (stringp pname)
             (> (length pname) 0))
    (let* ((pkg-el (expand-file-name (format "%s-pkg.el" pname) dir))
           (main-el (expand-file-name (format "%s.el" pname) dir)))
      (or (and (anvil-pkg-compat-file-exists-p pkg-el)
               (anvil-pkg-emacs--parse-define-package
                (anvil-pkg-compat-read-file pkg-el)))
          (and (anvil-pkg-compat-file-exists-p main-el)
               (anvil-pkg-emacs--parse-package-requires-header
                (anvil-pkg-compat-read-file main-el)))))))

(provide 'anvil-pkg-emacs)
;;; anvil-pkg-emacs.el ends here
