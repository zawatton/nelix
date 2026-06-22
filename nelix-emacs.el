;;; nelix-emacs.el --- Package-Requires HTTP scraper for emacs-package -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/nelix-core
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix, emacs

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
;;   - TTL `nelix-emacs-cache-ttl-seconds' (default 30 days).
;;   - Status entries cached too — `:miss' / `:error' avoid hammering
;;     raw.githubusercontent.com on repeated installs.
;;   - Phase 4-C ships an in-process cache only; Phase 4-D promotes to
;;     an `nelix-state' SQLite namespace once `nelix-core' grows a
;;     hard dependency on `nelix-state'.
;;
;; Public surface:
;;   nelix-emacs-derive-deps           — IR  -> (SYM ...) | nil
;;   nelix-emacs-derive-deps-from-dir  — DIR -> (SYM ...) | nil
;;     (used by nelix-import.el for L21 local-clone scrape)
;;   nelix-emacs-clear-cache           — drop all cached entries
;;
;; Design doc: docs/design/06-phase4c.org section L18 + L21.

;;; Code:

(require 'nelix-compat)
(require 'nelix-state)

;; `url' is loaded lazily by `nelix-compat-http-get'; declare so
;; byte-compile keeps quiet.
(declare-function url-retrieve-synchronously "url" t t)

;;;; --- defcustoms / defvars -------------------------------------------------

(defgroup nelix-emacs nil
  "Package-Requires auto-derive for emacs-package builds."
  :group 'nelix-core
  :prefix "nelix-emacs-")

(defcustom nelix-emacs-cache-ttl-seconds (* 30 24 60 60)
  "TTL (seconds) for cached Package-Requires lookups.

Default 30 days.  Phase 4-D persists this cache to
`nelix-state' so it survives Emacs restarts."
  :type 'integer
  :group 'nelix-emacs)

(defcustom nelix-emacs-http-timeout 5
  "Seconds before an HTTP fetch against raw.githubusercontent.com aborts.

Per-lookup timeout; the lookup chain (`<pname>-pkg.el' →
`<pname>.el') performs at most two GETs so worst-case wall time is
2 * this value."
  :type 'integer
  :group 'nelix-emacs)

(defcustom nelix-emacs-tarball-timeout 30
  "Seconds before a tarball download (L24a) aborts.

Tarballs are bigger than the raw.githubusercontent.com header
fetches so the default is higher than `nelix-emacs-http-timeout'."
  :type 'integer
  :group 'nelix-emacs)

(defcustom nelix-emacs-tarball-max-bytes (* 50 1024 1024)
  "Maximum tarball size (bytes) accepted by L24a's deps scrape.

Tarballs whose Content-Length header exceeds this threshold are
refused with a warning; users with truly huge upstreams should
declare `:depends-on' explicitly.  Default 50 MiB (OQ16)."
  :type 'integer
  :group 'nelix-emacs)

(defcustom nelix-emacs-git-clone-timeout 60
  "Seconds before a git shallow clone (L24b) aborts.

Used as the wall-clock budget for the underlying `git clone' (or
fetch + checkout fallback).  Currently advisory — the dispatch
shells out via `nelix-compat-call-process' which does not honour
a per-call timeout; tests rely on mocking instead."
  :type 'integer
  :group 'nelix-emacs)

(defcustom nelix-emacs-melpa-upstream-fetch nil
  "Whether `:melpa-synth `auto'' consults the MELPA upstream recipe.

When non-nil, `nelix-core--render-melpa-post-unpack' (called at
flake render / install time) GETs
\"https://raw.githubusercontent.com/melpa/melpa/master/recipes/<pname>\"
and emits the upstream body verbatim when present, falling back to
the local synth on miss / error.

Default nil to preserve Phase 4-D behaviour (pure local synth, no
network calls during render).  Opt-in via:

  (setq nelix-emacs-melpa-upstream-fetch t)

`:melpa-synth `force'' explicitly bypasses this lookup even when
the defcustom is non-nil — it is the user's \"synth, do not consult
upstream\" signal.  Phase 4-E L27."
  :type 'boolean
  :group 'nelix-emacs)

