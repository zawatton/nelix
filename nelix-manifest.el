;;; nelix-manifest.el --- Nelix desired-state manifest operations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Desired-state operations for Nelix.  A manifest is regular Emacs Lisp whose
;; last relevant top-level form calls `nelix-manifest'.  The public operations
;; load that file, resolve its package lists, compare them against the Nelix
;; profile, and then apply/audit/sync as requested.

;;; Code:

(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-compat)
(require 'nelix-backend)
(require 'nelix-registry)

(defvar nelix-manifest-last nil
  "Most recently normalized manifest during `nelix-manifest-load'.")

(defvar nelix-manifest--environment-preload-imports nil
  "When non-nil, `nelix-environment' preloads imports before package forms.")

(defvar nelix-manifest--preloaded-imports nil
  "Dynamically bound import files loaded before a DSL manifest is normalized.")

(defvar nelix-manifest--last-preloaded-imports nil
  "Import files preloaded while reading the current manifest file.")

(defvar nelix-lock-last nil
  "Most recently loaded lock plist during `nelix-lock-read'.")

(defvar nelix-manifest--nelisp-package-target-cache nil
  "Standalone NeLisp cache for generated Emacs package target aliases.")

(defvar nelix-manifest--nelisp-package-pname-cache nil
  "Standalone NeLisp cache for generated Emacs package pnames.")

(defconst nelix-manifest-known-keys
  '(:name :profile :nix-channel :emacs :linux :debian-tools
    :bootstrap-apt :pins :imports :backend-policy :package-rows
    :linux-package-rows :version-pins :remove-policy)
  "Keyword set accepted by `nelix-manifest'.")

(defconst nelix-lock-schema-version 2
  "Current stable Nelix lock schema version.")

(defconst nelix-lock-schema-name "nelix-lock"
  "Stable schema name recorded in Nelix lock files.")

(defconst nelix-environment-dsl-version 1
  "Stable version of the public `nelix-environment' manifest DSL.")

(defconst nelix-environment-dsl-forms
  '(name profile nix-channel imports backend-policy emacs-packages
    linux-packages debian-tools bootstrap-apt-packages pins package
    linux-package version-pin remove-policy)
  "Stable subform names accepted by `nelix-environment' DSL v1.")

(defconst nelix-environment-dsl-manifest-keys
  '("name" "profile" "nix-channel" "imports" "backend-policy"
    "emacs" "linux" "debian-tools" "bootstrap-apt" "pins"
    "package-rows" "linux-package-rows" "version-pins"
    "remove-policy")
  "Stable manifest keys produced by `nelix-environment' DSL v1.")

(defconst nelix-environment-dsl-form-map
  '(("name" . "name")
    ("profile" . "profile")
    ("nix-channel" . "nix-channel")
    ("imports" . "imports")
    ("backend-policy" . "backend-policy")
    ("emacs-packages" . "emacs")
    ("linux-packages" . "linux")
    ("debian-tools" . "debian-tools")
    ("bootstrap-apt-packages" . "bootstrap-apt")
    ("pins" . "pins")
    ("package" . "package-rows")
    ("linux-package" . "linux-package-rows")
    ("version-pin" . "version-pins")
    ("remove-policy" . "remove-policy"))
  "Stable mapping from Nelix environment DSL v1 forms to manifest keys.")

(defconst nelix-environment-dsl-backends
  '(nelix-native nix apt dnf git elpa homebrew scoop winget)
  "Stable backend names accepted in `nelix-environment' backend-policy forms.")

(defconst nelix-environment-dsl-repeated-forms
  '(package linux-package version-pin)
  "DSL v1 forms that may appear more than once in `nelix-environment'.")

(defconst nelix-environment-dsl-package-option-keys
  '(:backend :pin :version :profile :group :feature :platform :when)
  "Stable keyword options accepted by DSL v1 package rows.")

(defconst nelix-environment-dsl-package-option-types
  '((:backend . "backend-symbol")
    (:pin . "boolean")
    (:version . "string-or-symbol")
    (:profile . "string-or-symbol")
    (:group . "string-or-symbol")
    (:feature . "string-or-symbol")
    (:platform . "string-or-symbol-or-list")
    (:when . "symbol-or-list"))
  "Stable value contracts for DSL v1 package row options.")

(defconst nelix-environment-dsl-package-row-required
  '("kind" "name")
  "Stable package row keys guaranteed by DSL v1 package declarations.")

(defconst nelix-environment-dsl-remove-policy-values
  '(confirm keep prune)
  "Stable remove-policy values accepted by DSL v1.")

(defconst nelix-environment-dsl-deferred-forms
  '("group" "feature" "platform" "platform-when")
  "Nix/Guix-style forms intentionally deferred beyond environment DSL v1.")

(defconst nelix-environment-dsl-forbidden-forms
  '(secret secrets private-repo private-repos credential credentials
    token access-token auth-header)
  "Private-data forms forbidden in `nelix-environment' DSL v1.")

(defconst nelix-lock-schema-required-json-keys
  '("schema" "schema-version" "version" "format" "lock"
    "manifest-digest" "manifest-files" "profile" "backend" "system"
    "nix-channel" "nix-version" "generated-at" "packages")
  "Required JSON keys in the public Nelix lock schema v2.")

(defconst nelix-lock-schema-package-required-json-keys
  '("name" "target" "backend" "system" "source")
  "Required package row keys in the public Nelix lock schema v2.")

(defconst nelix-lock-schema-nix-package-required-json-keys
  '("attr-path")
  "Required Nix package row keys in the public Nelix lock schema v2.")

(defconst nelix-lock-schema-native-package-required-json-keys
  '("recipe-version" "recipe-source" "recipe-install"
    "recipe-dependencies" "recipe-class")
  "Required native package row keys in the public Nelix lock schema v2.")

(defconst nelix-lock-schema-commands
  '("lock" "lock validate" "lock diff" "lock migrate")
  "Public CLI commands that own lockfile schema v2 lifecycle.")

(defconst nelix-lock-schema-compatibility
  '("legacy-v1-readable-migrate-required"
    "legacy-v2-readable"
    "future-version-rejected")
  "Stable compatibility policy labels for lockfile schema v2.")

(defconst nelix-transaction-schema-name "nelix-apply-transaction"
  "Stable schema name recorded in Nelix apply transaction records.")

(defconst nelix-transaction-schema-version 1
  "Current stable Nelix apply transaction record schema version.")

(defconst nelix-transaction-record-required-keys
  '(:schema :schema-version :id :status :manifest :profile
    :started-at :updated-at :plan :transaction :executed
    :rollback-plan :rollback :error)
  "Required top-level keys in a Nelix apply transaction record.")

(defconst nelix-transaction-plan-required-keys
  '(:operation :manifest :commands)
  "Required plan keys in a Nelix apply transaction record.")

(defconst nelix-transaction-metadata-required-keys
  '(:enabled :backend :profile :system :rollback-on-error
    :generation-captured :rollback-available :before-generation
    :before-generation-error :after-generation :record-id
    :record-file :record-started-at :record-status)
  "Required transaction metadata keys in a Nelix apply transaction record.")

(defconst nelix-transaction-rollback-plan-available-required-keys
  '(:operation :generation :argv)
  "Required rollback-plan keys when transaction rollback is available.")

(defconst nelix-transaction-status-values
  '("started" "running" "ok" "error")
  "Stable status values used in Nelix transaction records.")

(defconst nelix-transaction-rollback-unavailable-reasons
  '("transaction-disabled" "rollback-disabled" "before-generation-missing")
  "Stable rollback-plan reasons when rollback is unavailable.")

(defconst nelix-transaction-rollback-result-keys
  '("attempted" "ok" "generation" "after-rollback-generation"
    "verified" "reason" "error")
  "Stable rollback result keys that may be present after apply failure.")

(defcustom nelix-transaction-log-root nil
  "Directory used for Nelix apply transaction records.

When nil, records are written under the user's state directory at
~/.local/state/nelix/transactions."
  :type '(choice (const :tag "Default state directory" nil)
                 directory)
  :group 'anvil-pkg)

(defvar nelix-manifest--transaction-record-counter 0
  "Process-local suffix counter for generated transaction record files.")

