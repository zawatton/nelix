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
(require 'anvil-pkg-state)

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

Default 30 days.  Phase 4-D persists this cache to
`anvil-pkg-state' so it survives Emacs restarts."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-http-timeout 5
  "Seconds before an HTTP fetch against raw.githubusercontent.com aborts.

Per-lookup timeout; the lookup chain (`<pname>-pkg.el' →
`<pname>.el') performs at most two GETs so worst-case wall time is
2 * this value."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-tarball-timeout 30
  "Seconds before a tarball download (L24a) aborts.

Tarballs are bigger than the raw.githubusercontent.com header
fetches so the default is higher than `anvil-pkg-emacs-http-timeout'."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-tarball-max-bytes (* 50 1024 1024)
  "Maximum tarball size (bytes) accepted by L24a's deps scrape.

Tarballs whose Content-Length header exceeds this threshold are
refused with a warning; users with truly huge upstreams should
declare `:depends-on' explicitly.  Default 50 MiB (OQ16)."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-git-clone-timeout 60
  "Seconds before a git shallow clone (L24b) aborts.

Used as the wall-clock budget for the underlying `git clone' (or
fetch + checkout fallback).  Currently advisory — the dispatch
shells out via `anvil-pkg-compat-call-process' which does not honour
a per-call timeout; tests rely on mocking instead."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-melpa-upstream-fetch nil
  "Whether `:melpa-synth `auto'' consults the MELPA upstream recipe.

When non-nil, `anvil-pkg--render-melpa-post-unpack' (called at
flake render / install time) GETs
\"https://raw.githubusercontent.com/melpa/melpa/master/recipes/<pname>\"
and emits the upstream body verbatim when present, falling back to
the local synth on miss / error.

Default nil to preserve Phase 4-D behaviour (pure local synth, no
network calls during render).  Opt-in via:

  (setq anvil-pkg-emacs-melpa-upstream-fetch t)

`:melpa-synth `force'' explicitly bypasses this lookup even when
the defcustom is non-nil — it is the user's \"synth, do not consult
upstream\" signal.  Phase 4-E L27."
  :type 'boolean
  :group 'anvil-pkg-emacs)

