;;; anvil-pkg-import.el --- Importer for async-installer migration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, packages, nix, migration

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

;; Phase 4-B sub-task D of anvil-pkg.
;;
;; Read-only one-shot converter that turns a user's existing
;; `async-installer-git-list' value into equivalent `pkg-define'
;; forms written to a file.  The user can then `(load ...)' that
;; file from their init manually if they want.
;;
;; Design doc: docs/design/05-phase4b.org section "L17. anvil-pkg-
;; import-async-installer = read-only utility".
;;
;; Properties:
;;   - Read-only.  Source variable is never mutated.
;;   - Idempotent.  Same input -> byte-identical output (entries are
;;     sorted by package name; date line is the only non-determinism
;;     and tests stub `format-time-string' to keep it stable).
;;   - Single write.  `with-temp-file' / `anvil-pkg-compat-write-file'
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
;;     comments; anvil-pkg's emacs-package builder does not yet have
;;     direct equivalents, but we surface them so the user can act.
;;
;; This file is loadable independently of `anvil-pkg' / `anvil-pkg-dsl'
;; — it only emits text, it does not invoke the `pkg-define' macro,
;; so we do not require those packages here.

;;; Code:

(require 'anvil-pkg-compat)
(require 'cl-lib)

(eval-when-compile
  (require 'subr-x))

;;;; --- error symbol ----------------------------------------------------------

;; Local error symbol so this file does not require `anvil-pkg' (which
;; defines `anvil-pkg-error').  The caller catches either via the
;; `error' parent class.
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-import-error
                                      "anvil-pkg import error")

;;;; --- field extraction -----------------------------------------------------

(defun anvil-pkg-import--detect-shape (entry)
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
    (signal 'anvil-pkg-import-error
            (list (format "unrecognised entry shape: %S" entry))))))