(defcustom nelix-emacs-melpa-recipe-ttl-seconds (* 7 24 60 60)
  "TTL (seconds) for cached MELPA upstream recipe lookups.

Default 7 days.  Persisted to `nelix-state' namespace
`nelix-core:melpa-recipe', shared with `nelix-emacs--deps-namespace'
in storage but distinct in key prefix.  Phase 4-E L27."
  :type 'integer
  :group 'nelix-emacs)

(defconst nelix-emacs--deps-namespace "nelix-core:emacs-deps"
  "`nelix-state' namespace for Package-Requires lookup cache.

Key shapes (one per source type):
  - github-fetch: \"<owner>/<repo>@<rev>\"
  - url-fetch:    \"sha256:<hash>\"
  - git-fetch:    \"git:<url>@<rev>\"

Value = plist (:deps (SYM ...) :status SYM) where status ∈
(:hit-pkg-el :hit-header :miss :error).  TTL is supplied via
`nelix-emacs-cache-ttl-seconds' on every put.")

(defconst nelix-emacs--melpa-recipe-namespace "nelix-core:melpa-recipe"
  "`nelix-state' namespace for MELPA upstream recipe lookups.

Key = bare PNAME string.  Value plist
=(:status SYM :recipe STRING-or-nil)= where status ∈
=(:hit :miss :error)=.  TTL =nelix-emacs-melpa-recipe-ttl-seconds=
(default 7 days).  Phase 4-E L27.")

(defconst nelix-emacs--melpa-recipe-base-url
  "https://raw.githubusercontent.com/melpa/melpa/master/recipes/"
  "Base URL for raw MELPA recipe files; PNAME is appended verbatim.")

;;;; --- parsers --------------------------------------------------------------

(defun nelix-emacs--parse-define-package (sexp-string)
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

(defun nelix-emacs--parse-package-requires-header (file-content)
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

(defun nelix-emacs--raw-url (owner repo rev path)
  "Build a raw.githubusercontent.com URL for OWNER/REPO at REV/PATH."
  (format "https://raw.githubusercontent.com/%s/%s/%s/%s"
          owner repo rev path))

(defun nelix-emacs--http-fetch (url)
  "Synchronously GET URL with nelix-core's compat HTTP helper.

Returns plist (:status INT :body STRING).  Wraps
`nelix-compat-http-get' to centralise the timeout knob."
  (nelix-compat-http-get url nelix-emacs-http-timeout))

(defun nelix-emacs--lookup-pkg-el (owner repo rev pname)
  "Try PNAME-pkg.el on raw.githubusercontent.com.  Return SYM list or nil."
  (let* ((url (nelix-emacs--raw-url owner repo rev
                                        (format "%s-pkg.el" pname)))
         (resp (nelix-emacs--http-fetch url)))
    (when (eq 200 (plist-get resp :status))
      (nelix-emacs--parse-define-package
       (plist-get resp :body)))))

(defun nelix-emacs--lookup-header (owner repo rev pname)
  "Try PNAME.el header on raw.githubusercontent.com.  Return SYM list or nil."
  (let* ((url (nelix-emacs--raw-url owner repo rev
                                        (format "%s.el" pname)))
         (resp (nelix-emacs--http-fetch url)))
    (when (eq 200 (plist-get resp :status))
      (nelix-emacs--parse-package-requires-header
       (plist-get resp :body)))))

;;;; --- cache ---------------------------------------------------------------

(defun nelix-emacs--cache-key (owner repo rev)
  "Build the github-fetch cache key string for OWNER REPO REV."
  (format "%s/%s@%s" owner repo rev))

(defun nelix-emacs--cache-key-tarball (sha256)
  "Build the url-fetch cache key string from a tarball SHA256 hash."
  (format "sha256:%s" sha256))

(defun nelix-emacs--cache-key-git (url rev)
  "Build the git-fetch cache key string from URL and REV."
  (format "git:%s@%s" url rev))

(defun nelix-emacs--cache-get (key)
  "Return the cache entry for KEY, or nil when missing or expired.

TTL is enforced inside `nelix-state' itself (entries put with a
non-nil TTL drop transparently after expiry); this helper only
dereferences the namespaced KV."
  (nelix-state-get nelix-emacs--deps-namespace key))

(defun nelix-emacs--cache-put (key deps status)
  "Store DEPS + STATUS under KEY with the configured TTL."
  (nelix-state-put nelix-emacs--deps-namespace
                       key
                       (list :deps deps :status status)
                       nelix-emacs-cache-ttl-seconds))

;;;; --- MELPA upstream recipe lookup (Phase 4-E L27) ------------------------

(defun nelix-emacs--melpa-recipe-cache-get (pname)
  "Return cached upstream recipe entry for PNAME or nil if missing/expired.

TTL enforcement happens inside `nelix-state'."
  (nelix-state-get nelix-emacs--melpa-recipe-namespace pname))

(defun nelix-emacs--melpa-recipe-cache-put (pname recipe status)
  "Store RECIPE / STATUS under PNAME in the upstream-recipe namespace."
  (nelix-state-put nelix-emacs--melpa-recipe-namespace
                       pname
                       (list :recipe recipe :status status)
                       nelix-emacs-melpa-recipe-ttl-seconds))

(defun nelix-emacs-fetch-melpa-recipe (pname)
  "Return the canonical MELPA upstream recipe body for PNAME, or nil.

Hits =https://raw.githubusercontent.com/melpa/melpa/master/recipes/PNAME=
on first call within TTL; subsequent calls within
`nelix-emacs-melpa-recipe-ttl-seconds' return the cached body
without an HTTP round-trip.  Returns the body as a single trimmed
string (no surrounding newlines / whitespace).

Failure semantics — never signals:
  - Network error / non-200 → cache `:miss' / `:error', return nil.
  - Empty body              → cache `:miss', return nil.
  - Cache hit               → return stored recipe (may be nil for
                              negative cache).

This helper is used by `nelix-core--render-melpa-post-unpack' via
the indirection `nelix-emacs--render-fetch-fn'.  Phase 4-E L27."
  (when (and (stringp pname) (> (length pname) 0))
    (let ((cached (nelix-emacs--melpa-recipe-cache-get pname)))
      (cond
       (cached (plist-get cached :recipe))
       (t (nelix-emacs--melpa-recipe-fetch-and-cache pname))))))

(defun nelix-emacs--melpa-recipe-fetch-and-cache (pname)
  "Run the upstream recipe HTTP, cache the outcome, return body or nil."
  (let ((url (concat nelix-emacs--melpa-recipe-base-url pname)))
    (condition-case err
        (let* ((resp (nelix-emacs--http-fetch url))
               (status (plist-get resp :status))
               (body   (plist-get resp :body)))
          (cond
           ((and (eq status 200)
                 (stringp body)
                 (> (length (string-trim body)) 0))
            (let ((trimmed (string-trim body)))
              (nelix-emacs--melpa-recipe-cache-put pname trimmed :hit)
              trimmed))
           ((eq status 200)
            (nelix-emacs--melpa-recipe-cache-put pname nil :miss)
            nil)
           ((eq status 404)
            (nelix-emacs--melpa-recipe-cache-put pname nil :miss)
            nil)
           (t
            (lwarn 'nelix-core :warning
                   "nelix-emacs: melpa recipe fetch %s returned status %S"
                   url status)
            (nelix-emacs--melpa-recipe-cache-put pname nil :error)
            nil)))
      (error
       (lwarn 'nelix-core :warning
              "nelix-emacs: melpa recipe fetch failed for %s: %S"
              pname err)
       (nelix-emacs--melpa-recipe-cache-put pname nil :error)
       nil))))

(defun nelix-emacs-clear-melpa-recipe-cache ()
  "Clear the persistent MELPA upstream recipe cache namespace."
  (interactive)
  (nelix-state-clear nelix-emacs--melpa-recipe-namespace))

(defvar nelix-emacs--render-fetch-fn
  (lambda (pname)
    (when nelix-emacs-melpa-upstream-fetch
      (nelix-emacs-fetch-melpa-recipe pname)))
  "Render-time MELPA upstream fetch indirection.

A 1-arg lambda PNAME → STRING-or-nil.  The default consults the
defcustom `nelix-emacs-melpa-upstream-fetch'; when nil, returns
nil immediately (preserving Phase 4-D pure-render semantics).

Tests rebind via `cl-letf' / `let' to inject deterministic stub
recipes without touching the network or the cache.")

(unless (functionp nelix-emacs--render-fetch-fn)
  (setq nelix-emacs--render-fetch-fn
        (lambda (pname)
          (when nelix-emacs-melpa-upstream-fetch
            (nelix-emacs-fetch-melpa-recipe pname)))))

;;;; --- public API ----------------------------------------------------------

(defun nelix-emacs-clear-cache ()
  "Clear the persistent Package-Requires cache namespace."
  (interactive)
  (nelix-state-clear nelix-emacs--deps-namespace))

(defun nelix-emacs-derive-deps (ir)
  "Return derived `:depends-on' list of SYMBOLS for an emacs-package IR.

IR is the plist registered by `pkg-define' (see nelix-dsl.el).

Dispatch by `(plist-get source :type)`:
  - github-fetch  → raw.githubusercontent.com pkg-el / header scrape
                    (Phase 4-C L18).
  - url-fetch     → tarball download + `tar -tzf' / `tar -xzOf'
                    extraction of `<pname>-pkg.el' / `<pname>.el'
                    (Phase 4-D L24a).
  - git-fetch     → shallow clone + on-disk read of the same files
                    (Phase 4-D L24b).
  - other         → nil.

Returns nil when:
- explicit :depends-on is already set on IR (the L8 invariant — the
  caller should check before calling this; we guard defensively too);
- the source type is unknown / unsupported;
- the lookup fails / has no Package-Requires header /
  cache says :miss / :error within TTL.

Cache hit avoids HTTP / git / tar entirely.  Logs warnings via
`lwarn' on errors but never signals (failure → nil, install
proceeds)."
  (let* ((source (plist-get ir :source))
         (source-type (plist-get source :type))
         (explicit-deps (plist-get ir :depends-on))
         (name  (plist-get ir :name))
         (bs (plist-get ir :build-system))
         (pname (or (plist-get bs :pname)
                    (if (symbolp name) (symbol-name name)
                      (format "%s" name)))))
    (cond
     ;; L8 defensive guard: explicit deps win.
     (explicit-deps nil)
     ((eq source-type 'github-fetch)
      (nelix-emacs--derive-from-github source pname))
     ((eq source-type 'url-fetch)
      (nelix-emacs--derive-from-tarball source pname))
     ((eq source-type 'git-fetch)
      (nelix-emacs--derive-from-git source pname))
     (t nil))))

;;;; --- github-fetch dispatch (Phase 4-C L18) -------------------------------

(defun nelix-emacs--derive-from-github (source pname)
  "Github-fetch arm of `nelix-emacs-derive-deps'.

SOURCE is the IR's :source plist (already known to have :type
`github-fetch').  PNAME is the package symbol name (string)."
  (let* ((owner (plist-get source :owner))
         (repo  (plist-get source :repo))
         (rev   (plist-get source :rev))
         (key   (nelix-emacs--cache-key owner repo rev))
         (cached (nelix-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     (t
      (nelix-emacs--lookup-and-cache owner repo rev pname key)))))

(defun nelix-emacs--lookup-and-cache (owner repo rev pname key)
  "Run the github-fetch lookup chain, store under KEY, return deps or nil."
  (condition-case err
      (let ((pkg-el-deps (nelix-emacs--lookup-pkg-el
                          owner repo rev pname)))
        (cond
         (pkg-el-deps
          (nelix-emacs--cache-put key pkg-el-deps :hit-pkg-el)
          pkg-el-deps)
         (t
          (let ((header-deps (nelix-emacs--lookup-header
                              owner repo rev pname)))
            (cond
             (header-deps
              (nelix-emacs--cache-put key header-deps :hit-header)
              header-deps)
             (t
              ;; Both lookups failed to return parseable deps.
              ;; Distinguish :miss (got responses but no parse) vs
              ;; :error (network issue) by re-checking — but for
              ;; simplicity we treat any failure-to-parse as :miss.
              (nelix-emacs--cache-put key nil :miss)
              nil))))))
    (error
     (lwarn 'nelix-core :warning
            "nelix-emacs-derive-deps: lookup failed for %s: %S"
            key err)
     (nelix-emacs--cache-put key nil :error)
     nil)))

;;;; --- url-fetch dispatch (Phase 4-D L24a) ---------------------------------

(defun nelix-emacs--derive-from-tarball (source pname)
  "Url-fetch arm — download tarball, scrape header, return deps or nil.

SOURCE is the IR's :source plist with :type `url-fetch'; PNAME is
the package symbol name (string).  Cache key is `sha256:<hash>'."
  (let* ((url    (plist-get source :url))
         (sha256 (plist-get source :sha256))
         (key    (nelix-emacs--cache-key-tarball sha256))
         (cached (nelix-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     ((or (null url) (null sha256))
      ;; Malformed source plist; cache :miss so we do not retry.
      (nelix-emacs--cache-put key nil :miss)
      nil)
     (t
      (nelix-emacs--scrape-tarball url pname key)))))

(defun nelix-emacs--scrape-tarball (url pname key)
  "Download URL, scrape PNAME-pkg.el / PNAME.el, cache under KEY.

Returns deps list or nil; warns + caches `:error' on any failure.
Refuses + caches `:error' when Content-Length exceeds
`nelix-emacs-tarball-max-bytes'.  Tmp file cleaned via
`unwind-protect'."
  (condition-case err
      (let* ((resp (nelix-compat-http-get-binary
                    url nelix-emacs-tarball-timeout))
             (status (plist-get resp :status))
             (clen   (plist-get resp :content-length)))
        (cond
         ((and (numberp clen)
               (> clen nelix-emacs-tarball-max-bytes))
          (lwarn 'nelix-core :warning
                 "nelix-emacs: tarball %s too large (%d bytes > %d cap), skipping deps scrape"
                 url clen nelix-emacs-tarball-max-bytes)
          (nelix-emacs--cache-put key nil :error)
          nil)
         ((not (eq status 200))
          (lwarn 'nelix-core :warning
                 "nelix-emacs: tarball %s download failed (status %S)"
                 url status)
          (nelix-emacs--cache-put key nil :error)
          nil)
         (t
          (nelix-emacs--scrape-tarball-bytes
           (plist-get resp :body) pname key))))
    (error
     (lwarn 'nelix-core :warning
            "nelix-emacs: tarball lookup failed for %s: %S" key err)
     (nelix-emacs--cache-put key nil :error)
     nil)))

(defun nelix-emacs--scrape-tarball-bytes (body pname key)
  "Write BODY bytes to a tmp file and scrape PNAME-pkg.el / PNAME.el.

BODY is the raw tar.gz bytes.  Cleans the tmp file via
`unwind-protect'.  Caches result under KEY and returns deps or
nil."
  (let ((tmpfile (nelix-compat-make-temp-file "nelix-core-tarball-")))
    (unwind-protect
        (progn
          (nelix-emacs--write-binary tmpfile body)
          (let* ((entries (nelix-emacs--tar-list tmpfile))
                 (top-dir (nelix-emacs--tar-top-dir entries))
                 (pkg-el-path
                  (and top-dir
                       (nelix-emacs--tar-find-entry
                        entries (format "%s/%s-pkg.el" top-dir pname))))
                 (main-el-path
                  (and top-dir
                       (nelix-emacs--tar-find-entry
                        entries (format "%s/%s.el" top-dir pname)))))
            (cond
             (pkg-el-path
              (let* ((content (nelix-emacs--tar-extract
                               tmpfile pkg-el-path))
                     (deps (nelix-emacs--parse-define-package content)))
                (cond
                 (deps
                  (nelix-emacs--cache-put key deps :hit-pkg-el)
                  deps)
                 (main-el-path
                  (nelix-emacs--scrape-tarball-main
                   tmpfile main-el-path key))
                 (t
                  (nelix-emacs--cache-put key nil :miss)
                  nil))))
             (main-el-path
              (nelix-emacs--scrape-tarball-main
               tmpfile main-el-path key))
             (t
              (nelix-emacs--cache-put key nil :miss)
              nil))))
      (nelix-compat-delete-file-quietly tmpfile))))

(defun nelix-emacs--scrape-tarball-main (tmpfile path key)
  "Extract PATH from TMPFILE and parse Package-Requires header.

Caches result under KEY (`:hit-header' on success, `:miss'
otherwise) and returns deps or nil."
  (let* ((content (nelix-emacs--tar-extract tmpfile path))
         (deps (nelix-emacs--parse-package-requires-header content)))
    (cond
     (deps
      (nelix-emacs--cache-put key deps :hit-header)
      deps)
     (t
      (nelix-emacs--cache-put key nil :miss)
      nil))))

(defun nelix-emacs--write-binary (path bytes)
  "Write the raw byte string BYTES to PATH (no coding conversion)."
  (let ((coding-system-for-write 'binary))
    (nelix-compat-write-file path bytes)))

(defun nelix-emacs--tar-list (tarfile)
  "Run `tar -tzf TARFILE' and return its stdout lines as a list of strings."
  (let* ((resp (nelix-compat-call-process
                "tar" (list "-tzf" tarfile)))
         (exit (plist-get resp :exit))
         (stdout (or (plist-get resp :stdout) "")))
    (cond
     ((eq exit 0)
      ;; Drop empty trailing newline entry.
      (split-string stdout "\n" t))
     (t
      (error "tar -tzf failed (exit=%S, stderr=%s)"
             exit (plist-get resp :stderr))))))

(defun nelix-emacs--tar-top-dir (entries)
  "Return the only top-level directory in ENTRIES, or nil if ambiguous.

Top-level = component before the first slash.  If every entry
shares the same prefix, return it; otherwise nil (caller should
treat as a tarball without a single top dir)."
  (let ((dirs (delete-dups
               (delq nil
                     (mapcar (lambda (e)
                               (let ((slash (string-match "/" e)))
                                 (and slash (substring e 0 slash))))
                             entries)))))
    (when (and dirs (= 1 (length dirs)))
      (car dirs))))

(defun nelix-emacs--tar-find-entry (entries path)
  "Return PATH if it appears in ENTRIES, else nil.
Trailing-slash entries (directories) are ignored."
  (let ((found nil))
    (dolist (e entries)
      (when (and (not found)
                 (string= e path))
        (setq found e)))
    found))

(defun nelix-emacs--tar-extract (tarfile entry)
  "Run `tar -xzOf TARFILE ENTRY' and return its stdout as a string."
  (let* ((resp (nelix-compat-call-process
                "tar" (list "-xzOf" tarfile entry)))
         (exit (plist-get resp :exit)))
    (cond
     ((eq exit 0)
      (or (plist-get resp :stdout) ""))
     (t
      (error "tar -xzOf %s failed (exit=%S, stderr=%s)"
             entry exit (plist-get resp :stderr))))))

;;;; --- git-fetch dispatch (Phase 4-D L24b) ---------------------------------

(defun nelix-emacs--derive-from-git (source pname)
  "Git-fetch arm — shallow clone + on-disk scrape, cached by url@rev."
  (let* ((url (plist-get source :url))
         (rev (plist-get source :rev))
         (key (nelix-emacs--cache-key-git url rev))
         (cached (nelix-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     ((or (null url) (null rev))
      (nelix-emacs--cache-put key nil :miss)
      nil)
     (t
      (nelix-emacs--scrape-git url rev pname key)))))

(defun nelix-emacs--scrape-git (url rev pname key)
  "Shallow-clone URL @ REV into a tmpdir and scrape PNAME-pkg.el / .el.

Cleanup uses `unwind-protect' so a failed clone still removes the
tmpdir.  Falls back from `git clone --branch <rev>' to
`git fetch --depth 1 origin <rev>' + `git checkout FETCH_HEAD'
when the first variant rejects a SHA."
  (let ((tmpdir (nelix-emacs--make-temp-dir "nelix-core-git-")))
    (unwind-protect
        (condition-case err
            (cond
             ((nelix-emacs--git-clone url rev tmpdir)
              (let ((deps (nelix-emacs-derive-deps-from-dir
                           tmpdir pname)))
                (cond
                 (deps
                  (nelix-emacs--cache-put key deps :hit-pkg-el)
                  deps)
                 (t
                  (nelix-emacs--cache-put key nil :miss)
                  nil))))
             (t
              (lwarn 'nelix-core :warning
                     "nelix-emacs: git clone %s @ %s failed"
                     url rev)
              (nelix-emacs--cache-put key nil :error)
              nil))
          (error
           (lwarn 'nelix-core :warning
                  "nelix-emacs: git lookup failed for %s: %S" key err)
           (nelix-emacs--cache-put key nil :error)
           nil))
      (nelix-emacs--delete-directory-quietly tmpdir))))

(defun nelix-emacs--git-credential-args (url)
  "Return git CLI args (a list) injecting auth for URL, or nil.

Phase 4-G L42: when URL is HTTPS against a host with a
configured credential env var, return =-c
http.<HOST>/.extraheader=Authorization: Bearer TOKEN= so the
clone subprocess can authenticate.  SSH URLs return nil — SSH
agent / =~/.ssh/= keys handle auth out-of-band."
  (when (and (stringp url)
             (string-match-p "\\`https://" url))
    (let* ((auth (nelix-compat-credential-for-url url))
           (host (nelix-compat--url-host url)))
      (when (and auth host)
        (list "-c"
              (format "http.https://%s/.extraheader=Authorization: %s"
                      host auth))))))

(defun nelix-emacs--git-clone (url rev tmpdir)
  "Shallow-clone URL @ REV into TMPDIR.  Return non-nil on success.

Tries `git clone --depth 1 --branch <rev>' first; falls back to
`git init' + `git fetch --depth 1' + `git checkout FETCH_HEAD'
when the branch flag rejects a raw SHA (typical for pinned
revisions).

Phase 4-G L42: when URL is HTTPS against a host with a
credential env var, prepends =-c http.HOST/.extraheader=...= so
the subprocess can authenticate.  SSH URLs unchanged."
  (let* ((cred (nelix-emacs--git-credential-args url))
         (primary
          (nelix-compat-call-process
           "git" (append cred
                         (list "clone" "--depth" "1"
                               "--branch" rev "--single-branch"
                               url tmpdir)))))
    (cond
     ((eq 0 (plist-get primary :exit)) t)
     (t
      ;; Fallback: init + fetch + checkout (handles SHA refs).
      ;; Make sure the tmpdir is clean before re-init.
      (nelix-emacs--delete-directory-quietly tmpdir)
      (nelix-compat-make-directory tmpdir t)
      (let* ((init (nelix-compat-call-process
                    "git" (list "-C" tmpdir "init" "-q")))
             (remote (and (eq 0 (plist-get init :exit))
                          (nelix-compat-call-process
                           "git" (list "-C" tmpdir
                                       "remote" "add" "origin" url))))
             (fetch (and remote
                         (eq 0 (plist-get remote :exit))
                         (nelix-compat-call-process
                          "git" (append cred
                                        (list "-C" tmpdir
                                              "fetch" "--depth" "1"
                                              "origin" rev)))))
             (checkout (and fetch
                            (eq 0 (plist-get fetch :exit))
                            (nelix-compat-call-process
                             "git" (list "-C" tmpdir
                                         "checkout" "FETCH_HEAD")))))
        (and checkout (eq 0 (plist-get checkout :exit))))))))

(defun nelix-emacs--make-temp-dir (prefix)
  "Create + return a fresh directory under TMPDIR with PREFIX.

Wraps Emacs `make-temp-file' with DIR-FLAG so the result is an
empty directory (vs the file flavour used elsewhere in this
module)."
  (cond
   ((fboundp 'make-temp-file)
    (make-temp-file prefix t))
   (t
    (let* ((path (nelix-compat-make-temp-file prefix)))
      (nelix-compat-delete-file-quietly path)
      (nelix-compat-make-directory path t)
      path))))

(defun nelix-emacs--delete-directory-quietly (dir)
  "Recursively delete DIR; ignore errors / missing dir."
  (when (and (stringp dir)
             (nelix-compat-file-exists-p dir))
    (condition-case _
        (cond
         ((fboundp 'delete-directory)
          (delete-directory dir t))
         (t
          ;; Fallback shell-out for environments without
          ;; `delete-directory'.
          (nelix-compat-call-process "rm" (list "-rf" dir))))
      (error nil))))

(defun nelix-emacs-derive-deps-from-dir (dir pname)
  "Read deps from local DIR for package PNAME.

Mirrors the lookup order of `nelix-emacs-derive-deps' but
against on-disk files instead of HTTP:
  1. <DIR>/<pname>-pkg.el → parse define-package sexp.
  2. <DIR>/<pname>.el     → parse Package-Requires header.

Returns list of SYMBOLS or nil.  Used by nelix-import.el for
L21 local-clone scrape (so the importer can populate
`(depends-on ...)` without requiring network access when the
user already has the package cloned locally)."
  (when (and (stringp dir)
             (nelix-compat-file-exists-p dir)
             (stringp pname)
             (> (length pname) 0))
    (let* ((pkg-el (expand-file-name (format "%s-pkg.el" pname) dir))
           (main-el (expand-file-name (format "%s.el" pname) dir)))
      (or (and (nelix-compat-file-exists-p pkg-el)
               (nelix-emacs--parse-define-package
                (nelix-compat-read-file pkg-el)))
          (and (nelix-compat-file-exists-p main-el)
               (nelix-emacs--parse-package-requires-header
                (nelix-compat-read-file main-el)))))))

(provide 'nelix-emacs)
;;; nelix-emacs.el ends here