(defun nelix-schema--manifest-dsl-v1 ()
  "Return the public manifest DSL v1 schema summary."
  (list :name "manifest-dsl-v1"
        :schema "nelix-environment"
        :schema-version nelix-environment-dsl-version
        :entrypoint "nelix-environment"
        :json-schema "docs/schema/nelix-manifest-dsl-v1.schema.json"
        :forms (mapcar #'symbol-name nelix-environment-dsl-forms)
        :manifest-keys nelix-environment-dsl-manifest-keys
        :form-map (mapcar (lambda (pair)
                            (list :form (car pair)
                                  :manifest-key (cdr pair)))
                          nelix-environment-dsl-form-map)
        :backends (mapcar #'symbol-name nelix-environment-dsl-backends)
        :backend-policy "backend-symbols-or-os-rows"
        :package-forms '("package" "linux-package")
        :package-options (mapcar #'symbol-name
                                 nelix-environment-dsl-package-option-keys)
        :package-option-types
        (mapcar (lambda (pair)
                  (list :option (symbol-name (car pair))
                        :type (cdr pair)))
                nelix-environment-dsl-package-option-types)
        :package-row-required nelix-environment-dsl-package-row-required
        :package-row-semantics "metadata-plus-target-list"
        :version-pin "metadata-plus-pin-name"
        :remove-policy-values (mapcar #'symbol-name
                                      nelix-environment-dsl-remove-policy-values)
        :deferred-forms nelix-environment-dsl-deferred-forms
        :forbidden-forms (mapcar #'symbol-name
                                 nelix-environment-dsl-forbidden-forms)
        :remove-policy "manifest-declares-cli-still-confirms"
        :classification "package-options-group-feature"
        :platform-conditions "package-option-platform-metadata"
        :private-data "forbidden"
        :stable t))

(defun nelix-schema--lock-v2 ()
  "Return the public lockfile schema v2 summary."
  (list :name "lock-v2"
        :schema nelix-lock-schema-name
        :schema-version nelix-lock-schema-version
        :version nelix-lock-schema-version
        :format "sexp"
        :source-of-truth "MANIFEST.nelix-lock"
        :json-output "nelix --json lock MANIFEST"
        :commands nelix-lock-schema-commands
        :compatibility nelix-lock-schema-compatibility
        :migration "nelix lock migrate MANIFEST [--dry-run]"
        :validation "nelix lock validate MANIFEST"
        :diff "nelix lock diff MANIFEST"
        :json-schema "docs/schema/nelix-lock-v2.schema.json"
        :required nelix-lock-schema-required-json-keys
        :package-required nelix-lock-schema-package-required-json-keys
        :nix-package-required nelix-lock-schema-nix-package-required-json-keys
        :native-package-required
        nelix-lock-schema-native-package-required-json-keys
        :stable t))

(defun nelix-schema--keyword-names (keys)
  "Return stable schema names for keyword KEYS."
  (mapcar (lambda (key)
            (let ((name (symbol-name key)))
              (if (string-prefix-p ":" name)
                  (substring name 1)
                name)))
          keys))

(defun nelix-schema--transaction-v1 ()
  "Return the public apply transaction record schema v1 summary."
  (list :name "transaction-v1"
        :schema nelix-transaction-schema-name
        :schema-version nelix-transaction-schema-version
        :format "sexp"
        :json-schema "docs/schema/nelix-transaction-v1.schema.json"
        :required (nelix-schema--keyword-names
                   nelix-transaction-record-required-keys)
        :plan-required (nelix-schema--keyword-names
                        nelix-transaction-plan-required-keys)
        :transaction-required
        (nelix-schema--keyword-names
         nelix-transaction-metadata-required-keys)
        :rollback-plan-required '("available")
        :rollback-plan-available-required
        (nelix-schema--keyword-names
         nelix-transaction-rollback-plan-available-required-keys)
        :status-values nelix-transaction-status-values
        :rollback-plan-unavailable-reasons
        nelix-transaction-rollback-unavailable-reasons
        :rollback-result-keys nelix-transaction-rollback-result-keys
        :recovery "nelix transaction recover ID|FILE (--dry-run|--execute)"
        :executed-required '("action" "name")
        :stable t))

;;;###autoload
(defun nelix-schema (&optional name)
  "Return public Nelix schema contract information for NAME.

NAME may be nil, \"all\", \"manifest-dsl-v1\", \"lock-v2\", or
\"transaction-v1\"."
  (let ((schemas (list (nelix-schema--manifest-dsl-v1)
                       (nelix-schema--lock-v2)
                       (nelix-schema--transaction-v1))))
    (cond
     ((or (null name) (equal name "all"))
      (list :status 'ok
            :schemas schemas))
     ((member name '("manifest-dsl-v1" "lock-v2" "transaction-v1"))
      (append (list :status 'ok)
              (car (cl-remove-if-not
                    (lambda (schema)
                      (equal (plist-get schema :name) name))
                    schemas))))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix schema: unknown schema %S" name)))))))

(defun nelix-manifest--plist-keys (plist)
  "Return keyword keys from PLIST, rejecting malformed plists."
  (let ((rest plist)
        keys)
    (while rest
      (unless (and (consp rest) (consp (cdr rest)))
        (signal 'anvil-pkg-error
                (list (format "nelix-manifest: malformed plist %S" plist))))
      (push (car rest) keys)
      (setq rest (cddr rest)))
    (nreverse keys)))

(defun nelix-manifest--normalize-string (caller value)
  "Normalize VALUE to a non-empty string for CALLER."
  (cond
   ((stringp value)
    (let ((trimmed (anvil-pkg-compat-string-trim value)))
      (if (zerop (length trimmed))
          (signal 'anvil-pkg-error
                  (list (format "%s: value must be non-empty, got %S"
                                caller value)))
        trimmed)))
   ((symbolp value) (symbol-name value))
   (t
    (signal 'anvil-pkg-error
            (list (format "%s: value must be string or symbol, got %S"
                          caller value))))))

(defun nelix-manifest--normalize-symbol-or-string-list (caller value)
  "Validate VALUE as a list of symbols/strings for CALLER."
  (cond
   ((null value) nil)
   ((listp value)
    (mapcar
     (lambda (item)
       (cond
        ((stringp item) (nelix-manifest--normalize-string caller item))
        ((symbolp item) item)
        (t
         (signal 'anvil-pkg-error
                 (list (format "%s: list values must be strings or symbols, got %S"
                               caller item))))))
     value))
   (t
    (signal 'anvil-pkg-error
            (list (format "%s: value must be a list, got %S"
                          caller value))))))

(defun nelix-manifest--normalize-string-list (caller value)
  "Validate VALUE as a list of strings or symbols and return strings."
  (mapcar (lambda (item)
            (nelix-manifest--normalize-string caller item))
          (nelix-manifest--normalize-symbol-or-string-list caller value)))

(defun nelix-manifest--normalize-imports (value)
  "Validate VALUE as an import path list."
  (nelix-manifest--normalize-string-list "nelix-manifest :imports" value))

(defun nelix-manifest--normalize-remove-policy (value)
  "Validate VALUE as a remove-policy symbol."
  (cond
   ((null value) 'confirm)
   ((memq value nelix-environment-dsl-remove-policy-values) value)
   (t
    (signal 'anvil-pkg-error
            (list (format "nelix-manifest :remove-policy: unsupported value %S"
                          value))))))

(defun nelix-manifest--package-row-options (row)
  "Return ROW option plist without the required DSL identity keys."
  (let ((rest row)
        options)
    (while rest
      (let ((key (car rest))
            (value (cadr rest)))
        (unless (memq key '(:kind :name))
          (setq options (append options (list key value)))))
      (setq rest (cddr rest)))
    options))

(defun nelix-manifest--normalize-package-rows (caller rows &optional expected-kind)
  "Validate ROWS as DSL package metadata rows for CALLER."
  (cond
   ((null rows) nil)
   ((listp rows)
    (mapcar
     (lambda (row)
       (unless (and (listp row)
                    (condition-case nil
                        (= 0 (% (length row) 2))
                      (error nil)))
         (signal 'anvil-pkg-error
                 (list (format "%s: malformed package row %S"
                               caller row))))
       (let ((kind (plist-get row :kind))
             (name (plist-get row :name)))
         (unless (and (memq kind '(package linux-package))
                      (or (symbolp name) (stringp name)))
           (signal 'anvil-pkg-error
                   (list (format "%s: malformed package row %S"
                                 caller row))))
         (when (and expected-kind (not (eq kind expected-kind)))
           (signal 'anvil-pkg-error
                   (list (format "%s: expected :kind %S, got %S"
                                 caller expected-kind kind))))
         (nelix-environment--validate-package-options
          (format "%s row %S" caller name)
          (nelix-manifest--package-row-options row)))
       row)
     rows))
   (t
    (signal 'anvil-pkg-error
            (list (format "%s: value must be a list, got %S"
                          caller rows))))))

(defun nelix-manifest--normalize-version-pins (value)
  "Validate VALUE as DSL version pin metadata rows."
  (cond
   ((null value) nil)
   ((listp value)
    (mapcar
     (lambda (row)
       (unless (and (listp row)
                    (or (symbolp (plist-get row :name))
                        (stringp (plist-get row :name)))
                    (or (symbolp (plist-get row :version))
                        (stringp (plist-get row :version))))
         (signal 'anvil-pkg-error
                 (list (format "nelix-manifest :version-pins: malformed row %S"
                               row))))
       row)
     value))
   (t
    (signal 'anvil-pkg-error
            (list (format "nelix-manifest :version-pins: value must be a list, got %S"
                          value))))))

(defun nelix-environment--single-value (caller args)
  "Return the only value in ARGS for CALLER, or signal a DSL error."
  (unless (= 1 (length args))
    (signal 'anvil-pkg-error
            (list (format "%s: expected exactly one value, got %S"
                          caller args))))
  (car args))

(defun nelix-environment--list-value (args)
  "Return a DSL value expression for package-like ARGS."
  (if (= 1 (length args))
      (car args)
    (list 'quote args)))

(defun nelix-environment--imports-value (args)
  "Return a DSL value expression for import ARGS."
  (cons 'list args))

(defun nelix-environment--backend-policy-value (args)
  "Return a manifest backend-policy value expression for ARGS."
  (nelix-environment--validate-backend-policy args)
  (list 'quote args))

(defun nelix-environment--literal-list-expr (values)
  "Return an expression that evaluates to literal VALUES."
  (list 'quote values))

(defun nelix-environment--append-list-expr (left right)
  "Return an expression appending list expressions LEFT and RIGHT."
  (cond
   ((null left) right)
   ((null right) left)
   (t (list 'append left right))))

(defun nelix-environment--forbidden-option-p (key)
  "Return non-nil when package option KEY embeds private data."
  (and (keywordp key)
       (let ((name (substring (symbol-name key) 1)))
         (member name (mapcar #'symbol-name
                              nelix-environment-dsl-forbidden-forms)))))

(defun nelix-environment--validate-package-options (caller options)
  "Validate package row OPTIONS for CALLER."
  (let ((rest options))
    (while rest
      (unless (and (consp rest) (consp (cdr rest)) (keywordp (car rest)))
        (signal 'anvil-pkg-error
                (list (format "%s: options must be keyword pairs, got %S"
                              caller options))))
      (let ((key (car rest))
            (value (cadr rest)))
        (when (nelix-environment--forbidden-option-p key)
          (signal 'anvil-pkg-error
                  (list (format "%s: private data option %S is forbidden"
                                caller key))))
        (unless (memq key nelix-environment-dsl-package-option-keys)
          (signal 'anvil-pkg-error
                  (list (format "%s: unknown option %S" caller key))))
        (when (eq key :backend)
          (unless (symbolp value)
            (signal 'anvil-pkg-error
                    (list (format "%s: :backend must be a symbol, got %S"
                                  caller value))))
          (nelix-environment--validate-backend-symbol value))
        (when (eq key :pin)
          (unless (memq value '(nil t))
            (signal 'anvil-pkg-error
                    (list (format "%s: :pin must be t or nil, got %S"
                                  caller value)))))
        (when (memq key '(:version :profile :group :feature))
          (unless (or (symbolp value) (stringp value))
            (signal 'anvil-pkg-error
                    (list (format "%s: %S must be a string or symbol, got %S"
                                  caller key value)))))
        (when (eq key :platform)
          (unless (or (symbolp value) (stringp value) (listp value))
            (signal 'anvil-pkg-error
                    (list (format "%s: :platform must be a string, symbol, or list, got %S"
                                  caller value)))))
        (when (eq key :when)
          (unless (or (symbolp value) (listp value))
            (signal 'anvil-pkg-error
                    (list (format "%s: :when must be a symbol or list, got %S"
                                  caller value)))))
        (setq rest (cddr rest))))))

(defun nelix-environment--package-row (kind args)
  "Return a validated package row plist for KIND and ARGS."
  (unless args
    (signal 'anvil-pkg-error
            (list (format "nelix-environment %s: package name is required"
                          kind))))
  (let ((name (car args))
        (options (cdr args)))
    (unless (or (symbolp name) (stringp name))
      (signal 'anvil-pkg-error
              (list (format "nelix-environment %s: name must be string or symbol, got %S"
                            kind name))))
    (nelix-environment--validate-package-options
     (format "nelix-environment %s %S" kind name)
     options)
    (append (list :kind kind :name name) options)))

(defun nelix-environment--version-pin-row (args)
  "Return a validated version-pin row plist from ARGS."
  (unless (= 2 (length args))
    (signal 'anvil-pkg-error
            (list (format "nelix-environment version-pin: expected NAME VERSION, got %S"
                          args))))
  (let ((name (car args))
        (version (cadr args)))
    (unless (or (symbolp name) (stringp name))
      (signal 'anvil-pkg-error
              (list (format "nelix-environment version-pin: name must be string or symbol, got %S"
                            name))))
    (unless (or (symbolp version) (stringp version))
      (signal 'anvil-pkg-error
              (list (format "nelix-environment version-pin: version must be string or symbol, got %S"
                            version))))
    (list :name name :version version)))

(defun nelix-environment--remove-policy-value (args)
  "Return the validated remove-policy value from ARGS."
  (let ((policy (nelix-environment--single-value
                 "nelix-environment remove-policy"
                 args)))
    (unless (memq policy nelix-environment-dsl-remove-policy-values)
      (signal 'anvil-pkg-error
              (list (format "nelix-environment remove-policy: unsupported value %S"
                            policy))))
    (list 'quote policy)))

(defun nelix-environment--preload-imports (imports)
  "Load DSL IMPORTS relative to `default-directory' before package variables."
  (let ((normalized (nelix-manifest--normalize-imports imports))
        loaded)
    (dolist (path normalized (nreverse loaded))
      (let ((expanded (nelix-manifest--expand-path path default-directory)))
        (unless (anvil-pkg-compat-file-exists-p expanded)
          (signal 'anvil-pkg-error
                  (list (format "nelix-environment: import file does not exist: %s"
                                expanded))))
        (nelix-manifest--load-elisp-file expanded)
        (push expanded loaded)))))

(defun nelix-environment--validate-backend-symbol (backend)
  "Validate BACKEND against the stable environment DSL v1 backend set."
  (unless (memq backend nelix-environment-dsl-backends)
    (signal 'anvil-pkg-error
            (list (format "nelix-environment backend-policy: unsupported backend %S"
                          backend)))))

(defun nelix-environment--validate-backend-policy-row (row)
  "Validate one OS-specific backend policy ROW."
  (unless (and (consp row) (symbolp (car row)))
    (signal 'anvil-pkg-error
            (list (format "nelix-environment backend-policy: malformed row %S"
                          row))))
  (unless (cdr row)
    (signal 'anvil-pkg-error
            (list (format "nelix-environment backend-policy: row %S has no backends"
                          row))))
  (dolist (backend (cdr row))
    (unless (symbolp backend)
      (signal 'anvil-pkg-error
              (list (format "nelix-environment backend-policy: malformed backend %S"
                            backend))))
    (nelix-environment--validate-backend-symbol backend)))

(defun nelix-environment--validate-backend-policy (args)
  "Validate backend-policy ARGS for the stable environment DSL v1 contract."
  (unless args
    (signal 'anvil-pkg-error
            (list "nelix-environment backend-policy: at least one backend or OS row is required")))
  (cond
   ((cl-every #'symbolp args)
    (dolist (backend args)
      (nelix-environment--validate-backend-symbol backend)))
   ((cl-every (lambda (row)
                (and (consp row) (symbolp (car row))))
              args)
    (dolist (row args)
      (nelix-environment--validate-backend-policy-row row)))
   (t
    (signal 'anvil-pkg-error
            (list "nelix-environment backend-policy: use either backend symbols or OS rows")))))

(defun nelix-environment--form-to-plist-pair (form)
  "Translate one `nelix-environment' FORM into a plist pair."
  (unless (and (consp form) (symbolp (car form)))
    (signal 'anvil-pkg-error
            (list (format "nelix-environment: malformed form %S" form))))
  (let ((head (car form))
        (args (cdr form)))
    (when (memq head nelix-environment-dsl-forbidden-forms)
      (signal 'anvil-pkg-error
              (list (format "nelix-environment: private data form %S is forbidden"
                            head))))
    (when (member (symbol-name head) nelix-environment-dsl-deferred-forms)
      (signal 'anvil-pkg-error
              (list (format "nelix-environment: form %S is reserved for a later DSL version"
                            head))))
    (pcase head
      ((or 'package 'linux-package 'version-pin 'remove-policy)
       (signal 'anvil-pkg-error
               (list (format "nelix-environment: form %S is handled by the DSL aggregator"
                             head))))
      ('name
       (list :name (nelix-environment--single-value "nelix-environment name"
                                                    args)))
      ('profile
       (list :profile
             (nelix-environment--single-value "nelix-environment profile"
                                              args)))
      ('nix-channel
       (list :nix-channel
             (nelix-environment--single-value "nelix-environment nix-channel"
                                              args)))
      ('imports
       (list :imports (nelix-environment--imports-value args)))
      ('backend-policy
       (list :backend-policy (nelix-environment--backend-policy-value args)))
      ('emacs-packages
       (list :emacs (nelix-environment--list-value args)))
      ('linux-packages
       (list :linux (nelix-environment--list-value args)))
      ('debian-tools
       (list :debian-tools (nelix-environment--list-value args)))
      ('bootstrap-apt-packages
       (list :bootstrap-apt (nelix-environment--list-value args)))
      ('pins
       (list :pins (list 'quote args)))
      (_
       (signal 'anvil-pkg-error
               (list (format "nelix-environment: unknown form %S" head)))))))

;;;###autoload
(defmacro nelix-environment (&rest forms)
  "Nix/Guix-style manifest DSL v1.

This macro is a stable front-end for `nelix-manifest'.  Existing
`nelix-manifest' plists remain supported; new manifests should prefer
forms such as:

  (nelix-environment
    (name \"default\")
    (profile \"default\")
    (nix-channel \"nixpkgs\")
    (imports \"custom-lisp/nelix-linux.el\")
    (backend-policy (gnu/linux nix nelix-native))
    (emacs-packages nelix-package-emacs-packages)
    (linux-packages nelix-linux-base-nix-packages)
    (package magit :backend elpa :group editor :feature git)
    (linux-package ripgrep :backend nix :pin t)
    (version-pin fd \"10.2.0\"))

Package list forms with a single argument evaluate that argument, which
supports generated package variables.  Package list forms with multiple
arguments are treated as a literal package list.  `package' and
`linux-package' rows are repeated metadata rows that also contribute to
the normalized Emacs and Linux target lists."
  (let (plist seen emacs-expr linux-expr pins-expr
              package-rows linux-package-rows version-pin-rows)
    (dolist (form forms)
      (unless (and (consp form) (symbolp (car form)))
        (signal 'anvil-pkg-error
                (list (format "nelix-environment: malformed form %S" form))))
      (let ((head (car form))
            (args (cdr form)))
        (when (and (memq head seen)
                   (not (memq head nelix-environment-dsl-repeated-forms)))
          (signal 'anvil-pkg-error
                  (list (format "nelix-environment: duplicate form %S"
                                head))))
        (push head seen)
        (pcase head
          ('package
           (let ((row (nelix-environment--package-row 'package args)))
             (push row package-rows)
             (setq emacs-expr
                   (nelix-environment--append-list-expr
                    emacs-expr
                    (nelix-environment--literal-list-expr
                     (list (plist-get row :name)))))
             (when (plist-get row :pin)
               (setq pins-expr
                     (nelix-environment--append-list-expr
                      pins-expr
                      (nelix-environment--literal-list-expr
                       (list (plist-get row :name))))))))
          ('linux-package
           (let ((row (nelix-environment--package-row 'linux-package args)))
             (push row linux-package-rows)
             (setq linux-expr
                   (nelix-environment--append-list-expr
                    linux-expr
                    (nelix-environment--literal-list-expr
                     (list (plist-get row :name)))))
             (when (plist-get row :pin)
               (setq pins-expr
                     (nelix-environment--append-list-expr
                      pins-expr
                      (nelix-environment--literal-list-expr
                       (list (plist-get row :name))))))))
          ('version-pin
           (let ((row (nelix-environment--version-pin-row args)))
             (push row version-pin-rows)
             (setq pins-expr
                   (nelix-environment--append-list-expr
                    pins-expr
                    (nelix-environment--literal-list-expr
                     (list (plist-get row :name)))))))
          ('emacs-packages
           (setq emacs-expr
                 (nelix-environment--append-list-expr
                  emacs-expr
                  (nelix-environment--list-value args))))
          ('linux-packages
           (setq linux-expr
                 (nelix-environment--append-list-expr
                  linux-expr
                  (nelix-environment--list-value args))))
          ('pins
           (setq pins-expr
                 (nelix-environment--append-list-expr
                  pins-expr
                  (list 'quote args))))
          ('remove-policy
           (setq plist
                 (append plist
                         (list :remove-policy
                               (nelix-environment--remove-policy-value
                                args)))))
          (_
           (let ((pair (nelix-environment--form-to-plist-pair form)))
             (setq plist (append plist pair)))))))
    (when emacs-expr
      (setq plist (append plist (list :emacs emacs-expr))))
    (when linux-expr
      (setq plist (append plist (list :linux linux-expr))))
    (when pins-expr
      (setq plist (append plist (list :pins pins-expr))))
    (when package-rows
      (setq plist
            (append plist
                    (list :package-rows
                          (list 'quote (nreverse package-rows))))))
    (when linux-package-rows
      (setq plist
            (append plist
                    (list :linux-package-rows
                          (list 'quote (nreverse linux-package-rows))))))
    (when version-pin-rows
      (setq plist
            (append plist
                    (list :version-pins
                          (list 'quote (nreverse version-pin-rows))))))
    (let ((imports-expr (plist-get plist :imports)))
      `(if nelix-manifest--environment-preload-imports
           (let ((nelix-manifest--preloaded-imports
                  ,(and imports-expr
                        `(nelix-environment--preload-imports ,imports-expr))))
             (nelix-manifest ,@plist))
         (nelix-manifest ,@plist)))))

;;;###autoload
(defun nelix-manifest (&rest plist)
  "Return a normalized Nelix manifest plist from PLIST.

Unknown keywords and malformed values signal `anvil-pkg-error'.
The normalized plist is also stored in `nelix-manifest-last' so
`nelix-manifest-load' can recover it after evaluating a manifest
file."
  (let ((keys (nelix-manifest--plist-keys plist)))
    (dolist (key keys)
      (unless (memq key nelix-manifest-known-keys)
        (signal 'anvil-pkg-error
                (list (format "nelix-manifest: unknown keyword %S" key)))))
    (unless (memq :name keys)
      (signal 'anvil-pkg-error
              (list "nelix-manifest: :name is required")))
    (let* ((name (nelix-manifest--normalize-string
                  "nelix-manifest :name" (plist-get plist :name)))
           (profile (if (memq :profile keys)
                        (nelix-manifest--normalize-string
                         "nelix-manifest :profile" (plist-get plist :profile))
                      "default"))
           (channel (if (memq :nix-channel keys)
                        (nelix-manifest--normalize-string
                         "nelix-manifest :nix-channel"
                         (plist-get plist :nix-channel))
                      anvil-pkg-nix-channel))
           (emacs (nelix-manifest--normalize-symbol-or-string-list
                   "nelix-manifest :emacs" (plist-get plist :emacs)))
           (linux (nelix-manifest--normalize-string-list
                   "nelix-manifest :linux" (plist-get plist :linux)))
           (debian-tools (nelix-manifest--normalize-string-list
                          "nelix-manifest :debian-tools"
                          (plist-get plist :debian-tools)))
           (bootstrap-apt (nelix-manifest--normalize-symbol-or-string-list
                           "nelix-manifest :bootstrap-apt"
                           (plist-get plist :bootstrap-apt)))
           (pins (nelix-manifest--normalize-string-list
                  "nelix-manifest :pins" (plist-get plist :pins)))
           (imports (nelix-manifest--normalize-imports
                     (plist-get plist :imports)))
           (package-rows (nelix-manifest--normalize-package-rows
                          "nelix-manifest :package-rows"
                          (plist-get plist :package-rows)
                          'package))
           (linux-package-rows (nelix-manifest--normalize-package-rows
                                "nelix-manifest :linux-package-rows"
                                (plist-get plist :linux-package-rows)
                                'linux-package))
           (version-pins (nelix-manifest--normalize-version-pins
                          (plist-get plist :version-pins)))
           (remove-policy (nelix-manifest--normalize-remove-policy
                           (plist-get plist :remove-policy)))
           (preloaded-imports nelix-manifest--preloaded-imports)
           (backend-policy (plist-get plist :backend-policy)))
      (when (and backend-policy (not (listp backend-policy)))
        (signal 'anvil-pkg-error
                (list (format "nelix-manifest :backend-policy: value must be a list, got %S"
                              backend-policy))))
      (when preloaded-imports
        (setq nelix-manifest--last-preloaded-imports preloaded-imports))
      (setq nelix-manifest-last
            (list :name name
                  :profile profile
                  :nix-channel channel
                  :emacs emacs
                  :linux linux
                  :debian-tools debian-tools
                  :bootstrap-apt bootstrap-apt
                  :pins pins
                  :imports (or preloaded-imports imports)
                  :backend-policy backend-policy
                  :package-rows package-rows
                  :linux-package-rows linux-package-rows
                  :version-pins version-pins
                  :remove-policy remove-policy)))))

(defun nelix-manifest--expand-path (path base-dir)
  "Expand PATH relative to BASE-DIR."
  (expand-file-name path base-dir))

(defun nelix-manifest--load-elisp-file (file)
  "Load FILE with its directory as `default-directory'."
  (let ((default-directory (file-name-directory (expand-file-name file))))
    (load (expand-file-name file) nil nil t)))

(defun nelix-manifest--load-imports (manifest manifest-file)
  "Load import files declared by MANIFEST relative to MANIFEST-FILE."
  (let ((base-dir (file-name-directory (expand-file-name manifest-file)))
        loaded)
    (dolist (path (plist-get manifest :imports) (nreverse loaded))
      (let ((expanded (nelix-manifest--expand-path path base-dir)))
        (unless (anvil-pkg-compat-file-exists-p expanded)
          (signal 'anvil-pkg-error
                  (list (format "nelix-manifest: import file does not exist: %s"
                                expanded))))
        (nelix-manifest--load-elisp-file expanded)
        (push expanded loaded)))))

;;;###autoload
(defun nelix-manifest-load (file)
  "Load FILE and return its normalized Nelix manifest plist."
  (let* ((expanded (expand-file-name file))
         (nelix-manifest-last nil)
         (nelix-manifest--environment-preload-imports t)
         (nelix-manifest--last-preloaded-imports nil))
    (unless (anvil-pkg-compat-file-exists-p expanded)
      (signal 'anvil-pkg-error
              (list (format "nelix-manifest-load: file does not exist: %s"
                            expanded))))
    (nelix-manifest--load-elisp-file expanded)
    (unless nelix-manifest-last
      (signal 'anvil-pkg-error
              (list (format "nelix-manifest-load: %s did not call nelix-manifest"
                            expanded))))
    (let ((manifest (copy-sequence nelix-manifest-last)))
      (setq manifest (plist-put manifest :file expanded))
      (setq manifest
            (plist-put manifest :imports
                       (or nelix-manifest--last-preloaded-imports
                           (nelix-manifest--load-imports manifest expanded))))
      manifest)))

(defun nelix-manifest--dedupe (items)
  "Return ITEMS without duplicates, preserving the first occurrence."
  (if (anvil-pkg-compat--standalone-nelisp-p)
      (let ((seen (make-hash-table :test 'equal))
            (out nil))
        (dolist (item items (nreverse out))
          (unless (gethash item seen)
            (puthash item t seen)
            (push item out))))
    (let ((seen nil)
          (out nil))
      (dolist (item items (nreverse out))
        (unless (member item seen)
          (push item seen)
          (push item out))))))

(defun nelix-manifest--nelisp-package-target-cache ()
  "Return a hash table for generated package target aliases."
  (unless nelix-manifest--nelisp-package-target-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-nixpkgs-overrides)
        (dolist (entry nelix-package-nixpkgs-overrides)
          (puthash (car entry) (cdr entry) cache)))
      (when (boundp 'nelix-package-install-aliases)
        (dolist (entry nelix-package-install-aliases)
          (puthash (car entry) (cdr entry) cache)))
      (setq nelix-manifest--nelisp-package-target-cache cache)))
  nelix-manifest--nelisp-package-target-cache)

(defun nelix-manifest--nelisp-package-pname-cache ()
  "Return a hash table for generated package pnames."
  (unless nelix-manifest--nelisp-package-pname-cache
    (let ((cache (make-hash-table :test 'equal)))
      (when (boundp 'nelix-package-pname-overrides)
        (dolist (entry nelix-package-pname-overrides)
          (puthash (car entry) (cdr entry) cache)))
      (setq nelix-manifest--nelisp-package-pname-cache cache)))
  nelix-manifest--nelisp-package-pname-cache)

(defun nelix-manifest--nelisp-upgrade-candidate-names (package)
  "Return lightweight profile-name candidates for PACKAGE on NeLisp."
  (let* ((display (nelix-manifest--target-name package))
         (target (gethash package
                          (nelix-manifest--nelisp-package-target-cache)))
         (target-name (and target (nelix-manifest--target-name target)))
         (target-tail (and target-name
                           (nelix-manifest--attr-tail-name target-name)))
         (pname (gethash package
                         (nelix-manifest--nelisp-package-pname-cache)))
         (out nil))
    (dolist (name (list display target-name target-tail pname)
                  (nreverse out))
      (when (and (stringp name)
                 (> (length name) 0)
                 (not (member name out)))
        (push name out)))))

(defun nelix-manifest--nelisp-upgrade-find-entry (package index)
  "Return installed entry for PACKAGE from name INDEX."
  (let ((found nil))
    (dolist (name (nelix-manifest--nelisp-upgrade-candidate-names package)
                  found)
      (when (and (null found) (gethash name index))
        (setq found (gethash name index))))))

(defun nelix-manifest--resolve-emacs-target (package)
  "Resolve Emacs PACKAGE through generated helpers when available."
  (cond
   ((and (anvil-pkg-compat--standalone-nelisp-p)
         (or (boundp 'nelix-package-nixpkgs-overrides)
             (boundp 'nelix-package-install-aliases)))
    (or (gethash package
                 (nelix-manifest--nelisp-package-target-cache))
        package))
   ((fboundp 'nelix-package-install-target)
    (nelix-package-install-target package))
   (t package)))

(defun nelix-manifest-targets (manifest &optional backend)
  "Return install targets declared by MANIFEST."
  (nelix-manifest--dedupe
   (append
    (mapcar (lambda (package)
              (if (eq backend 'nelix-native)
                  package
                (nelix-manifest--resolve-emacs-target package)))
            (plist-get manifest :emacs))
    (plist-get manifest :linux)
    (plist-get manifest :debian-tools))))

(defun nelix-manifest-backend-policy (manifest &optional os)
  "Return backend policy for MANIFEST on OS."
  (let ((policy (plist-get manifest :backend-policy))
        (os* (or os system-type)))
    (cond
     ((null policy)
      (if (nelix-backend-available-p 'nix)
          '(nix nelix-native)
        '(nelix-native nix)))
     ((and (consp policy)
           (symbolp (car policy)))
      policy)
     ((cdr (assq os* policy)))
     (t
      (nelix-backend-policy-for-os os*)))))

(defun nelix-manifest-select-backend (manifest &optional target)
  "Select a backend for MANIFEST and optional TARGET."
  (nelix-backend-select
   target
   (nelix-current-system)
   (nelix-manifest-backend-policy manifest)))

;;;###autoload
(defun nelix-validate (manifest-file)
  "Validate MANIFEST-FILE without inspecting or mutating profiles.
This is intentionally process-free: it loads the manifest and imports,
normalizes fields, and reports declared package counts.  Use it before
`nelix-audit' on standalone NeLisp or on machines where Nix/profile
inspection is not available yet."
  (let* ((manifest (nelix-manifest-load manifest-file))
         (emacs (plist-get manifest :emacs))
         (linux (plist-get manifest :linux))
         (debian-tools (plist-get manifest :debian-tools))
         (bootstrap-apt (plist-get manifest :bootstrap-apt))
         (pins (plist-get manifest :pins))
         (imports (plist-get manifest :imports)))
    (list :ok t
          :manifest (plist-get manifest :file)
          :name (plist-get manifest :name)
          :profile (plist-get manifest :profile)
          :nix-channel (plist-get manifest :nix-channel)
          :backend-policy (or (plist-get manifest :backend-policy)
                              :default)
          :imports imports
          :counts (list :emacs (length emacs)
                        :linux (length linux)
                        :debian-tools (length debian-tools)
                        :bootstrap-apt (length bootstrap-apt)
                        :pins (length pins)
                        :imports (length imports)))))

(defun nelix-manifest--target-name (target)
  "Return a display/install name for TARGET."
  (cond
   ((stringp target) target)
   ((symbolp target) (symbol-name target))
   (t (format "%S" target))))

(defun nelix-manifest--strip-profile-duplicate-suffix (name)
  "Return NAME without a Nix profile duplicate suffix like \"-1\"."
  (if (and (stringp name)
           (string-match-p "-[0-9]+\\'" name))
      (replace-regexp-in-string "-[0-9]+\\'" "" name)
    name))

(defun nelix-manifest--attr-tail-name (name)
  "Return the final dot-separated component of NAME."
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

(defun nelix-manifest--target-candidate-names (target)
  "Return profile names that may satisfy TARGET."
  (let* ((display (nelix-manifest--target-name target))
         (tail (nelix-manifest--attr-tail-name display)))
    (cond
     ((not (and (stringp display) (> (length display) 0)))
      nil)
     ((or (not (stringp tail))
          (zerop (length tail))
          (equal display tail))
      (list display))
     (t
      (list display tail)))))

(defun nelix-manifest--installed-name-index (installed)
  "Return a hash table mapping installed names to INSTALLED rows."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (entry installed index)
      (let ((name (plist-get entry :name)))
        (when (and (stringp name) (> (length name) 0))
          (puthash name entry index)
          (puthash (nelix-manifest--strip-profile-duplicate-suffix name)
                   entry
                   index))))))

(defun nelix-manifest--installed-entry-by-name (target index)
  "Return profile row satisfying TARGET from name INDEX, or nil."
  (let ((found nil))
    (dolist (name (nelix-manifest--target-candidate-names target) found)
      (when (and (null found) (gethash name index))
        (setq found (gethash name index))))))

(defun nelix-manifest--target-attr-paths (target)
  "Return profile attr paths that can satisfy install TARGET."
  (cond
   ((and (fboundp 'nelix-package--target-attr-paths)
         (or (symbolp target) (stringp target)))
    (nelix-package--target-attr-paths target))
   ((stringp target)
    (list target
          (format "legacyPackages.x86_64-linux.%s" target)
          (format "packages.x86_64-linux.%s" target)))
   ((symbolp target)
    (list (format "packages.x86_64-linux.%s" (symbol-name target))
          (format "legacyPackages.x86_64-linux.%s" (symbol-name target))))
   (t nil)))

(defun nelix-manifest--installed-entry (target installed)
  "Return profile row in INSTALLED satisfying TARGET, or nil."
  (let ((attrs (nelix-manifest--target-attr-paths target))
        (name (nelix-manifest--target-name target))
        (found nil))
    (dolist (entry installed found)
      (when (and (null found)
                 (or (equal name (plist-get entry :name))
                     (member (plist-get entry :attr-path) attrs)))
        (setq found entry)))))

(defun nelix-manifest--entry-owned-p (entry targets)
  "Return non-nil when ENTRY is represented by TARGETS."
  (let ((owned nil))
    (dolist (target targets owned)
      (when (and (null owned)
                 (nelix-manifest--installed-entry target (list entry)))
        (setq owned t)))))

(defun nelix-manifest--installed-entries (manifest backend)
  "Return installed entries for MANIFEST under BACKEND."
  (pcase backend
    ('nelix-native
     (condition-case _
         (plist-get (nelix-profile-read (plist-get manifest :profile)) :entries)
       (error nil)))
    (_
     (nelix-list))))

(defun nelix-manifest-installation-report (manifest &optional backend)
  "Return per-target installation rows for MANIFEST."
  (nelix-manifest-installation-report-from-installed
   manifest
   backend
   (nelix-manifest--installed-entries manifest backend)))

(defun nelix-manifest-installation-report-from-installed
    (manifest backend installed &optional targets)
  "Return per-target installation rows for MANIFEST using INSTALLED entries."
  (let ((index (and (anvil-pkg-compat--standalone-nelisp-p)
                    (nelix-manifest--installed-name-index installed)))
        (targets (or targets (nelix-manifest-targets manifest backend)))
        (rows nil))
    (dolist (target targets (nreverse rows))
      (let ((entry (if index
                       (nelix-manifest--installed-entry-by-name target index)
                     (nelix-manifest--installed-entry target installed))))
        (push (list :target target
                    :name (nelix-manifest--target-name target)
                    :installed (and entry t)
                    :backend backend
                    :entry entry
                    :attr-path (plist-get entry :attr-path)
                    :original-url (plist-get entry :original-url))
              rows)))))

(defun nelix-manifest-missing-targets (manifest)
  "Return install targets from MANIFEST not present in the profile."
  (let (missing)
    (dolist (row (nelix-manifest-installation-report manifest)
                 (nreverse missing))
      (unless (plist-get row :installed)
        (push (plist-get row :target) missing)))))

(defun nelix-manifest-extra-entries (manifest &optional backend)
  "Return installed profile entries not represented by MANIFEST."
  (nelix-manifest-extra-entries-from-installed
   manifest
   backend
   (nelix-manifest--installed-entries manifest backend)))

(defun nelix-manifest-extra-entries-from-installed
    (manifest backend installed &optional targets)
  "Return INSTALLED entries not represented by MANIFEST."
  (let ((targets (or targets (nelix-manifest-targets manifest backend)))
        (extras nil))
    (if (anvil-pkg-compat--standalone-nelisp-p)
        (let ((owned-names (make-hash-table :test 'equal)))
          (dolist (target targets)
            (dolist (name (nelix-manifest--target-candidate-names target))
              (puthash name t owned-names)))
          (dolist (entry installed (nreverse extras))
            (let* ((name (plist-get entry :name))
                   (base (nelix-manifest--strip-profile-duplicate-suffix name)))
              (unless (or (gethash name owned-names)
                          (gethash base owned-names))
                (push entry extras)))))
      (dolist (entry installed (nreverse extras))
        (unless (nelix-manifest--entry-owned-p entry targets)
          (push entry extras))))))

(defun nelix-manifest--target-key (target)
  "Return a stable comparison key for TARGET."
  (format "%S" target))

(defun nelix-manifest--lock-package-find (packages row)
  "Return the lock package from PACKAGES matching install ROW."
  (let ((name (plist-get row :name))
        found)
    (dolist (package packages found)
      (when (and (null found)
                 (equal name (plist-get package :name)))
        (setq found package)))))

(defun nelix-manifest--lock-row-find (rows package)
  "Return the install row from ROWS matching lock PACKAGE."
  (let ((name (plist-get package :name))
        found)
    (dolist (row rows found)
      (when (and (null found)
                 (equal name (plist-get row :name)))
        (setq found row)))))

(defun nelix-manifest--lock-package-list-find (packages name)
  "Return package row named NAME from PACKAGES."
  (let (found)
    (dolist (package packages found)
      (when (and (null found)
                 (equal name (plist-get package :name)))
        (setq found package)))))

(defun nelix-manifest--lock-dependency-name (dependency)
  "Return lock dependency package name for DEPENDENCY."
  (cond
   ((stringp dependency) dependency)
   ((symbolp dependency) (symbol-name dependency))
   ((and (consp dependency)
         (plist-get dependency :name))
    (nelix-manifest--lock-dependency-name
     (plist-get dependency :name)))
   (t
    (signal 'anvil-pkg-error
            (list (format "nelix lock: invalid dependency %S"
                          dependency))))))

(defun nelix-manifest--lock-dependency-closure (roots packages)
  "Return dependency names reachable from ROOTS using PACKAGES.

Signals when a dependency name is not present in PACKAGES so locked
native apply never falls back to the mutable registry."
  (let ((seen (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (package)
          (dolist (dependency (plist-get package :recipe-dependencies))
            (let* ((name (nelix-manifest--lock-dependency-name dependency))
                   (row (nelix-manifest--lock-package-list-find
                         packages name)))
              (unless row
                (signal 'anvil-pkg-error
                        (list (format "nelix locked mode: missing dependency lock package row for %s"
                                      name))))
              (unless (gethash name seen)
                (puthash name t seen)
                (visit row))))))
      (dolist (package roots)
        (visit package)))
    seen))

(defun nelix-manifest--recipe-system-entry (recipe system)
  "Return RECIPE system entry for SYSTEM."
  (let (found)
    (dolist (entry (plist-get recipe :systems) found)
      (when (and (null found)
                 (consp entry)
                 (eq (car entry) system))
        (setq found (cdr entry))))))

(defun nelix-manifest--locked-package-plan
    (manifest-file manifest selection report)
  "Return lock package plan for MANIFEST-FILE, MANIFEST, SELECTION and REPORT.

The returned plist contains the lock file plist and packages ordered
like REPORT.  Signals `anvil-pkg-error' if the lock package rows no
longer match the selected backend, profile, system, or current
manifest targets."
  (let* ((lock (nelix-lock-read manifest-file))
         (version (plist-get lock :version))
         (backend (plist-get selection :backend))
         (system (plist-get selection :system))
         (profile (plist-get manifest :profile))
         (packages (plist-get lock :packages))
         ordered)
    (unless (and (integerp version) (>= version 2))
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: lock version %S cannot enforce package rows"
                            version))))
    (unless (eq backend (plist-get lock :backend))
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: backend drift, lock=%S current=%S"
                            (plist-get lock :backend) backend))))
    (unless (equal profile (plist-get lock :profile))
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: profile drift, lock=%S current=%S"
                            (plist-get lock :profile) profile))))
    (unless (eq system (plist-get lock :system))
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: system drift, lock=%S current=%S"
                            (plist-get lock :system) system))))
    (dolist (row report)
      (let ((package (nelix-manifest--lock-package-find packages row)))
        (unless package
          (signal 'anvil-pkg-error
                  (list (format "nelix locked mode: missing lock package row for %s"
                                (plist-get row :name)))))
        (unless (eq backend (plist-get package :backend))
          (signal 'anvil-pkg-error
                  (list (format "nelix locked mode: package backend drift for %s"
                                (plist-get row :name)))))
        (unless (eq system (plist-get package :system))
          (signal 'anvil-pkg-error
                  (list (format "nelix locked mode: package system drift for %s"
                                (plist-get row :name)))))
        (unless (equal (nelix-manifest--target-key (plist-get row :target))
                       (nelix-manifest--target-key
                        (plist-get package :target)))
          (signal 'anvil-pkg-error
                  (list (format "nelix locked mode: package target drift for %s"
                                (plist-get row :name)))))
        (unless (plist-get package :target)
          (signal 'anvil-pkg-error
                  (list (format "nelix locked mode: package %s has no locked target"
                                (plist-get row :name)))))
        (push package ordered)))
    (dolist (package packages)
      (unless (or (nelix-manifest--lock-row-find report package)
                  (and (eq backend 'nelix-native)
                       (gethash (plist-get package :name)
                                (nelix-manifest--lock-dependency-closure
                                 ordered packages))))
        (signal 'anvil-pkg-error
                (list (format "nelix locked mode: extra lock package row for %s"
                              (plist-get package :name))))))
    (list :lock lock
          :packages (nreverse ordered)
          :all-packages packages)))

(defun nelix-apply--legacy-backend
    (manifest-file manifest selection backend lock-check rollback-on-error)
  "Apply MANIFEST-FILE through the pre-plan non-Nix BACKEND path."
  (let* ((report (nelix-manifest-installation-report manifest backend))
         (locked-plan (and lock-check
                           (nelix-manifest--locked-package-plan
                            manifest-file manifest selection report)))
         (locked-packages (plist-get locked-plan :packages))
         (locked-cursor locked-packages)
         (missing nil)
         (already nil)
         (installed-locked nil)
         (pins (plist-get manifest :pins))
         (profile (plist-get manifest :profile))
         (system (plist-get selection :system))
         transaction-commands
         transaction-plan
         transaction
         executed)
    (dolist (row report)
      (let ((locked-package (car locked-cursor)))
        (when locked-plan
          (setq locked-cursor (cdr locked-cursor)))
        (if (plist-get row :installed)
            (push (plist-get row :target) already)
          (push (if locked-package
                    (plist-get locked-package :target)
                  (plist-get row :target))
                missing)
          (when locked-package
            (push locked-package installed-locked)))))
    (setq missing (nreverse missing)
          already (nreverse already)
          installed-locked (nreverse installed-locked))
    (setq transaction-commands
          (and (eq backend 'nelix-native)
               (mapcar (lambda (target)
                         (list :action 'install
                               :name (nelix-manifest--target-name target)
                               :backend backend
                               :target target))
                       missing)))
    (when transaction-commands
      (setq transaction-plan
            (condition-case _
                (nelix-plan manifest-file)
              (error
               (list :operation 'apply
                     :manifest (plist-get manifest :file)
                     :backend backend
                     :backend-selection selection))))
      (setq transaction-plan
            (plist-put transaction-plan :commands transaction-commands))
      (setq transaction-plan
            (plist-put transaction-plan :dry-run nil))
      (setq transaction-plan
            (plist-put transaction-plan :locked (and lock-check t)))
      (setq transaction-plan
            (plist-put transaction-plan :lock-check lock-check))
      (setq transaction-plan
            (plist-put transaction-plan :lock-enforced
                       (and locked-plan t)))
      (setq transaction
            (nelix-manifest--transaction-begin
             transaction-commands rollback-on-error backend profile system))
      (setq transaction
            (nelix-manifest--transaction-record-begin
             manifest-file transaction-plan transaction)))
    (when missing
      (condition-case err
          (if (and locked-plan (eq backend 'nelix-native))
              (dolist (package installed-locked)
                (let* ((name (plist-get package :name))
                       (result
                        (nelix-native-install-lock-package
                         package profile system
                         (plist-get locked-plan :all-packages))))
                  (push (list :action 'install
                              :name name
                              :backend backend
                              :ok t
                              :result result)
                        executed)
                  (setq transaction
                        (nelix-manifest--transaction-record-update
                         manifest-file transaction-plan transaction 'running
                         (nreverse (copy-sequence executed))))))
            (dolist (target missing)
              (let* ((name (nelix-manifest--target-name target))
                     (result
                      (nelix-backend-install
                       backend (list target) profile system)))
                (push (list :action 'install
                            :name name
                            :backend backend
                            :ok t
                            :result result)
                      executed)
                (setq transaction
                      (nelix-manifest--transaction-record-update
                       manifest-file transaction-plan transaction 'running
                       (nreverse (copy-sequence executed)))))))
        (error
         (let* ((rollback
                 (nelix-manifest--transaction-rollback transaction))
                (message
                 (format "nelix-apply: %S backend failed after %d executed action(s): %s; rollback=%s"
                         backend
                         (length executed)
                         (error-message-string err)
                         (if (plist-get rollback :ok) "ok" "not-ok"))))
           (setq transaction
                 (nelix-manifest--transaction-record-update
                  manifest-file transaction-plan transaction 'error
                  (nreverse (copy-sequence executed))
                  rollback (error-message-string err)))
           (signal 'anvil-pkg-error
                   (list message
                         :error (error-message-string err)
                         :executed (nreverse executed)
                         :transaction transaction
                         :rollback rollback))))))
    (dolist (pin pins)
      (nelix-pin pin))
    (when transaction
      (setq executed (nreverse executed))
      (setq transaction
            (nelix-manifest--transaction-finish transaction))
      (setq transaction-plan
            (plist-put transaction-plan :executed executed))
      (setq transaction
            (nelix-manifest--transaction-record-update
             manifest-file transaction-plan transaction 'ok executed)))
    (list :status 'ok
          :manifest (plist-get manifest :file)
          :backend backend
          :backend-selection selection
          :installed missing
          :already-present already
          :pinned pins
          :skipped nil
          :locked (and lock-check t)
          :lock-check lock-check
          :lock-enforced (and locked-plan t)
          :lock-packages (plist-get locked-plan :packages)
          :lock-all-packages (plist-get locked-plan :all-packages)
          :locked-installed installed-locked
          :executed executed
          :transaction transaction
          :profile (plist-get manifest :profile)
          :nix-profile (and (eq backend 'nix) anvil-pkg-profile-dir))))

(defun nelix-manifest--active-generation-id ()
  "Return the currently active Nix profile generation id, or nil."
  (let ((generations (pkg-list-generations))
        active)
    (dolist (generation generations)
      (when (and (null active)
                 (plist-get generation :active))
        (setq active generation)))
    (plist-get active :id)))

(defun nelix-manifest--native-active-generation-id (profile-name)
  "Return the active native PROFILE-NAME generation id, or nil."
  (condition-case _
      (plist-get (nelix-profile-read (or profile-name "default")) :generation)
    (error nil)))

(defun nelix-manifest--native-ensure-generation (profile-name system)
  "Return a rollback generation for native PROFILE-NAME and SYSTEM.
When the profile does not exist, create an empty generation before the first
apply step so rollback has a concrete pre-apply target."
  (or (nelix-manifest--native-active-generation-id profile-name)
      (plist-get
       (nelix-profile-create-generation
        (or profile-name "default")
        (or system (nelix-current-system))
        nil)
       :generation)))

(defun nelix-manifest--run-nix-command-nelisp (argv)
  "Run Nix command ARGV through a shell PATH lookup for NeLisp."
  (if (or (boundp 'emacs-version)
          (not (anvil-pkg-compat--runtime-nelisp-p))
          (not (eq anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default)))
      (nelix-manifest--run-nix-command argv)
    (anvil-pkg--ensure-nix)
    (let ((res (anvil-pkg-compat-call-process
                "sh"
                (append (list "-c" "exec \"$@\"" "nelix-nix"
                              anvil-pkg-nix-program)
                        argv))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'anvil-pkg-nix-failed
                (list (format "nix %s failed (exit %s): %s"
                              (mapconcat #'identity argv " ")
                              (plist-get res :exit)
                              (anvil-pkg-compat-string-trim
                               (or (plist-get res :stderr) "")))
                      :stderr (plist-get res :stderr))))
      (list :argv argv
            :exit (plist-get res :exit)
            :stdout (plist-get res :stdout)
            :stderr (plist-get res :stderr)))))

(defun nelix-manifest--active-generation-id-nelisp ()
  "Return the active Nix profile generation id through the NeLisp runner."
  (if (or (boundp 'emacs-version)
          (not (anvil-pkg-compat--runtime-nelisp-p))
          (not (eq anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default)))
      (nelix-manifest--active-generation-id)
    (let* ((res (nelix-manifest--run-nix-command-nelisp
                 (append (list "profile" "history" "--json")
                         (anvil-pkg--profile-args))))
           (generations (anvil-pkg--parse-history
                         (or (plist-get res :stdout) "")))
           active)
      (anvil-pkg--generations-cache-put generations)
      (dolist (generation generations)
        (when (and (null active)
                   (plist-get generation :active))
          (setq active generation)))
      (plist-get active :id))))

(defun nelix-manifest--rollback-generation-nelisp (generation)
  "Rollback the Nix profile to GENERATION through the NeLisp runner."
  (if (or (boundp 'emacs-version)
          (not (anvil-pkg-compat--runtime-nelisp-p))
          (not (eq anvil-pkg--call-nix-fn #'anvil-pkg--call-nix-default)))
      (nelix-rollback generation)
    (nelix-manifest--run-nix-command-nelisp
     (append (list "profile" "rollback")
             (anvil-pkg--profile-args)
             (list "--to-generation" (number-to-string generation))))
    (condition-case _
        (nelix-manifest--active-generation-id-nelisp)
      (error nil))
    t))

(defun nelix-manifest--transaction-preview (commands rollback-on-error)
  "Return dry-run transaction metadata for COMMANDS."
  (list :enabled (and commands t)
        :rollback-on-error (and rollback-on-error t)
        :generation-captured nil
        :rollback-available nil
        :dry-run t))

(defun nelix-manifest--state-root ()
  "Return the user state root for Nelix metadata."
  (expand-file-name
   (or (anvil-pkg-compat-getenv "XDG_STATE_HOME")
       "~/.local/state")))

(defun nelix-manifest--transaction-log-root ()
  "Return the transaction log root directory."
  (expand-file-name
   (or nelix-transaction-log-root
       (expand-file-name "nelix/transactions"
                         (nelix-manifest--state-root)))))

(defun nelix-manifest--timestamp ()
  "Return a compact timestamp for transaction records."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun nelix-manifest--transaction-record-file (root)
  "Return a new transaction record path below ROOT.

Do not use `make-temp-file' here.  Standalone NeLisp's compatibility
implementation treats an absolute prefix as relative to TMPDIR, which would
move transaction records outside the configured log root."
  (let* ((pid (cond
               ((fboundp 'emacs-pid) (emacs-pid))
               ((fboundp 'nelisp-syscall-getpid)
                (nelisp-syscall-getpid))
               (t 0)))
         (root-dir (file-name-as-directory (expand-file-name root)))
         (stamp (format-time-string "%Y%m%dT%H%M%S%z"))
         file)
    (while (or (not file)
               (anvil-pkg-compat-file-exists-p file))
      (setq nelix-manifest--transaction-record-counter
            (1+ nelix-manifest--transaction-record-counter))
      (setq file
            (expand-file-name
             (format "apply-%s-%s-%s.el"
                     stamp pid nelix-manifest--transaction-record-counter)
             root-dir)))
    file))

(defun nelix-manifest--transaction-record-id (file)
  "Return the generated transaction record id for FILE."
  (let ((name (file-name-nondirectory file)))
    (if (and (>= (length name) 3)
             (equal (substring name (- (length name) 3)) ".el"))
        (substring name 0 (- (length name) 3))
      name)))

(defun nelix-manifest--transaction-record-write (file record)
  "Write transaction RECORD to FILE."
  (anvil-pkg-compat-make-directory (file-name-directory file) t)
  (anvil-pkg-compat-write-file
   file
   (concat ";;; generated Nelix apply transaction record -*- lexical-binding: t; -*-\n\n"
           (prin1-to-string record)
           "\n")))

(defun nelix-manifest--transaction-rollback-plan (transaction)
  "Return the rollback plan implied by TRANSACTION."
  (let ((generation (plist-get transaction :before-generation)))
    (cond
     ((not (plist-get transaction :enabled))
      (list :available nil :reason "transaction-disabled"))
     ((not (plist-get transaction :rollback-on-error))
      (list :available nil :reason "rollback-disabled"))
     ((not generation)
      (list :available nil :reason "before-generation-missing"))
     (t
      (list :available t
            :operation 'rollback
            :generation generation
            :argv (append (list "profile" "rollback")
                          (anvil-pkg--profile-args)
                          (list "--to-generation"
                                (number-to-string generation))))))))

(defun nelix-manifest--transaction-record (status manifest-file plan
                                                  transaction executed
                                                  &optional rollback error)
  "Return a transaction record for STATUS and current apply state."
  (list :schema nelix-transaction-schema-name
        :schema-version nelix-transaction-schema-version
        :id (plist-get transaction :record-id)
        :status status
        :manifest (expand-file-name manifest-file)
        :profile anvil-pkg-profile-dir
        :started-at (plist-get transaction :record-started-at)
        :updated-at (nelix-manifest--timestamp)
        :plan plan
        :transaction transaction
        :executed executed
        :rollback-plan (nelix-manifest--transaction-rollback-plan
                        transaction)
        :rollback rollback
        :error error))

(defun nelix-manifest--transaction-record-begin
    (manifest-file plan transaction)
  "Persist the initial PLAN snapshot for TRANSACTION."
  (if (not (plist-get transaction :enabled))
      transaction
    (let* ((root (nelix-manifest--transaction-log-root))
           (_dir (anvil-pkg-compat-make-directory root t))
           (file (nelix-manifest--transaction-record-file root))
           (id (nelix-manifest--transaction-record-id file))
           (started-at (nelix-manifest--timestamp)))
      (setq transaction (plist-put transaction :record-id id))
      (setq transaction (plist-put transaction :record-file file))
      (setq transaction (plist-put transaction :record-started-at started-at))
      (setq transaction (plist-put transaction :record-status 'started))
      (nelix-manifest--transaction-record-write
       file
       (nelix-manifest--transaction-record
        'started manifest-file plan transaction nil))
      transaction)))

(defun nelix-manifest--transaction-record-update
    (manifest-file plan transaction status executed &optional rollback error)
  "Update TRANSACTION record with STATUS, EXECUTED, ROLLBACK, and ERROR."
  (let ((file (plist-get transaction :record-file)))
    (if (not file)
        transaction
      (setq transaction (plist-put transaction :record-status status))
      (setq transaction (plist-put transaction :record-updated-at
                                  (nelix-manifest--timestamp)))
      (nelix-manifest--transaction-record-write
       file
       (nelix-manifest--transaction-record
        status manifest-file plan transaction executed rollback error))
      transaction)))

(defun nelix-transaction--nil-like-p (value)
  "Return non-nil when VALUE represents nil across runtimes."
  (or (null value)
      (equal value "nil")
      (and (symbolp value)
           (equal (symbol-name value) "nil"))))

(defun nelix-transaction--true-like-p (value)
  "Return non-nil when VALUE represents t across runtimes."
  (or (eq value t)
      (equal value "t")
      (and (symbolp value)
           (equal (symbol-name value) "t"))))

(defun nelix-transaction--normalize-bool (value)
  "Normalize VALUE when it is a runtime-dependent boolean."
  (cond
   ((nelix-transaction--nil-like-p value) nil)
   ((nelix-transaction--true-like-p value) t)
   (t value)))

(defun nelix-transaction--normalize-plist-bools (plist keys)
  "Return PLIST with boolean-like KEYS normalized."
  (let ((result (copy-sequence plist)))
    (dolist (key keys result)
      (when (plist-member result key)
        (setq result
              (plist-put result key
                         (nelix-transaction--normalize-bool
                          (plist-get result key))))))))

(defun nelix-transaction--normalize-record (record)
  "Normalize runtime-dependent boolean/null fields in RECORD."
  (let ((result (copy-sequence record)))
    (dolist (key '(:error :rollback))
      (when (and (plist-member result key)
                 (nelix-transaction--nil-like-p (plist-get result key)))
        (setq result (plist-put result key nil))))
    (when (plist-get result :transaction)
      (setq result
            (plist-put
             result :transaction
             (nelix-transaction--normalize-plist-bools
              (plist-get result :transaction)
              '(:enabled :rollback-on-error
                :generation-captured :rollback-available)))))
    (when (plist-get result :rollback-plan)
      (setq result
            (plist-put
             result :rollback-plan
             (nelix-transaction--normalize-plist-bools
              (plist-get result :rollback-plan)
              '(:available)))))
    (when (plist-get result :rollback)
      (setq result
            (plist-put
             result :rollback
             (nelix-transaction--normalize-plist-bools
              (plist-get result :rollback)
              '(:attempted :ok :verified)))))
    (when (plist-get result :executed)
      (setq result
            (plist-put
             result :executed
             (mapcar
              (lambda (row)
                (if (and (listp row) (plist-member row :ok))
                    (nelix-transaction--normalize-plist-bools row '(:ok))
                  row))
              (plist-get result :executed)))))
    result))

(defun nelix-transaction--require-keys (where plist keys)
  "Signal unless PLIST contains every key in KEYS for WHERE."
  (dolist (key keys)
    (unless (plist-member plist key)
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: %s is missing required key %S"
                            where key))))))

(defun nelix-transaction--validate-record-shape (record file)
  "Validate stable transaction RECORD shape read from FILE."
  (nelix-transaction--require-keys
   "record" record nelix-transaction-record-required-keys)
  (let ((plan (plist-get record :plan))
        (transaction (plist-get record :transaction))
        (rollback-plan (plist-get record :rollback-plan)))
    (unless (listp plan)
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: record plan is not a plist in %s"
                            file))))
    (unless (listp transaction)
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: record transaction is not a plist in %s"
                            file))))
    (unless (listp rollback-plan)
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: record rollback-plan is not a plist in %s"
                            file))))
    (nelix-transaction--require-keys
     "record plan" plan nelix-transaction-plan-required-keys)
    (nelix-transaction--require-keys
     "record transaction" transaction
     nelix-transaction-metadata-required-keys)
    (nelix-transaction--require-keys
     "record rollback-plan" rollback-plan '(:available))
    (when (plist-get rollback-plan :available)
      (nelix-transaction--require-keys
       "record rollback-plan" rollback-plan
       nelix-transaction-rollback-plan-available-required-keys))
    (unless (plist-get rollback-plan :available)
      (let ((reason (plist-get rollback-plan :reason)))
        (unless (and (stringp reason)
                     (member reason
                             nelix-transaction-rollback-unavailable-reasons))
          (signal 'anvil-pkg-error
                  (list (format "nelix transaction: record rollback-plan has unstable unavailable reason in %s: %S"
                                file reason))))))
    (dolist (row (plist-get record :executed))
      (unless (and (listp row)
                   (plist-member row :action)
                   (plist-member row :name))
        (signal 'anvil-pkg-error
                (list (format "nelix transaction: executed row is missing action/name in %s"
                              file))))))
  record)

(defun nelix-transaction-record-read (file)
  "Read and validate a generated Nelix apply transaction record FILE."
  (unless (anvil-pkg-compat-file-exists-p file)
    (signal 'anvil-pkg-error
            (list (format "nelix transaction: file does not exist: %s"
                          file))))
  (let* ((text (anvil-pkg-compat-read-file file))
         (record (car (read-from-string text)))
         (schema (plist-get record :schema))
         (schema-version (plist-get record :schema-version)))
    (unless (and (equal schema nelix-transaction-schema-name)
                 (integerp schema-version)
                 (= schema-version nelix-transaction-schema-version))
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: unsupported record schema in %s"
                            file))))
    (setq record (nelix-transaction--normalize-record record))
    (nelix-transaction--validate-record-shape record file)))

(defun nelix-transaction--record-files ()
  "Return generated transaction record files in the transaction log root."
  (let ((root (nelix-manifest--transaction-log-root)))
    (if (file-directory-p root)
        (directory-files root t "\\`apply-.*\\.el\\'")
      nil)))

(defun nelix-transaction--file-mtime (file)
  "Return FILE modification time as a floating point number."
  (condition-case _
      (let* ((attrs (and (fboundp 'file-attributes)
                         (file-attributes file)))
             (mtime (cond
                     ((and attrs
                           (fboundp 'file-attribute-modification-time))
                      (file-attribute-modification-time attrs))
                     (attrs (nth 5 attrs))
                     (t nil))))
        (cond
         ((and mtime (fboundp 'float-time)) (float-time mtime))
         ((numberp mtime) mtime)
         (t 0)))
    (error 0)))

(defun nelix-transaction--summary (file)
  "Return a summary plist for transaction record FILE."
  (let* ((record (nelix-transaction-record-read file))
         (plan (plist-get record :plan))
         (executed (plist-get record :executed))
         (rollback-plan (plist-get record :rollback-plan))
         (error (plist-get record :error)))
    (list :id (or (plist-get record :id)
                  (file-name-base file))
          :file file
          :schema (plist-get record :schema)
          :schema-version (plist-get record :schema-version)
          :status (plist-get record :status)
          :manifest (plist-get record :manifest)
          :profile (plist-get record :profile)
          :started-at (plist-get record :started-at)
          :updated-at (plist-get record :updated-at)
          :mtime (nelix-transaction--file-mtime file)
          :command-count (length (plist-get plan :commands))
          :executed-count (length executed)
          :rollback-available
          (and (plist-get rollback-plan :available) t)
          :error (and (stringp error) error))))

;;;###autoload
(defun nelix-transaction-list (&optional limit)
  "Return summaries for generated Nelix apply transaction records.

When LIMIT is non-nil, return at most LIMIT records.  Records are ordered by
file modification time, newest first."
  (let* ((root (nelix-manifest--transaction-log-root))
         (files (sort (nelix-transaction--record-files)
                      (lambda (a b)
                        (> (nelix-transaction--file-mtime a)
                           (nelix-transaction--file-mtime b)))))
         (rows nil)
         (remaining limit))
    (while (and files
                (or (null remaining) (> remaining 0)))
      (push (nelix-transaction--summary (car files)) rows)
      (setq files (cdr files))
      (when remaining
        (setq remaining (1- remaining))))
    (setq rows (nreverse rows))
    (list :status 'ok
          :operation 'transaction-list
          :root root
          :count (length rows)
          :transactions rows)))

(defun nelix-transaction--absolute-file-name-p (path)
  "Return non-nil when PATH is syntactically absolute."
  (or (string-prefix-p "/" path)
      (string-prefix-p "~/" path)
      (string-match-p "\\`[A-Za-z]:[\\/]" path)))

(defun nelix-transaction--resolve-file (id-or-file)
  "Resolve transaction ID-OR-FILE to a record file."
  (let* ((root (nelix-manifest--transaction-log-root))
         (path
          (cond
           ((or (nelix-transaction--absolute-file-name-p id-or-file)
                (string-match-p "/" id-or-file))
            (expand-file-name id-or-file))
           ((string-suffix-p ".el" id-or-file)
            (expand-file-name id-or-file root))
           (t
            (expand-file-name (concat id-or-file ".el") root)))))
    (unless (anvil-pkg-compat-file-exists-p path)
      (signal 'anvil-pkg-error
              (list (format "nelix transaction show: record not found: %s"
                            id-or-file))))
    path))

;;;###autoload
(defun nelix-transaction-show (id-or-file)
  "Return the generated Nelix apply transaction record ID-OR-FILE."
  (let* ((file (nelix-transaction--resolve-file id-or-file))
         (record (nelix-transaction-record-read file)))
    (list :status 'ok
          :operation 'transaction-show
          :file file
          :record record)))

(defun nelix-transaction--recover-command (record rollback-plan)
  "Return a public manual rollback command for RECORD and ROLLBACK-PLAN."
  (let* ((transaction (plist-get record :transaction))
         (backend (plist-get transaction :backend))
         (generation (plist-get rollback-plan :generation))
         (profile (plist-get transaction :profile)))
    (cond
     ((eq backend 'nelix-native)
      (append (list "native" "rollback")
              (and profile (list "--profile" profile))
              (and generation
                   (list "--generation" (number-to-string generation)))))
     (generation
      (list "rollback" (number-to-string generation)))
     (t nil))))

;;;###autoload
(defun nelix-transaction-recover (id-or-file &rest args)
  "Return the recovery plan for transaction record ID-OR-FILE.

ARGS must contain exactly one of `:dry-run t' or `:execute t'.  Dry-run
validates the record and reports the manual rollback command.  Execute performs
the rollback recorded in the transaction metadata."
  (let ((dry-run (plist-get args :dry-run))
        (execute (plist-get args :execute)))
    (when (and dry-run execute)
      (signal 'anvil-pkg-error
              (list "nelix transaction recover: use either --dry-run or --execute, not both")))
    (unless (or dry-run execute)
      (signal 'anvil-pkg-error
              (list "nelix transaction recover: use --dry-run to inspect or --execute to rollback")))
    (let* ((file (nelix-transaction--resolve-file id-or-file))
           (record (nelix-transaction-record-read file))
           (rollback-plan (plist-get record :rollback-plan))
           (transaction (plist-get record :transaction))
           (record-status (plist-get record :status))
           (manual-command
            (nelix-transaction--recover-command record rollback-plan)))
      (unless (plist-get rollback-plan :available)
        (signal 'anvil-pkg-error
                (list (format "nelix transaction recover: rollback unavailable for %s: %s"
                              id-or-file
                              (or (plist-get rollback-plan :reason)
                                  "unknown")))))
      (unless manual-command
        (signal 'anvil-pkg-error
                (list (format "nelix transaction recover: rollback command unavailable for %s"
                              id-or-file))))
      (when (and execute (eq record-status 'ok))
        (signal 'anvil-pkg-error
                (list (format "nelix transaction recover: refusing to rollback successful transaction %s"
                              id-or-file))))
      (let* ((base (list :status 'ok
                         :operation 'transaction-recover
                         :dry-run (and dry-run t)
                         :execute (and execute t)
                         :file file
                         :record-id (plist-get record :id)
                         :record-status record-status
                         :backend (plist-get transaction :backend)
                         :profile (plist-get transaction :profile)
                         :profile-root
                         (if (eq (plist-get transaction :backend) 'nelix-native)
                             (and (fboundp 'nelix-profile-root)
                                  (nelix-profile-root))
                           anvil-pkg-profile-dir)
                         :generation (plist-get rollback-plan :generation)
                         :rollback-plan rollback-plan
                         :manual-command manual-command
                         :command-count
                         (length (plist-get (plist-get record :plan)
                                            :commands))
                         :executed-count
                         (length (plist-get record :executed)))))
        (if dry-run
            base
          (let ((rollback (nelix-manifest--transaction-rollback transaction)))
            (unless (plist-get rollback :ok)
              (signal 'anvil-pkg-error
                      (list (format "nelix transaction recover: rollback failed for %s: %s"
                                    id-or-file
                                    (or (plist-get rollback :reason)
                                        (plist-get rollback :error)
                                        "unknown"))
                            :rollback rollback
                            :transaction transaction)))
            (append base (list :rollback rollback))))))))

(defun nelix-manifest--transaction-active-generation (transaction)
  "Return the active generation for TRANSACTION's backend."
  (if (eq (plist-get transaction :backend) 'nelix-native)
      (nelix-manifest--native-active-generation-id
       (plist-get transaction :profile))
    (if (anvil-pkg-compat--standalone-nelisp-p)
        (nelix-manifest--active-generation-id-nelisp)
      (nelix-manifest--active-generation-id))))

(defun nelix-manifest--transaction-capture-generation (transaction)
  "Return the rollback generation for TRANSACTION's backend."
  (if (eq (plist-get transaction :backend) 'nelix-native)
      (nelix-manifest--native-ensure-generation
       (plist-get transaction :profile)
       (plist-get transaction :system))
    (nelix-manifest--transaction-active-generation transaction)))

(defun nelix-manifest--transaction-begin
    (commands rollback-on-error &optional backend profile system)
  "Capture pre-apply generation metadata for COMMANDS."
  (let ((transaction
         (list :enabled (and commands t)
               :backend (or backend 'nix)
               :profile profile
               :system system
               :rollback-on-error (and rollback-on-error t)
               :generation-captured nil
               :rollback-available nil
               :before-generation nil
               :before-generation-error nil
               :after-generation nil)))
    (when commands
      (condition-case err
          (let ((generation
                 (nelix-manifest--transaction-capture-generation
                  transaction)))
            (setq transaction
                  (plist-put transaction :before-generation generation))
            (setq transaction
                  (plist-put transaction :generation-captured
                             (and generation t)))
            (setq transaction
                  (plist-put transaction :rollback-available
                             (and rollback-on-error generation t))))
        (error
         (setq transaction
               (plist-put transaction :before-generation-error
                          (error-message-string err))))))
    transaction))

(defun nelix-manifest--transaction-finish (transaction)
  "Capture post-apply generation metadata for TRANSACTION."
  (if (not (plist-get transaction :enabled))
      transaction
    (condition-case err
        (plist-put transaction
                   :after-generation
                   (nelix-manifest--transaction-active-generation
                    transaction))
      (error
       (plist-put transaction
                  :after-generation-error
                  (error-message-string err))))))

(defun nelix-manifest--transaction-rollback (transaction)
  "Rollback TRANSACTION to its before-generation when possible."
  (let ((generation (plist-get transaction :before-generation)))
    (cond
     ((not (plist-get transaction :enabled))
      (list :attempted nil :ok nil :reason "transaction-disabled"))
     ((not (plist-get transaction :rollback-on-error))
      (list :attempted nil :ok nil :reason "rollback-disabled"))
     ((not generation)
      (list :attempted nil :ok nil :reason "before-generation-missing"))
     (t
      (condition-case err
          (let (after)
            (cond
             ((eq (plist-get transaction :backend) 'nelix-native)
              (nelix-profile-rollback
               (plist-get transaction :profile)
               generation))
             ((anvil-pkg-compat--standalone-nelisp-p)
              (nelix-manifest--rollback-generation-nelisp generation))
             (t
              (nelix-rollback generation)))
            (setq after
                  (nelix-manifest--transaction-active-generation
                   transaction))
            (list :attempted t
                  :ok (equal after generation)
                  :generation generation
                  :after-rollback-generation after
                  :verified (equal after generation)
                  :reason (unless (equal after generation)
                            "rollback-generation-mismatch")))
        (error
         (list :attempted t
               :ok nil
               :generation generation
               :error (error-message-string err))))))))

(defun nelix-manifest--remove-actions (commands)
  "Return remove actions from COMMANDS."
  (let (remove)
    (dolist (action commands (nreverse remove))
      (when (eq 'remove (plist-get action :action))
        (push action remove)))))

(defun nelix-manifest--remove-safety (remove allow-remove allow-remove-count)
  "Return remove safety metadata for REMOVE and explicit allow settings."
  (let* ((count (length remove))
         (allowed (or (zerop count)
                      allow-remove
                      (and allow-remove-count
                           (= count allow-remove-count)))))
    (list :remove-count count
          :allow-remove (and allow-remove t)
          :allow-remove-count allow-remove-count
          :allowed (and allowed t)
          :required (and (> count 0) (not allowed) t))))

(defun nelix-manifest--require-remove-safe
    (remove allow-remove allow-remove-count)
  "Signal unless REMOVE is explicitly allowed."
  (let ((safety
         (nelix-manifest--remove-safety
          remove allow-remove allow-remove-count)))
    (when (plist-get safety :required)
      (signal 'anvil-pkg-error
              (list
               (format "nelix-apply: refusing to remove %d package(s); rerun with --allow-remove-count %d or --allow-remove"
                       (length remove)
                       (length remove))
               :remove remove
               :remove-safety safety)))
    safety))

;;;###autoload
(defun nelix-apply (manifest-file &rest args)
  "Converge the selected backend profile to MANIFEST-FILE.

When ARGS contains `:locked t', refuse to mutate the profile unless
the associated lock file exists and matches the manifest plus every
loaded import file.  Locked mode also makes install actions use the
package rows recorded in the lock file.  When ARGS contains
`:dry-run t', return the plan without invoking backend install/remove.
By default Nix apply captures the active profile generation before
mutation and rolls back to it when a command fails.  Pass
`:rollback-on-error nil' to disable that transaction rollback.
Real apply refuses unmanaged removals unless ARGS contains
`:allow-remove t' or `:allow-remove-count N' matching the planned
remove count."
  (if (anvil-pkg-compat--standalone-nelisp-p)
      (apply #'nelix-apply--nelisp manifest-file args)
    (let* ((dry-run (plist-get args :dry-run))
         (rollback-on-error
          (if (plist-member args :rollback-on-error)
              (plist-get args :rollback-on-error)
            t))
         (allow-remove (plist-get args :allow-remove))
         (allow-remove-count (plist-get args :allow-remove-count))
         (manifest (nelix-manifest-load manifest-file))
         (selection (nelix-manifest-select-backend manifest))
         (backend (plist-get selection :backend))
         (lock-check (and (plist-get args :locked)
                          (not (anvil-pkg-compat--standalone-nelisp-p))
                          (nelix-manifest--require-lock-ok
                           manifest-file)))
         (report nil)
         (locked-plan nil)
         (plan nil)
         commands
         remove
         remove-safety
         executed
         transaction)
    (when (and (plist-get args :locked)
               (anvil-pkg-compat--standalone-nelisp-p))
      (signal 'anvil-pkg-error
              (list "nelix-apply: --locked is not supported by NeLisp runtime yet")))
    (unless backend
      (signal 'anvil-pkg-error
              (list (format "nelix-apply: no available backend for %s"
                            manifest-file))))
    (if (not (eq backend 'nix))
        (progn
          (if dry-run
              (progn
                (setq report (nelix-manifest-installation-report
                              manifest backend))
                (setq locked-plan
                      (and lock-check
                           (nelix-manifest--locked-package-plan
                            manifest-file manifest selection report)))
                (setq plan (nelix-plan manifest-file))
                (setq plan (plist-put plan :status 'dry-run))
                (setq plan (plist-put plan :dry-run t))
                (setq plan (plist-put plan :locked (and lock-check t)))
                (setq plan (plist-put plan :lock-check lock-check))
                (setq plan (plist-put plan :lock-enforced
                                      (and locked-plan t)))
                (setq plan (plist-put plan :lock-packages
                                      (plist-get locked-plan :packages)))
                (setq plan (plist-put plan :lock-all-packages
                                      (plist-get locked-plan :all-packages)))
                (setq plan (plist-put
                            plan
                            :locked-installed
                            (delq nil
                                  (mapcar (lambda (action)
                                            (plist-get action :lock))
                                          (plist-get plan :install)))))
                (setq remove (plist-get plan :remove))
                (setq plan (plist-put
                            plan
                            :remove-safety
                            (nelix-manifest--remove-safety
                             remove allow-remove allow-remove-count)))
                (setq plan (plist-put
                            plan
                            :transaction
                            (nelix-manifest--transaction-preview
                             nil rollback-on-error)))
                plan)
             (nelix-apply--legacy-backend
              manifest-file manifest selection backend lock-check
              rollback-on-error)))
      (setq report (nelix-manifest-installation-report manifest backend))
      (setq locked-plan
            (and lock-check
                 (nelix-manifest--locked-package-plan
                  manifest-file manifest selection report)))
      (setq plan (nelix-plan manifest-file))
      (setq commands (plist-get plan :commands))
      (setq plan (plist-put plan :locked (and lock-check t)))
      (setq plan (plist-put plan :lock-check lock-check))
      (setq plan (plist-put plan :lock-enforced (and locked-plan t)))
      (setq plan (plist-put plan :lock-packages
                            (plist-get locked-plan :packages)))
      (setq plan (plist-put plan :locked-installed
                            (delq nil
                                  (mapcar (lambda (action)
                                            (plist-get action :lock))
                                          (plist-get plan :install)))))
      (setq remove (nelix-manifest--remove-actions commands))
      (setq remove-safety
            (nelix-manifest--remove-safety
             remove allow-remove allow-remove-count))
      (setq plan (plist-put plan :remove-safety remove-safety))
      (if dry-run
          (progn
            (setq plan (plist-put plan :status 'dry-run))
            (setq plan (plist-put plan :dry-run t))
            (setq plan (plist-put plan :transaction
                                  (nelix-manifest--transaction-preview
                                   commands rollback-on-error)))
            plan)
        (setq remove-safety
              (nelix-manifest--require-remove-safe
               remove allow-remove allow-remove-count))
        (setq plan (plist-put plan :remove-safety remove-safety))
        (setq plan (plist-put plan :dry-run nil))
        (setq transaction
              (nelix-manifest--transaction-begin
               commands rollback-on-error))
        (setq transaction
              (nelix-manifest--transaction-record-begin
               manifest-file plan transaction))
        (condition-case err
            (progn
              (dolist (action commands)
                (push (append (list :action (plist-get action :action)
                                    :name (plist-get action :name))
                              (nelix-manifest--run-nix-command
                               (plist-get action :argv)))
                      executed)
                (setq transaction
                      (nelix-manifest--transaction-record-update
                       manifest-file plan transaction 'running
                       (nreverse (copy-sequence executed)))))
              (dolist (pin (plist-get manifest :pins))
                (nelix-pin pin))
              (setq executed (nreverse executed))
              (setq transaction
                    (nelix-manifest--transaction-finish transaction))
              (setq plan (plist-put plan :status 'ok))
              (setq plan (plist-put plan :dry-run nil))
              (setq plan (plist-put plan :executed executed))
              (setq plan (plist-put plan :installed
                                    (mapcar (lambda (row) (plist-get row :name))
                                            (plist-get plan :install))))
              (setq plan (plist-put plan :removed
                                    (mapcar (lambda (row) (plist-get row :name))
                                            (plist-get plan :remove))))
              (setq plan (plist-put plan :pinned (plist-get manifest :pins)))
              (setq transaction
                    (nelix-manifest--transaction-record-update
                     manifest-file plan transaction 'ok executed))
              (setq plan (plist-put plan :transaction transaction))
              plan)
          (error
           (let* ((rollback
                   (nelix-manifest--transaction-rollback transaction))
                  (message
                   (format "nelix-apply: command failed after %d executed action(s): %s; rollback=%s"
                           (length executed)
                           (error-message-string err)
                           (if (plist-get rollback :ok) "ok" "not-ok"))))
             (setq transaction
                   (nelix-manifest--transaction-record-update
                    manifest-file plan transaction 'error
                    (nreverse (copy-sequence executed))
                    rollback (error-message-string err)))
             (signal 'anvil-pkg-error
                     (list message
                           :error (error-message-string err)
                           :executed (nreverse executed)
                           :transaction transaction
                           :rollback rollback))))))))))

(defun nelix-manifest--list-difference (a b)
  "Return members of A that are not equal to any member of B."
  (let (out)
    (dolist (item a (nreverse out))
      (unless (member item b)
        (push item out)))))

(defun nelix-manifest--bootstrap-report (manifest)
  "Return bootstrap report for MANIFEST using generated helpers when available."
  (cond
   ((fboundp 'nelix-linux-audit)
    (let ((audit (nelix-linux-audit)))
      (list :missing (plist-get audit :missing-bootstrap-apt)
            :outdated (plist-get audit :outdated-bootstrap-apt)
            :raw audit)))
   (t
    (list :declared (plist-get manifest :bootstrap-apt)
          :missing nil
          :outdated nil))))

(defun nelix-manifest--command-report ()
  "Return generated Linux command audit data when available."
  (if (fboundp 'nelix-linux-audit)
      (let ((audit (nelix-linux-audit)))
        (list :missing (plist-get audit :missing-commands)
              :non-profile (plist-get audit :non-profile-commands)
              :raw audit))
    (list :missing nil :non-profile nil)))

(defun nelix-manifest-lock-file-name (manifest-file)
  "Return default lock file path for MANIFEST-FILE."
  (concat (expand-file-name manifest-file) ".nelix-lock"))

(defun nelix-manifest--legacy-lock-file-name (manifest-file)
  "Return the pre-plan/apply lock file path for MANIFEST-FILE."
  (concat (file-name-sans-extension (expand-file-name manifest-file))
          ".lock.el"))

(defun nelix-manifest--selected-lock-file-name (manifest-file)
  "Return the lock file path currently selected for MANIFEST-FILE."
  (let ((default-lock-file (nelix-manifest-lock-file-name manifest-file))
        (legacy-lock-file (nelix-manifest--legacy-lock-file-name
                           manifest-file)))
    (if (anvil-pkg-compat-file-exists-p default-lock-file)
        default-lock-file
      legacy-lock-file)))

(defun nelix-manifest--lock-drift (manifest-file)
  "Return lock drift details for MANIFEST-FILE, or nil."
  (let ((lock-path (nelix-manifest-lock-file-name manifest-file)))
    (when (and (anvil-pkg-compat-file-exists-p lock-path)
               (not (anvil-pkg-compat--standalone-nelisp-p)))
      (let ((check (nelix-lock-check manifest-file)))
        (unless (plist-get check :ok)
          check)))))

(defvar nelix-manifest--audit-manifest nil)
(defvar nelix-manifest--audit-selection nil)
(defvar nelix-manifest--audit-backend nil)
(defvar nelix-manifest--audit-installed nil)
(defvar nelix-manifest--audit-targets nil)
(defvar nelix-manifest--audit-report nil)
(defvar nelix-manifest--audit-extra nil)
(defvar nelix-manifest--audit-missing nil)
(defvar nelix-manifest--audit-expected-pins nil)
(defvar nelix-manifest--audit-actual-pins nil)
(defvar nelix-manifest--audit-pin-missing nil)
(defvar nelix-manifest--audit-pin-extra nil)
(defvar nelix-manifest--audit-bootstrap nil)
(defvar nelix-manifest--audit-commands nil)
(defvar nelix-manifest--audit-lock-drift nil)
(defvar nelix-manifest--audit-native nil)
(defvar nelix-manifest--audit-warnings nil)
(defvar nelix-manifest--apply-missing nil)
(defvar nelix-manifest--apply-already nil)
(defvar nelix-manifest--apply-pins nil)
(defvar nelix-manifest--apply-row nil)
(defvar nelix-manifest--prune-remove nil)
(defvar nelix-manifest--prune-protected nil)
(defvar nelix-manifest--prune-pins nil)
(defvar nelix-manifest--prune-entry nil)
(defvar nelix-manifest--upgrade-pins nil)
(defvar nelix-manifest--upgrade-rows nil)
(defvar nelix-manifest--upgrade-pinned nil)
(defvar nelix-manifest--upgrade-row nil)
(defvar nelix-manifest--upgrade-name nil)
(defvar nelix-manifest--nelisp-progress-file nil
  "Optional progress file injected by the standalone NeLisp runner.")

(defun nelix-manifest--nelisp-progress (stage)
  "Write STAGE to `NELIX_PROGRESS_FILE' when requested."
  (let ((file (or nelix-manifest--nelisp-progress-file
                  (anvil-pkg-compat-getenv "NELIX_PROGRESS_FILE"))))
    (when (and file (> (length file) 0))
      (condition-case _err
          (anvil-pkg-compat-write-file file (format "%S\n" stage))
        (error nil)))))

(defun nelix-manifest--compact-report-row (row)
  "Return a compact ROW suitable for standalone NeLisp CLI output."
  (list :target (plist-get row :target)
        :name (plist-get row :name)
        :installed (plist-get row :installed)
        :backend (plist-get row :backend)
        :attr-path (plist-get row :attr-path)
        :original-url (plist-get row :original-url)))

(defun nelix-manifest--compact-entry-row (row)
  "Return compact installed profile ROW data for standalone NeLisp output."
  (list :name (plist-get row :name)
        :attr-path (plist-get row :attr-path)
        :original-url (plist-get row :original-url)))

(defun nelix-audit--nelisp-load-stage (manifest-file)
  "Load MANIFEST-FILE and profile rows for NeLisp audit."
  (setq nelix-manifest--audit-manifest
        (nelix-manifest-load manifest-file))
  ;; Resolve the backend/system from the manifest's backend-policy (the same
  ;; selection `nelix lock' records) instead of hard-coding nix, so the NeLisp
  ;; audit/apply path agrees with a no-Nix `nelix-native' manifest and does not
  ;; raise a spurious "backend drift" against a native lock.
  (setq nelix-manifest--audit-selection
        (nelix-manifest-select-backend nelix-manifest--audit-manifest))
  (setq nelix-manifest--audit-backend
        (or (plist-get nelix-manifest--audit-selection :backend) 'nix))
  (setq nelix-manifest--audit-installed
        (nelix-manifest--installed-entries
         nelix-manifest--audit-manifest
         nelix-manifest--audit-backend)))

(defun nelix-audit--nelisp-report-stage ()
  "Build report, extra and missing rows for NeLisp audit."
  (setq nelix-manifest--audit-targets
        (nelix-manifest-targets
         nelix-manifest--audit-manifest
         nelix-manifest--audit-backend))
  (setq nelix-manifest--audit-report
        (nelix-manifest-installation-report-from-installed
         nelix-manifest--audit-manifest
         nelix-manifest--audit-backend
         nelix-manifest--audit-installed
         nelix-manifest--audit-targets))
  (setq nelix-manifest--audit-extra
        (nelix-manifest-extra-entries-from-installed
         nelix-manifest--audit-manifest
         nelix-manifest--audit-backend
         nelix-manifest--audit-installed
         nelix-manifest--audit-targets))
  (setq nelix-manifest--audit-missing nil)
  (dolist (row nelix-manifest--audit-report)
    (unless (plist-get row :installed)
      (push row nelix-manifest--audit-missing)))
  (setq nelix-manifest--audit-missing
        (nreverse nelix-manifest--audit-missing)))

(defun nelix-audit--nelisp-drift-stage (manifest-file)
  "Build pin, bootstrap, command and lock drift data for NeLisp audit."
  (setq nelix-manifest--audit-expected-pins
        (plist-get nelix-manifest--audit-manifest :pins))
  (setq nelix-manifest--audit-actual-pins
        (if (null nelix-manifest--audit-expected-pins)
            nil
          (nelix-list-pins)))
  (setq nelix-manifest--audit-pin-missing
        (nelix-manifest--list-difference
         nelix-manifest--audit-expected-pins
         nelix-manifest--audit-actual-pins))
  (setq nelix-manifest--audit-pin-extra
        (nelix-manifest--list-difference
         nelix-manifest--audit-actual-pins
         nelix-manifest--audit-expected-pins))
  (setq nelix-manifest--audit-bootstrap
        (list :declared (plist-get nelix-manifest--audit-manifest
                                   :bootstrap-apt)
              :missing nil
              :outdated nil
              :skipped :nelisp))
  (setq nelix-manifest--audit-commands
        '(:missing nil :non-profile nil :skipped :nelisp))
  (setq nelix-manifest--audit-lock-drift
        (nelix-manifest--lock-drift manifest-file))
  (setq nelix-manifest--audit-native
        (and (eq nelix-manifest--audit-backend 'nelix-native)
             (nelix-native-audit nelix-manifest--audit-targets)))
  (setq nelix-manifest--audit-warnings nil)
  (when nelix-manifest--audit-lock-drift
    (push :lock-drift nelix-manifest--audit-warnings)))

(defun nelix-audit--nelisp-result ()
  "Return the final NeLisp audit plist."
  (list :ok (and (null nelix-manifest--audit-missing)
                 (null nelix-manifest--audit-pin-missing)
                 (null nelix-manifest--audit-pin-extra)
                 (null (plist-get nelix-manifest--audit-bootstrap :missing))
                 (null (plist-get nelix-manifest--audit-bootstrap :outdated))
                 (null (plist-get nelix-manifest--audit-commands :missing))
                 (null (plist-get nelix-manifest--audit-commands :non-profile))
                 (or (null nelix-manifest--audit-native)
                     (plist-get nelix-manifest--audit-native :ok))
                 (null nelix-manifest--audit-lock-drift))
        :manifest (plist-get nelix-manifest--audit-manifest :file)
        :backend nelix-manifest--audit-backend
        :backend-selection nelix-manifest--audit-selection
        :missing nelix-manifest--audit-missing
        :extra nelix-manifest--audit-extra
        :native nelix-manifest--audit-native
        :pins (list :expected nelix-manifest--audit-expected-pins
                    :actual nelix-manifest--audit-actual-pins
                    :missing nelix-manifest--audit-pin-missing
                    :extra nelix-manifest--audit-pin-extra)
        :bootstrap nelix-manifest--audit-bootstrap
        :commands nelix-manifest--audit-commands
        :lock-drift nelix-manifest--audit-lock-drift
        :warnings (nreverse nelix-manifest--audit-warnings)))

(defun nelix-audit--nelisp (manifest-file)
  "Return audit report for MANIFEST-FILE using a NeLisp-friendly path."
  (nelix-audit--nelisp-load-stage manifest-file)
  (nelix-audit--nelisp-report-stage)
  (nelix-audit--nelisp-drift-stage manifest-file)
  (nelix-audit--nelisp-result))

(defun nelix-prune-plan--nelisp (manifest-file)
  "Return a NeLisp-friendly prune plan for MANIFEST-FILE."
  (nelix-audit--nelisp-load-stage manifest-file)
  (nelix-audit--nelisp-report-stage)
  (setq nelix-manifest--prune-pins
        (plist-get nelix-manifest--audit-manifest :pins))
  (setq nelix-manifest--prune-remove nil)
  (setq nelix-manifest--prune-protected nil)
  (dolist (nelix-manifest--prune-entry nelix-manifest--audit-extra)
    (if (member (plist-get nelix-manifest--prune-entry :name)
                nelix-manifest--prune-pins)
        (push nelix-manifest--prune-entry
              nelix-manifest--prune-protected)
      (push nelix-manifest--prune-entry
            nelix-manifest--prune-remove)))
  (list :backend 'nix
        :backend-selection nelix-manifest--audit-selection
        :remove (nreverse nelix-manifest--prune-remove)
        :keep nelix-manifest--audit-report
        :protected (nreverse nelix-manifest--prune-protected)
        :reason (and nelix-manifest--prune-protected '(:pinned))))

(defun nelix-upgrade-plan--nelisp (manifest-file)
  "Return a NeLisp-friendly manifest upgrade plan for MANIFEST-FILE."
  (nelix-manifest--nelisp-progress :fast-upgrade-plan)
  (require 'nelix-fast nil t)
  (if (fboundp 'nelix-fast-upgrade-plan)
      (nelix-fast-upgrade-plan manifest-file)
    (signal 'anvil-pkg-error
            (list "nelix-upgrade-plan: nelix-fast is not loaded"))))

(defun nelix-apply--nelisp (manifest-file &rest args)
  "Apply MANIFEST-FILE through a compact NeLisp Nix path."
  (let ((dry-run (plist-get args :dry-run))
        (locked (plist-get args :locked))
        (rollback-on-error
         (if (plist-member args :rollback-on-error)
             (plist-get args :rollback-on-error)
           t))
        (allow-remove (plist-get args :allow-remove))
        (allow-remove-count (plist-get args :allow-remove-count))
        install
        keep
        remove
        commands
        remove-safety
        transaction
        executed
        lock-check
        locked-plan
        locked-packages
        locked-cursor
        plan)
    (nelix-audit--nelisp-load-stage manifest-file)
    (nelix-audit--nelisp-report-stage)
    (nelix-manifest--nelisp-progress :apply-lock-check-begin)
    (setq lock-check
          (and locked
               (let ((check (nelix-lock-check--nelisp
                             manifest-file
                             nelix-manifest--audit-manifest)))
                 (unless (plist-get (plist-get check :schema-check) :ok)
                   (signal 'anvil-pkg-error
                           (list (format "nelix locked mode: lock schema incompatible for %s"
                                         (expand-file-name manifest-file)))))
                 (unless (plist-get check :ok)
                   (signal 'anvil-pkg-error
                           (list (format "nelix locked mode: lock drift for %s"
                                         (expand-file-name manifest-file)))))
                 check)))
    (nelix-manifest--nelisp-progress :apply-lock-check-end)
    (setq locked-plan
          (and lock-check
               (nelix-manifest--locked-package-plan
                manifest-file
                nelix-manifest--audit-manifest
                nelix-manifest--audit-selection
                nelix-manifest--audit-report)))
    (nelix-manifest--nelisp-progress :apply-locked-plan-end)
    (setq locked-packages (plist-get locked-plan :packages))
    (setq locked-cursor locked-packages)
    (dolist (row nelix-manifest--audit-report)
      (let* ((name (plist-get row :name))
             (target (plist-get row :target))
             (locked-package (car locked-cursor)))
        (when locked-plan
          (setq locked-cursor (cdr locked-cursor)))
        (if (plist-get row :installed)
            (push (list :action 'keep
                        :name name
                        :backend nelix-manifest--audit-backend
                        :target target
                        :resolved-target target
                        :installed-name (plist-get (plist-get row :entry)
                                                   :name)
                        :pinned nil
                        :entry (plist-get row :entry))
                  keep)
          (let ((target* (or (plist-get locked-package :resolved-target)
                             (plist-get locked-package :target)
                             target)))
            (push (list :action 'install
                        :name name
                        :backend nelix-manifest--audit-backend
                        :target target*
                        :resolved-target target*
                        :installed-name nil
                        :pinned (and (member name
                                             (plist-get
                                              nelix-manifest--audit-manifest
                                              :pins))
                                     t)
                        :lock locked-package
                        :argv (and (eq nelix-manifest--audit-backend 'nix)
                                   (nelix-manifest--nix-install-argv
                                    nelix-manifest--audit-manifest target*)))
                  install)))))
    (dolist (entry nelix-manifest--audit-extra)
      (push (list :action 'remove
                  :name (plist-get entry :name)
                  :backend nelix-manifest--audit-backend
                  :target nil
                  :resolved-target nil
                  :installed-name (plist-get entry :name)
                  :pinned nil
                  :entry entry
                  :argv (and (eq nelix-manifest--audit-backend 'nix)
                             (nelix-manifest--nix-remove-argv entry)))
            remove))
    (setq install (nreverse install)
          keep (nreverse keep)
          remove (nreverse remove)
          commands (append install remove)
          remove-safety (nelix-manifest--remove-safety
                         remove allow-remove allow-remove-count))
    (setq plan
          (list :operation 'apply
                :status (if dry-run 'dry-run 'planned)
                :dry-run (and dry-run t)
                :manifest (plist-get nelix-manifest--audit-manifest :file)
                :lock (nelix-manifest-lock-file-name manifest-file)
                :lock-present
                (and (anvil-pkg-compat-file-exists-p
                      (nelix-manifest-lock-file-name manifest-file))
                     t)
                :backend nelix-manifest--audit-backend
                :backend-selection nelix-manifest--audit-selection
                :profile (plist-get nelix-manifest--audit-manifest :profile)
                :nix-profile anvil-pkg-profile-dir
                :install install
                :remove remove
                :keep keep
                :protected nil
                :commands commands
                :count (+ (length install) (length remove))
                :empty (and (null install) (null remove))
                :locked (and lock-check t)
                :lock-check lock-check
                :lock-enforced (and locked-plan t)
                :lock-packages locked-packages
                :locked-installed
                (delq nil
                      (mapcar (lambda (action)
                                (plist-get action :lock))
                              install))
                :remove-safety remove-safety))
    (if dry-run
        (plist-put plan :transaction
                   (nelix-manifest--transaction-preview
                    commands rollback-on-error))
      (nelix-manifest--require-remove-safe
       remove allow-remove allow-remove-count)
      (setq transaction
            (nelix-manifest--transaction-begin
             commands rollback-on-error))
      (setq transaction
            (nelix-manifest--transaction-record-begin
             manifest-file plan transaction))
      (condition-case err
          (progn
            (if (eq nelix-manifest--audit-backend 'nelix-native)
                ;; Native backend executes through the native store/profile
                ;; (shim creation + new generation), not `nix profile' commands.
                (let ((profile* (plist-get nelix-manifest--audit-manifest
                                           :profile))
                      (system* (plist-get nelix-manifest--audit-selection
                                          :system)))
                  (require 'nelix-builder nil t)
                  (dolist (action install)
                    (let ((result
                           (nelix-native-install-lock-package
                            (plist-get action :lock)
                            profile* system*
                            (plist-get locked-plan :all-packages))))
                      (push (list :action 'install
                                  :name (plist-get action :name)
                                  :backend 'nelix-native
                                  :ok t
                                  :result result)
                            executed)
                      (setq transaction
                            (nelix-manifest--transaction-record-update
                             manifest-file plan transaction 'running
                             (nreverse (copy-sequence executed))))))
                  (when remove
                    (nelix-profile-prune
                     profile*
                     (mapcar (lambda (a) (plist-get a :name)) remove)
                     system*)
                    (dolist (action remove)
                      (push (list :action 'remove
                                  :name (plist-get action :name)
                                  :backend 'nelix-native
                                  :ok t)
                            executed)
                      (setq transaction
                            (nelix-manifest--transaction-record-update
                             manifest-file plan transaction 'running
                             (nreverse (copy-sequence executed)))))))
              (dolist (action commands)
                (push (append (list :action (plist-get action :action)
                                    :name (plist-get action :name))
                              (nelix-manifest--run-nix-command-nelisp
                               (plist-get action :argv)))
                      executed)
                (setq transaction
                      (nelix-manifest--transaction-record-update
                       manifest-file plan transaction 'running
                       (nreverse (copy-sequence executed))))))
            (dolist (pin (plist-get nelix-manifest--audit-manifest :pins))
              (nelix-pin pin))
            (setq executed (nreverse executed))
            (setq transaction
                  (nelix-manifest--transaction-finish transaction))
            (setq plan (plist-put plan :status 'ok))
            (setq plan (plist-put plan :dry-run nil))
            (setq plan (plist-put plan :executed executed))
            (setq plan (plist-put
                        plan
                        :installed
                        (mapcar (lambda (row) (plist-get row :name))
                                install)))
            (setq plan (plist-put
                        plan
                        :removed
                        (mapcar (lambda (row) (plist-get row :name))
                                remove)))
            (setq plan (plist-put
                        plan
                        :pinned
                        (plist-get nelix-manifest--audit-manifest :pins)))
            (setq transaction
                  (nelix-manifest--transaction-record-update
                   manifest-file plan transaction 'ok executed))
            (setq plan (plist-put plan :transaction transaction))
            plan)
        (error
         (let* ((rollback
                 (nelix-manifest--transaction-rollback transaction))
                (message
                 (format "nelix-apply: command failed after %d executed action(s): %s; rollback=%s"
                         (length executed)
                         (error-message-string err)
                         (if (plist-get rollback :ok) "ok" "not-ok"))))
           (setq transaction
                 (nelix-manifest--transaction-record-update
                  manifest-file plan transaction 'error
                  (nreverse (copy-sequence executed))
                  rollback (error-message-string err)))
           (signal 'anvil-pkg-error
                   (list message
                         :error (error-message-string err)
                         :executed (nreverse executed)
                         :transaction transaction
                         :rollback rollback))))))))

;;;###autoload
(defun nelix-audit (manifest-file)
  "Return a read-only audit report for MANIFEST-FILE."
  (if (anvil-pkg-compat--standalone-nelisp-p)
      (progn
        (require 'nelix-fast nil t)
        (if (fboundp 'nelix-fast-audit)
            (nelix-fast-audit manifest-file)
          (nelix-audit--nelisp manifest-file)))
    (let ((manifest nil)
        (selection nil)
        (backend nil)
        (installed nil)
        (targets nil)
        (report nil)
        (extra nil)
        (missing nil)
        (expected-pins nil)
        (actual-pins nil)
        (pin-missing nil)
        (pin-extra nil)
        (bootstrap nil)
        (commands nil)
        (lock-drift nil)
        (native nil)
        (warnings nil))
    (setq manifest (nelix-manifest-load manifest-file))
    (setq selection (nelix-manifest-select-backend manifest))
    (setq backend (plist-get selection :backend))
    (setq installed (nelix-manifest--installed-entries manifest backend))
    (setq targets (nelix-manifest-targets manifest backend))
    (setq report (nelix-manifest-installation-report-from-installed
                  manifest backend installed targets))
    (setq extra (nelix-manifest-extra-entries-from-installed
                 manifest backend installed targets))
    (dolist (row report)
      (unless (plist-get row :installed)
        (push row missing)))
    (setq missing (nreverse missing))
    (setq expected-pins (plist-get manifest :pins))
    (setq actual-pins (if (and (null expected-pins)
                               (anvil-pkg-compat--standalone-nelisp-p))
                          nil
                        (nelix-list-pins)))
    (setq pin-missing (nelix-manifest--list-difference
                       expected-pins actual-pins))
    (setq pin-extra (nelix-manifest--list-difference
                     actual-pins expected-pins))
    (setq bootstrap (nelix-manifest--bootstrap-report manifest))
    (setq commands (nelix-manifest--command-report))
    (setq lock-drift (nelix-manifest--lock-drift manifest-file))
    (setq native (and (eq backend 'nelix-native)
                      (nelix-native-audit targets)))
    (when lock-drift
      (push :lock-drift warnings))
    (list :ok (and (null missing)
                   (null pin-missing)
                   (null pin-extra)
                   (null (plist-get bootstrap :missing))
                   (null (plist-get bootstrap :outdated))
                   (null (plist-get commands :missing))
                   (null (plist-get commands :non-profile))
                   (or (null native)
                       (plist-get native :ok))
                   (null lock-drift))
          :manifest (plist-get manifest :file)
          :backend backend
          :backend-selection selection
          :missing missing
          :extra extra
          :native native
          :pins (list :expected expected-pins
                      :actual actual-pins
                      :missing pin-missing
                      :extra pin-extra)
          :bootstrap bootstrap
          :commands commands
          :lock-drift lock-drift
          :warnings (nreverse warnings)))))

;;;###autoload
(defun nelix-prune-plan (manifest-file)
  "Return a read-only prune plan for MANIFEST-FILE."
  (if (anvil-pkg-compat--standalone-nelisp-p)
      (nelix-prune-plan--nelisp manifest-file)
    (let* ((manifest (nelix-manifest-load manifest-file))
           (selection (nelix-manifest-select-backend manifest))
           (backend (plist-get selection :backend))
           (pins (plist-get manifest :pins))
           (extras (nelix-manifest-extra-entries manifest backend))
           (remove nil)
           (protected nil))
      (dolist (entry extras)
        (if (member (plist-get entry :name) pins)
            (push entry protected)
          (push entry remove)))
      (list :backend backend
            :backend-selection selection
            :remove (nreverse remove)
            :keep (nelix-manifest-installation-report manifest backend)
            :protected (nreverse protected)
            :reason (and protected '(:pinned))))))

;;;###autoload
(defun nelix-sync (manifest-file &rest args)
  "Converge the profile to MANIFEST-FILE.

When ARGS contains `:prune t', remove unmanaged entries reported
by `nelix-prune-plan'.  When ARGS contains `:locked t', require a
matching lock before any install or prune mutation.  Remove safety
uses the same `:allow-remove' and `:allow-remove-count' options as
`nelix-apply'."
  (let* ((locked (plist-get args :locked))
         (allow-remove (plist-get args :allow-remove))
         (allow-remove-count (plist-get args :allow-remove-count))
         (apply-report (apply #'nelix-apply
                              manifest-file
                              (append
                               (and locked (list :locked t))
                               (and allow-remove
                                    (list :allow-remove t))
                               (and allow-remove-count
                                    (list :allow-remove-count
                                          allow-remove-count)))))
         (prune (plist-get args :prune))
         (backend (plist-get apply-report :backend))
         (pruned nil))
    (when prune
      (if (eq backend 'nelix-native)
          (let* ((plan (nelix-prune-plan manifest-file))
                 (remove (plist-get plan :remove))
                 (profile-name (plist-get apply-report :profile))
                 (prune-report
                  (nelix-profile-prune
                   profile-name
                   (mapcar (lambda (entry) (plist-get entry :name))
                           remove)
                   (plist-get (plist-get apply-report :backend-selection)
                              :system)))
                 (gc-report (nelix-store-gc :profile profile-name)))
            (setq pruned (plist-get prune-report :removed))
            (setq apply-report
                  (plist-put apply-report :prune-report prune-report))
            (setq apply-report
                  (plist-put apply-report :gc gc-report)))
        (dolist (entry (plist-get (nelix-prune-plan manifest-file) :remove))
          (nelix-uninstall (plist-get entry :name))
          (push entry pruned))))
    (plist-put apply-report :pruned (nreverse pruned))))

(defun nelix-manifest--digest-file (file)
  "Return sha256 digest string for FILE."
  (cond
   ((fboundp 'secure-hash)
    (concat "sha256-" (secure-hash 'sha256
                                    (anvil-pkg-compat-read-file file))))
   ((anvil-pkg-compat-executable-find "sha256sum")
    (let* ((res (anvil-pkg-compat-call-process
                 "sha256sum" (list (expand-file-name file))))
           (stdout (or (plist-get res :stdout) "")))
      (unless (eq 0 (plist-get res :exit))
        (signal 'anvil-pkg-error
                (list (format "nelix-lock: sha256sum failed for %s" file))))
      (concat "sha256-" (car (split-string stdout)))))
   (t
    (signal 'anvil-pkg-error
            (list "nelix-lock: no sha256 backend available")))))

(defun nelix-manifest--digest-string (string)
  "Return sha256 digest string for STRING."
  (cond
   ((fboundp 'secure-hash)
    (concat "sha256-" (secure-hash 'sha256 string)))
   ((anvil-pkg-compat-executable-find "sha256sum")
    (let ((tmp (make-temp-file "nelix-lock-digest-" nil ".txt")))
      (unwind-protect
          (progn
            (anvil-pkg-compat-write-file tmp string)
            (nelix-manifest--digest-file tmp))
        (when (anvil-pkg-compat-file-exists-p tmp)
          (delete-file tmp)))))
   (t
    (signal 'anvil-pkg-error
            (list "nelix-lock: no sha256 backend available")))))

(defun nelix-manifest--lock-files (manifest)
  "Return lock file digest rows for MANIFEST."
  (let ((rows (list (list :role 'manifest
                          :path (plist-get manifest :file)
                          :digest (nelix-manifest--digest-file
                                   (plist-get manifest :file))))))
    (dolist (file (plist-get manifest :imports) (nreverse rows))
      (push (list :role 'import
                  :path file
                  :digest (nelix-manifest--digest-file file))
            rows))))

(defun nelix-manifest--combined-file-digest (file-rows)
  "Return one deterministic digest for FILE-ROWS."
  (nelix-manifest--digest-string
   (mapconcat
    (lambda (row)
      (format "%S\0%s\0%s"
              (plist-get row :role)
              (expand-file-name (plist-get row :path))
              (plist-get row :digest)))
    file-rows
    "\0")))

(defun nelix-manifest--target-backend (manifest)
  "Return selected backend for MANIFEST, or nil when unavailable."
  (plist-get (nelix-manifest-select-backend manifest) :backend))

(defun nelix-manifest--lock-package-row (manifest backend row)
  "Return one strict package lock row for MANIFEST BACKEND and install ROW."
  (let* ((target (plist-get row :target))
         (entry (plist-get row :entry))
         (name (plist-get row :name))
         (pins (plist-get manifest :pins))
         (system (nelix-current-system))
         (native-entry (and (eq backend 'nelix-native) entry))
         (recipe (and (eq backend 'nelix-native)
                      (nelix-registry-get name)))
         (recipe-system-entry
          (and recipe
               (nelix-manifest--recipe-system-entry recipe system))))
    (append
     (list :name name
           :target target
           :resolved-target target
           :installed-name (plist-get entry :name)
           :pinned (and (member name pins) t)
           :backend backend
           :system system
           :source (if (eq backend 'nelix-native) 'registry 'nixpkgs)
           :nix-channel (and (eq backend 'nix)
                             (plist-get manifest :nix-channel))
           :attr-path (plist-get row :attr-path)
           :original-url (plist-get row :original-url))
     (when native-entry
       (list :version (plist-get native-entry :version)
             :hash (plist-get native-entry :hash)
             :store-path (plist-get native-entry :store-path)))
     (when recipe
       (list :recipe-version (plist-get recipe :version)
             :recipe-source (plist-get recipe-system-entry :source)
             :recipe-install (plist-get recipe-system-entry :install)
             :recipe-dependencies
             (plist-get recipe-system-entry :dependencies)
             :recipe-class (plist-get recipe :class))))))

(defun nelix-manifest--lock-native-dependency-packages
    (manifest backend packages)
  "Return PACKAGES plus native dependency package rows.

Dependency rows are materialized from the registry while the lock is
written.  Locked apply later replays those rows without consulting the
registry again."
  (let ((known (make-hash-table :test 'equal))
        (queue packages)
        (extra nil))
    (dolist (package packages)
      (puthash (plist-get package :name) t known))
    (while queue
      (let ((package (pop queue)))
        (dolist (dependency (plist-get package :recipe-dependencies))
          (let* ((name (nelix-manifest--lock-dependency-name dependency))
                 (recipe (nelix-registry-get name)))
            (unless (gethash name known)
              (unless recipe
                (signal 'anvil-pkg-error
                        (list (format "nelix lock: missing dependency recipe %s"
                                      name))))
              (let ((row (nelix-manifest--lock-package-row
                          manifest backend
                          (list :name name :target name))))
                (unless (plist-get row :recipe-install)
                  (signal 'anvil-pkg-error
                          (list (format "nelix lock: dependency %s has no native recipe for %S"
                                        name
                                        (nelix-current-system)))))
                (puthash name t known)
                (push row extra)
                (push row queue)))))))
    (append packages (nreverse extra))))

(defun nelix-manifest--lock-packages (manifest backend)
  "Return strict package rows for MANIFEST under BACKEND."
  (let ((packages
         (mapcar (lambda (row)
                   (nelix-manifest--lock-package-row manifest backend row))
                 (nelix-manifest-installation-report manifest backend))))
    (if (eq backend 'nelix-native)
        (nelix-manifest--lock-native-dependency-packages
         manifest backend packages)
      packages)))

(defun nelix-manifest--string-source (string)
  "Return a readable Elisp string literal for STRING.

NeLisp's standalone formatter is intentionally still small and may not
quote top-level strings with `%S'.  Lock files are source files, so
string literals are emitted explicitly here instead of depending on the
runtime formatter."
  (let ((i 0)
        (n (length string))
        (out "\""))
    (while (< i n)
      (let ((piece (substring string i (1+ i))))
        (setq out
              (concat out
                      (cond
                       ((equal piece "\\") "\\\\")
                       ((equal piece "\"") "\\\"")
                       ((equal piece "\n") "\\n")
                       ((equal piece "\r") "\\r")
                       ((equal piece "\t") "\\t")
                       (t piece)))))
      (setq i (1+ i)))
    (concat out "\"")))

(defun nelix-manifest--format-lock-value (value)
  "Return Elisp source for VALUE in a generated lock file."
  (cond
   ((or (null value) (eq value t)) (format "%S" value))
   ((stringp value) (nelix-manifest--string-source value))
   ((symbolp value) (format "'%S" value))
   ((consp value) (format "'%S" value))
   (t (format "%S" value))))

(defun nelix-lock--substring-index (needle haystack &optional start)
  "Return the first index of NEEDLE in HAYSTACK at or after START."
  (let* ((needle-len (length needle))
         (limit (- (length haystack) needle-len))
         (i (or start 0))
         found)
    (while (and (null found) (<= i limit))
      (if (equal needle (substring haystack i (+ i needle-len)))
          (setq found i)
        (setq i (1+ i))))
    found))

(defun nelix-lock--substring-until (text start delimiters)
  "Return substring of TEXT from START until one of DELIMITERS."
  (let ((i start)
        (n (length text))
        stop)
    (while (and (< i n) (null stop))
      (if (member (substring text i (1+ i)) delimiters)
          (setq stop i)
        (setq i (1+ i))))
    (substring text start (or stop i))))

(defun nelix-lock--text-string (text key)
  "Return generated lock TEXT string value for KEY."
  (let* ((prefix (format ":%s \"" key))
         (start (nelix-lock--substring-index prefix text)))
    (when start
      (setq start (+ start (length prefix)))
      (let ((end (nelix-lock--substring-index "\"" text start)))
        (and end (substring text start end))))))

(defun nelix-lock--text-integer (text key)
  "Return generated lock TEXT integer value for KEY."
  (let* ((prefix (format ":%s " key))
         (start (nelix-lock--substring-index prefix text))
         value)
    (when start
      (setq start (+ start (length prefix)))
      (setq value (nelix-lock--substring-until
                   text start '(" " "\t" "\n" ")"))))
    (and value (string-to-number value))))

(defun nelix-lock--text-symbol (text key)
  "Return generated lock TEXT symbol value for KEY."
  (let* ((prefix (format ":%s '" key))
         (start (nelix-lock--substring-index prefix text))
         value)
    (when start
      (setq start (+ start (length prefix)))
      (setq value (nelix-lock--substring-until
                   text start '(" " "\t" "\n" ")"))))
    (and value (intern value))))

(defun nelix-lock--row-string (row key)
  "Return generated lock ROW string value for KEY.

The generated lock currently emits nil as a literal symbol.  Nil string
fields are returned as nil."
  (nelix-lock--text-string row key))

(defun nelix-lock--row-symbol (row key)
  "Return generated lock ROW symbol value for KEY."
  (let* ((prefix (format ":%s " key))
         (start (nelix-lock--substring-index prefix row))
         value)
    (when start
      (setq start (+ start (length prefix)))
      (setq value (nelix-lock--substring-until
                   row start '(" " "\t" "\n" ")"))))
    (cond
     ((null value) nil)
     ((equal value "nil") nil)
     ((equal value "t") t)
     (t (intern value)))))

(defun nelix-lock--row-bool (row key)
  "Return generated lock ROW boolean value for KEY."
  (let* ((prefix (format ":%s " key))
         (start (nelix-lock--substring-index prefix row))
         value)
    (when start
      (setq start (+ start (length prefix)))
      (setq value (nelix-lock--substring-until
                   row start '(" " "\t" "\n" ")"))))
    (and (equal value "t") t)))

(defun nelix-lock--row-has-key-p (row key)
  "Return non-nil when generated lock ROW contains KEY."
  (and (nelix-lock--substring-index (format ":%s " key) row) t))

(defun nelix-lock--row-string-list (row key)
  "Return generated lock ROW string list value for KEY.

Only the compact dependency-list shape emitted by Nelix locks is
supported.  Nil, absent, and empty lists all return nil."
  (let* ((prefix (format ":%s " key))
         (start (nelix-lock--substring-index prefix row))
         end chunk strings q1 q2)
    (when start
      (setq start (+ start (length prefix)))
      (unless (equal "nil" (substring row start (min (+ start 3)
                                                     (length row))))
        (setq end (or (nelix-lock--substring-index " :" row start)
                      (length row)))
        (setq chunk (substring row start end))
        (while (setq q1 (nelix-lock--substring-index "\"" chunk))
          (setq q2 (nelix-lock--substring-index "\"" chunk (1+ q1)))
          (if q2
              (progn
                (push (substring chunk (1+ q1) q2) strings)
                (setq chunk (substring chunk (1+ q2))))
            (setq chunk "")))))
    (nreverse strings)))

(defun nelix-lock--row-sexp-after (row key)
  "Read the Lisp value following \":KEY \" in lock ROW, or nil on failure.
Reads one s-expression with `read-from-string', so a nested recipe plist
(e.g. =:recipe-install (:type script-shim ...)=) replays faithfully on
standalone NeLisp without parsing the whole lock as one sexp."
  (let* ((marker (concat ":" key " "))
         (idx (nelix-lock--substring-index marker row)))
    (when idx
      (condition-case nil
          (car (read-from-string (substring row (+ idx (length marker)))))
        (error nil)))))

(defun nelix-lock--text-package-native-fields (row)
  "Return native replay fields read from generated lock ROW.

The standalone text reader preserves key presence so schema validation does
not reject valid native locks, and replays the recipe source/install plists
faithfully so the NeLisp native apply path can rebuild recipes."
  (let (fields)
    (when (nelix-lock--row-has-key-p row "recipe-version")
      (setq fields
            (append fields
                    (list :recipe-version
                          (nelix-lock--row-string row "recipe-version")))))
    (when (nelix-lock--row-has-key-p row "recipe-source")
      (setq fields (append fields
                           (list :recipe-source
                                 (nelix-lock--row-sexp-after row "recipe-source")))))
    (when (nelix-lock--row-has-key-p row "recipe-install")
      (setq fields (append fields
                           (list :recipe-install
                                 (nelix-lock--row-sexp-after row "recipe-install")))))
    (when (nelix-lock--row-has-key-p row "recipe-dependencies")
      (setq fields
            (append fields
                    (list :recipe-dependencies
                          (nelix-lock--row-string-list
                           row "recipe-dependencies")))))
    (when (nelix-lock--row-has-key-p row "recipe-class")
      (setq fields
            (append fields
                    (list :recipe-class
                          (nelix-lock--row-symbol row "recipe-class")))))
    fields))

(defun nelix-lock--text-manifest-files (text)
  "Return generated lock manifest file rows from TEXT."
  (let ((pos 0)
        start role-start role path-start path digest-start digest
        rows)
    (while (setq start (nelix-lock--substring-index "(:role " text pos))
      (setq role-start (+ start (length "(:role ")))
      (setq role (nelix-lock--substring-until
                  text role-start '(" " "\t" "\n" ")")))
      (setq path-start
            (nelix-lock--substring-index " :path \"" text role-start))
      (setq digest-start
            (and path-start
                 (nelix-lock--substring-index " :digest \"" text path-start)))
      (when (and path-start digest-start)
        (setq path-start (+ path-start (length " :path \"")))
        (setq path
              (substring text path-start
                         (nelix-lock--substring-index "\"" text path-start)))
        (setq digest-start (+ digest-start (length " :digest \"")))
        (setq digest
              (substring text digest-start
                         (nelix-lock--substring-index "\"" text digest-start)))
        (push (list :role (intern role)
                    :path path
                    :digest digest)
              rows))
      (setq pos (1+ role-start)))
    (nreverse rows)))

(defun nelix-lock--text-package-row (row)
  "Return one generated lock package ROW as a plist."
  (append
   (list :name (nelix-lock--row-string row "name")
         :target (nelix-lock--row-string row "target")
         :resolved-target (nelix-lock--row-string row "resolved-target")
         :installed-name (nelix-lock--row-string row "installed-name")
         :pinned (nelix-lock--row-bool row "pinned")
         :backend (nelix-lock--row-symbol row "backend")
         :system (nelix-lock--row-symbol row "system")
         :source (nelix-lock--row-symbol row "source")
         :nix-channel (nelix-lock--row-string row "nix-channel")
         :attr-path (nelix-lock--row-string row "attr-path")
         :original-url (nelix-lock--row-string row "original-url"))
   (nelix-lock--text-package-native-fields row)))

(defun nelix-lock--text-packages (text)
  "Return generated lock package rows from TEXT."
  (let ((pos 0)
        start
        starts
        rows)
    (while (setq start (nelix-lock--substring-index "(:name \"" text pos))
      (push start starts)
      (setq pos (+ start (length "(:name \""))))
    (setq starts (nreverse starts))
    (while starts
      (let* ((start (car starts))
             (end (or (cadr starts)
                      (or (nelix-lock--substring-index "\n)" text start)
                          (length text))))
             (row (substring text start end)))
        (push (nelix-lock--text-package-row row) rows)
        (setq starts (cdr starts))))
    (nreverse rows)))

(defun nelix-lock-read--nelisp-text (lock-file)
  "Read generated LOCK-FILE without evaluating it.

This avoids loading the full lock S-expression in standalone NeLisp,
where large quoted package rows are still a runtime risk."
  (let* ((text (anvil-pkg-compat-read-file lock-file))
         (schema (nelix-lock--text-string text "schema"))
         (schema-version (nelix-lock--text-integer text "schema-version"))
         (version (nelix-lock--text-integer text "version")))
    (unless (and (equal schema nelix-lock-schema-name)
                 (integerp schema-version)
                 (= schema-version nelix-lock-schema-version)
                 (integerp version)
                 (= version nelix-lock-schema-version))
      (signal 'anvil-pkg-error
              (list (format "nelix-lock-read: unsupported generated lock schema in %s"
                            lock-file))))
    (list :schema schema
          :schema-version schema-version
          :version version
          :format (nelix-lock--text-symbol text "format")
          :lock (nelix-lock--text-string text "lock")
          :manifest-digest (nelix-lock--text-string text "manifest-digest")
          :manifest-files (nelix-lock--text-manifest-files text)
          :profile (nelix-lock--text-string text "profile")
          :backend (nelix-lock--text-symbol text "backend")
          :system (nelix-lock--text-symbol text "system")
          :nix-channel (nelix-lock--text-string text "nix-channel")
          :nix-version (nelix-lock--text-string text "nix-version")
          :generated-at (nelix-lock--text-string text "generated-at")
          :packages (nelix-lock--text-packages text))))

;;;###autoload
(defun nelix-lock (&rest plist)
  "Record and return a normalized lock PLIST.

This is the constructor used inside generated lock files."
  (setq nelix-lock-last plist))

(defun nelix-lock--plist-has-key-p (plist key)
  "Return non-nil when PLIST contains KEY, even when its value is nil."
  (let ((rest plist)
        found)
    (while (and rest (not found))
      (when (eq (car rest) key)
        (setq found t))
      (setq rest (cddr rest)))
    found))

(defun nelix-lock--json-key-keyword (key)
  "Return plist keyword corresponding to public JSON schema KEY."
  (intern (concat ":" key)))

(defun nelix-lock--shape-missing-key (plist keys)
  "Return the first required JSON key in KEYS missing from PLIST."
  (let ((rest keys)
        missing)
    (while (and rest (null missing))
      (unless (nelix-lock--plist-has-key-p
               plist
               (nelix-lock--json-key-keyword (car rest)))
        (setq missing (car rest)))
      (setq rest (cdr rest)))
    missing))

(defun nelix-lock--current-v2-required-keys (schema)
  "Return top-level lock keys required for a current v2 lock with SCHEMA."
  (let ((keys nelix-lock-schema-required-json-keys)
        result)
    (while keys
      (let ((key (car keys)))
        (unless (and (null schema)
                     (or (equal key "schema")
                         (equal key "schema-version")))
          (push key result)))
      (setq keys (cdr keys)))
    (nreverse result)))

(defun nelix-lock--schema-shape-error (lock schema schema-version)
  "Return a stable v2 schema shape error for LOCK, or nil."
  (when (and (integerp schema-version)
             (= schema-version nelix-lock-schema-version))
    (let ((missing (nelix-lock--shape-missing-key
                    lock
                    (nelix-lock--current-v2-required-keys schema))))
      (cond
       (missing
        (format "lock is missing schema-required key :%s" missing))
       ((not (listp (plist-get lock :packages)))
        "lock packages is not a list")
       (t
        (let ((rows (plist-get lock :packages))
              (index 0)
              error)
          (while (and rows (null error))
            (let ((row (car rows)))
              (setq index (1+ index))
              (cond
               ((not (listp row))
                (setq error
                      (format "lock package row %d is not a plist" index)))
               ((setq missing
                      (nelix-lock--shape-missing-key
                       row
                       nelix-lock-schema-package-required-json-keys))
                (setq error
                      (format
                       "lock package row %d is missing schema-required key :%s"
                       index
                       missing)))
               ((and (eq 'nix (plist-get row :backend))
                     (not (eq 'nixpkgs (plist-get row :source))))
                (setq error
                      (format
                       "lock package row %d has invalid source %S for nix backend"
                       index
                       (plist-get row :source))))
               ((and (eq 'nelix-native (plist-get row :backend))
                     (not (eq 'registry (plist-get row :source))))
                (setq error
                      (format
                       "lock package row %d has invalid source %S for native backend"
                       index
                       (plist-get row :source))))
               ((and (eq 'nix (plist-get row :backend))
                     (setq missing
                           (nelix-lock--shape-missing-key
                            row
                            nelix-lock-schema-nix-package-required-json-keys)))
                (setq error
                      (format
                       "lock package row %d is missing nix schema-required key :%s"
                       index
                       missing)))
               ((and (eq 'nelix-native (plist-get row :backend))
                     (setq missing
                           (nelix-lock--shape-missing-key
                            row
                            nelix-lock-schema-native-package-required-json-keys)))
                (setq error
                      (format
                       "lock package row %d is missing native schema-required key :%s"
                       index
                       missing)))))
            (setq rows (cdr rows)))
          error))))))

;;;###autoload
(defun nelix-lock-schema-check (lock)
  "Return schema compatibility information for LOCK."
  (let* ((schema (plist-get lock :schema))
         (schema-version (or (plist-get lock :schema-version)
                             (plist-get lock :version)))
         (version (plist-get lock :version))
         (shape-error (nelix-lock--schema-shape-error
                       lock schema schema-version))
         (ok (and (or (null schema)
                      (equal schema nelix-lock-schema-name))
                  (integerp schema-version)
                  (<= schema-version nelix-lock-schema-version)
                  (integerp version)
                  (>= version 1)
                  (null shape-error))))
    (list :ok (and ok t)
          :schema (or schema nelix-lock-schema-name)
          :schema-version schema-version
          :current-schema nelix-lock-schema-name
          :current-schema-version nelix-lock-schema-version
          :version version
          :shape-ok (null shape-error)
          :shape-error shape-error)))

;;;###autoload
(defun nelix-lock-read (manifest-file)
  "Read the lock file associated with MANIFEST-FILE."
  (let* ((lock-file (nelix-manifest--selected-lock-file-name manifest-file))
         (nelix-lock-last nil))
    (unless (anvil-pkg-compat-file-exists-p lock-file)
      (signal 'anvil-pkg-error
              (list (format "nelix-lock-read: file does not exist: %s"
                            lock-file))))
    (if (anvil-pkg-compat--standalone-nelisp-p)
        (nelix-lock-read--nelisp-text lock-file)
      (nelix-manifest--load-elisp-file lock-file)
      (unless nelix-lock-last
        (signal 'anvil-pkg-error
          (list (format "nelix-lock-read: %s did not call nelix-lock"
                              lock-file))))
      nelix-lock-last)))

(defun nelix-manifest--maybe-lock-read (manifest-file)
  "Return MANIFEST-FILE lock data, or nil when no lock exists."
  (if (anvil-pkg-compat--standalone-nelisp-p)
      (and (anvil-pkg-compat-file-exists-p
            (nelix-manifest-lock-file-name manifest-file))
           '(:nelix-lock-present t))
    (condition-case _
        (nelix-lock-read manifest-file)
      (error nil))))

;;;###autoload
(defun nelix-lock-write (manifest-file)
  "Write a lock file next to MANIFEST-FILE and return its plist."
  (let* ((manifest (nelix-manifest-load manifest-file))
         (files (nelix-manifest--lock-files manifest))
         (digest (nelix-manifest--combined-file-digest files))
         (backend (nelix-manifest--target-backend manifest))
         (_registry-update
          (and (eq backend 'nelix-native)
               (nelix-registry-update)))
         (packages (nelix-manifest--lock-packages manifest backend))
         (lock-file (nelix-manifest-lock-file-name manifest-file))
         (lock (list :schema nelix-lock-schema-name
                     :schema-version nelix-lock-schema-version
                     :version nelix-lock-schema-version
                     :format 'sexp
                     :lock lock-file
                     :manifest-digest digest
                     :manifest-files files
                     :profile (plist-get manifest :profile)
                     :backend backend
                     :system (nelix-current-system)
                     :nix-channel (plist-get manifest :nix-channel)
                     :nix-version (condition-case _
                                      (anvil-pkg--detect-nix-version)
                                    (error nil))
                     :generated-at (format-time-string "%FT%T%z")
                     :packages packages)))
    (anvil-pkg-compat-write-file
     lock-file
     (concat ";;; " (file-name-nondirectory lock-file)
             " --- generated Nelix lock file -*- lexical-binding: t; -*-\n\n"
             "(require 'nelix-manifest)\n\n"
             "(nelix-lock\n"
             (mapconcat (lambda (pair)
                          (format " %S %s"
                                  (car pair)
                                  (nelix-manifest--format-lock-value
                                   (cadr pair))))
                        (let (pairs rest)
                          (setq rest lock)
                          (while rest
                            (push (list (car rest) (cadr rest)) pairs)
                            (setq rest (cddr rest)))
                          (nreverse pairs))
                        "\n")
             ")\n"))
    lock))

;;;###autoload
(defun nelix-lock-check (manifest-file)
  "Return whether MANIFEST-FILE matches its lock digest."
  (let* ((lock (nelix-lock-read manifest-file))
         (schema-check (nelix-lock-schema-check lock))
         (manifest (nelix-manifest-load manifest-file))
         (actual-files (nelix-manifest--lock-files manifest))
         (actual (nelix-manifest--combined-file-digest actual-files))
         (expected (plist-get lock :manifest-digest))
         (expected-files (plist-get lock :manifest-files)))
    (list :ok (and (plist-get schema-check :ok)
                   (equal expected actual)
                   (equal expected-files actual-files))
          :manifest (expand-file-name manifest-file)
          :lock (nelix-manifest-lock-file-name manifest-file)
          :schema-check schema-check
          :expected expected
          :actual actual
          :expected-files expected-files
          :actual-files actual-files)))

(defun nelix-lock-check--nelisp (manifest-file &optional manifest)
  "Return a lightweight lock check for standalone NeLisp.

The standalone runtime avoids loading or deeply comparing the full lock
S-expression.  Schema and combined manifest/import digest are still
verified before locked apply may mutate a profile."
  (nelix-manifest--nelisp-progress :lock-check-read-begin)
  (let* ((lock (nelix-lock-read manifest-file))
         (schema-check (nelix-lock-schema-check lock))
         actual-files actual expected)
    (nelix-manifest--nelisp-progress :lock-check-read-end)
    (unless manifest
      (setq manifest (nelix-manifest-load manifest-file))
      (nelix-manifest--nelisp-progress :lock-check-manifest-loaded))
    (setq actual-files (nelix-manifest--lock-files manifest))
    (setq actual (nelix-manifest--combined-file-digest actual-files))
    (setq expected (plist-get lock :manifest-digest))
    (list :ok (and (plist-get schema-check :ok)
                   (equal expected actual))
          :manifest (expand-file-name manifest-file)
          :lock (nelix-manifest-lock-file-name manifest-file)
          :schema-check schema-check
          :expected expected
          :actual actual
          :expected-files (plist-get lock :manifest-files)
          :actual-files actual-files)))

;;;###autoload
(defun nelix-lock-validate (manifest-file)
  "Validate the lockfile associated with MANIFEST-FILE without drift checks."
  (let* ((lock (nelix-lock-read manifest-file))
         (schema-check (nelix-lock-schema-check lock))
         (format (plist-get lock :format))
         (format-ok (or (null format)
                        (eq format 'sexp)
                        (equal format "sexp"))))
    (list :ok (and (plist-get schema-check :ok) format-ok t)
          :manifest (expand-file-name manifest-file)
          :lock (nelix-manifest-lock-file-name manifest-file)
          :schema-check schema-check
          :schema (plist-get schema-check :schema)
          :schema-version (plist-get schema-check :schema-version)
          :version (plist-get schema-check :version)
          :format (or format 'sexp)
          :format-ok format-ok)))

;;;###autoload
(defun nelix-lock-migrate (manifest-file &rest args)
  "Migrate MANIFEST-FILE lock data to the current lock schema.

When ARGS contains `:dry-run' non-nil, return the migration plan without
writing a lockfile.  Migration preserves old lockfiles and writes the current
v2 S-expression lock at `nelix-manifest-lock-file-name'."
  (let* ((dry-run (plist-get args :dry-run))
         (source-lock-file (nelix-manifest--selected-lock-file-name
                            manifest-file))
         (target-lock-file (nelix-manifest-lock-file-name manifest-file))
         (legacy-lock-file (nelix-manifest--legacy-lock-file-name
                            manifest-file))
         (lock (nelix-lock-read manifest-file))
         (schema-check (nelix-lock-schema-check lock))
         (source-schema-version (plist-get schema-check :schema-version))
         (source-format (or (plist-get lock :format) 'sexp))
         (needed (or (not (equal (expand-file-name source-lock-file)
                                 (expand-file-name target-lock-file)))
                     (not (plist-get schema-check :ok))
                     (not (and (integerp source-schema-version)
                               (= source-schema-version
                                  nelix-lock-schema-version)))
                     (not (or (eq source-format 'sexp)
                              (equal source-format "sexp")))))
         (report (list :ok (plist-get schema-check :ok)
                       :status (if needed 'migration-needed 'current)
                       :needed needed
                       :dry-run (and dry-run t)
                       :manifest (expand-file-name manifest-file)
                       :source-lock source-lock-file
                       :target-lock target-lock-file
                       :legacy-lock legacy-lock-file
                       :schema-check schema-check
                       :from-schema-version source-schema-version
                       :to-schema-version nelix-lock-schema-version
                       :from-format source-format
                       :to-format 'sexp)))
    (if dry-run
        report
      (unless (plist-get schema-check :ok)
        (signal 'anvil-pkg-error
                (list (format "nelix-lock-migrate: unsupported lock schema in %s"
                              source-lock-file))))
      (let ((written (nelix-lock-write manifest-file)))
        (setq report (plist-put report :status 'migrated))
        (setq report (plist-put report :ok t))
        (setq report (plist-put report :written-lock
                                (plist-get written :lock)))
        (plist-put report :written-schema-version
                   (plist-get written :schema-version))))))

(defun nelix-lock--file-row-path (row)
  "Return ROW path normalized for comparisons."
  (expand-file-name (plist-get row :path)))

(defun nelix-lock--file-row-by-path (rows path)
  "Return file row in ROWS matching PATH."
  (let ((normalized (expand-file-name path))
        found)
    (while (and rows (null found))
      (let ((row (car rows)))
        (when (equal normalized (nelix-lock--file-row-path row))
          (setq found row)))
      (setq rows (cdr rows)))
    found))

(defun nelix-lock--file-diff (expected actual)
  "Return path-level differences between EXPECTED and ACTUAL file rows."
  (let (added removed changed unchanged)
    (dolist (row actual)
      (let* ((path (plist-get row :path))
             (expected-row (nelix-lock--file-row-by-path expected path))
             (actual-digest (plist-get row :digest))
             (expected-digest (and expected-row
                                   (plist-get expected-row :digest))))
        (cond
         ((null expected-row)
          (push row added))
         ((equal expected-digest actual-digest)
          (push row unchanged))
         (t
          (push (list :path path
                      :role (plist-get row :role)
                      :expected expected-digest
                      :actual actual-digest)
                changed)))))
    (dolist (row expected)
      (unless (nelix-lock--file-row-by-path actual (plist-get row :path))
        (push row removed)))
    (list :added (nreverse added)
          :removed (nreverse removed)
          :changed (nreverse changed)
          :unchanged (nreverse unchanged))))

;;;###autoload
(defun nelix-lock-diff (manifest-file)
  "Return read-only differences between MANIFEST-FILE and its lock."
  (let* ((check (if (anvil-pkg-compat--standalone-nelisp-p)
                    (nelix-lock-check--nelisp manifest-file)
                  (nelix-lock-check manifest-file)))
         (expected-files (plist-get check :expected-files))
         (actual-files (plist-get check :actual-files))
         (file-diff (nelix-lock--file-diff expected-files actual-files)))
    (list :ok (and (plist-get check :ok) t)
          :status (if (plist-get check :ok) 'clean 'drift)
          :manifest (plist-get check :manifest)
          :lock (plist-get check :lock)
          :schema-check (plist-get check :schema-check)
          :manifest-digest (list :expected (plist-get check :expected)
                                 :actual (plist-get check :actual))
          :manifest-files file-diff)))

(defun nelix-manifest--nix-flakeref (manifest target)
  "Return the Nix flake reference for MANIFEST TARGET."
  (let ((name (nelix-manifest--target-name target)))
    (if (string-match-p "#" name)
        name
      (format "%s#%s" (plist-get manifest :nix-channel) name))))

(defun nelix-manifest--nix-install-argv (manifest target)
  "Return argv for installing TARGET from MANIFEST through Nix."
  (append (list "profile" (anvil-pkg--nix-install-subcommand))
          (anvil-pkg--profile-args)
          (list (nelix-manifest--nix-flakeref manifest target))))

(defun nelix-manifest--nix-remove-argv (entry)
  "Return argv for removing installed ENTRY through Nix."
  (append (list "profile" "remove" (plist-get entry :name))
          (anvil-pkg--profile-args)))

(defun nelix-manifest--lock-package-by-name (lock name)
  "Return LOCK package named NAME."
  (let (found)
    (dolist (package (plist-get lock :packages) found)
      (when (and (null found)
                 (equal name (plist-get package :name)))
        (setq found package)))))

(defun nelix-manifest--plan-install-action
    (manifest lock row &optional backend selection)
  "Return one install action for MANIFEST LOCK and missing ROW."
  (let* ((name (plist-get row :name))
         (backend* (or backend 'nix))
         (package (and lock (nelix-manifest--lock-package-by-name lock name)))
         (target (or (plist-get package :resolved-target)
                     (plist-get package :target)
                     (plist-get row :target)))
         (system (plist-get selection :system))
         (recipe (and (eq backend* 'nelix-native)
                      (nelix-registry-get name)))
         (recipe-system-entry
          (and recipe
               (nelix-manifest--recipe-system-entry recipe system))))
    (append
     (list :action 'install
           :name name
           :backend backend*
           :target target
           :resolved-target target
           :installed-name nil
           :pinned (and (member name (plist-get manifest :pins)) t)
           :lock package)
     (pcase backend*
       ('nix
        (list :argv (nelix-manifest--nix-install-argv manifest target)))
       ('nelix-native
        (append
         (list :profile (plist-get manifest :profile)
               :system system
               :source 'registry
               :recipe-version (plist-get recipe :version)
               :recipe-class (plist-get recipe :class)
               :recipe-source (plist-get recipe-system-entry :source)
               :recipe-install (plist-get recipe-system-entry :install)
               :recipe-dependencies
               (plist-get recipe-system-entry :dependencies))
         (cond
          ((null recipe)
           (list :blocked :missing-registry-recipe))
          ((null recipe-system-entry)
           (list :blocked :unsupported-system))
          (t nil))))
       (_ nil)))))

(defun nelix-manifest--plan-remove-action
    (entry &optional backend selection profile)
  "Return one remove action for installed ENTRY."
  (let ((backend* (or backend 'nix)))
    (append
     (list :action 'remove
           :name (plist-get entry :name)
           :backend backend*
           :target nil
           :resolved-target nil
           :installed-name (plist-get entry :name)
           :pinned nil
           :entry entry)
     (pcase backend*
       ('nix
        (list :argv (nelix-manifest--nix-remove-argv entry)))
       ('nelix-native
        (list :profile profile
              :system (plist-get selection :system)
              :store-path (plist-get entry :store-path)
              :version (plist-get entry :version)))
       (_ nil)))))

(defun nelix-manifest--plan-keep-action (row)
  "Return one keep action for installed ROW."
  (list :action 'keep
        :name (plist-get row :name)
        :backend (plist-get row :backend)
        :target (plist-get row :target)
        :resolved-target (plist-get row :target)
        :installed-name (plist-get (plist-get row :entry) :name)
        :pinned nil
        :entry (plist-get row :entry)))

(defun nelix-manifest--run-nix-command (argv)
  "Run Nix command ARGV and return a result plist."
  (anvil-pkg--ensure-nix)
  (let ((res (anvil-pkg--call-nix argv)))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-nix-failed
              (list (format "nix %s failed (exit %s): %s"
                            (mapconcat #'identity argv " ")
                            (plist-get res :exit)
                            (anvil-pkg-compat-string-trim
                             (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))
    (list :argv argv
          :exit (plist-get res :exit)
          :stdout (plist-get res :stdout)
          :stderr (plist-get res :stderr))))

;;;###autoload
(defun nelix-plan (manifest-file)
  "Return a convergence plan for MANIFEST-FILE.

The plan is read-only.  It compares desired manifest targets with the
current profile, annotates the associated lock file when present, and
emits backend-specific install/remove rows.  Nix rows include the exact
argv that `nelix-apply' will execute; native rows include registry and
profile metadata for read-only review."
  (let* ((manifest (nelix-manifest-load manifest-file))
         (selection (nelix-manifest-select-backend manifest))
         (backend (plist-get selection :backend))
         (_registry-update
          (and (eq backend 'nelix-native)
               (nelix-registry-update)))
         (lock (nelix-manifest--maybe-lock-read manifest-file))
         (installed (nelix-manifest--installed-entries manifest backend))
         (targets (nelix-manifest-targets manifest backend))
         (report (nelix-manifest-installation-report-from-installed
                  manifest backend installed targets))
         (extras (nelix-manifest-extra-entries-from-installed
                  manifest backend installed targets))
         (pins (plist-get manifest :pins))
         install remove keep protected)
    (dolist (row report)
      (if (plist-get row :installed)
          (push (nelix-manifest--plan-keep-action row) keep)
        (push (nelix-manifest--plan-install-action
               manifest lock row backend selection)
              install)))
    (dolist (entry extras)
      (if (member (plist-get entry :name) pins)
          (push (list :action 'protect
                      :name (plist-get entry :name)
                      :backend backend
                      :installed-name (plist-get entry :name)
                      :pinned t
                      :entry entry)
                protected)
        (push (nelix-manifest--plan-remove-action
               entry backend selection (plist-get manifest :profile))
              remove)))
    (setq install (nreverse install)
          remove (nreverse remove)
          keep (nreverse keep)
          protected (nreverse protected))
    (list :operation 'apply
          :status 'planned
          :dry-run t
          :manifest (plist-get manifest :file)
          :lock (nelix-manifest-lock-file-name manifest-file)
          :lock-present (and lock t)
          :backend backend
          :backend-selection selection
          :profile (plist-get manifest :profile)
          :nix-profile (and (eq backend 'nix) anvil-pkg-profile-dir)
          :install install
          :remove remove
          :keep keep
          :protected protected
          :commands (and (eq backend 'nix) (append install remove))
          :count (+ (length install) (length remove))
          :empty (and (null install) (null remove)))))

(defun nelix-manifest--require-lock-ok (manifest-file)
  "Return lock check for MANIFEST-FILE or signal when it is not clean."
  (let ((check (condition-case err
                   (nelix-lock-check manifest-file)
                 (error
                  (signal 'anvil-pkg-error
                          (list (format "nelix locked mode: lock check failed for %s: %s"
                                        (expand-file-name manifest-file)
                                        (error-message-string err))))))))
    (unless (plist-get (plist-get check :schema-check) :ok)
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: lock schema incompatible for %s"
                            (expand-file-name manifest-file)))))
    (unless (plist-get check :ok)
      (signal 'anvil-pkg-error
              (list (format "nelix locked mode: lock drift for %s"
                            (expand-file-name manifest-file)))))
    check))

;;;###autoload
(defun nelix-profile-upgrade-plan (&optional name)
  "Return the profile-only upgrade plan for NAME."
  (pkg-upgrade-plan name))

(defun nelix-manifest--existing-file-p (path)
  "Return non-nil when PATH is a string naming an existing file."
  (and (stringp path)
       (anvil-pkg-compat-file-exists-p (expand-file-name path))))

;;;###autoload
(defun nelix-upgrade-plan (&optional manifest-or-name)
  "Return a read-only upgrade plan.

When MANIFEST-OR-NAME names an existing file, include
desired-state context from that manifest.  Otherwise delegate to
the profile-only `pkg-upgrade-plan' API for backward
compatibility."
  (if (nelix-manifest--existing-file-p manifest-or-name)
      (if (anvil-pkg-compat--standalone-nelisp-p)
          (nelix-upgrade-plan--nelisp manifest-or-name)
        (let* ((base (pkg-upgrade-plan))
               (manifest (nelix-manifest-load manifest-or-name))
               (audit (nelix-audit manifest-or-name)))
          (append (list :manifest (plist-get manifest :file)
                        :missing (plist-get audit :missing)
                        :extra (plist-get audit :extra)
                        :lock-drift (plist-get audit :lock-drift))
                  base)))
    (pkg-upgrade-plan manifest-or-name)))

(defun nelix-outdated--plist-p (value)
  "Return non-nil when VALUE looks like a plist."
  (and (consp value)
       (keywordp (car value))
       (zerop (% (length value) 2))))

(defun nelix-outdated--as-list (value)
  "Return VALUE as a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   (t (list value))))

(defun nelix-outdated--backend-symbol (backend)
  "Normalize BACKEND to a symbol."
  (cond
   ((null backend) nil)
   ((symbolp backend) backend)
   ((stringp backend) (intern backend))
   (t
    (signal 'anvil-pkg-error
            (list (format "nelix-outdated: BACKEND must be string, symbol, or nil, got %S"
                          backend))))))

(defun nelix-outdated--backend-policy (manifest backend)
  "Return the backend list for MANIFEST and optional BACKEND."
  (if backend
      (list (nelix-outdated--backend-symbol backend))
    (if manifest
        (nelix-manifest-backend-policy manifest)
      (nelix-backend-policy-for-os))))

(defun nelix-outdated--annotate-row (backend row)
  "Return ROW with BACKEND recorded."
  (if (and (listp row) (not (plist-get row :backend)))
      (append row (list :backend backend))
    row))

(defun nelix-outdated--annotate-rows (backend rows)
  "Return ROWS with BACKEND recorded on each row."
  (mapcar (lambda (row) (nelix-outdated--annotate-row backend row))
          rows))

(defun nelix-outdated--plan-section (plan key)
  "Return PLAN section KEY as a list."
  (cond
   ((nelix-outdated--plist-p plan)
    (nelix-outdated--as-list (plist-get plan key)))
   ((and (listp plan) (not (nelix-outdated--plist-p plan)))
    (let (rows)
      (dolist (subplan plan (nreverse rows))
        (setq rows
              (nconc (reverse
                      (nelix-outdated--plan-section subplan key))
                     rows)))))
   (t nil)))

(defun nelix-outdated--summarize-plan (backend targets plan)
  "Return a normalized outdated summary row for BACKEND TARGETS PLAN."
  (let* ((upgrade (nelix-outdated--annotate-rows
                   backend (nelix-outdated--plan-section plan :upgrade)))
         (pinned (nelix-outdated--annotate-rows
                  backend (nelix-outdated--plan-section plan :pinned)))
         (missing (nelix-outdated--annotate-rows
                   backend (nelix-outdated--plan-section plan :missing)))
         (blocked (nelix-outdated--annotate-rows
                   backend (nelix-outdated--plan-section plan :blocked)))
         (current (nelix-outdated--annotate-rows
                   backend (nelix-outdated--plan-section plan :current))))
    (list :backend backend
          :targets targets
          :plan plan
          :count (length upgrade)
          :outdated upgrade
          :pinned pinned
          :missing missing
          :blocked blocked
          :current current
          :empty (null upgrade))))

;;;###autoload
(defun nelix-outdated (&optional manifest-or-name backend)
  "Return a read-only cross-backend outdated report.

When MANIFEST-OR-NAME is an existing manifest file, use its backend
policy and declared targets.  Otherwise treat MANIFEST-OR-NAME as an
optional package/profile target.  BACKEND, when non-nil, restricts the
report to that backend.

This function does not mutate profiles, lock files, generations, or
native store entries."
  (let* ((manifest-file (and (nelix-manifest--existing-file-p
                              manifest-or-name)
                             (expand-file-name manifest-or-name)))
         (manifest (and manifest-file (nelix-manifest-load manifest-file)))
         (target (and (not manifest-file) manifest-or-name))
         (backends (nelix-outdated--backend-policy manifest backend))
         backend-reports skipped outdated pinned missing blocked current)
    (dolist (backend* backends)
      (if (nelix-backend-available-p backend*)
          (condition-case err
              (let* ((targets (if manifest
                                  (nelix-manifest-targets manifest backend*)
                                target))
                     (plan (nelix-backend-upgrade-plan backend* targets))
                     (summary (nelix-outdated--summarize-plan
                               backend* targets plan)))
                (push summary backend-reports)
                (setq outdated
                      (nconc (reverse (plist-get summary :outdated))
                             outdated))
                (setq pinned
                      (nconc (reverse (plist-get summary :pinned))
                             pinned))
                (setq missing
                      (nconc (reverse (plist-get summary :missing))
                             missing))
                (setq blocked
                      (nconc (reverse (plist-get summary :blocked))
                             blocked))
                (setq current
                      (nconc (reverse (plist-get summary :current))
                             current)))
            (error
             (push (list :backend backend*
                         :reason :unsupported-upgrade-plan
                         :error (error-message-string err))
                   skipped)))
        (push (list :backend backend*
                    :reason :unavailable)
              skipped)))
    (setq backend-reports (nreverse backend-reports)
          skipped (nreverse skipped)
          outdated (nreverse outdated)
          pinned (nreverse pinned)
          missing (nreverse missing)
          blocked (nreverse blocked)
          current (nreverse current))
    (list :operation 'outdated
          :manifest manifest-file
          :target target
          :backend (and backend (nelix-outdated--backend-symbol backend))
          :backends backend-reports
          :skipped skipped
          :count (length outdated)
          :outdated outdated
          :pinned pinned
          :missing missing
          :blocked blocked
          :current current
          :empty (null outdated))))

(defun nelix-manifest--upgrade-row-name (row)
  "Return the installed/profile element name represented by ROW."
  (cond
   ((stringp row) row)
   ((symbolp row) (symbol-name row))
   (t
    (or (plist-get row :name)
        (plist-get (plist-get row :entry) :name)
        (plist-get row :target)))))

(defun nelix-manifest--upgrade-row-names (rows)
  "Return upgrade target names represented by ROWS."
  (let (names)
    (dolist (row rows (nreverse names))
      (let ((name (nelix-manifest--upgrade-row-name row)))
        (when (and name (not (member name names)))
          (push name names))))))

(defun nelix-manifest--upgrade-backend (backend names profile system)
  "Upgrade NAMES through BACKEND for PROFILE and SYSTEM."
  (pcase backend
    ('nix
     (mapcar (lambda (name)
               (list :name name :result (pkg-upgrade name)))
             names))
    ('nelix-native
     (mapcar (lambda (report)
               (list :name (plist-get report :name)
                     :version (plist-get report :version)
                     :result report))
             (nelix-backend-install 'nelix-native names profile system)))
    (_
     (signal 'anvil-pkg-error
             (list (format "nelix-upgrade: backend %S does not support manifest upgrade"
                           backend))))))

;;;###autoload
(defun nelix-upgrade (&optional manifest-or-name)
  "Upgrade packages.

When MANIFEST-OR-NAME names an existing manifest file, upgrade the
outdated entries declared by that manifest through the selected
backend.  Otherwise preserve the historical profile API and delegate
to `pkg-upgrade' with MANIFEST-OR-NAME.

Manifest upgrades are driven by the read-only `nelix-outdated' report:
pinned, missing, current, and unsupported backend entries are reported
but not mutated."
  (if (nelix-manifest--existing-file-p manifest-or-name)
      (if (anvil-pkg-compat--standalone-nelisp-p)
          (let* ((plan (nelix-upgrade-plan manifest-or-name))
                 (names (nelix-manifest--upgrade-row-names
                         (plist-get plan :upgrade)))
                 (reports (when names
                            (nelix-manifest--upgrade-backend
                             'nix names
                             (plist-get plan :profile)
                             (plist-get plan :system)))))
            (list :status 'ok
                  :operation 'upgrade
                  :manifest (plist-get plan :manifest)
                  :backend 'nix
                  :backend-selection (plist-get plan :backend-selection)
                  :profile (plist-get plan :profile)
                  :system (plist-get plan :system)
                  :upgraded names
                  :reports reports
                  :count (length names)
                  :plan plan
                  :empty (null names)
                  :skipped (plist-get plan :skipped)))
        (let* ((manifest-file (expand-file-name manifest-or-name))
             (manifest (nelix-manifest-load manifest-file))
             (selection (nelix-manifest-select-backend manifest))
             (backend (plist-get selection :backend))
             (profile (plist-get manifest :profile))
             (system (plist-get selection :system)))
        (unless backend
          (signal 'anvil-pkg-error
                  (list (format "nelix-upgrade: no available backend for %s"
                                manifest-file))))
        (let* ((plan (nelix-outdated manifest-file backend))
               (rows (plist-get plan :outdated))
               (names (nelix-manifest--upgrade-row-names rows))
               (reports (when names
                          (nelix-manifest--upgrade-backend
                           backend names profile system))))
          (list :status 'ok
                :operation 'upgrade
                :manifest manifest-file
                :backend backend
                :backend-selection selection
                :profile profile
                :system system
                :upgraded names
                :reports reports
                :count (length names)
                :plan plan
                :empty (null names)))))
    (pkg-upgrade manifest-or-name)))

(provide 'nelix-manifest)
;;; nelix-manifest.el ends here
