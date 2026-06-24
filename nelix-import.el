;;; nelix-import.el --- Importer for async-installer migration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/nelix-core
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix, migration

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

;; Phase 4-B sub-task D of nelix-core.
;;
;; Read-only one-shot converter that turns a user's existing
;; `async-installer-git-list' value into equivalent `pkg-define'
;; forms written to a file.  The user can then `(load ...)' that
;; file from their init manually if they want.
;;
;; Design doc: docs/design/05-phase4b.org section "L17. nelix-core-
;; import-async-installer = read-only utility".
;;
;; Properties:
;;   - Read-only.  Source variable is never mutated.
;;   - Idempotent.  Same input -> byte-identical output (entries are
;;     sorted by package name; date line is the only non-determinism
;;     and tests stub `format-time-string' to keep it stable).
;;   - Single write.  `with-temp-file' / `nelix-compat-write-file'
;;     means no partial-state on disk if anything signals.
;;   - Handles two input shapes:
;;       (a) async-installer real shape (plist):
;;           (:repo URL :commit X :branch B :tag T :subdir D :main F
;;            :pre-build CMDS)
;;           — package name derived from URL basename minus ".git".
;;       (b) design-doc / tutorial shape (alist key + plist):
;;           ("owner/repo" :commit X :tag Y :native-compile Z :require W)
;;           — package name = basename of "owner/repo".
;;
;; Field mapping decisions:
;;   - GitHub URLs (https://github.com/OWNER/REPO[.git]) and the
;;     "owner/repo" short form both render as `(github-fetch :owner
;;     OWNER :repo REPO :rev REV :sha256 PLACEHOLDER)'.
;;   - Other Git URLs render as `(git-fetch :url URL :rev REV
;;     :sha256 PLACEHOLDER)'.
;;   - REV preference: :commit > :tag > :branch > "HEAD" (with
;;     ;; FIXME comment + lwarn when "HEAD" is used).
;;   - sha256 is always emitted as "sha256-PLACEHOLDER-MUST-FILL"
;;     because async-installer never required hashes; lwarn ONCE at
;;     end with the placeholder count.
;;   - VERSION sub-form: prefer :tag (treated as upstream version
;;     when present), else "0.0.0-unknown" with a ;; FIXME comment.
;;   - :native-compile t -> (build-system (emacs-package :native-comp t)).
;;     Default build-system is plain `emacs-package'.
;;   - :require -> emitted as a comment hint above the form, since
;;     :require is a `pkg-install' keyword and not part of pkg-define
;;     grammar.
;;   - :subdir / :main / :pre-build / :branch — emitted as ;; Note
;;     comments; nelix-core's emacs-package builder does not yet have
;;     direct equivalents, but we surface them so the user can act.
;;
;; This file is loadable independently of `nelix-core' / `nelix-dsl'
;; — it only emits text, it does not invoke the `pkg-define' macro,
;; so we do not require those packages here.

;;; Code:

(require 'nelix-compat)
(require 'cl-lib)
(require 'nelix-fetch)

(eval-when-compile
  (require 'subr-x))

;;;; --- error symbol ----------------------------------------------------------

;; Local error symbol so this file does not require `nelix-core' (which
;; defines `nelix-error').  The caller catches either via the
;; `error' parent class.
(nelix-compat-define-error-symbol 'nelix-import-error
                                      "nelix-core import error")

;;;; --- field extraction -----------------------------------------------------

(defun nelix-import--detect-shape (entry)
  "Return symbol describing ENTRY shape.

`'plist' for the real async-installer shape (plist starts with
keyword :repo).  `'alist-pair' for the design-doc shape (cons
whose car is a string \"owner/repo\" and cdr is a plist).
Otherwise signals."
  (cond
   ((and (consp entry)
         (keywordp (car entry)))
    'plist)
   ((and (consp entry)
         (stringp (car entry)))
    'alist-pair)
   (t
    (signal 'nelix-import-error
            (list (format "unrecognised entry shape: %S" entry))))))

(defun nelix-import--repo-string (entry)
  "Return the raw repo identifier string from ENTRY.
This is either the full Git URL (real shape) or \"owner/repo\"
(design-doc shape)."
  (pcase (nelix-import--detect-shape entry)
    ('plist (plist-get entry :repo))
    ('alist-pair (car entry))))

(defun nelix-import--options (entry)
  "Return the options plist from ENTRY (without the repo key/cell)."
  (pcase (nelix-import--detect-shape entry)
    ('plist
     ;; Strip :repo k/v from the plist so the rest is uniform with
     ;; the alist-pair shape.
     (let ((acc '())
           (rest entry))
       (while rest
         (let ((k (car rest))
               (v (cadr rest)))
           (unless (eq k :repo)
             (push k acc)
             (push v acc))
           (setq rest (cddr rest))))
       (nreverse acc)))
    ('alist-pair (cdr entry))))

(defun nelix-import--parse-repo (repo)
  "Parse REPO string into a plist `(:host HOST :owner O :repo R)'.

Returns nil if REPO can't be split into owner/repo (e.g. plain URL
without a recognisable path)."
  (cond
   ;; "owner/repo" short form, no scheme
   ((and (stringp repo)
         (not (string-match-p "://" repo))
         (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" repo))
    (list :host 'github
          :owner (match-string 1 repo)
          :repo (nelix-import--strip-git-suffix
                 (match-string 2 repo))))
   ;; https://github.com/OWNER/REPO[.git] (or http://, git@)
   ((and (stringp repo)
         (string-match
          "\\`\\(?:https?://github\\.com/\\|git@github\\.com:\\)\\([^/]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?/?\\'"
          repo))
    (list :host 'github
          :owner (match-string 1 repo)
          :repo (match-string 2 repo)))
   ;; Any other URL — treat as opaque git URL, no owner/repo split
   ((stringp repo)
    (list :host 'git :url repo))
   (t nil)))

(defun nelix-import--strip-git-suffix (s)
  "Drop a trailing \".git\" from S."
  (if (and (stringp s) (string-suffix-p ".git" s))
      (substring s 0 (- (length s) 4))
    s))

(defun nelix-import--package-name (repo-info repo-raw)
  "Derive the package symbol name from parsed REPO-INFO / REPO-RAW.

Prefers the :repo field of REPO-INFO; falls back to the basename
of the raw URL string with .git stripped."
  (let ((name (or (plist-get repo-info :repo)
                  (and (stringp repo-raw)
                       (nelix-import--strip-git-suffix
                        (file-name-nondirectory repo-raw))))))
    (or name "unknown-package")))

(defun nelix-import--rev (opts)
  "Return (REV . NEEDS-FIXME) from OPTS plist.

REV is the checkout target; NEEDS-FIXME is non-nil when we had
to fall back to \"HEAD\" because no commit/tag/branch was given."
  (let ((commit (plist-get opts :commit))
        (tag    (plist-get opts :tag))
        (branch (plist-get opts :branch)))
    (cond
     ((and commit (> (length commit) 0)) (cons commit nil))
     ((and tag    (> (length tag) 0))    (cons tag nil))
     ((and branch (> (length branch) 0)) (cons branch nil))
     (t (cons "HEAD" t)))))

(defun nelix-import--version (opts needs-fixme)
  "Return (VERSION-STRING . NEEDS-FIXME) for OPTS plist.

Uses :tag when present (assumed to be a usable upstream version);
otherwise \"0.0.0-unknown\" with a FIXME flag.  NEEDS-FIXME is the
incoming flag from rev derivation; we OR with our own."
  (let ((tag (plist-get opts :tag)))
    (cond
     ((and (stringp tag) (> (length tag) 0)) (cons tag needs-fixme))
     (t (cons "0.0.0-unknown" t)))))

;;;; --- form rendering -------------------------------------------------------

(defconst nelix-import--placeholder-sha256
  "sha256-PLACEHOLDER-MUST-FILL"
  "Placeholder hash inserted for every imported entry.

async-installer never required content hashes, but nelix-core / Nix
do.  The user must replace each placeholder with a real sha256
before installing.")

(defun nelix-import--symbol-name-safe (s)
  "Return S as a string suitable for `intern'-ing into a package name.

Replaces non-symbol-friendly characters with `-' so e.g. \"dash.el\"
stays \"dash.el\" (legal symbol) but \"my package\" becomes
\"my-package\"."
  (let ((cleaned (replace-regexp-in-string "[ \t\n]+" "-" (or s ""))))
    (if (zerop (length cleaned)) "unknown-package" cleaned)))

(defun nelix-import--render-source (repo-info rev)
  "Render the (source ...) sub-form for REPO-INFO + REV.
Returns a string."
  (pcase (plist-get repo-info :host)
    ('github
     (format
      "  (source (github-fetch :owner %S :repo %S :rev %S :sha256 %S))"
      (plist-get repo-info :owner)
      (plist-get repo-info :repo)
      rev
      nelix-import--placeholder-sha256))
    (_
     (format
      "  (source (git-fetch :url %S :rev %S :sha256 %S))"
      (plist-get repo-info :url)
      rev
      nelix-import--placeholder-sha256))))

(defun nelix-import--render-build-system (opts)
  "Render the (build-system ...) sub-form for OPTS plist.
Returns a string."
  (if (plist-get opts :native-compile)
      "  (build-system (emacs-package :native-comp t))"
    "  (build-system emacs-package)"))

(defun nelix-import--render-depends-on (deps)
  "Render the (depends-on (list ...)) sub-form for DEPS list of SYMS.
Returns a string with leading two spaces, no trailing newline.
Returns nil when DEPS is empty."
  (when (and deps (listp deps))
    (format "  (depends-on (list %s))"
            (mapconcat #'symbol-name deps " "))))

(defun nelix-import--render-comments (opts needs-rev-fixme needs-version-fixme)
  "Build a list of leading-comment lines for an entry.
Each element is a string starting with `;; '."
  (let (lines)
    (when needs-rev-fixme
      (push ";; FIXME: pin to a real commit/tag (was missing in async-installer entry)" lines))
    (when needs-version-fixme
      (push ";; FIXME: set real upstream version" lines))
    (when (plist-get opts :require)
      (push ";; Note: install with (pkg-install 'NAME :require 'NAME)" lines))
    (when (plist-get opts :subdir)
      (push (format ";; Note: original :subdir was %S — nelix-core has no direct equivalent yet"
                    (plist-get opts :subdir))
            lines))
    (when (plist-get opts :main)
      (push (format ";; Note: original :main was %S — load explicitly after install if needed"
                    (plist-get opts :main))
            lines))
    (when (plist-get opts :pre-build)
      (push (format ";; Note: original :pre-build was %S — port to (build-phase ...) manually"
                    (plist-get opts :pre-build))
            lines))
    (when (plist-get opts :branch)
      (push (format ";; Note: original :branch was %S (nelix-core pins by :rev)"
                    (plist-get opts :branch))
            lines))
    (nreverse lines)))

;; Phase 4-C L21: per-call config threaded into the per-entry renderer.
;; `nelix-import-async-installer' binds these dynamically before
;; mapping over the entry list so the existing
;; `nelix-import--render-entry' signature stays single-arg.
(defvar nelix-import--scrape-deps nil
  "When non-nil, attempt `:depends-on' scrape per entry.
Bound dynamically by `nelix-import-async-installer'.")

(defvar nelix-import--clone-dir-fn nil
  "Function returning the local clone directory for an entry plist.
Bound dynamically by `nelix-import-async-installer' when
`:scrape-deps' is non-nil.  See
`nelix-import-default-clone-dir' for the default heuristic.")

(defun nelix-import-default-clone-dir (entry-info)
  "Return the default async-installer clone path for ENTRY-INFO.

ENTRY-INFO is a plist carrying :name (package basename string).
Returns the conventional async-installer location:

  ~/.emacs.d/external-packages/<basename>

Caller can override via the `:clone-dir-fn' keyword to
`nelix-import-async-installer'."
  (let ((basename (plist-get entry-info :name)))
    (when (and (stringp basename) (> (length basename) 0))
      (expand-file-name (format "external-packages/%s" basename)
                        (expand-file-name
                         ".emacs.d"
                         (or (nelix-compat-getenv "HOME") "~"))))))

(declare-function nelix-emacs-derive-deps-from-dir "nelix-emacs")
(declare-function nelix-emacs-derive-deps "nelix-emacs")

(defun nelix-import--scrape-deps-for (sym-name repo-info rev)
  "Phase 4-C L21 per-entry deps lookup.

Tries the local clone first (via `nelix-import--clone-dir-fn')
then falls back to L18's HTTP path.  Returns list of SYMBOLS or
nil.  No-op + nil when `nelix-import--scrape-deps' is nil
(= caller passed `:scrape-deps nil')."
  (when nelix-import--scrape-deps
    (require 'nelix-emacs)
    (let* ((entry-info (list :name sym-name))
           (clone-dir (and nelix-import--clone-dir-fn
                           (funcall nelix-import--clone-dir-fn
                                    entry-info)))
           (local (and clone-dir
                       (nelix-emacs-derive-deps-from-dir
                        clone-dir sym-name))))
      (cond
       (local local)
       ;; HTTP fallback uses a synthetic IR carrying just the source
       ;; metadata `nelix-emacs-derive-deps' needs.  Only attempt
       ;; the HTTP path for github-fetch entries.
       ((eq (plist-get repo-info :host) 'github)
        (let ((synthetic-ir
               (list :name (intern sym-name)
                     :source (list :type 'github-fetch
                                   :owner (plist-get repo-info :owner)
                                   :repo (plist-get repo-info :repo)
                                   :rev rev))))
          (nelix-emacs-derive-deps synthetic-ir)))
       (t nil)))))

(defun nelix-import--render-entry (entry)
  "Render ENTRY into a string containing comments + one pkg-define form.
The returned string ends with a single newline (no trailing blank
line; the caller joins entries with `\\n\\n').

When `nelix-import--scrape-deps' is non-nil, attempt to derive
`:depends-on' via local clone or HTTP (Phase 4-C L21) and emit
`(depends-on (list ...))' as an extra sub-form."
  (let* ((repo-raw (nelix-import--repo-string entry))
         (opts (nelix-import--options entry))
         (repo-info (nelix-import--parse-repo repo-raw))
         (name (nelix-import--package-name repo-info repo-raw))
         (sym-name (nelix-import--symbol-name-safe name))
         (rev-pair (nelix-import--rev opts))
         (rev (car rev-pair))
         (needs-rev-fixme (cdr rev-pair))
         (ver-pair (nelix-import--version opts needs-rev-fixme))
         (version (car ver-pair))
         (needs-version-fixme (cdr ver-pair))
         (comments (nelix-import--render-comments
                    opts needs-rev-fixme needs-version-fixme))
         (deps (nelix-import--scrape-deps-for sym-name repo-info rev))
         (deps-line (nelix-import--render-depends-on deps))
         (form-lines
          (delq nil
                (list (format "(pkg-define %s" sym-name)
                      (format "  (version %S)" version)
                      (nelix-import--render-source repo-info rev)
                      (nelix-import--render-build-system opts)
                      deps-line
                      "  (description \"Imported from async-installer-git-list\"))"))))
    (concat (mapconcat #'identity comments "\n")
            (when comments "\n")
            (mapconcat #'identity form-lines "\n")
            "\n")))

;;;; --- file rendering -------------------------------------------------------

(defun nelix-import--render-header (var-name basename count placeholder-count)
  "Render the header comment block as a string."
  (let ((date (format-time-string "%Y-%m-%d")))
    (concat
     (format ";;; %s --- Imported from `%s' -*- lexical-binding: t; -*-\n"
             basename var-name)
     ";;\n"
     (format ";; Generated by nelix-import on %s\n" date)
     (format ";; %d entries\n" count)
     (if (> placeholder-count 0)
         (format ";; WARNING: %d entries contain `%s' that must be replaced\n"
                 placeholder-count
                 nelix-import--placeholder-sha256)
       "")
     ";;\n"
     ";; This file was produced by `nelix-import-async-installer'.\n"
     ";; Review each entry, replace sha256 placeholders, then load the\n"
     ";; file manually from your init if you want the packages tracked\n"
     ";; by nelix-core.\n\n")))

(defun nelix-import--sort-entries (entries)
  "Return ENTRIES sorted by derived package name (deterministic).

Used so that two runs over the same input always produce the same
on-disk output (precondition for the idempotency contract)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let* ((ra (nelix-import--repo-string a))
                 (rb (nelix-import--repo-string b))
                 (na (nelix-import--package-name
                      (nelix-import--parse-repo ra) ra))
                 (nb (nelix-import--package-name
                      (nelix-import--parse-repo rb) rb)))
            (string< na nb)))))

(defun nelix-import--count-placeholders (count)
  "Return COUNT (every entry currently emits one placeholder).

Kept as a function so the heuristic can change later without
touching the call sites."
  count)

;;;###autoload
(cl-defun nelix-import-async-installer
    (&key (var 'async-installer-git-list)
          emit
          (scrape-deps t)
          clone-dir-fn)
  "Convert ASYNC-INSTALLER-GIT-LIST entries to pkg-define forms.

VAR is the symbol whose value supplies the alist (default
`async-installer-git-list').  EMIT is the absolute path of the
output file (required).

SCRAPE-DEPS (default t, Phase 4-C L21) controls whether each entry
should be augmented with `(depends-on (list ...))' derived from
the package's `Package-Requires' header.  Lookup order:

  1. Local async-installer clone (read `<pname>-pkg.el' or
     `<pname>.el' from disk).  Default location:
     `~/.emacs.d/external-packages/<basename>'.  Override with
     CLONE-DIR-FN — a function that takes a plist
     `(:name BASENAME)' and returns an absolute path (or nil).
  2. HTTP fallback to raw.githubusercontent.com (L18 path) when
     the local read returns nil and the entry is a GitHub repo.

Failure to derive deps is silent: the entry simply has no
`depends-on' sub-form and the user is expected to fill it in
manually if needed.  The L8 invariant (explicit deps win) is not
relevant here — the importer never sees explicit deps, it always
emits fresh forms.

Returns the count of pkg-define forms emitted.  Read-only: the
source variable is never mutated.  Idempotent (when SCRAPE-DEPS
inputs are stable): re-running with the same input + same local
clone state produces byte-identical output."
  (unless (and emit (stringp emit) (> (length emit) 0))
    (signal 'nelix-import-error
            (list ":emit absolute file path is required")))
  (when scrape-deps
    ;; Lazy require: the importer remains loadable without
    ;; nelix-emacs when the user passes :scrape-deps nil.
    (require 'nelix-emacs))
  (let* ((basename (file-name-nondirectory emit))
         (provide-sym (file-name-sans-extension basename))
         (entries (and (boundp var) (symbol-value var)))
         (nelix-import--scrape-deps scrape-deps)
         (nelix-import--clone-dir-fn
          (or clone-dir-fn #'nelix-import-default-clone-dir)))
    (cond
     ;; Empty / unbound — write header-only file, lwarn, return 0.
     ((or (null entries) (not (boundp var)))
      (lwarn 'nelix-import :warning
             "%s is unbound or empty; writing header-only file %s"
             var emit)
      (nelix-compat-write-file
       emit
       (concat (nelix-import--render-header var basename 0 0)
               (format "(provide '%s)\n" provide-sym)
               (format ";;; %s ends here\n" basename)))
      0)
     (t
      (let* ((sorted (nelix-import--sort-entries entries))
             (count (length sorted))
             (placeholder-count
              (nelix-import--count-placeholders count))
             (header (nelix-import--render-header
                      var basename count placeholder-count))
             (requires "(require 'nelix-core)\n(require 'nelix-dsl)\n\n")
             (body (mapconcat #'nelix-import--render-entry
                              sorted "\n"))
             (footer (concat "\n"
                             (format "(provide '%s)\n" provide-sym)
                             (format ";;; %s ends here\n" basename))))
        ;; Single write keeps the file consistent on disk if any
        ;; intermediate step signals.
        (nelix-compat-write-file
         emit
         (concat header requires body footer))
        ;; Surface the placeholder count once, after the write is
        ;; complete (so the warning is not blamed for a write-failure
        ;; partial state if any).
        (when (> placeholder-count 0)
          (lwarn 'nelix-import :warning
                 "%d sha256 placeholders emitted in %s — replace before installing"
                 placeholder-count emit))
        count)))))

;;;; Doc 33 M3: flake.nix -> emacs-package recipe import
;;
;; Convert the Nix flake's `pkgs.emacsPackages.melpaBuild' derivations into
;; native `emacs-package' recipes (Doc 33 M2 preset).  A fetchFromGitHub block
;; maps to a GitHub codeload tarball URL; the Nix NAR sha256 cannot be reused as
;; the tarball hash, so the tarball is downloaded and re-hashed when
;; RESOLVE-SHA256 is requested.

(defun nelix-import--parse-flake-emacs-blocks (flake-file)
  "Parse FLAKE-FILE `pkgs.emacsPackages.melpaBuild' GitHub blocks.
Return a list of plists (:name :version :owner :repo :rev :deps).  Blocks
without owner/repo/rev (fetchgit / fetchurl) are skipped."
  (with-temp-buffer
    (insert-file-contents flake-file)
    (goto-char (point-min))
    (let (blocks)
      (while (re-search-forward
              "^      \\([a-zA-Z0-9_-]+\\) = pkgs\\.emacsPackages\\.melpaBuild {" nil t)
        (let* ((block-start (point))
               (block-end (save-excursion
                            (if (re-search-forward "^      };" nil t) (point) (point-max))))
               pname version owner repo rev deps)
          (save-restriction
            (narrow-to-region block-start block-end)
            (cl-flet ((field (re)
                        (goto-char (point-min))
                        (when (re-search-forward re nil t) (match-string 1))))
              (setq pname (field "pname = \"\\([^\"]+\\)\";")
                    version (field "version = \"\\([^\"]+\\)\";")
                    owner (field "owner = \"\\([^\"]+\\)\";")
                    repo (field "repo = \"\\([^\"]+\\)\";")
                    rev (field "rev = \"\\([^\"]+\\)\";"))
              (goto-char (point-min))
              (when (re-search-forward
                     "packageRequires = with pkgs\\.emacsPackages; \\[\\([^]]*\\)\\]" nil t)
                (setq deps (split-string (match-string 1) "[ \t\n]+" t)))))
          (when (and pname owner repo rev)
            (push (list :name pname :version (or version "0.0.0")
                        :owner owner :repo repo :rev rev :deps deps)
                  blocks))
          (goto-char block-end)))
      (nreverse blocks))))

(defun nelix-import--flake-codeload-url (owner repo rev)
  "Return the GitHub codeload tarball URL for OWNER/REPO at REV."
  (format "https://codeload.github.com/%s/%s/tar.gz/%s" owner repo rev))

(defun nelix-import--resolve-tarball-sha256 (url)
  "Download URL to a temp file and return its `sha256-<hex>' digest."
  (let ((tmp (nelix-compat-make-temp-file "nelix-import-tarball-")))
    (unwind-protect
        (progn
          (nelix-fetch--download-url url tmp)
          (nelix-fetch-sha256-file tmp))
      (ignore-errors (delete-file tmp)))))

(defun nelix-import-flake-block-to-recipe (block &optional system resolve-sha256)
  "Render flake BLOCK plist into an `emacs-package' recipe plist.
BLOCK comes from `nelix-import--parse-flake-emacs-blocks'.  SYSTEM defaults
to x86_64-linux.  When RESOLVE-SHA256 is non-nil, download the tarball and
fill :sha256 (the Nix NAR hash is not the tarball hash)."
  (let* ((sys (or system 'x86_64-linux))
         (name (plist-get block :name))
         (url (nelix-import--flake-codeload-url
               (plist-get block :owner) (plist-get block :repo) (plist-get block :rev)))
         (sha (when resolve-sha256 (nelix-import--resolve-tarball-sha256 url))))
    (list :name name
          :version (plist-get block :version)
          :class 'emacs-package
          :systems
          (list (cons sys
                      (list :source (append (list :type 'url :url url)
                                            (when sha (list :sha256 sha)))
                            :dependencies (plist-get block :deps)
                            :install (list :type 'build
                                           :build-system 'emacs-package
                                           :pname name
                                           :load-paths '(".")
                                           :features (list (intern name)))))))))

;;;###autoload
(defun nelix-import-flake-emacs (flake-file &optional names resolve-sha256)
  "Import FLAKE-FILE Emacs packages as `emacs-package' recipe plists.
NAMES, when non-nil, restricts to those package names.  RESOLVE-SHA256
downloads each tarball to fill :sha256 (slow; off by default)."
  (let ((blocks (nelix-import--parse-flake-emacs-blocks flake-file)))
    (mapcar (lambda (b) (nelix-import-flake-block-to-recipe b nil resolve-sha256))
            (if names
                (cl-remove-if-not
                 (lambda (b) (member (plist-get b :name) names)) blocks)
              blocks))))

(defun nelix-import--recipe-field-string (key value)
  "Render recipe KEY VALUE as `KEY VALUE' text, quoting non-self-evaluating VALUE."
  (let ((vs (cond ((or (stringp value) (numberp value) (keywordp value) (null value))
                   (prin1-to-string value))
                  (t (concat "'" (prin1-to-string value))))))
    (format "%s %s" key vs)))

(defun nelix-import-write-emacs-recipe (recipe dir)
  "Write RECIPE plist as a registry `.el' file under DIR; return the file path."
  (let* ((name (plist-get recipe :name))
         (file (expand-file-name (concat name ".el") dir)))
    (with-temp-file file
      (insert (format ";;; %s.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-\n\n(require 'nelix-registry)\n\n(nelix-package" name))
      (let ((p recipe))
        (while p
          (insert "\n " (nelix-import--recipe-field-string (car p) (cadr p)))
          (setq p (cddr p))))
      (insert (format ")\n\n;;; %s.el ends here\n" name)))
    file))

(provide 'nelix-import)
;;; nelix-import.el ends here