(defun anvil-pkg-import--repo-string (entry)
  "Return the raw repo identifier string from ENTRY.
This is either the full Git URL (real shape) or \"owner/repo\"
(design-doc shape)."
  (pcase (anvil-pkg-import--detect-shape entry)
    ('plist (plist-get entry :repo))
    ('alist-pair (car entry))))

(defun anvil-pkg-import--options (entry)
  "Return the options plist from ENTRY (without the repo key/cell)."
  (pcase (anvil-pkg-import--detect-shape entry)
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

(defun anvil-pkg-import--parse-repo (repo)
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
          :repo (anvil-pkg-import--strip-git-suffix
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

(defun anvil-pkg-import--strip-git-suffix (s)
  "Drop a trailing \".git\" from S."
  (if (and (stringp s) (string-suffix-p ".git" s))
      (substring s 0 (- (length s) 4))
    s))

(defun anvil-pkg-import--package-name (repo-info repo-raw)
  "Derive the package symbol name from parsed REPO-INFO / REPO-RAW.

Prefers the :repo field of REPO-INFO; falls back to the basename
of the raw URL string with .git stripped."
  (let ((name (or (plist-get repo-info :repo)
                  (and (stringp repo-raw)
                       (anvil-pkg-import--strip-git-suffix
                        (file-name-nondirectory repo-raw))))))
    (or name "unknown-package")))

(defun anvil-pkg-import--rev (opts)
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

(defun anvil-pkg-import--version (opts needs-fixme)
  "Return (VERSION-STRING . NEEDS-FIXME) for OPTS plist.

Uses :tag when present (assumed to be a usable upstream version);
otherwise \"0.0.0-unknown\" with a FIXME flag.  NEEDS-FIXME is the
incoming flag from rev derivation; we OR with our own."
  (let ((tag (plist-get opts :tag)))
    (cond
     ((and (stringp tag) (> (length tag) 0)) (cons tag needs-fixme))
     (t (cons "0.0.0-unknown" t)))))

;;;; --- form rendering -------------------------------------------------------

(defconst anvil-pkg-import--placeholder-sha256
  "sha256-PLACEHOLDER-MUST-FILL"
  "Placeholder hash inserted for every imported entry.

async-installer never required content hashes, but anvil-pkg / Nix
do.  The user must replace each placeholder with a real sha256
before installing.")

(defun anvil-pkg-import--symbol-name-safe (s)
  "Return S as a string suitable for `intern'-ing into a package name.

Replaces non-symbol-friendly characters with `-' so e.g. \"dash.el\"
stays \"dash.el\" (legal symbol) but \"my package\" becomes
\"my-package\"."
  (let ((cleaned (replace-regexp-in-string "[ \t\n]+" "-" (or s ""))))
    (if (zerop (length cleaned)) "unknown-package" cleaned)))

(defun anvil-pkg-import--render-source (repo-info rev)
  "Render the (source ...) sub-form for REPO-INFO + REV.
Returns a string."
  (pcase (plist-get repo-info :host)
    ('github
     (format
      "  (source (github-fetch :owner %S :repo %S :rev %S :sha256 %S))"
      (plist-get repo-info :owner)
      (plist-get repo-info :repo)
      rev
      anvil-pkg-import--placeholder-sha256))
    (_
     (format
      "  (source (git-fetch :url %S :rev %S :sha256 %S))"
      (plist-get repo-info :url)
      rev
      anvil-pkg-import--placeholder-sha256))))

(defun anvil-pkg-import--render-build-system (opts)
  "Render the (build-system ...) sub-form for OPTS plist.
Returns a string."
  (if (plist-get opts :native-compile)
      "  (build-system (emacs-package :native-comp t))"
    "  (build-system emacs-package)"))

(defun anvil-pkg-import--render-comments (opts needs-rev-fixme needs-version-fixme)
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
      (push (format ";; Note: original :subdir was %S — anvil-pkg has no direct equivalent yet"
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
      (push (format ";; Note: original :branch was %S (anvil-pkg pins by :rev)"
                    (plist-get opts :branch))
            lines))
    (nreverse lines)))

(defun anvil-pkg-import--render-entry (entry)
  "Render ENTRY into a string containing comments + one pkg-define form.
The returned string ends with a single newline (no trailing blank
line; the caller joins entries with `\\n\\n')."
  (let* ((repo-raw (anvil-pkg-import--repo-string entry))
         (opts (anvil-pkg-import--options entry))
         (repo-info (anvil-pkg-import--parse-repo repo-raw))
         (name (anvil-pkg-import--package-name repo-info repo-raw))
         (sym-name (anvil-pkg-import--symbol-name-safe name))
         (rev-pair (anvil-pkg-import--rev opts))
         (rev (car rev-pair))
         (needs-rev-fixme (cdr rev-pair))
         (ver-pair (anvil-pkg-import--version opts needs-rev-fixme))
         (version (car ver-pair))
         (needs-version-fixme (cdr ver-pair))
         (comments (anvil-pkg-import--render-comments
                    opts needs-rev-fixme needs-version-fixme))
         (form-lines
          (list (format "(pkg-define %s" sym-name)
                (format "  (version %S)" version)
                (anvil-pkg-import--render-source repo-info rev)
                (anvil-pkg-import--render-build-system opts)
                "  (description \"Imported from async-installer-git-list\"))")))
    (concat (mapconcat #'identity comments "\n")
            (when comments "\n")
            (mapconcat #'identity form-lines "\n")
            "\n")))

;;;; --- file rendering -------------------------------------------------------

(defun anvil-pkg-import--render-header (var-name basename count placeholder-count)
  "Render the header comment block as a string."
  (let ((date (format-time-string "%Y-%m-%d")))
    (concat
     (format ";;; %s --- Imported from `%s' -*- lexical-binding: t; -*-\n"
             basename var-name)
     ";;\n"
     (format ";; Generated by anvil-pkg-import on %s\n" date)
     (format ";; %d entries\n" count)
     (if (> placeholder-count 0)
         (format ";; WARNING: %d entries contain `%s' that must be replaced\n"
                 placeholder-count
                 anvil-pkg-import--placeholder-sha256)
       "")
     ";;\n"
     ";; This file was produced by `anvil-pkg-import-async-installer'.\n"
     ";; Review each entry, replace sha256 placeholders, then load the\n"
     ";; file manually from your init if you want the packages tracked\n"
     ";; by anvil-pkg.\n\n")))

(defun anvil-pkg-import--sort-entries (entries)
  "Return ENTRIES sorted by derived package name (deterministic).

Used so that two runs over the same input always produce the same
on-disk output (precondition for the idempotency contract)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let* ((ra (anvil-pkg-import--repo-string a))
                 (rb (anvil-pkg-import--repo-string b))
                 (na (anvil-pkg-import--package-name
                      (anvil-pkg-import--parse-repo ra) ra))
                 (nb (anvil-pkg-import--package-name
                      (anvil-pkg-import--parse-repo rb) rb)))
            (string< na nb)))))

(defun anvil-pkg-import--count-placeholders (count)
  "Return COUNT (every entry currently emits one placeholder).

Kept as a function so the heuristic can change later without
touching the call sites."
  count)

;;;###autoload
(cl-defun anvil-pkg-import-async-installer (&key (var 'async-installer-git-list) emit)
  "Convert ASYNC-INSTALLER-GIT-LIST entries to pkg-define forms.

VAR is the symbol whose value supplies the alist (default
`async-installer-git-list').  EMIT is the absolute path of the
output file (required).

Returns the count of pkg-define forms emitted.  Read-only: the
source variable is never mutated.  Idempotent: re-running with
the same input produces byte-identical output (deterministic
ordering + formatting)."
  (unless (and emit (stringp emit) (> (length emit) 0))
    (signal 'anvil-pkg-import-error
            (list ":emit absolute file path is required")))
  (let* ((basename (file-name-nondirectory emit))
         (provide-sym (file-name-sans-extension basename))
         (entries (and (boundp var) (symbol-value var))))
    (cond
     ;; Empty / unbound — write header-only file, lwarn, return 0.
     ((or (null entries) (not (boundp var)))
      (lwarn 'anvil-pkg-import :warning
             "%s is unbound or empty; writing header-only file %s"
             var emit)
      (anvil-pkg-compat-write-file
       emit
       (concat (anvil-pkg-import--render-header var basename 0 0)
               (format "(provide '%s)\n" provide-sym)
               (format ";;; %s ends here\n" basename)))
      0)
     (t
      (let* ((sorted (anvil-pkg-import--sort-entries entries))
             (count (length sorted))
             (placeholder-count
              (anvil-pkg-import--count-placeholders count))
             (header (anvil-pkg-import--render-header
                      var basename count placeholder-count))
             (requires "(require 'anvil-pkg)\n(require 'anvil-pkg-dsl)\n\n")
             (body (mapconcat #'anvil-pkg-import--render-entry
                              sorted "\n"))
             (footer (concat "\n"
                             (format "(provide '%s)\n" provide-sym)
                             (format ";;; %s ends here\n" basename))))
        ;; Single write keeps the file consistent on disk if any
        ;; intermediate step signals.
        (anvil-pkg-compat-write-file
         emit
         (concat header requires body footer))
        ;; Surface the placeholder count once, after the write is
        ;; complete (so the warning is not blamed for a write-failure
        ;; partial state if any).
        (when (> placeholder-count 0)
          (lwarn 'anvil-pkg-import :warning
                 "%d sha256 placeholders emitted in %s — replace before installing"
                 placeholder-count emit))
        count)))))

(provide 'anvil-pkg-import)
;;; anvil-pkg-import.el ends here
