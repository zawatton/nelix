;;; nelix-fast.el --- Fast Nelix manifest paths for standalone NeLisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone NeLisp is much slower than Emacs at plist/list-heavy report
;; construction and generic JSON printing.  This module keeps manifest CLI
;; operations on compact package-name sets so list/audit/upgrade-plan avoid the
;; normal row-heavy Emacs compatibility path.

;;; Code:

(require 'anvil-pkg)
(require 'anvil-pkg-compat)
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
    "bootstrap-apt-packages" "pins")
  "Stable DSL v1 subform names accepted by the fast validator.")

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
    (signal 'anvil-pkg-error
            (list "NELIX_NELISP_AOT=1 requested, but nelix-aot-manifest-engine is not loadable"))))

(defun nelix-fast--target-cache ()
  "Return a hash table for generated package target aliases."
  (unless nelix-fast--target-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-nixpkgs-overrides)
        (dolist (entry nelix-package-nixpkgs-overrides)
          (puthash (car entry) (cdr entry) cache)))
      (when (boundp 'nelix-package-install-aliases)
        (dolist (entry nelix-package-install-aliases)
          (puthash (car entry) (cdr entry) cache)))
      (setq nelix-fast--target-cache cache)))
  nelix-fast--target-cache)

(defun nelix-fast--pname-cache ()
  "Return a hash table for generated package pnames."
  (unless nelix-fast--pname-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-pname-overrides)
        (dolist (entry nelix-package-pname-overrides)
          (puthash (car entry) (cdr entry) cache)))
      (setq nelix-fast--pname-cache cache)))
  nelix-fast--pname-cache)

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
    (let* ((profile (expand-file-name (or profile-dir anvil-pkg-profile-dir)))
           (script
            "\"$1\" profile list --profile \"$2\" | sed -n 's/\\x1b\\[[0-9;]*m//g; s/^Name:[[:space:]]*//p'")
           (res (anvil-pkg-compat-call-process
                 "sh"
                 (list "-c" script "nelix-fast-profile-list"
                       anvil-pkg-nix-program profile))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'anvil-pkg-nix-failed
                (list (format "nix profile list failed (exit %s): %s"
                              (plist-get res :exit)
                              (anvil-pkg-compat-string-trim
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
  "Return a hash table mapping normalized profile names to actual names."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (name names map)
      (when (and (stringp name) (> (length name) 0))
        (puthash name name map)
        (puthash (nelix-fast--strip-duplicate-suffix name) name map)))))

(defun nelix-fast--find-name (candidates index)
  "Return the installed name matching any member of CANDIDATES in INDEX."
  (let ((found nil))
    (dolist (name candidates found)
      (when (and (null found) (gethash name index))
        (setq found (gethash name index))))))

(defun nelix-fast--aot-field (value)
  "Return VALUE as a safe Nelix AOT line-protocol field."
  (let ((field (nelix-fast--target-name value)))
    (when (or (string-match-p "\n" field)
              (string-match-p "\t" field))
      (signal 'anvil-pkg-error
              (list (format "nelix-fast AOT field contains tab/newline: %S"
                            field))))
    field))

(defun nelix-fast--aot-line (&rest fields)
  "Return one tab-separated AOT line for FIELDS."
  (concat (mapconcat #'nelix-fast--aot-field fields "\t") "\n"))

(defun nelix-fast--target-rows (manifest)
  "Return compact target rows for MANIFEST."
  (let ((targets (append (plist-get manifest :emacs)
                         (plist-get manifest :linux)
                         (plist-get manifest :debian-tools)))
        rows)
    (dolist (target targets (nreverse rows))
      (push (list :target target
                  :name (nelix-fast--target-name target)
                  :candidates (nelix-fast-target-candidates target))
            rows))))

(defun nelix-fast-load-manifest (manifest-file)
  "Load MANIFEST-FILE and compile it into the fast manifest shape."
  (let* ((manifest (nelix-manifest-load manifest-file))
         (rows (nelix-fast--target-rows manifest))
         (desired-set (make-hash-table :test 'equal))
         (desired-names nil)
         (pins (plist-get manifest :pins))
         (pins-set (nelix-fast--name-set pins)))
    (dolist (row rows)
      (push (plist-get row :name) desired-names)
      (dolist (candidate (plist-get row :candidates))
        (puthash candidate t desired-set)
        (puthash (nelix-fast--strip-duplicate-suffix candidate)
                 t
                 desired-set)))
    (list :file (plist-get manifest :file)
          :name (plist-get manifest :name)
          :profile (plist-get manifest :profile)
          :backend 'nix
          :backend-selection '(:backend nix :system x86_64-linux :fallback :nelisp-fast)
          :system 'x86_64-linux
          :targets rows
          :desired-order (nreverse desired-names)
          :desired-set desired-set
          :pins-order pins
          :pins-set pins-set
          :bootstrap-apt (plist-get manifest :bootstrap-apt))))

(defun nelix-fast-list ()
  "Return installed profile names through the NeLisp fast path."
  (nelix-fast-profile-names))

(defun nelix-fast--read-file-as-string (path)
  "Return PATH contents as a string."
  (cond
   ((and (fboundp 'anvil-pkg-compat--standalone-nelisp-p)
         (anvil-pkg-compat--standalone-nelisp-p)
         (fboundp 'rdf))
    (or (rdf path) ""))
   ((fboundp 'nelisp-core-read-file-as-string)
    (nelisp-core-read-file-as-string path))
   ((fboundp 'insert-file-contents)
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string)))
   ((fboundp 'anvil-pkg-compat-read-file)
    (anvil-pkg-compat-read-file path))
   (t
    (signal 'anvil-pkg-error
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
       (signal 'anvil-pkg-error
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
        (signal 'anvil-pkg-error
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
      (signal 'anvil-pkg-error
              (list (format "%s must be a string or symbol, got %S"
                            caller value)))))))

(defun nelix-fast--dsl-string-list (caller values)
  "Normalize VALUES to a string list for CALLER."
  (mapcar (lambda (value)
            (cond
             ((stringp value) value)
             ((symbolp value) (symbol-name value))
             (t
              (signal 'anvil-pkg-error
                      (list (format "%s must contain strings or symbols, got %S"
                                    caller value))))))
          values))

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
      (signal 'anvil-pkg-error
              (list "nelix-fast validate: top-level nelix-manifest is not DSL v1")))
    (unless (= 1 (length environment-forms))
      (signal 'anvil-pkg-error
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
        (signal 'anvil-pkg-error
                (list (format "nelix-fast validate: malformed DSL form %S"
                              form))))
      (let ((name (symbol-name (car form))))
        (unless (member name nelix-fast--environment-form-names)
          (signal 'anvil-pkg-error
                  (list (format "nelix-fast validate: unknown DSL form %S"
                                (car form)))))
        (when (member name seen)
          (signal 'anvil-pkg-error
                  (list (format "nelix-fast validate: duplicate DSL form %S"
                                (car form)))))
        (push name seen)))))

(defun nelix-fast--environment-imports (environment-form)
  "Return import strings from ENVIRONMENT-FORM without evaluating variables."
  (let (imports)
    (dolist (form (cdr environment-form) (nreverse imports))
      (when (and (consp form)
                 (nelix-fast--symbol-name-p (car form) "imports"))
        (dolist (item (cdr form))
          (unless (stringp item)
            (signal 'anvil-pkg-error
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
        (signal 'anvil-pkg-error
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
       (t
        (signal 'anvil-pkg-error
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
  (when (and (fboundp 'anvil-pkg-compat--standalone-nelisp-p)
             (anvil-pkg-compat--standalone-nelisp-p))
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
                            (cdr form) texts)))))
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
      (dolist (name (cons (plist-get row :name)
                          (plist-get row :candidates)))
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
    (push (nelix-fast--aot-line "profile" (plist-get fast :profile))
          chunks)
    (push (nelix-fast--aot-line "system" (plist-get fast :system))
          chunks)
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (plist-get row :name)
                   (plist-get row :candidates))
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
                    (gethash (plist-get row :name) name-ids))
                   (mapcar (lambda (candidate)
                             (number-to-string
                              (gethash candidate name-ids)))
                           (plist-get row :candidates)))
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
    (let* ((profile (expand-file-name anvil-pkg-profile-dir))
           (script
            (concat
             "if awk -F '\\t' '$1 == \"target-id\" { found = 1 } "
             "END { exit(found ? 0 : 1) }' \"$1\"; then "
             "awk -F '\\t' 'NR == 1 || $1 == \"manifest\" || "
             "$1 == \"profile\" || $1 == \"system\" || "
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
           (res (anvil-pkg-compat-call-process
                 "sh"
                 (list "-c" script
                       "nelix-aot-target-cache"
                       cache-file
                       anvil-pkg-nix-program
                       profile))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'anvil-pkg-nix-failed
                (list (format "nix profile list failed (exit %s): %s"
                              (plist-get res :exit)
                              (anvil-pkg-compat-string-trim
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
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (plist-get row :name)
                   (plist-get row :candidates))
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
    (dolist (row (plist-get fast :targets))
      (push (apply #'nelix-fast--aot-line
                   "target"
                   (plist-get row :name)
                   (plist-get row :candidates))
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
      (and (fboundp 'anvil-pkg-compat--standalone-nelisp-p)
           (anvil-pkg-compat--standalone-nelisp-p))))

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

(defun nelix-fast--json-string-list (values)
  "Return VALUES encoded as a JSON string array."
  (let ((out "[")
        (first t))
    (while values
      (unless first
        (setq out (concat out ",")))
      (setq out (concat out (nelix-fast--json-string (car values))))
      (setq first nil)
      (setq values (cdr values)))
    (concat out "]")))

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
  (concat
   ",\"backend\":\"nix\""
   ",\"backend-selection\":{"
   "\"backend\":\"nix\","
   "\"system\":" (nelix-fast--json-nullable-string
                  (nelix-fast--target-name (plist-get fast :system)))
   ",\"fallback\":" (nelix-fast--json-string fallback)
   "}"))

(defun nelix-fast-aot-audit-from-fast (fast &optional installed-names)
  "Return a compact AOT audit report for compiled FAST manifest data."
  (nelix-fast--ensure-aot-engine)
  (let ((report (nelix-aot-audit
                 (nelix-fast-aot-input-from-fast fast installed-names))))
    (append report
            (list :backend 'nix
                  :backend-selection
                  '(:backend nix
                    :system x86_64-linux
                    :fallback :nelisp-aot)))))

(defun nelix-fast-aot-audit-from-cache (cache-file)
  "Return a compact AOT audit report using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (let ((report (nelix-aot-audit
                 (nelix-fast-aot-input-from-target-cache cache-file))))
    (append report
            (list :backend 'nix
                  :backend-selection
                  '(:backend nix
                    :system x86_64-linux
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
         (desired-set (plist-get fast :desired-set))
         present missing extra)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (plist-get row :candidates)
                     installed-map)))
        (if actual
            (push actual present)
          (push (plist-get row :name) missing))))
    (dolist (name installed)
      (unless (or (gethash name desired-set)
                  (gethash (nelix-fast--strip-duplicate-suffix name)
                           desired-set))
        (push name extra)))
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
               (nelix-fast-aot-input-from-fast fast installed-names))))
    (append plan
            (list :backend 'nix
                  :backend-selection
                  '(:backend nix
                    :system x86_64-linux
                    :fallback :nelisp-aot)))))

(defun nelix-fast-aot-upgrade-plan-from-cache (cache-file)
  "Return a compact AOT upgrade plan using CACHE-FILE."
  (nelix-fast--ensure-aot-engine)
  (let ((plan (nelix-aot-upgrade-plan
               (nelix-fast-aot-input-from-target-cache cache-file))))
    (append plan
            (list :backend 'nix
                  :backend-selection
                  '(:backend nix
                    :system x86_64-linux
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
         (pin-set (plist-get fast :pins-set))
         upgrade pinned missing)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (plist-get row :candidates)
                     installed-map)))
        (if actual
            (if (or (gethash actual pin-set)
                    (gethash (nelix-fast--strip-duplicate-suffix actual)
                             pin-set))
                (push actual pinned)
              (push actual upgrade))
          (push (plist-get row :name) missing))))
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
         (desired-set (plist-get fast :desired-set))
         present missing extra)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (plist-get row :candidates)
                     installed-map)))
        (if actual
            (push actual present)
          (push (plist-get row :name) missing))))
    (dolist (name installed)
      (unless (or (gethash name desired-set)
                  (gethash (nelix-fast--strip-duplicate-suffix name)
                           desired-set))
        (push name extra)))
    (setq present (nreverse present)
          missing (nreverse missing)
          extra (nreverse extra))
    (list :ok (and (null missing) (null extra))
          :manifest (plist-get fast :file)
          :backend 'nix
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
         (pin-set (plist-get fast :pins-set))
         upgrade pinned missing)
    (dolist (row (plist-get fast :targets))
      (let ((actual (nelix-fast--find-name
                     (plist-get row :candidates)
                     installed-map)))
        (if actual
            (if (or (gethash actual pin-set)
                    (gethash (nelix-fast--strip-duplicate-suffix actual)
                             pin-set))
                (push actual pinned)
              (push actual upgrade))
          (push (plist-get row :name) missing))))
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
          :backend 'nix
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
