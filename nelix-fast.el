;;; nelix-fast.el --- Fast Nelix manifest paths for standalone NeLisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone NeLisp is much slower than Emacs at plist/list-heavy report
;; construction and generic JSON printing.  This module keeps manifest CLI
;; operations on compact package-name sets so list/audit/upgrade-plan avoid the
;; normal row-heavy Emacs compatibility path.

;;; Code:

(require 'nelix-core)
(require 'nelix-compat)
(require 'nelix-manifest)

(declare-function nelix-aot-audit "nelix-aot-manifest-engine" (input-text))
(declare-function nelix-aot-upgrade-plan "nelix-aot-manifest-engine"
                  (input-text))
(declare-function nelix-aot-audit-json "nelix-aot-manifest-engine"
                  (input-text &optional fallback cache-file))
(declare-function nelix-aot-upgrade-plan-json "nelix-aot-manifest-engine"
                  (input-text &optional fallback cache-file))

(defvar nelix-fast--target-cache nil
  "Hash table of generated package install target aliases.")

(defvar nelix-fast--pname-cache nil
  "Hash table of generated package pnames.")

(defvar nelix-package-nixpkgs-overrides)
(defvar nelix-package-install-aliases)
(defvar nelix-package-pname-overrides)
(defvar nelix-fast-aot-force nil
  "Explicit AOT opt-in value injected by non-Emacs runtimes.")

(defvar nelix-fast-aot-target-cache-suffix ".nelix-aot-targets"
  "Suffix for manifest-local Nelix AOT target cache files.")

(defvar nelix-fast-validate-data-symbols
  '(nelix-package-emacs-packages
    nelix-linux-base-nix-packages
    nelix-linux-bootstrap-apt-packages
    nelix-linux-core-nix-packages
    nelix-linux-debian-nix-packages
    nelix-linux-debian-wrapper-nix-packages
    nelix-linux-apt-wrapper-packages)
  "Data symbols read by the standalone NeLisp fast validator.")

(defconst nelix-fast--environment-form-names
  '("name" "profile" "nix-channel" "imports" "backend-policy"
    "emacs-packages" "linux-packages" "debian-tools"
    "bootstrap-apt-packages" "pins" "package" "linux-package"
    "version-pin" "remove-policy")
  "Stable DSL v1 subform names accepted by the fast validator.")

(defconst nelix-fast--environment-repeated-form-names
  '("package" "linux-package" "version-pin")
  "DSL v1 subforms that may appear more than once.")

(defconst nelix-fast--environment-deferred-form-names
  '("group" "feature" "platform" "platform-when")
  "DSL v1 subforms reserved for later versions.")

(defconst nelix-fast--environment-forbidden-form-names
  '("secret" "secrets" "private-repo" "private-repos" "credential"
    "credentials" "token" "access-token" "auth-header")
  "Private-data DSL v1 subforms rejected by the fast validator.")

(defconst nelix-fast--environment-package-option-keys
  '(:backend :pin :version :profile :group :feature :platform :when)
  "Stable DSL v1 package option keys accepted by the fast validator.")

(defun nelix-fast--every (predicate values)
  "Return non-nil when PREDICATE is true for every item in VALUES."
  (let ((ok t))
    (while (and ok values)
      (unless (funcall predicate (car values))
        (setq ok nil))
      (setq values (cdr values)))
    ok))