(defcustom anvil-pkg-emacs-melpa-recipe-ttl-seconds (* 7 24 60 60)
  "TTL (seconds) for cached MELPA upstream recipe lookups.

Default 7 days.  Persisted to `anvil-pkg-state' namespace
`anvil-pkg:melpa-recipe', shared with `anvil-pkg-emacs--deps-namespace'
in storage but distinct in key prefix.  Phase 4-E L27."
  :type 'integer
  :group 'anvil-pkg-emacs)

(defconst anvil-pkg-emacs--deps-namespace "anvil-pkg:emacs-deps"
  "`anvil-pkg-state' namespace for Package-Requires lookup cache.

Key shapes (one per source type):
  - github-fetch: \"<owner>/<repo>@<rev>\"
  - url-fetch:    \"sha256:<hash>\"
  - git-fetch:    \"git:<url>@<rev>\"

Value = plist (:deps (SYM ...) :status SYM) where status ∈
(:hit-pkg-el :hit-header :miss :error).  TTL is supplied via
`anvil-pkg-emacs-cache-ttl-seconds' on every put.")

(defconst anvil-pkg-emacs--melpa-recipe-namespace "anvil-pkg:melpa-recipe"
  "`anvil-pkg-state' namespace for MELPA upstream recipe lookups.

Key = bare PNAME string.  Value plist
=(:status SYM :recipe STRING-or-nil)= where status ∈
=(:hit :miss :error)=.  TTL =anvil-pkg-emacs-melpa-recipe-ttl-seconds=
(default 7 days).  Phase 4-E L27.")

(defconst anvil-pkg-emacs--melpa-recipe-base-url
  "https://raw.githubusercontent.com/melpa/melpa/master/recipes/"
  "Base URL for raw MELPA recipe files; PNAME is appended verbatim.")

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
  "Build the github-fetch cache key string for OWNER REPO REV."
  (format "%s/%s@%s" owner repo rev))

(defun anvil-pkg-emacs--cache-key-tarball (sha256)
  "Build the url-fetch cache key string from a tarball SHA256 hash."
  (format "sha256:%s" sha256))

(defun anvil-pkg-emacs--cache-key-git (url rev)
  "Build the git-fetch cache key string from URL and REV."
  (format "git:%s@%s" url rev))

(defun anvil-pkg-emacs--cache-get (key)
  "Return the cache entry for KEY, or nil when missing or expired.

TTL is enforced inside `anvil-pkg-state' itself (entries put with a
non-nil TTL drop transparently after expiry); this helper only
dereferences the namespaced KV."
  (anvil-pkg-state-get anvil-pkg-emacs--deps-namespace key))

(defun anvil-pkg-emacs--cache-put (key deps status)
  "Store DEPS + STATUS under KEY with the configured TTL."
  (anvil-pkg-state-put anvil-pkg-emacs--deps-namespace
                       key
                       (list :deps deps :status status)
                       anvil-pkg-emacs-cache-ttl-seconds))

;;;; --- MELPA upstream recipe lookup (Phase 4-E L27) ------------------------

(defun anvil-pkg-emacs--melpa-recipe-cache-get (pname)
  "Return cached upstream recipe entry for PNAME or nil if missing/expired.

TTL enforcement happens inside `anvil-pkg-state'."
  (anvil-pkg-state-get anvil-pkg-emacs--melpa-recipe-namespace pname))

(defun anvil-pkg-emacs--melpa-recipe-cache-put (pname recipe status)
  "Store RECIPE / STATUS under PNAME in the upstream-recipe namespace."
  (anvil-pkg-state-put anvil-pkg-emacs--melpa-recipe-namespace
                       pname
                       (list :recipe recipe :status status)
                       anvil-pkg-emacs-melpa-recipe-ttl-seconds))

(defun anvil-pkg-emacs-fetch-melpa-recipe (pname)
  "Return the canonical MELPA upstream recipe body for PNAME, or nil.

Hits =https://raw.githubusercontent.com/melpa/melpa/master/recipes/PNAME=
on first call within TTL; subsequent calls within
`anvil-pkg-emacs-melpa-recipe-ttl-seconds' return the cached body
without an HTTP round-trip.  Returns the body as a single trimmed
string (no surrounding newlines / whitespace).

Failure semantics — never signals:
  - Network error / non-200 → cache `:miss' / `:error', return nil.
  - Empty body              → cache `:miss', return nil.
  - Cache hit               → return stored recipe (may be nil for
                              negative cache).

This helper is used by `anvil-pkg--render-melpa-post-unpack' via
the indirection `anvil-pkg-emacs--render-fetch-fn'.  Phase 4-E L27."
  (when (and (stringp pname) (> (length pname) 0))
    (let ((cached (anvil-pkg-emacs--melpa-recipe-cache-get pname)))
      (cond
       (cached (plist-get cached :recipe))
       (t (anvil-pkg-emacs--melpa-recipe-fetch-and-cache pname))))))

(defun anvil-pkg-emacs--melpa-recipe-fetch-and-cache (pname)
  "Run the upstream recipe HTTP, cache the outcome, return body or nil."
  (let ((url (concat anvil-pkg-emacs--melpa-recipe-base-url pname)))
    (condition-case err
        (let* ((resp (anvil-pkg-emacs--http-fetch url))
               (status (plist-get resp :status))
               (body   (plist-get resp :body)))
          (cond
           ((and (eq status 200)
                 (stringp body)
                 (> (length (string-trim body)) 0))
            (let ((trimmed (string-trim body)))
              (anvil-pkg-emacs--melpa-recipe-cache-put pname trimmed :hit)
              trimmed))
           ((eq status 200)
            (anvil-pkg-emacs--melpa-recipe-cache-put pname nil :miss)
            nil)
           ((eq status 404)
            (anvil-pkg-emacs--melpa-recipe-cache-put pname nil :miss)
            nil)
           (t
            (lwarn 'anvil-pkg :warning
                   "anvil-pkg-emacs: melpa recipe fetch %s returned status %S"
                   url status)
            (anvil-pkg-emacs--melpa-recipe-cache-put pname nil :error)
            nil)))
      (error
       (lwarn 'anvil-pkg :warning
              "anvil-pkg-emacs: melpa recipe fetch failed for %s: %S"
              pname err)
       (anvil-pkg-emacs--melpa-recipe-cache-put pname nil :error)
       nil))))

(defun anvil-pkg-emacs-clear-melpa-recipe-cache ()
  "Clear the persistent MELPA upstream recipe cache namespace."
  (interactive)
  (anvil-pkg-state-clear anvil-pkg-emacs--melpa-recipe-namespace))

(defvar anvil-pkg-emacs--render-fetch-fn
  (lambda (pname)
    (when anvil-pkg-emacs-melpa-upstream-fetch
      (anvil-pkg-emacs-fetch-melpa-recipe pname)))
  "Render-time MELPA upstream fetch indirection.

A 1-arg lambda PNAME → STRING-or-nil.  The default consults the
defcustom `anvil-pkg-emacs-melpa-upstream-fetch'; when nil, returns
nil immediately (preserving Phase 4-D pure-render semantics).

Tests rebind via `cl-letf' / `let' to inject deterministic stub
recipes without touching the network or the cache.")

(unless (functionp anvil-pkg-emacs--render-fetch-fn)
  (setq anvil-pkg-emacs--render-fetch-fn
        (lambda (pname)
          (when anvil-pkg-emacs-melpa-upstream-fetch
            (anvil-pkg-emacs-fetch-melpa-recipe pname)))))

;;;; --- public API ----------------------------------------------------------

(defun anvil-pkg-emacs-clear-cache ()
  "Clear the persistent Package-Requires cache namespace."
  (interactive)
  (anvil-pkg-state-clear anvil-pkg-emacs--deps-namespace))

(defun anvil-pkg-emacs-derive-deps (ir)
  "Return derived `:depends-on' list of SYMBOLS for an emacs-package IR.

IR is the plist registered by `pkg-define' (see anvil-pkg-dsl.el).

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
      (anvil-pkg-emacs--derive-from-github source pname))
     ((eq source-type 'url-fetch)
      (anvil-pkg-emacs--derive-from-tarball source pname))
     ((eq source-type 'git-fetch)
      (anvil-pkg-emacs--derive-from-git source pname))
     (t nil))))

;;;; --- github-fetch dispatch (Phase 4-C L18) -------------------------------

(defun anvil-pkg-emacs--derive-from-github (source pname)
  "Github-fetch arm of `anvil-pkg-emacs-derive-deps'.

SOURCE is the IR's :source plist (already known to have :type
`github-fetch').  PNAME is the package symbol name (string)."
  (let* ((owner (plist-get source :owner))
         (repo  (plist-get source :repo))
         (rev   (plist-get source :rev))
         (key   (anvil-pkg-emacs--cache-key owner repo rev))
         (cached (anvil-pkg-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     (t
      (anvil-pkg-emacs--lookup-and-cache owner repo rev pname key)))))

(defun anvil-pkg-emacs--lookup-and-cache (owner repo rev pname key)
  "Run the github-fetch lookup chain, store under KEY, return deps or nil."
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

;;;; --- url-fetch dispatch (Phase 4-D L24a) ---------------------------------

(defun anvil-pkg-emacs--derive-from-tarball (source pname)
  "Url-fetch arm — download tarball, scrape header, return deps or nil.

SOURCE is the IR's :source plist with :type `url-fetch'; PNAME is
the package symbol name (string).  Cache key is `sha256:<hash>'."
  (let* ((url    (plist-get source :url))
         (sha256 (plist-get source :sha256))
         (key    (anvil-pkg-emacs--cache-key-tarball sha256))
         (cached (anvil-pkg-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     ((or (null url) (null sha256))
      ;; Malformed source plist; cache :miss so we do not retry.
      (anvil-pkg-emacs--cache-put key nil :miss)
      nil)
     (t
      (anvil-pkg-emacs--scrape-tarball url pname key)))))

(defun anvil-pkg-emacs--scrape-tarball (url pname key)
  "Download URL, scrape PNAME-pkg.el / PNAME.el, cache under KEY.

Returns deps list or nil; warns + caches `:error' on any failure.
Refuses + caches `:error' when Content-Length exceeds
`anvil-pkg-emacs-tarball-max-bytes'.  Tmp file cleaned via
`unwind-protect'."
  (condition-case err
      (let* ((resp (anvil-pkg-compat-http-get-binary
                    url anvil-pkg-emacs-tarball-timeout))
             (status (plist-get resp :status))
             (clen   (plist-get resp :content-length)))
        (cond
         ((and (numberp clen)
               (> clen anvil-pkg-emacs-tarball-max-bytes))
          (lwarn 'anvil-pkg :warning
                 "anvil-pkg-emacs: tarball %s too large (%d bytes > %d cap), skipping deps scrape"
                 url clen anvil-pkg-emacs-tarball-max-bytes)
          (anvil-pkg-emacs--cache-put key nil :error)
          nil)
         ((not (eq status 200))
          (lwarn 'anvil-pkg :warning
                 "anvil-pkg-emacs: tarball %s download failed (status %S)"
                 url status)
          (anvil-pkg-emacs--cache-put key nil :error)
          nil)
         (t
          (anvil-pkg-emacs--scrape-tarball-bytes
           (plist-get resp :body) pname key))))
    (error
     (lwarn 'anvil-pkg :warning
            "anvil-pkg-emacs: tarball lookup failed for %s: %S" key err)
     (anvil-pkg-emacs--cache-put key nil :error)
     nil)))

(defun anvil-pkg-emacs--scrape-tarball-bytes (body pname key)
  "Write BODY bytes to a tmp file and scrape PNAME-pkg.el / PNAME.el.

BODY is the raw tar.gz bytes.  Cleans the tmp file via
`unwind-protect'.  Caches result under KEY and returns deps or
nil."
  (let ((tmpfile (anvil-pkg-compat-make-temp-file "anvil-pkg-tarball-")))
    (unwind-protect
        (progn
          (anvil-pkg-emacs--write-binary tmpfile body)
          (let* ((entries (anvil-pkg-emacs--tar-list tmpfile))
                 (top-dir (anvil-pkg-emacs--tar-top-dir entries))
                 (pkg-el-path
                  (and top-dir
                       (anvil-pkg-emacs--tar-find-entry
                        entries (format "%s/%s-pkg.el" top-dir pname))))
                 (main-el-path
                  (and top-dir
                       (anvil-pkg-emacs--tar-find-entry
                        entries (format "%s/%s.el" top-dir pname)))))
            (cond
             (pkg-el-path
              (let* ((content (anvil-pkg-emacs--tar-extract
                               tmpfile pkg-el-path))
                     (deps (anvil-pkg-emacs--parse-define-package content)))
                (cond
                 (deps
                  (anvil-pkg-emacs--cache-put key deps :hit-pkg-el)
                  deps)
                 (main-el-path
                  (anvil-pkg-emacs--scrape-tarball-main
                   tmpfile main-el-path key))
                 (t
                  (anvil-pkg-emacs--cache-put key nil :miss)
                  nil))))
             (main-el-path
              (anvil-pkg-emacs--scrape-tarball-main
               tmpfile main-el-path key))
             (t
              (anvil-pkg-emacs--cache-put key nil :miss)
              nil))))
      (anvil-pkg-compat-delete-file-quietly tmpfile))))

(defun anvil-pkg-emacs--scrape-tarball-main (tmpfile path key)
  "Extract PATH from TMPFILE and parse Package-Requires header.

Caches result under KEY (`:hit-header' on success, `:miss'
otherwise) and returns deps or nil."
  (let* ((content (anvil-pkg-emacs--tar-extract tmpfile path))
         (deps (anvil-pkg-emacs--parse-package-requires-header content)))
    (cond
     (deps
      (anvil-pkg-emacs--cache-put key deps :hit-header)
      deps)
     (t
      (anvil-pkg-emacs--cache-put key nil :miss)
      nil))))

(defun anvil-pkg-emacs--write-binary (path bytes)
  "Write the raw byte string BYTES to PATH (no coding conversion)."
  (let ((coding-system-for-write 'binary))
    (anvil-pkg-compat-write-file path bytes)))

(defun anvil-pkg-emacs--tar-list (tarfile)
  "Run `tar -tzf TARFILE' and return its stdout lines as a list of strings."
  (let* ((resp (anvil-pkg-compat-call-process
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

(defun anvil-pkg-emacs--tar-top-dir (entries)
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

(defun anvil-pkg-emacs--tar-find-entry (entries path)
  "Return PATH if it appears in ENTRIES, else nil.
Trailing-slash entries (directories) are ignored."
  (let ((found nil))
    (dolist (e entries)
      (when (and (not found)
                 (string= e path))
        (setq found e)))
    found))

(defun anvil-pkg-emacs--tar-extract (tarfile entry)
  "Run `tar -xzOf TARFILE ENTRY' and return its stdout as a string."
  (let* ((resp (anvil-pkg-compat-call-process
                "tar" (list "-xzOf" tarfile entry)))
         (exit (plist-get resp :exit)))
    (cond
     ((eq exit 0)
      (or (plist-get resp :stdout) ""))
     (t
      (error "tar -xzOf %s failed (exit=%S, stderr=%s)"
             entry exit (plist-get resp :stderr))))))

;;;; --- git-fetch dispatch (Phase 4-D L24b) ---------------------------------

(defun anvil-pkg-emacs--derive-from-git (source pname)
  "Git-fetch arm — shallow clone + on-disk scrape, cached by url@rev."
  (let* ((url (plist-get source :url))
         (rev (plist-get source :rev))
         (key (anvil-pkg-emacs--cache-key-git url rev))
         (cached (anvil-pkg-emacs--cache-get key)))
    (cond
     (cached
      (plist-get cached :deps))
     ((or (null url) (null rev))
      (anvil-pkg-emacs--cache-put key nil :miss)
      nil)
     (t
      (anvil-pkg-emacs--scrape-git url rev pname key)))))

(defun anvil-pkg-emacs--scrape-git (url rev pname key)
  "Shallow-clone URL @ REV into a tmpdir and scrape PNAME-pkg.el / .el.

Cleanup uses `unwind-protect' so a failed clone still removes the
tmpdir.  Falls back from `git clone --branch <rev>' to
`git fetch --depth 1 origin <rev>' + `git checkout FETCH_HEAD'
when the first variant rejects a SHA."
  (let ((tmpdir (anvil-pkg-emacs--make-temp-dir "anvil-pkg-git-")))
    (unwind-protect
        (condition-case err
            (cond
             ((anvil-pkg-emacs--git-clone url rev tmpdir)
              (let ((deps (anvil-pkg-emacs-derive-deps-from-dir
                           tmpdir pname)))
                (cond
                 (deps
                  (anvil-pkg-emacs--cache-put key deps :hit-pkg-el)
                  deps)
                 (t
                  (anvil-pkg-emacs--cache-put key nil :miss)
                  nil))))
             (t
              (lwarn 'anvil-pkg :warning
                     "anvil-pkg-emacs: git clone %s @ %s failed"
                     url rev)
              (anvil-pkg-emacs--cache-put key nil :error)
              nil))
          (error
           (lwarn 'anvil-pkg :warning
                  "anvil-pkg-emacs: git lookup failed for %s: %S" key err)
           (anvil-pkg-emacs--cache-put key nil :error)
           nil))
      (anvil-pkg-emacs--delete-directory-quietly tmpdir))))

(defun anvil-pkg-emacs--git-credential-args (url)
  "Return git CLI args (a list) injecting auth for URL, or nil.

Phase 4-G L42: when URL is HTTPS against a host with a
configured credential env var, return =-c
http.<HOST>/.extraheader=Authorization: Bearer TOKEN= so the
clone subprocess can authenticate.  SSH URLs return nil — SSH
agent / =~/.ssh/= keys handle auth out-of-band."
  (when (and (stringp url)
             (string-match-p "\\`https://" url))
    (let* ((auth (anvil-pkg-compat-credential-for-url url))
           (host (anvil-pkg-compat--url-host url)))
      (when (and auth host)
        (list "-c"
              (format "http.https://%s/.extraheader=Authorization: %s"
                      host auth))))))

(defun anvil-pkg-emacs--git-clone (url rev tmpdir)
  "Shallow-clone URL @ REV into TMPDIR.  Return non-nil on success.

Tries `git clone --depth 1 --branch <rev>' first; falls back to
`git init' + `git fetch --depth 1' + `git checkout FETCH_HEAD'
when the branch flag rejects a raw SHA (typical for pinned
revisions).

Phase 4-G L42: when URL is HTTPS against a host with a
credential env var, prepends =-c http.HOST/.extraheader=...= so
the subprocess can authenticate.  SSH URLs unchanged."
  (let* ((cred (anvil-pkg-emacs--git-credential-args url))
         (primary
          (anvil-pkg-compat-call-process
           "git" (append cred
                         (list "clone" "--depth" "1"
                               "--branch" rev "--single-branch"
                               url tmpdir)))))
    (cond
     ((eq 0 (plist-get primary :exit)) t)
     (t
      ;; Fallback: init + fetch + checkout (handles SHA refs).
      ;; Make sure the tmpdir is clean before re-init.
      (anvil-pkg-emacs--delete-directory-quietly tmpdir)
      (anvil-pkg-compat-make-directory tmpdir t)
      (let* ((init (anvil-pkg-compat-call-process
                    "git" (list "-C" tmpdir "init" "-q")))
             (remote (and (eq 0 (plist-get init :exit))
                          (anvil-pkg-compat-call-process
                           "git" (list "-C" tmpdir
                                       "remote" "add" "origin" url))))
             (fetch (and remote
                         (eq 0 (plist-get remote :exit))
                         (anvil-pkg-compat-call-process
                          "git" (append cred
                                        (list "-C" tmpdir
                                              "fetch" "--depth" "1"
                                              "origin" rev)))))
             (checkout (and fetch
                            (eq 0 (plist-get fetch :exit))
                            (anvil-pkg-compat-call-process
                             "git" (list "-C" tmpdir
                                         "checkout" "FETCH_HEAD")))))
        (and checkout (eq 0 (plist-get checkout :exit))))))))

(defun anvil-pkg-emacs--make-temp-dir (prefix)
  "Create + return a fresh directory under TMPDIR with PREFIX.

Wraps Emacs `make-temp-file' with DIR-FLAG so the result is an
empty directory (vs the file flavour used elsewhere in this
module)."
  (cond
   ((fboundp 'make-temp-file)
    (make-temp-file prefix t))
   (t
    (let* ((path (anvil-pkg-compat-make-temp-file prefix)))
      (anvil-pkg-compat-delete-file-quietly path)
      (anvil-pkg-compat-make-directory path t)
      path))))

(defun anvil-pkg-emacs--delete-directory-quietly (dir)
  "Recursively delete DIR; ignore errors / missing dir."
  (when (and (stringp dir)
             (anvil-pkg-compat-file-exists-p dir))
    (condition-case _
        (cond
         ((fboundp 'delete-directory)
          (delete-directory dir t))
         (t
          ;; Fallback shell-out for environments without
          ;; `delete-directory'.
          (anvil-pkg-compat-call-process "rm" (list "-rf" dir))))
      (error nil))))

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