(defun nelix-fast-aot-enabled-p ()
  "Return non-nil when the opt-in Nelix AOT engine is enabled."
  (let ((value (or nelix-fast-aot-force
                   (getenv "NELIX_NELISP_AOT"))))
    (and (member value '("1" "true" "yes" "on")) t)))

(defun nelix-fast--ensure-aot-engine ()
  "Load the portable Nelix AOT engine or signal an explicit error."
  (unless (fboundp 'nelix-aot-audit)
    (require 'nelix-aot-manifest-engine nil t))
  (unless (fboundp 'nelix-aot-audit)
    (load "scripts/nelix-aot-manifest-engine.el" nil t))
  (unless (fboundp 'nelix-aot-audit)
    (load "nelix-aot-manifest-engine.el" nil t))
  (unless (and (fboundp 'nelix-aot-audit)
               (fboundp 'nelix-aot-upgrade-plan)
               (fboundp 'nelix-aot-audit-json)
               (fboundp 'nelix-aot-upgrade-plan-json))
    (signal 'nelix-error
            (list "NELIX_NELISP_AOT=1 requested, but nelix-aot-manifest-engine is not loadable"))))

(defun nelix-fast--target-cache ()
  "Return a hash table for generated package target aliases."
  (unless nelix-fast--target-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-nixpkgs-overrides)
        (dolist (entry nelix-package-nixpkgs-overrides)
          (nelix-fast--put-cache-alias (car entry) (cdr entry) cache)))
      (when (boundp 'nelix-package-install-aliases)
        (dolist (entry nelix-package-install-aliases)
          (nelix-fast--put-cache-alias (car entry) (cdr entry) cache)))
      (setq nelix-fast--target-cache cache)))
  nelix-fast--target-cache)

(defun nelix-fast--pname-cache ()
  "Return a hash table for generated package pnames."
  (unless nelix-fast--pname-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-pname-overrides)
        (dolist (entry nelix-package-pname-overrides)
          (nelix-fast--put-cache-alias (car entry) (cdr entry) cache)))
      (setq nelix-fast--pname-cache cache)))
  nelix-fast--pname-cache)

(defun nelix-fast--put-cache-alias (key value cache)
  "Store KEY -> VALUE in CACHE, including a string alias for symbol keys."
  (puthash key value cache)
  (when (symbolp key)
    (puthash (symbol-name key) value cache)))

(defun nelix-fast--target-name (target)
  "Return TARGET as a package/profile name string."
  (cond
   ((stringp target) target)
   ((symbolp target) (symbol-name target))
   (t (format "%S" target))))

(defun nelix-fast--attr-tail-name (name)
  "Return the final profile-facing package name for attr path NAME."
  (cond
   ((and (stringp name)
         (string-prefix-p "emacsPackages." name))
    (substring name (length "emacsPackages.")))
   ((and (stringp name)
         (string-prefix-p "packages.x86_64-linux." name))
    (substring name (length "packages.x86_64-linux.")))
   ((and (stringp name)
         (string-prefix-p "legacyPackages.x86_64-linux.emacsPackages." name))
    (substring name (length "legacyPackages.x86_64-linux.emacsPackages.")))
   ((and (stringp name)
         (string-prefix-p "legacyPackages.x86_64-linux." name))
    (substring name (length "legacyPackages.x86_64-linux.")))
   (t name)))

(defun nelix-fast--strip-duplicate-suffix (name)
  "Return NAME without a Nix profile duplicate suffix like \"-1\"."
  (let ((i (and (stringp name) (1- (length name))))
        (saw-digit nil))
    (while (and i (>= i 0)
                (let ((ch (aref name i)))
                  (and (>= ch ?0) (<= ch ?9))))
      (setq saw-digit t)
      (setq i (1- i)))
    (if (and saw-digit i (>= i 0) (eq (aref name i) ?-))
        (substring name 0 i)
      name)))

(defun nelix-fast--push-unique (value out)
  "Return OUT with VALUE consed when VALUE is a non-empty new string."
  (if (and (stringp value)
           (> (length value) 0)
           (not (member value out)))
      (cons value out)
    out))

(defun nelix-fast--push-unique-set (value out seen)
  "Return OUT with VALUE consed when VALUE is a new string in SEEN."
  (if (and (stringp value)
           (> (length value) 0)
           (not (gethash value seen)))
      (progn
        (puthash value t seen)
        (cons value out))
    out))

(defun nelix-fast-target-candidates (target)
  "Return profile-name candidates that may satisfy TARGET."
  (let* ((display (nelix-fast--target-name target))
         (target* (gethash target (nelix-fast--target-cache)))
         (target-name (and target* (nelix-fast--target-name target*)))
         (target-tail (and target-name
                           (nelix-fast--attr-tail-name target-name)))
         (display-tail (nelix-fast--attr-tail-name display))
         (pname (gethash target (nelix-fast--pname-cache)))
         out)
    (setq out (nelix-fast--push-unique display out))
    (setq out (nelix-fast--push-unique display-tail out))
    (setq out (nelix-fast--push-unique target-name out))
    (setq out (nelix-fast--push-unique target-tail out))
    (setq out (nelix-fast--push-unique pname out))
    (nreverse out)))

(defun nelix-fast--target-row (target)
  "Return a compact fast row for TARGET."
  (let ((name (nelix-fast--target-name target)))
    (cons name (nelix-fast-target-candidates target))))

(defun nelix-fast--row-name (row)
  "Return fast ROW's display name."
  (if (and (consp row) (stringp (car row)))
      (car row)
    (plist-get row :name)))

(defun nelix-fast--row-candidates (row)
  "Return fast ROW's profile-name candidates."
  (if (and (consp row) (stringp (car row)))
      (cdr row)
    (plist-get row :candidates)))

(defun nelix-fast--parse-name-lines (text)
  "Return non-empty newline-separated names from TEXT."
  (let ((i 0)
        (start 0)
        (n (length (or text "")))
        names)
    (setq text (or text ""))
    (while (< i n)
      (if (eq (aref text i) ?\n)
          (progn
            (when (> i start)
              (push (substring text start i) names))
            (setq start (1+ i))))
      (setq i (1+ i)))
    (when (> n start)
      (push (substring text start n) names))
    (nreverse names)))

(defun nelix-fast-profile-names (&optional profile-dir)
  "Return installed Nelix profile names with minimal parsing.

In real standalone NeLisp this asks the Nix subprocess to reduce
`nix profile list' to one name per line.  When Emacs tests mock the
standalone predicate, fall back to `nelix-list' so fixtures stay pure."
  (if (boundp 'emacs-version)
      (mapcar (lambda (row) (plist-get row :name)) (nelix-list))
    (let* ((profile (expand-file-name (or profile-dir nelix-core-profile-dir)))
           (script
            "\"$1\" profile list --profile \"$2\" | sed -n 's/\\x1b\\[[0-9;]*m//g; s/^Name:[[:space:]]*//p'")
           (res (nelix-compat-call-process
                 "sh"
                 (list "-c" script "nelix-fast-profile-list"
                       nelix-core-nix-program profile))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-nix-failed
                (list (format "nix profile list failed (exit %s): %s"
                              (plist-get res :exit)
                              (nelix-compat-string-trim
                               (or (plist-get res :stderr) "")))
                      :stderr (plist-get res :stderr))))
      (nelix-fast--parse-name-lines (plist-get res :stdout)))))

(defun nelix-fast--name-set (names)
  "Return a hash table set for NAMES."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (name names set)
      (when (and (stringp name) (> (length name) 0))
        (puthash name t set)
        (puthash (nelix-fast--strip-duplicate-suffix name) t set)))))

(defun nelix-fast--name-map (names)
  "Return a hash table mapping exact profile NAMES to actual names."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (name names map)
      (when (and (stringp name) (> (length name) 0))
        (puthash name name map)))))

(defun nelix-fast--normalized-name-map (names)
  "Return a hash table mapping duplicate-suffix aliases to actual NAMES."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (name names map)
      (when (and (stringp name) (> (length name) 0))
        (let ((normalized (nelix-fast--strip-duplicate-suffix name)))
          (unless (equal normalized name)
            (puthash normalized name map)))))))

(defun nelix-fast--find-name (candidates index &optional normalized-index)
  "Return the installed name matching CANDIDATES.

Exact profile-name matches in INDEX win before duplicate-suffix fallback
matches in NORMALIZED-INDEX.  This keeps aliases such as company-prescient and
prescient-1 from collapsing to the same target."
  (let ((found nil))
    (dolist (name candidates found)
      (when (and (null found) (gethash name index))
        (setq found (gethash name index))))
    (when (and (null found) normalized-index)
      (dolist (name candidates found)
        (when (and (null found) (gethash name normalized-index))
          (setq found (gethash name normalized-index)))))
    found))

(defun nelix-fast--aot-field (value)
  "Return VALUE as a safe Nelix AOT line-protocol field."
  (let ((field (nelix-fast--target-name value)))
    (when (or (string-match-p "\n" field)
              (string-match-p "\t" field))
      (signal 'nelix-error
              (list (format "nelix-fast AOT field contains tab/newline: %S"
                            field))))
    field))

(defun nelix-fast--aot-line (&rest fields)
  "Return one tab-separated AOT line for FIELDS."
  (concat (mapconcat #'nelix-fast--aot-field fields "\t") "\n"))

(defun nelix-fast--target-rows (manifest)
  "Return compact target rows for MANIFEST."
  (let ((targets (nelix-manifest-targets manifest 'nix))
        rows)
    (dolist (target targets (nreverse rows))
      (push (nelix-fast--target-row target) rows))))

(defun nelix-fast--resolve-emacs-target (package)
  "Return the Nix install target for Emacs PACKAGE."
  (or (gethash package (nelix-fast--target-cache))
      package))

(defun nelix-fast--dedupe-equal (items)
  "Return ITEMS with duplicates removed using `equal'."
  (let ((seen (make-hash-table :test 'equal))
        out)
    (dolist (item items (nreverse out))
      (unless (gethash item seen)
        (puthash item t seen)
        (push item out)))))

(defun nelix-fast--target-rows-from-fields (emacs linux debian-tools)
  "Return compact target rows from manifest field values."
  (let ((targets (nelix-fast--dedupe-equal
                  (append (mapcar #'nelix-fast--resolve-emacs-target emacs)
                          linux
                          debian-tools)))
        rows)
    (dolist (target targets (nreverse rows))
      (push (nelix-fast--target-row target) rows))))

(defun nelix-fast--resolve-backend (backend-policy)
  "Return the backend symbol selected by BACKEND-POLICY for this OS.
Deterministic: pick the first backend in the policy resolved for the
current `system-type' so the AOT/fast lane agrees with the manifest's
declared backend-policy (e.g. a no-Nix `nelix-native' policy) instead
of always reporting nix.  Falls back to nix only when no policy is
declared, preserving the historical default."
  (or (and backend-policy
           (car (nelix-manifest-backend-policy
                 (list :backend-policy backend-policy))))
      'nix))

(defun nelix-fast--manifest-shape
    (file name profile imports bootstrap-apt rows pins &optional backend-policy)
  "Assemble the canonical fast manifest plist from already-compiled parts.

Single source of truth for the fast manifest shape so the field-based
entry point (`nelix-fast--compile-manifest-fields', used by the DSL v1
`nelix-environment' fast loader) and the normalized-manifest entry point
(`nelix-fast--compile-manifest', the `nelix-manifest-load' fallback)
cannot drift apart -- e.g. a key added to one branch but not the other."
  (let ((desired-set (make-hash-table :test 'equal))
        (desired-names nil)
        (pins-set (nelix-fast--name-set pins))
        (selected-backend (nelix-fast--resolve-backend backend-policy))
        (current-system (nelix-current-system)))
    (dolist (row rows)
      (push (nelix-fast--row-name row) desired-names)
      (dolist (candidate (nelix-fast--row-candidates row))
        (puthash candidate t desired-set)
        (puthash (nelix-fast--strip-duplicate-suffix candidate)
                 t
                 desired-set)))
    (list :file file
          :name name
          :profile profile
          :imports imports
          :backend selected-backend
          :backend-selection (list :backend selected-backend
                                   :system current-system
                                   :fallback :nelisp-fast)
          :system current-system
          :targets rows
          :desired-order (nreverse desired-names)
          :desired-set desired-set
          :pins-order pins
          :pins-set pins-set
          :bootstrap-apt bootstrap-apt)))

(defun nelix-fast--compile-manifest-fields
    (file name profile imports emacs linux debian-tools bootstrap-apt pins
          &optional backend-policy)
  "Compile manifest field values into the fast manifest shape."
  (nelix-fast--manifest-shape
   file name profile imports bootstrap-apt
   (nelix-fast--target-rows-from-fields emacs linux debian-tools)
   pins backend-policy))

(defun nelix-fast--compile-manifest (manifest)
  "Compile normalized MANIFEST into the fast manifest shape."
  (nelix-fast--manifest-shape
   (plist-get manifest :file)
   (plist-get manifest :name)
   (plist-get manifest :profile)
   (plist-get manifest :imports)
   (plist-get manifest :bootstrap-apt)
   (nelix-fast--target-rows manifest)
   (plist-get manifest :pins)
   (plist-get manifest :backend-policy)))

(defun nelix-fast-load-manifest (manifest-file)
  "Load MANIFEST-FILE and compile it into the fast manifest shape."
  (or (and (fboundp 'nelix-compat--standalone-nelisp-p)
           (nelix-compat--standalone-nelisp-p)
           (nelix-fast--environment-manifest-load manifest-file))
      (let* ((manifest (nelix-manifest-load manifest-file)))
        (nelix-fast--compile-manifest manifest))))

(defun nelix-fast-list ()
  "Return installed profile names through the NeLisp fast path."
  (nelix-fast-profile-names))

(defun nelix-fast--read-file-as-string (path)
  "Return PATH contents as a string."
  (cond
   ((and (fboundp 'nelix-compat--standalone-nelisp-p)
         (nelix-compat--standalone-nelisp-p)
         (fboundp 'rdf))
    (or (rdf path) ""))
   ((fboundp 'nelisp-core-read-file-as-string)
    (nelisp-core-read-file-as-string path))
   ((fboundp 'insert-file-contents)
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string)))
   ((fboundp 'nelix-compat-read-file)
    (nelix-compat-read-file path))
   (t
    (signal 'nelix-error
            (list (format "nelix-fast: no file reader for %s" path))))))

(defun nelix-fast--read-forms (path)
  "Read all Elisp forms from PATH without evaluating them."
  (let* ((text (nelix-fast--read-file-as-string path))
         (pos 0)
         (len (length text))
         forms)
    (condition-case err
        (while (< pos len)
          (let* ((result (read-from-string text pos))
                 (form (car result))
                 (next (cdr result)))
            (if (and (null form) (>= next len))
                (setq pos len)
              (push form forms)
              (setq pos next))))
      (end-of-file nil)
      (error
       (signal 'nelix-error
               (list (format "nelix-fast: cannot read %s: %s"
                             path
                             (error-message-string err))))))
    (nreverse forms)))

(defun nelix-fast--env-get (env symbol)
  "Return SYMBOL's data value from ENV, or SYMBOL when unbound."
  (if (and (symbolp symbol)
           (hash-table-p env)
           (gethash symbol env))
      (gethash symbol env)
    symbol))

(defun nelix-fast--symbol-name-p (value name)
  "Return non-nil when VALUE is a symbol named NAME."
  (and (symbolp value)
       (equal (symbol-name value) name)))

(defun nelix-fast--literal-eval (form env)
  "Evaluate FORM as restricted data using ENV."
  (cond
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "quote"))
    (cadr form))
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "list"))
    (mapcar (lambda (item)
              (nelix-fast--literal-eval item env))
            (cdr form)))
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "append"))
    (apply #'append
           (mapcar (lambda (item)
                     (let ((value (nelix-fast--literal-eval item env)))
                       (cond
                        ((null value) nil)
                        ((listp value) value)
                        (t (list value)))))
                   (cdr form))))
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "mapcar"))
    (let ((fn (cadr form))
          (values (nelix-fast--literal-eval (caddr form) env)))
      (cond
       ((and (or (nelix-fast--symbol-name-p fn "cadr")
                 (and (consp fn)
                      (nelix-fast--symbol-name-p (car fn) "function")
                      (nelix-fast--symbol-name-p (cadr fn) "cadr")))
             (listp values))
        (mapcar #'cadr values))
       (t
        (signal 'nelix-error
                (list (format "nelix-fast validate: unsupported mapcar form %S"
                              form)))))))
   ((symbolp form)
    (nelix-fast--env-get env form))
   (t form)))

(defun nelix-fast--substring-index (needle haystack &optional start)
  "Return index of NEEDLE in HAYSTACK from START, or nil."
  (string-match (regexp-quote needle) haystack (or start 0)))

(defun nelix-fast--def-form-position (text symbol)
  "Return source position of SYMBOL's data definition in TEXT, or nil."
  (let ((name (symbol-name symbol)))
    (or (nelix-fast--substring-index (concat "(defconst " name) text)
        (nelix-fast--substring-index (concat "(defvar " name) text)
        (nelix-fast--substring-index (concat "(setq " name) text))))

(defun nelix-fast--literal-dependencies (form)
  "Return variable symbols referenced by restricted data FORM."
  (cond
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "quote"))
    nil)
   ((and (consp form)
         (or (nelix-fast--symbol-name-p (car form) "append")
             (nelix-fast--symbol-name-p (car form) "list")))
    (apply #'append (mapcar #'nelix-fast--literal-dependencies
                            (cdr form))))
   ((and (consp form)
         (nelix-fast--symbol-name-p (car form) "mapcar"))
    (nelix-fast--literal-dependencies (caddr form)))
   ((and (symbolp form)
         (not (memq form '(nil t)))
         (not (keywordp form)))
    (list form))
   (t nil)))

(defun nelix-fast--collect-defconst-symbol (text env symbol &optional seen)
  "Collect SYMBOL's restricted data definition from TEXT into ENV."
  (let ((key (and (symbolp symbol) (symbol-name symbol))))
    (when (and key
               (not (gethash symbol env))
               (not (member key seen)))
      (let ((pos (nelix-fast--def-form-position text symbol)))
        (when pos
          (let* ((form (car (read-from-string text pos)))
                 (value-form (caddr form)))
            (dolist (dependency (nelix-fast--literal-dependencies value-form))
              (nelix-fast--collect-defconst-symbol
               text env dependency (cons key seen)))
            (when (and (consp form)
                       (or (nelix-fast--symbol-name-p (car form) "defconst")
                           (nelix-fast--symbol-name-p (car form) "defvar")
                           (nelix-fast--symbol-name-p (car form) "setq"))
                       (symbolp (cadr form))
                       (cddr form))
              (puthash (cadr form)
                       (nelix-fast--literal-eval value-form env)
                       env))))))))

(defun nelix-fast--collect-defconsts (path env)
  "Collect restricted data definitions from PATH into ENV."
  (let ((text (nelix-fast--read-file-as-string path)))
    (dolist (symbol nelix-fast-validate-data-symbols)
      (nelix-fast--collect-defconst-symbol text env symbol))
    env))

(defun nelix-fast--dsl-value (args env)
  "Return one DSL value from ARGS using ENV."
  (if (= 1 (length args))
      (nelix-fast--literal-eval (car args) env)
    args))

(defun nelix-fast--dsl-string (caller args env)
  "Return CALLER's single value as a string using ENV."
  (let ((value (nelix-fast--dsl-value args env)))
    (cond
     ((stringp value) value)
     ((symbolp value) (symbol-name value))
     (t
      (signal 'nelix-error
              (list (format "%s must be a string or symbol, got %S"
                            caller value)))))))

(defun nelix-fast--dsl-string-list (caller values)
  "Normalize VALUES to a string list for CALLER."
  (mapcar (lambda (value)
            (cond
             ((stringp value) value)
             ((symbolp value) (symbol-name value))
             (t
              (signal 'nelix-error
                      (list (format "%s must contain strings or symbols, got %S"
                                    caller value))))))
          values))

(defun nelix-fast--package-row-name (caller args)
  "Return a one-element string list for package row ARGS in CALLER."
  (unless args
    (signal 'nelix-error
            (list (format "%s requires a package name" caller))))
  (let ((name (car args)))
    (unless (or (symbolp name) (stringp name))
      (signal 'nelix-error
              (list (format "%s package name must be string or symbol, got %S"
                            caller name))))
    (nelix-fast--dsl-string-list caller (list name))))

(defun nelix-fast--supported-backend-p (backend)
  "Return non-nil when BACKEND is a stable DSL v1 backend symbol."
  (and (symbolp backend)
       (memq backend nelix-environment-dsl-backends)))

(defun nelix-fast--forbidden-package-option-p (key)
  "Return non-nil when package option KEY embeds private data."
  (and (keywordp key)
       (member (substring (symbol-name key) 1)
               nelix-fast--environment-forbidden-form-names)))

(defun nelix-fast--validate-backend-policy (args)
  "Validate DSL v1 backend-policy ARGS without evaluating values."
  (unless args
    (signal 'nelix-error
            (list "nelix-fast validate: backend-policy requires at least one backend or OS row")))
  (cond
   ((nelix-fast--every #'symbolp args)
    (dolist (backend args)
      (unless (nelix-fast--supported-backend-p backend)
        (signal 'nelix-error
                (list (format "nelix-fast validate: unsupported backend %S"
                              backend))))))
   ((nelix-fast--every (lambda (row)
                         (and (consp row) (symbolp (car row))))
                       args)
    (dolist (row args)
      (unless (cdr row)
        (signal 'nelix-error
                (list (format "nelix-fast validate: backend-policy row %S has no backends"
                              row))))
      (dolist (backend (cdr row))
        (unless (nelix-fast--supported-backend-p backend)
          (signal 'nelix-error
                  (list (format "nelix-fast validate: unsupported backend %S"
                                backend)))))))
   (t
    (signal 'nelix-error
            (list "nelix-fast validate: backend-policy must use backend symbols or OS rows")))))

(defun nelix-fast--validate-package-row-options (caller options)
  "Validate package row OPTIONS for CALLER."
  (let ((rest options))
    (while rest
      (unless (and (consp rest) (consp (cdr rest)) (keywordp (car rest)))
        (signal 'nelix-error
                (list (format "%s options must be keyword pairs, got %S"
                              caller options))))
      (let ((key (car rest))
            (value (cadr rest)))
        (when (nelix-fast--forbidden-package-option-p key)
          (signal 'nelix-error
                  (list (format "%s private data option %S is forbidden"
                                caller key))))
        (unless (memq key nelix-fast--environment-package-option-keys)
          (signal 'nelix-error
                  (list (format "%s unknown option %S" caller key))))
        (when (eq key :backend)
          (unless (nelix-fast--supported-backend-p value)
            (signal 'nelix-error
                    (list (format "%s unsupported backend %S"
                                  caller value)))))
        (when (eq key :pin)
          (unless (memq value '(nil t))
            (signal 'nelix-error
                    (list (format "%s :pin must be t or nil, got %S"
                                  caller value)))))
        (when (memq key '(:version :profile :group :feature))
          (unless (or (symbolp value) (stringp value))
            (signal 'nelix-error
                    (list (format "%s %S must be a string or symbol, got %S"
                                  caller key value)))))
        (when (eq key :platform)
          (unless (or (symbolp value) (stringp value) (listp value))
            (signal 'nelix-error
                    (list (format "%s :platform must be a string, symbol, or list, got %S"
                                  caller value)))))
        (when (eq key :when)
          (unless (or (symbolp value) (listp value))
            (signal 'nelix-error
                    (list (format "%s :when must be a symbol or list, got %S"
                                  caller value)))))
        (setq rest (cddr rest))))))

(defun nelix-fast--validate-package-row (caller args)
  "Validate package row ARGS for CALLER."
  (nelix-fast--package-row-name caller args)
  (nelix-fast--validate-package-row-options caller (cdr args)))

(defun nelix-fast--validate-version-pin-row (args)
  "Validate DSL v1 version-pin ARGS."
  (unless (= 2 (length args))
    (signal 'nelix-error
            (list (format "nelix-fast validate: version-pin expected NAME VERSION, got %S"
                          args))))
  (dolist (value args)
    (unless (or (symbolp value) (stringp value))
      (signal 'nelix-error
              (list (format "nelix-fast validate: version-pin values must be strings or symbols, got %S"
                            value))))))

(defun nelix-fast--validate-remove-policy (args)
  "Validate DSL v1 remove-policy ARGS."
  (unless (= 1 (length args))
    (signal 'nelix-error
            (list (format "nelix-fast validate: remove-policy expects one value, got %S"
                          args))))
  (unless (memq (car args) nelix-environment-dsl-remove-policy-values)
    (signal 'nelix-error
            (list (format "nelix-fast validate: unsupported remove-policy %S"
                          (car args))))))

(defun nelix-fast--package-row-pinned-p (args)
  "Return non-nil when package row ARGS contain :pin t."
  (let ((rest (cdr args))
        pinned)
    (while rest
      (when (and (eq (car rest) :pin)
                 (consp (cdr rest))
                 (cadr rest))
        (setq pinned t))
      (setq rest (cddr rest)))
    pinned))

(defun nelix-fast--environment-forms (manifest-file)
  "Return top-level `nelix-environment' forms from MANIFEST-FILE."
  (let (environment-forms manifest-forms)
    (dolist (form (nelix-fast--read-forms manifest-file))
      (when (and (consp form)
                 (nelix-fast--symbol-name-p (car form) "nelix-environment"))
        (push form environment-forms))
      (when (and (consp form)
                 (nelix-fast--symbol-name-p (car form) "nelix-manifest"))
        (push form manifest-forms)))
    (when manifest-forms
      (signal 'nelix-error
              (list "nelix-fast validate: top-level nelix-manifest is not DSL v1")))
    (unless (= 1 (length environment-forms))
      (signal 'nelix-error
              (list (format "nelix-fast validate: expected one nelix-environment form, got %S"
                            (length environment-forms)))))
    (dolist (environment-form environment-forms)
      (nelix-fast--environment-check-forms environment-form))
    environment-forms))

(defun nelix-fast--environment-check-forms (environment-form)
  "Validate DSL v1 subforms in ENVIRONMENT-FORM without evaluating values."
  (let (seen)
    (dolist (form (cdr environment-form))
      (unless (and (consp form) (symbolp (car form)))
        (signal 'nelix-error
                (list (format "nelix-fast validate: malformed DSL form %S"
                              form))))
      (let ((name (symbol-name (car form))))
        (when (member name nelix-fast--environment-forbidden-form-names)
          (signal 'nelix-error
                  (list (format "nelix-fast validate: private data form %S is forbidden"
                                (car form)))))
        (when (member name nelix-fast--environment-deferred-form-names)
          (signal 'nelix-error
                  (list (format "nelix-fast validate: form %S is reserved for a later DSL version"
                                (car form)))))
        (unless (member name nelix-fast--environment-form-names)
          (signal 'nelix-error
                  (list (format "nelix-fast validate: unknown DSL form %S"
                                (car form)))))
        (when (and (member name seen)
                   (not (member name
                                nelix-fast--environment-repeated-form-names)))
          (signal 'nelix-error
                  (list (format "nelix-fast validate: duplicate DSL form %S"
                                (car form)))))
        (cond
         ((string= name "backend-policy")
          (nelix-fast--validate-backend-policy (cdr form)))
         ((string= name "package")
          (nelix-fast--validate-package-row
           "nelix-fast validate: package" (cdr form)))
         ((string= name "linux-package")
          (nelix-fast--validate-package-row
           "nelix-fast validate: linux-package" (cdr form)))
         ((string= name "version-pin")
          (nelix-fast--validate-version-pin-row (cdr form)))
         ((string= name "remove-policy")
          (nelix-fast--validate-remove-policy (cdr form))))
        (push name seen)))))

(defun nelix-fast--environment-imports (environment-form)
  "Return import strings from ENVIRONMENT-FORM without evaluating variables."
  (let (imports)
    (dolist (form (cdr environment-form) (nreverse imports))
      (when (and (consp form)
                 (nelix-fast--symbol-name-p (car form) "imports"))
        (dolist (item (cdr form))
          (unless (stringp item)
            (signal 'nelix-error
                    (list (format "nelix-fast validate: import must be literal string, got %S"
                                  item))))
          (push item imports))))))

(defun nelix-fast--environment-data-symbols (environment-form)
  "Return variable symbols referenced by ENVIRONMENT-FORM package clauses."
  (let (symbols)
    (dolist (form (cdr environment-form) (nreverse symbols))
      (when (and (consp form)
                 (= 2 (length form))
                 (or (nelix-fast--symbol-name-p (car form) "emacs-packages")
                     (nelix-fast--symbol-name-p (car form) "linux-packages")
                     (nelix-fast--symbol-name-p (car form) "debian-tools")
                     (nelix-fast--symbol-name-p (car form)
                                                "bootstrap-apt-packages")
                     (nelix-fast--symbol-name-p (car form) "pins"))
                 (symbolp (cadr form)))
        (push (cadr form) symbols)))))

(defun nelix-fast--space-char-p (ch)
  "Return non-nil when CH is simple Elisp whitespace."
  (or (eq ch ?\s) (eq ch ?\t) (eq ch ?\n) (eq ch ?\r)))

(defun nelix-fast--skip-space (text pos)
  "Return first non-whitespace position in TEXT at or after POS."
  (let ((n (length text)))
    (while (and (< pos n)
                (nelix-fast--space-char-p (aref text pos)))
      (setq pos (1+ pos)))
    pos))

(defun nelix-fast--matching-paren (text open)
  "Return matching close paren index for TEXT at OPEN."
  (let ((i open)
        (n (length text))
        (depth 0)
        (in-string nil)
        (escape nil)
        close)
    (while (and (< i n) (null close))
      (let ((ch (aref text i)))
        (cond
         (escape
          (setq escape nil))
         ((and in-string (eq ch ?\\))
          (setq escape t))
         ((eq ch ?\")
          (setq in-string (not in-string)))
         (in-string nil)
         ((eq ch ?\()
          (setq depth (1+ depth)))
         ((eq ch ?\))
          (setq depth (1- depth))
          (when (= depth 0)
            (setq close i)))))
      (setq i (1+ i)))
    close))

(defun nelix-fast--count-list-items-at (text open)
  "Count top-level items in list TEXT at OPEN."
  (let ((i (1+ open))
        (n (length text))
        (depth 1)
        (in-string nil)
        (escape nil)
        (expecting t)
        (count 0))
    (while (and (< i n) (> depth 0))
      (let ((ch (aref text i)))
        (cond
         (escape
          (setq escape nil))
         ((and in-string (eq ch ?\\))
          (setq escape t))
         ((eq ch ?\")
          (when (and (= depth 1) expecting)
            (setq count (1+ count))
            (setq expecting nil))
          (setq in-string (not in-string)))
         (in-string nil)
         ((eq ch ?\;)
          (while (and (< i n) (not (eq (aref text i) ?\n)))
            (setq i (1+ i))))
         ((eq ch ?\()
          (when (and (= depth 1) expecting)
            (setq count (1+ count))
            (setq expecting nil))
          (setq depth (1+ depth)))
         ((eq ch ?\))
          (setq depth (1- depth))
          (when (= depth 1)
            (setq expecting t)))
         ((and (= depth 1) (nelix-fast--space-char-p ch))
          (setq expecting t))
         ((and (= depth 1) expecting)
          (setq count (1+ count))
          (setq expecting nil))))
      (setq i (1+ i)))
    count))

(defun nelix-fast--value-position-after-def (text symbol)
  "Return value start for SYMBOL's defconst/defvar/setq in TEXT."
  (let* ((pos (nelix-fast--def-form-position text symbol))
         (name (and pos (symbol-name symbol))))
    (when pos
      (nelix-fast--skip-space text (+ pos (length "(defconst ") (length name))))))

(defun nelix-fast--symbol-token-at (text pos)
  "Return symbol token in TEXT at POS."
  (let ((start pos)
        (n (length text)))
    (while (and (< pos n)
                (let ((ch (aref text pos)))
                  (or (and (>= ch ?a) (<= ch ?z))
                      (and (>= ch ?A) (<= ch ?Z))
                      (and (>= ch ?0) (<= ch ?9))
                      (eq ch ?-)
                      (eq ch ?_)
                      (eq ch ?/))))
      (setq pos (1+ pos)))
    (and (> pos start) (substring text start pos))))

(defun nelix-fast--symbols-in-range (text start end)
  "Return symbol tokens in TEXT between START and END."
  (let (symbols token)
    (while (< start end)
      (setq token (nelix-fast--symbol-token-at text start))
      (if token
          (progn
            (push (intern token) symbols)
            (setq start (+ start (length token))))
        (setq start (1+ start))))
    (nreverse symbols)))

(defun nelix-fast--count-def-symbol (texts symbol &optional seen)
  "Count package items for SYMBOL using imported TEXTS."
  (let ((key (and (symbolp symbol) (symbol-name symbol)))
        count)
    (when (and key (not (member key seen)))
      (dolist (text texts count)
        (let ((pos (nelix-fast--value-position-after-def text symbol)))
          (when (and pos (null count))
            (cond
             ((and (< (1+ pos) (length text))
                   (eq (aref text pos) ?')
                   (eq (aref text (1+ pos)) ?\())
              (setq count (nelix-fast--count-list-items-at text (1+ pos))))
             ((and (< pos (length text))
                   (eq (aref text pos) ?\())
              (let* ((end (or (nelix-fast--matching-paren text pos) pos))
                     (tokens (nelix-fast--symbols-in-range text (1+ pos) end))
                     (sum 0))
                (dolist (token tokens)
                  (unless (member (symbol-name token)
                                  '("append" "mapcar" "function" "cadr"))
                    (setq sum (+ sum (or (nelix-fast--count-def-symbol
                                          texts token (cons key seen))
                                         0)))))
                (setq count sum)))
             (t
              (setq count 0)))))))))

(defun nelix-fast--count-dsl-values (args texts)
  "Count package-like DSL ARGS using imported TEXTS."
  (cond
   ((and (= 1 (length args)) (symbolp (car args)))
    (or (nelix-fast--count-def-symbol texts (car args)) 0))
   (t
    (length args))))

(defun nelix-fast--validate-compiled (manifest-file)
  "Return compact DSL v1 validation data for MANIFEST-FILE."
  (let* ((manifest (expand-file-name manifest-file))
         (dir (file-name-directory manifest))
         (environment-form (car (nelix-fast--environment-forms manifest)))
         (env (make-hash-table :test 'equal))
         (imports (nelix-fast--environment-imports environment-form))
         (data-symbols (append (nelix-fast--environment-data-symbols
                                environment-form)
                               nelix-fast-validate-data-symbols))
         name profile channel backend-policy emacs linux debian-tools
         bootstrap pins)
    (let ((nelix-fast-validate-data-symbols data-symbols))
      (dolist (import imports)
        (nelix-fast--collect-defconsts
         (expand-file-name import dir)
         env)))
    (dolist (form (cdr environment-form))
      (unless (and (consp form) (symbolp (car form)))
        (signal 'nelix-error
                (list (format "nelix-fast validate: malformed DSL form %S"
                              form))))
      (cond
       ((nelix-fast--symbol-name-p (car form) "name")
         (setq name (nelix-fast--dsl-string "nelix-environment name"
                                            (cdr form)
                                            env)))
       ((nelix-fast--symbol-name-p (car form) "profile")
         (setq profile (nelix-fast--dsl-string "nelix-environment profile"
                                               (cdr form)
                                               env)))
       ((nelix-fast--symbol-name-p (car form) "nix-channel")
         (setq channel (nelix-fast--dsl-string
                        "nelix-environment nix-channel"
                        (cdr form)
                        env)))
       ((nelix-fast--symbol-name-p (car form) "imports")
        nil)
       ((nelix-fast--symbol-name-p (car form) "backend-policy")
        (setq backend-policy (cdr form)))
       ((nelix-fast--symbol-name-p (car form) "emacs-packages")
         (setq emacs
               (nelix-fast--dsl-string-list
                "nelix-environment emacs-packages"
                (nelix-fast--dsl-value (cdr form) env))))
       ((nelix-fast--symbol-name-p (car form) "linux-packages")
         (setq linux
               (nelix-fast--dsl-string-list
                "nelix-environment linux-packages"
                (nelix-fast--dsl-value (cdr form) env))))
       ((nelix-fast--symbol-name-p (car form) "debian-tools")
         (setq debian-tools
               (nelix-fast--dsl-string-list
                "nelix-environment debian-tools"
                (nelix-fast--dsl-value (cdr form) env))))
       ((nelix-fast--symbol-name-p (car form) "bootstrap-apt-packages")
         (setq bootstrap
               (nelix-fast--dsl-string-list
                "nelix-environment bootstrap-apt-packages"
                (nelix-fast--dsl-value (cdr form) env))))
       ((nelix-fast--symbol-name-p (car form) "pins")
         (setq pins
               (nelix-fast--dsl-string-list
                "nelix-environment pins"
                (nelix-fast--dsl-value (cdr form) env))))
       ((nelix-fast--symbol-name-p (car form) "package")
        (setq emacs
              (append emacs
                      (nelix-fast--package-row-name
                       "nelix-environment package"
                       (cdr form))))
        (when (nelix-fast--package-row-pinned-p (cdr form))
          (setq pins
                (append pins
                        (nelix-fast--package-row-name
                         "nelix-environment package"
                         (cdr form))))))
       ((nelix-fast--symbol-name-p (car form) "linux-package")
        (setq linux
              (append linux
                      (nelix-fast--package-row-name
                       "nelix-environment linux-package"
                       (cdr form))))
        (when (nelix-fast--package-row-pinned-p (cdr form))
          (setq pins
                (append pins
                        (nelix-fast--package-row-name
                         "nelix-environment linux-package"
                         (cdr form))))))
       ((nelix-fast--symbol-name-p (car form) "version-pin")
        (setq pins
              (append pins
                      (nelix-fast--package-row-name
                       "nelix-environment version-pin"
                       (cdr form)))))
       ((nelix-fast--symbol-name-p (car form) "remove-policy")
        nil)
       (t
        (signal 'nelix-error
                (list (format "nelix-fast validate: unknown DSL form %S"
                              (car form)))))))
    (list :manifest manifest
          :name (or name "default")
          :profile (or profile "default")
          :nix-channel (or channel "nixpkgs")
          :backend-policy backend-policy
          :imports (mapcar (lambda (path) (expand-file-name path dir))
                           imports)
          :emacs (or emacs nil)
          :linux (or linux nil)
          :debian-tools (or debian-tools nil)
          :bootstrap-apt (or bootstrap nil)
          :pins (or pins nil))))

(defun nelix-fast--environment-manifest-load (manifest-file)
  "Return fast manifest data for a literal DSL v1 manifest file.

This reuses `nelix-fast--validate-compiled' so standalone NeLisp can keep
audit, list, plan, and upgrade-plan off the full `nelix-manifest-load' path
when the manifest is a literal `nelix-environment' form."
  (condition-case nil
      (let ((compiled (nelix-fast--validate-compiled manifest-file)))
        (nelix-fast--compile-manifest-fields
         (plist-get compiled :manifest)
         (plist-get compiled :name)
         (plist-get compiled :profile)
         (plist-get compiled :imports)
         (plist-get compiled :emacs)
         (plist-get compiled :linux)
         (plist-get compiled :debian-tools)
         (plist-get compiled :bootstrap-apt)
         (plist-get compiled :pins)
         (plist-get compiled :backend-policy)))
    (error nil)))

(defun nelix-fast--json-symbol-list (values)
  "Return VALUES encoded as a JSON string array by symbol names."
  (nelix-fast--json-string-list
   (mapcar #'nelix-fast--target-name values)))

(defun nelix-fast--json-backend-policy (policy)
  "Return backend POLICY encoded as a JSON object."
  (let ((out "{")
        (first t))
    (dolist (row policy)
      (when (and (consp row) (car row))
        (unless first
          (setq out (concat out ",")))
        (setq out
              (concat out
                      (nelix-fast--json-string
                       (nelix-fast--target-name (car row)))
                      ":"
                      (nelix-fast--json-symbol-list (cdr row))))
        (setq first nil)))
    (concat out "}")))

;;;###autoload
(defun nelix-fast-validate-json (manifest-file)
  "Return DSL v1 validation JSON for MANIFEST-FILE without loading it."
  (when (and (fboundp 'nelix-compat--standalone-nelisp-p)
             (nelix-compat--standalone-nelisp-p))
    (let* ((manifest (expand-file-name manifest-file))
           (dir (file-name-directory manifest))
           (environment-form (car (nelix-fast--environment-forms manifest)))
           (imports (nelix-fast--environment-imports environment-form))
           (texts (mapcar (lambda (path)
                            (nelix-fast--read-file-as-string
                             (expand-file-name path dir)))
                          imports))
           (name "default")
           (profile "default")
           (channel "nixpkgs")
           backend-policy
           (emacs-count 0)
           (linux-count 0)
           (debian-tools-count 0)
           (bootstrap-count 0)
           (pins-count 0))
      (dolist (form (cdr environment-form))
        (cond
         ((nelix-fast--symbol-name-p (car form) "name")
          (setq name (nelix-fast--dsl-string
                      "nelix-environment name" (cdr form) nil)))
         ((nelix-fast--symbol-name-p (car form) "profile")
          (setq profile (nelix-fast--dsl-string
                         "nelix-environment profile" (cdr form) nil)))
         ((nelix-fast--symbol-name-p (car form) "nix-channel")
          (setq channel (nelix-fast--dsl-string
                         "nelix-environment nix-channel" (cdr form) nil)))
         ((nelix-fast--symbol-name-p (car form) "backend-policy")
          (setq backend-policy (cdr form)))
         ((nelix-fast--symbol-name-p (car form) "emacs-packages")
          (setq emacs-count (nelix-fast--count-dsl-values
                             (cdr form) texts)))
         ((nelix-fast--symbol-name-p (car form) "linux-packages")
          (setq linux-count (nelix-fast--count-dsl-values
                             (cdr form) texts)))
         ((nelix-fast--symbol-name-p (car form) "debian-tools")
          (setq debian-tools-count (nelix-fast--count-dsl-values
                                    (cdr form) texts)))
         ((nelix-fast--symbol-name-p (car form) "bootstrap-apt-packages")
          (setq bootstrap-count (nelix-fast--count-dsl-values
                                 (cdr form) texts)))
         ((nelix-fast--symbol-name-p (car form) "pins")
          (setq pins-count (nelix-fast--count-dsl-values
                            (cdr form) texts)))
         ((nelix-fast--symbol-name-p (car form) "package")
          (setq emacs-count (1+ emacs-count))
          (when (nelix-fast--package-row-pinned-p (cdr form))
            (setq pins-count (1+ pins-count))))
         ((nelix-fast--symbol-name-p (car form) "linux-package")
          (setq linux-count (1+ linux-count))
          (when (nelix-fast--package-row-pinned-p (cdr form))
            (setq pins-count (1+ pins-count))))
         ((nelix-fast--symbol-name-p (car form) "version-pin")
          (setq pins-count (1+ pins-count)))
         ((nelix-fast--symbol-name-p (car form) "remove-policy")
          nil)))
      (concat
       "{\"ok\":true"
       ",\"manifest\":" (nelix-fast--json-string
                         manifest)
       ",\"name\":" (nelix-fast--json-string name)
       ",\"profile\":" (nelix-fast--json-string
                        profile)
       ",\"nix-channel\":" (nelix-fast--json-string
                            channel)
       ",\"backend-policy\":"
       (nelix-fast--json-backend-policy backend-policy)
       ",\"imports\":"
       (nelix-fast--json-string-list
        (mapcar (lambda (path) (expand-file-name path dir)) imports))
       ",\"counts\":{"
       "\"emacs\":" (number-to-string emacs-count)
       ",\"linux\":" (number-to-string linux-count)
       ",\"debian-tools\":" (number-to-string debian-tools-count)
       ",\"bootstrap-apt\":" (number-to-string bootstrap-count)
       ",\"pins\":" (number-to-string pins-count)
       ",\"imports\":" (number-to-string
                        (length imports))
       "}"
       ",\"backend\":\"nelisp-fast-validate\""
       "}\n"))))

(defun nelix-fast-aot-target-cache-path (manifest-file)
  "Return the default AOT target cache path for MANIFEST-FILE."
  (concat (expand-file-name manifest-file)
          nelix-fast-aot-target-cache-suffix))

(defun nelix-fast-aot--name-id-get (name table next-id)
  "Return (ID . NEXT-ID) for NAME in TABLE."
  (let ((id (gethash name table)))
    (unless id
      (setq id next-id)
      (puthash name id table)
      (puthash (nelix-fast--strip-duplicate-suffix name) id table)
      (setq next-id (1+ next-id)))
    (cons id next-id)))

(defun nelix-fast-aot--collect-name-ids (fast)
  "Return a name->ID table for FAST manifest target candidates and pins."
  (let ((table (make-hash-table :test 'equal))
        (next-id 1)
        pair)
    (dolist (row (plist-get fast :targets))
      (dolist (name (cons (nelix-fast--row-name row)
                          (nelix-fast--row-candidates row)))
        (when (and (stringp name) (> (length name) 0))
          (setq pair (nelix-fast-aot--name-id-get name table next-id))
          (setq next-id (cdr pair)))))
    (dolist (pin (plist-get fast :pins-order))
      (when (and (stringp pin) (> (length pin) 0))
        (setq pair (nelix-fast-aot--name-id-get pin table next-id))
        (setq next-id (cdr pair))))
    table))

(defun nelix-fast-aot--name-id-entries (table)
  "Return TABLE entries sorted by numeric ID."
  (let (entries)
    (maphash (lambda (name id)
               (when (equal (gethash name table) id)
                 (push (cons id name) entries)))
             table)
    (sort entries
          (lambda (a b)
            (if (= (car a) (car b))
                (string< (cdr a) (cdr b))
              (< (car a) (car b)))))))

(defun nelix-fast-aot-target-cache-write (manifest-file &optional cache-file)
  "Write the manifest-dependent AOT target cache for MANIFEST-FILE.
The cache intentionally excludes installed profile names and the final
=end= record.  Runtime AOT can then append the current profile names
without importing the manifest in standalone NeLisp."
  (let* ((fast (nelix-fast-load-manifest manifest-file))
         (cache (or cache-file
                    (nelix-fast-aot-target-cache-path manifest-file)))
         (name-ids (nelix-fast-aot--collect-name-ids fast))
         (chunks (list "NELIX-AOT-MANIFEST-V1\n")))
    (push (nelix-fast--aot-line "manifest" (plist-get fast :file))
          chunks)
    (push (nelix-fast--aot-line "source-file" (plist-get fast :file))
          chunks)
    (dolist (import (plist-get fast :imports))
      (push (nelix-fast--aot-line "source-file" import)
            chunks))
    (push (nelix-fast--aot-line "profile" (plist-get fast :profile))
          chunks)
    (push (nelix-fast--aot-line "system" (plist-get fast :system))
          chunks)
    (push (nelix-fast--aot-line "backend" (plist-get fast :backend))
          chunks)
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (nelix-fast--row-name row)
                   (nelix-fast--row-candidates row))
            chunks))
    (dolist (pin (plist-get fast :pins-order))
      (push (nelix-fast--aot-line "pin" pin) chunks))
    (dolist (entry (nelix-fast-aot--name-id-entries name-ids))
      (push (nelix-fast--aot-line "name-id"
                                  (number-to-string (car entry))
                                  (cdr entry))
            chunks))
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target-id"
                   (number-to-string
                    (gethash (nelix-fast--row-name row) name-ids))
                   (mapcar (lambda (candidate)
                             (number-to-string
                              (gethash candidate name-ids)))
                           (nelix-fast--row-candidates row)))
            chunks))
    (dolist (pin (plist-get fast :pins-order))
      (push (nelix-fast--aot-line "pin-id"
                                  (number-to-string (gethash pin name-ids)))
            chunks))
    (with-temp-file cache
      (insert (apply #'concat (nreverse chunks))))
    (list :status 'ok
          :cache cache
          :manifest (plist-get fast :file)
          :targets (length (plist-get fast :targets))
          :pins (length (plist-get fast :pins-order)))))

(defun nelix-fast-aot-target-cache-name-ids (cache-file)
  "Return name->ID table parsed from CACHE-FILE name-id records."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (line (split-string (nelix-fast--read-file-as-string cache-file)
                                "\n" t))
      (let ((fields (split-string line "\t")))
        (when (and (equal (car fields) "name-id")
                   (cadr fields)
                   (caddr fields))
          (puthash (caddr fields)
                   (string-to-number (cadr fields))
                   table)
          (puthash (nelix-fast--strip-duplicate-suffix (caddr fields))
                   (string-to-number (cadr fields))
                   table))))
    table))

(defun nelix-fast-aot-target-cache-has-id-records-p (cache-file)
  "Return non-nil when CACHE-FILE contains target-id records."
  (let ((found nil))
    (dolist (line (split-string (nelix-fast--read-file-as-string cache-file)
                                "\n" t)
                  found)
      (when (and (not found)
                 (equal (car (split-string line "\t")) "target-id"))
        (setq found t)))))

(defun nelix-fast-aot-target-cache-runtime-prefix (cache-file)
  "Return CACHE-FILE records needed at runtime.
When numeric ID records are available, omit string target/pin records so
standalone NeLisp parses less data on the hot cache path."
  (let ((id-records (nelix-fast-aot-target-cache-has-id-records-p cache-file)))
    (if (not id-records)
        (nelix-fast--read-file-as-string cache-file)
      (let ((chunks nil)
            tag)
        (dolist (line (split-string (nelix-fast--read-file-as-string cache-file)
                                    "\n" t))
          (setq tag (car (split-string line "\t")))
          (when (or (string-prefix-p "NELIX-AOT-MANIFEST-V1" line)
                    (member tag '("manifest"
                                  "profile"
                                  "system"
                                  "backend"
                                  "name-id"
                                  "target-id"
                                  "pin-id")))
            (push (concat line "\n") chunks)))
        (apply #'concat (nreverse chunks))))))

(defun nelix-fast-aot-target-cache-existing (manifest-file)
  "Return MANIFEST-FILE's target cache path when it exists."
  (let ((cache (nelix-fast-aot-target-cache-path manifest-file)))
    (and (file-exists-p cache) cache)))

(defun nelix-fast-aot-input-from-target-cache (cache-file &optional installed-names)
  "Return full AOT line protocol using CACHE-FILE and INSTALLED-NAMES.
When INSTALLED-NAMES is nil, ask the Nix profile directly through a
small shell pipeline so standalone NeLisp does not build the payload
record-by-record in Elisp."
  (if installed-names
      (let ((chunks (list (nelix-fast-aot-target-cache-runtime-prefix
                           cache-file)))
            (name-ids (nelix-fast-aot-target-cache-name-ids cache-file))
            id)
        (dolist (name installed-names)
          (push (nelix-fast--aot-line "installed" name) chunks)
          (setq id (or (gethash name name-ids)
                       (gethash (nelix-fast--strip-duplicate-suffix name)
                                name-ids)))
          (when id
            (push (nelix-fast--aot-line "installed-id"
                                        (number-to-string id))
                  chunks)))
        (push "end\n" chunks)
        (apply #'concat (nreverse chunks)))
    (let* ((profile (expand-file-name nelix-core-profile-dir))
           (script
            (concat
             "if awk -F '\\t' '$1 == \"target-id\" { found = 1 } "
             "END { exit(found ? 0 : 1) }' \"$1\"; then "
             "awk -F '\\t' 'NR == 1 || $1 == \"manifest\" || "
             "$1 == \"profile\" || $1 == \"system\" || $1 == \"backend\" || "
             "$1 == \"name-id\" || $1 == \"target-id\" || "
             "$1 == \"pin-id\" { print }' \"$1\"; "
             "else cat \"$1\"; fi; "
             "\"$2\" profile list --profile \"$3\" "
             "| sed -n 's/\\x1b\\[[0-9;]*m//g; s/^Name:[[:space:]]*//p' "
             "| awk -F '\\t' '"
             "BEGIN { OFS = \"\\t\" } "
             "FILENAME == ARGV[1] { "
             "if ($1 == \"name-id\" && $2 != \"\" && $3 != \"\") ids[$3] = $2; "
             "next } "
             "{ name = $0; print \"installed\", name; lookup = name; "
             "sub(/-[0-9]+$/, \"\", lookup); "
             "if (name in ids) print \"installed-id\", ids[name]; "
             "else if (lookup in ids) print \"installed-id\", ids[lookup] }"
             "' \"$1\" -; "
             "printf 'end\\n'"))
           (res (nelix-compat-call-process
                 "sh"
                 (list "-c" script
                       "nelix-aot-target-cache"
                       cache-file
                       nelix-core-nix-program
                       profile))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-nix-failed
                (list (format "nix profile list failed (exit %s): %s"
                              (plist-get res :exit)
                              (nelix-compat-string-trim
                               (or (plist-get res :stderr) "")))
                      :stderr (plist-get res :stderr))))
      (plist-get res :stdout))))

(defun nelix-fast-aot-input (manifest-file &optional installed-names)
  "Return a compact line protocol for native/AOT manifest engines.

The protocol avoids plist/alist traversal on the hot native side.  Each
line is tab-separated and ends with a newline.  Version 1 contains:

  NELIX-AOT-MANIFEST-V1
  manifest PATH
  profile PROFILE
  system SYSTEM
  target DISPLAY CANDIDATE...
  pin NAME
  installed NAME
  end

When INSTALLED-NAMES is nil, read the current profile via
`nelix-fast-profile-names'."
  (let* ((fast (nelix-fast-load-manifest manifest-file))
         (installed (or installed-names (nelix-fast-profile-names)))
         (chunks (list "NELIX-AOT-MANIFEST-V1\n")))
    (push (nelix-fast--aot-line "manifest" (plist-get fast :file))
          chunks)
    (push (nelix-fast--aot-line "profile" (plist-get fast :profile))
          chunks)
    (push (nelix-fast--aot-line "system" (plist-get fast :system))
          chunks)
    (push (nelix-fast--aot-line "backend" (plist-get fast :backend))
          chunks)
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (nelix-fast--row-name row)
                   (nelix-fast--row-candidates row))
            chunks))
    (dolist (pin (plist-get fast :pins-order))
      (push (nelix-fast--aot-line "pin" pin) chunks))
    (dolist (name installed)
      (push (nelix-fast--aot-line "installed" name) chunks))
    (push "end\n" chunks)
    (apply #'concat (nreverse chunks))))

(defvar nelix-fast-aot-portable-max-targets 64
  "Maximum target count for the portable line-protocol AOT engine.
The portable engine is a proof path.  On current standalone NeLisp,
building the line protocol for large real manifests is slower than the
direct fast path, so large manifests fall back until the native parser
artifact replaces this Elisp bridge.")

(defvar nelix-fast-aot-portable-max-records 128
  "Maximum target+installed records for the portable AOT bridge.")

(defun nelix-fast-aot-input-from-fast (fast &optional installed-names)
  "Return AOT line protocol for compiled FAST manifest data."
  (let ((installed (or installed-names (nelix-fast-profile-names)))
        (chunks (list "NELIX-AOT-MANIFEST-V1\n")))
    (push (nelix-fast--aot-line "manifest" (plist-get fast :file))
          chunks)
    (push (nelix-fast--aot-line "profile" (plist-get fast :profile))
          chunks)
    (push (nelix-fast--aot-line "system" (plist-get fast :system))
          chunks)
    (push (nelix-fast--aot-line "backend" (plist-get fast :backend))
          chunks)
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (nelix-fast--row-name row)
                   (nelix-fast--row-candidates row))
            chunks))
    (dolist (pin (plist-get fast :pins-order))
      (push (nelix-fast--aot-line "pin" pin) chunks))
    (dolist (name installed)
      (push (nelix-fast--aot-line "installed" name) chunks))
    (push "end\n" chunks)
    (apply #'concat (nreverse chunks))))

(defun nelix-fast--portable-aot-eligible-p (fast installed)
  "Return non-nil when FAST and INSTALLED are small enough for AOT."
  (and (<= (length (plist-get fast :targets))
           nelix-fast-aot-portable-max-targets)
       (<= (+ (length (plist-get fast :targets))
              (length installed))
           nelix-fast-aot-portable-max-records)))

(defun nelix-fast--aot-skipped (fast)
  "Return a diagnostic plist explaining why portable AOT was skipped."
  (list :reason :portable-target-limit
        :targets (length (plist-get fast :targets))
        :record-limit nelix-fast-aot-portable-max-records
        :limit nelix-fast-aot-portable-max-targets))

(defun nelix-fast--direct-json-enabled-p ()
  "Return non-nil when fast direct JSON should replace generic CLI JSON.
Keep the non-AOT direct writer scoped to standalone NeLisp so ordinary Emacs
commands continue to use the full plist/report encoder."
  (or (nelix-fast-aot-enabled-p)
      (and (fboundp 'nelix-compat--standalone-nelisp-p)
           (nelix-compat--standalone-nelisp-p))))

(defun nelix-fast--json-escape-string (string)
  "Return STRING escaped as a JSON string body."
  (let ((i 0)
        (len (length string))
        (needs-escape nil))
    (while (and (< i len) (null needs-escape))
      (let ((ch (aref string i)))
        (when (or (eq ch ?\\)
                  (eq ch ?\")
                  (eq ch ?\n)
                  (eq ch ?\r)
                  (eq ch ?\t))
          (setq needs-escape t)))
      (setq i (1+ i)))
    (if needs-escape
        (nelix-fast--json-escape-string-slow string)
      string)))

(defun nelix-fast--json-escape-string-slow (string)
  "Return STRING escaped as a JSON string body using the slow path."
  (let ((i 0)
        (len (length string))
        (out ""))
    (while (< i len)
      (let ((ch (aref string i)))
        (setq out
              (concat out
                      (cond
                       ((eq ch ?\\) "\\\\")
                       ((eq ch ?\") "\\\"")
                       ((eq ch ?\n) "\\n")
                       ((eq ch ?\r) "\\r")
                       ((eq ch ?\t) "\\t")
                       (t (char-to-string ch))))))
      (setq i (1+ i)))
    out))

(defun nelix-fast--json-string (value)
  "Return VALUE encoded as a JSON string."
  (concat "\"" (nelix-fast--json-escape-string (or value "")) "\""))

(defun nelix-fast--json-bool (value)
  "Return VALUE encoded as a JSON boolean."
  (if value "true" "false"))

(defun nelix-fast--json-nullable-string (value)
  "Return VALUE encoded as a JSON string or null."
  (if value
      (nelix-fast--json-string value)
    "null"))

(defun nelix-fast--concat-balanced (parts)
  "Return concatenated PARTS without one very large `apply' call."
  (let ((items parts)
        next)
    (while (cdr items)
      (setq next nil)
      (while items
        (let ((left (car items))
              (right (cadr items)))
          (push (if right
                    (concat left right)
                  left)
                next))
        (setq items (cddr items)))
      (setq items (nreverse next)))
    (or (car items) "")))

(defun nelix-fast--json-string-list (values)
  "Return VALUES encoded as a JSON string array."
  (let ((parts (list "["))
        (first t))
    (while values
      (unless first
        (push "," parts))
      (push (nelix-fast--json-string (car values)) parts)
      (setq first nil)
      (setq values (cdr values)))
    (push "]" parts)
    (nelix-fast--concat-balanced (nreverse parts))))

(defun nelix-fast--json-skipped-object (pairs)
  "Return PAIRS encoded as a JSON object with string values."
  (let ((out "{")
        (first t))
    (while pairs
      (unless first
        (setq out (concat out ",")))
      (setq out
            (concat out
                    (nelix-fast--json-string
                     (substring (symbol-name (car pairs)) 1))
                    ":"
                    (nelix-fast--json-string
                     (symbol-name (cadr pairs)))))
      (setq first nil)
      (setq pairs (cddr pairs)))
    (concat out "}")))

(defun nelix-fast--json-backend-fields (fast fallback)
  "Return compact backend JSON fields for FAST and FALLBACK."
  (let ((backend (nelix-fast--target-name
                  (or (plist-get fast :backend) 'nix))))
    (concat
     ",\"backend\":" (nelix-fast--json-string backend)
     ",\"backend-selection\":{"
     "\"backend\":" (nelix-fast--json-string backend) ","
     "\"system\":" (nelix-fast--json-nullable-string
                    (nelix-fast--target-name (plist-get fast :system)))
     ",\"fallback\":" (nelix-fast--json-string fallback)
     "}")))

(defun nelix-fast-aot--cache-meta-field (cache-file key)
  "Return metadata value string for KEY in CACHE-FILE, or nil when absent."
  (let ((prefix (concat key "\t"))
        value)
    (dolist (line (split-string
                   (nelix-fast--read-file-as-string cache-file) "\n" t)
                  value)
      (when (and (null value) (string-prefix-p prefix line))
        (setq value (substring line (length prefix)))))))

(defun nelix-fast-aot--cache-backend (cache-file)
  "Return the backend symbol recorded in CACHE-FILE (nix when absent)."
  (intern (or (nelix-fast-aot--cache-meta-field cache-file "backend") "nix")))

(defun nelix-fast-aot--cache-system (cache-file)
  "Return the system symbol recorded in CACHE-FILE (x86_64-linux default)."
  (intern (or (nelix-fast-aot--cache-meta-field cache-file "system")
              "x86_64-linux")))

(defun nelix-fast-aot-audit-from-fast (fast &optional installed-names)
  "Return a compact AOT audit report for compiled FAST manifest data."
  (nelix-fast--ensure-aot-engine)
  (let ((report (nelix-aot-audit
                 (nelix-fast-aot-input-from-fast fast installed-names)))
        (backend (or (plist-get fast :backend) 'nix)))
    (append report
            (list :backend backend
                  :backend-selection
                  (list :backend backend
                        :system (plist-get fast :system)
                        :fallback :nelisp-aot)))))

(defun nelix-fast-aot-audit-from-cache (cache-file)
  "Return a compact AOT audit report using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (let ((report (nelix-aot-audit
                 (nelix-fast-aot-input-from-target-cache cache-file)))
        (backend (nelix-fast-aot--cache-backend cache-file)))
    (append report
            (list :backend backend
                  :backend-selection
                  (list :backend backend
                        :system (nelix-fast-aot--cache-system cache-file)
                        :fallback :nelisp-aot-cache)
                  :aot-cache cache-file))))

(defun nelix-fast-aot-audit-json-from-cache (cache-file)
  "Return compact AOT audit JSON using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (nelix-aot-audit-json
   (nelix-fast-aot-input-from-target-cache cache-file)
   ":nelisp-aot-cache"
   cache-file))

(defun nelix-fast-aot-audit (manifest-file)
  "Return a compact AOT audit report for MANIFEST-FILE."
  (let* ((fast (nelix-fast-load-manifest manifest-file))
         (installed (nelix-fast-profile-names)))
    (if (nelix-fast--portable-aot-eligible-p fast installed)
        (nelix-fast-aot-audit-from-fast fast installed)
      (append (nelix-fast-audit-default fast)
              (list :aot-skipped (nelix-fast--aot-skipped fast))))))

(defun nelix-fast-aot-audit-json-from-fast (fast &optional installed-names)
  "Return compact AOT audit JSON for compiled FAST manifest data."
  (nelix-fast--ensure-aot-engine)
  (nelix-aot-audit-json
   (nelix-fast-aot-input-from-fast fast installed-names)
   ":nelisp-aot"
   nil))

(defun nelix-fast-audit-json (manifest-file)
  "Return direct JSON for MANIFEST-FILE without generic plist encoding."
  (when (nelix-fast--direct-json-enabled-p)
    (let ((cache (and (nelix-fast-aot-enabled-p)
                      (nelix-fast-aot-target-cache-existing manifest-file))))
      (if cache
          (nelix-fast-aot-audit-json-from-cache cache)
        (let* ((fast (nelix-fast-load-manifest manifest-file))
               (installed (nelix-fast-profile-names)))
          (if (and (nelix-fast-aot-enabled-p)
                   (nelix-fast--portable-aot-eligible-p fast installed))
              (nelix-fast-aot-audit-json-from-fast fast installed)
            (nelix-fast-audit-json-default fast installed)))))))

(defun nelix-fast-audit-json-default (fast &optional installed-names)
  "Return direct compact audit JSON for FAST."
  (let* ((installed (or installed-names (nelix-fast-profile-names)))
         (installed-map (nelix-fast--name-map installed))
         (normalized-installed-map
          (nelix-fast--normalized-name-map installed))
         (desired-set (plist-get fast :desired-set))
         (present-set (make-hash-table :test 'equal))
         (missing-set (make-hash-table :test 'equal))
         (extra-set (make-hash-table :test 'equal))
         present missing extra)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (nelix-fast--row-candidates row)
                     installed-map
                     normalized-installed-map)))
        (if actual
            (setq present
                  (nelix-fast--push-unique-set actual present present-set))
          (setq missing
                (nelix-fast--push-unique-set
                 (nelix-fast--row-name row) missing missing-set)))))
    (dolist (name installed)
      (unless (or (gethash name desired-set)
                  (gethash (nelix-fast--strip-duplicate-suffix name)
                           desired-set))
        (setq extra (nelix-fast--push-unique-set name extra extra-set))))
    (setq present (nreverse present)
          missing (nreverse missing)
          extra (nreverse extra))
    (concat
     "{\"ok\":" (nelix-fast--json-bool (and (null missing) (null extra)))
     ",\"manifest\":" (nelix-fast--json-nullable-string
                       (plist-get fast :file))
     ",\"profile\":" (nelix-fast--json-nullable-string
                      (plist-get fast :profile))
     ",\"system\":" (nelix-fast--json-nullable-string
                     (nelix-fast--target-name (plist-get fast :system)))
     ",\"present\":" (nelix-fast--json-string-list present)
     ",\"missing\":" (nelix-fast--json-string-list missing)
     ",\"extra\":" (nelix-fast--json-string-list extra)
     ",\"skipped\":"
     (nelix-fast--json-skipped-object
      '(:state-pins :nelisp
        :lock-drift :nelisp
        :linux-command-audit :nelisp))
     (nelix-fast--json-backend-fields fast ":nelisp-fast")
     "}")))

(defun nelix-fast-aot-upgrade-plan-from-fast (fast &optional installed-names)
  "Return a compact AOT upgrade plan for compiled FAST manifest data."
  (nelix-fast--ensure-aot-engine)
  (let ((plan (nelix-aot-upgrade-plan
               (nelix-fast-aot-input-from-fast fast installed-names)))
        (backend (or (plist-get fast :backend) 'nix)))
    (append plan
            (list :backend backend
                  :backend-selection
                  (list :backend backend
                        :system (plist-get fast :system)
                        :fallback :nelisp-aot)))))

(defun nelix-fast-aot-upgrade-plan-from-cache (cache-file)
  "Return a compact AOT upgrade plan using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (let ((plan (nelix-aot-upgrade-plan
               (nelix-fast-aot-input-from-target-cache cache-file)))
        (backend (nelix-fast-aot--cache-backend cache-file)))
    (append plan
            (list :backend backend
                  :backend-selection
                  (list :backend backend
                        :system (nelix-fast-aot--cache-system cache-file)
                        :fallback :nelisp-aot-cache)
                  :aot-cache cache-file))))

(defun nelix-fast-aot-upgrade-plan-json-from-cache (cache-file)
  "Return compact AOT upgrade-plan JSON using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (nelix-aot-upgrade-plan-json
   (nelix-fast-aot-input-from-target-cache cache-file)
   ":nelisp-aot-cache"
   cache-file))

(defun nelix-fast-aot-upgrade-plan (manifest-file)
  "Return a compact AOT upgrade plan for MANIFEST-FILE."
  (let* ((fast (nelix-fast-load-manifest manifest-file))
         (installed (nelix-fast-profile-names)))
    (if (nelix-fast--portable-aot-eligible-p fast installed)
        (nelix-fast-aot-upgrade-plan-from-fast fast installed)
      (append (nelix-fast-upgrade-plan-default fast)
              (list :aot-skipped (nelix-fast--aot-skipped fast))))))

(defun nelix-fast-aot-upgrade-plan-json-from-fast (fast &optional installed-names)
  "Return compact AOT upgrade-plan JSON for compiled FAST manifest data."
  (nelix-fast--ensure-aot-engine)
  (nelix-aot-upgrade-plan-json
   (nelix-fast-aot-input-from-fast fast installed-names)
   ":nelisp-aot"
   nil))

(defun nelix-fast-upgrade-plan-json (manifest-file)
  "Return direct JSON for MANIFEST-FILE without generic plist encoding."
  (when (and manifest-file (nelix-fast--direct-json-enabled-p))
    (let ((cache (and (nelix-fast-aot-enabled-p)
                      (nelix-fast-aot-target-cache-existing manifest-file))))
      (if cache
          (nelix-fast-aot-upgrade-plan-json-from-cache cache)
        (let* ((fast (nelix-fast-load-manifest manifest-file))
               (installed (nelix-fast-profile-names)))
          (if (and (nelix-fast-aot-enabled-p)
                   (nelix-fast--portable-aot-eligible-p fast installed))
              (nelix-fast-aot-upgrade-plan-json-from-fast fast installed)
            (nelix-fast-upgrade-plan-json-default fast installed)))))))

(defun nelix-fast-upgrade-plan-json-default (fast &optional installed-names)
  "Return direct compact upgrade-plan JSON for FAST."
  (let* ((installed (or installed-names (nelix-fast-profile-names)))
         (installed-map (nelix-fast--name-map installed))
         (normalized-installed-map
          (nelix-fast--normalized-name-map installed))
         (pin-set (plist-get fast :pins-set))
         (upgrade-set (make-hash-table :test 'equal))
         (pinned-set (make-hash-table :test 'equal))
         (missing-set (make-hash-table :test 'equal))
         upgrade pinned missing)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (nelix-fast--row-candidates row)
                     installed-map
                     normalized-installed-map)))
        (if actual
            (if (or (gethash actual pin-set)
                    (gethash (nelix-fast--strip-duplicate-suffix actual)
                             pin-set))
                (setq pinned
                      (nelix-fast--push-unique-set actual pinned pinned-set))
              (setq upgrade
                    (nelix-fast--push-unique-set actual upgrade upgrade-set)))
          (setq missing
                (nelix-fast--push-unique-set
                 (nelix-fast--row-name row) missing missing-set)))))
    (setq upgrade (nreverse upgrade)
          pinned (nreverse pinned)
          missing (nreverse missing))
    (concat
     "{\"operation\":\"upgrade\""
     ",\"name\":\":manifest\""
     ",\"count\":" (number-to-string (length upgrade))
     ",\"upgrade\":" (nelix-fast--json-string-list upgrade)
     ",\"pinned\":" (nelix-fast--json-string-list pinned)
     ",\"pinned-names\":" (nelix-fast--json-string-list
                           (plist-get fast :pins-order))
     ",\"blocked\":null"
     ",\"empty\":" (nelix-fast--json-bool (null upgrade))
     ",\"manifest\":" (nelix-fast--json-nullable-string
                       (plist-get fast :file))
     ",\"profile\":" (nelix-fast--json-nullable-string
                      (plist-get fast :profile))
     ",\"system\":" (nelix-fast--json-nullable-string
                     (nelix-fast--target-name (plist-get fast :system)))
     ",\"missing\":" (nelix-fast--json-string-list missing)
     ",\"extra\":null"
     ",\"lock-drift\":null"
     ",\"skipped\":"
     (nelix-fast--json-skipped-object
      '(:extra-scan :nelisp
        :lock-drift :nelisp
        :state-pins :nelisp))
     (nelix-fast--json-backend-fields fast ":nelisp-fast")
     "}")))

(defun nelix-fast-audit-default (fast &optional installed-names)
  "Return the direct fast audit report for compiled FAST manifest data."
  (let* ((installed (or installed-names (nelix-fast-profile-names)))
         (installed-map (nelix-fast--name-map installed))
         (normalized-installed-map
          (nelix-fast--normalized-name-map installed))
         (desired-set (plist-get fast :desired-set))
         (present-set (make-hash-table :test 'equal))
         (missing-set (make-hash-table :test 'equal))
         (extra-set (make-hash-table :test 'equal))
         present missing extra)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (nelix-fast--row-candidates row)
                     installed-map
                     normalized-installed-map)))
        (if actual
            (setq present
                  (nelix-fast--push-unique-set actual present present-set))
          (setq missing
                (nelix-fast--push-unique-set
                 (nelix-fast--row-name row) missing missing-set)))))
    (dolist (name installed)
      (unless (or (gethash name desired-set)
                  (gethash (nelix-fast--strip-duplicate-suffix name)
                           desired-set))
        (setq extra (nelix-fast--push-unique-set name extra extra-set))))
    (setq present (nreverse present)
          missing (nreverse missing)
          extra (nreverse extra))
    (list :ok (and (null missing) (null extra))
          :manifest (plist-get fast :file)
          :backend (or (plist-get fast :backend) 'nix)
          :backend-selection (plist-get fast :backend-selection)
          :present present
          :missing missing
          :extra extra
          :pins (list :expected (plist-get fast :pins-order)
                      :actual :skipped
                      :missing :skipped
                      :extra :skipped)
          :bootstrap (list :declared (plist-get fast :bootstrap-apt)
                           :missing nil
                           :outdated nil
                           :skipped :nelisp)
          :commands '(:missing nil :non-profile nil :skipped :nelisp)
          :lock-drift nil
          :warnings nil
          :skipped '(:state-pins :nelisp
                     :lock-drift :nelisp
                     :linux-command-audit :nelisp))))

(defun nelix-fast-audit (manifest-file)
  "Return a compact read-only audit report for MANIFEST-FILE."
  (let ((cache (and (nelix-fast-aot-enabled-p)
                    (nelix-fast-aot-target-cache-existing manifest-file))))
    (if cache
        (nelix-fast-aot-audit-from-cache cache)
      (let* ((fast (nelix-fast-load-manifest manifest-file))
             (installed (nelix-fast-profile-names)))
        (if (and (nelix-fast-aot-enabled-p)
                 (nelix-fast--portable-aot-eligible-p fast installed))
            (nelix-fast-aot-audit-from-fast fast installed)
          (append (nelix-fast-audit-default fast installed)
                  (and (nelix-fast-aot-enabled-p)
                       (list :aot-skipped
                             (nelix-fast--aot-skipped fast)))))))))

(defun nelix-fast-upgrade-plan-default (fast &optional installed-names)
  "Return the direct fast upgrade plan for compiled FAST manifest data."
  (let* ((installed (or installed-names (nelix-fast-profile-names)))
         (installed-map (nelix-fast--name-map installed))
         (normalized-installed-map
          (nelix-fast--normalized-name-map installed))
         (pin-set (plist-get fast :pins-set))
         (upgrade-set (make-hash-table :test 'equal))
         (pinned-set (make-hash-table :test 'equal))
         (missing-set (make-hash-table :test 'equal))
         upgrade pinned missing)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (nelix-fast--row-candidates row)
                     installed-map
                     normalized-installed-map)))
        (if actual
            (if (or (gethash actual pin-set)
                    (gethash (nelix-fast--strip-duplicate-suffix actual)
                             pin-set))
                (setq pinned
                      (nelix-fast--push-unique-set actual pinned pinned-set))
              (setq upgrade
                    (nelix-fast--push-unique-set actual upgrade upgrade-set)))
          (setq missing
                (nelix-fast--push-unique-set
                 (nelix-fast--row-name row) missing missing-set)))))
    (setq upgrade (nreverse upgrade)
          pinned (nreverse pinned)
          missing (nreverse missing))
    (list :operation 'upgrade
          :name :manifest
          :count (length upgrade)
          :upgrade upgrade
          :pinned pinned
          :pinned-names (plist-get fast :pins-order)
          :blocked nil
          :empty (null upgrade)
          :backend (or (plist-get fast :backend) 'nix)
          :backend-selection (plist-get fast :backend-selection)
          :manifest (plist-get fast :file)
          :profile (plist-get fast :profile)
          :system (plist-get fast :system)
          :missing missing
          :extra nil
          :lock-drift nil
          :skipped '(:extra-scan :nelisp
                     :lock-drift :nelisp
                     :state-pins :nelisp))))

(defun nelix-fast-upgrade-plan (manifest-file)
  "Return a compact manifest upgrade plan for MANIFEST-FILE."
  (let ((cache (and (nelix-fast-aot-enabled-p)
                    (nelix-fast-aot-target-cache-existing manifest-file))))
    (if cache
        (nelix-fast-aot-upgrade-plan-from-cache cache)
      (let* ((fast (nelix-fast-load-manifest manifest-file))
             (installed (nelix-fast-profile-names)))
        (if (and (nelix-fast-aot-enabled-p)
                 (nelix-fast--portable-aot-eligible-p fast installed))
            (nelix-fast-aot-upgrade-plan-from-fast fast installed)
          (append (nelix-fast-upgrade-plan-default fast installed)
                  (and (nelix-fast-aot-enabled-p)
                       (list :aot-skipped
                             (nelix-fast--aot-skipped fast)))))))))

(provide 'nelix-fast)
;;; nelix-fast.el ends here
