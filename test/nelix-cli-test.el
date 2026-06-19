;;; nelix-cli-test.el --- Tests for Nelix CLI wrapper -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nelix-cli)
(require 'nelix-aot-manifest-engine)

(defvar nelix-package-nixpkgs-overrides)

(defconst nelix-cli-test--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing nelix-cli-test.el.")

(defun nelix-cli-test--fixture (name)
  "Return the test fixture path for NAME."
  (expand-file-name (concat "fixtures/" name)
                    nelix-cli-test--directory))

(defun nelix-cli-test--schema (name)
  "Return the parsed JSON schema NAME from docs/schema."
  (json-parse-string
   (with-temp-buffer
     (insert-file-contents
      (expand-file-name (concat "../docs/schema/" name)
                        nelix-cli-test--directory))
     (buffer-string))
   :object-type 'alist
   :array-type 'list))

(defun nelix-cli-test--alist-key-string (key)
  "Return the JSON object key string represented by KEY."
  (cond
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun nelix-cli-test--alist-has-json-key-p (alist key)
  "Return non-nil when ALIST has JSON object KEY."
  (let (found)
    (dolist (cell alist found)
      (when (equal (nelix-cli-test--alist-key-string (car cell)) key)
        (setq found t)))))

(defun nelix-cli-test--json-array-list (value)
  "Return VALUE as a list when it is a JSON array."
  (if (vectorp value)
      (append value nil)
    value))

(defun nelix-cli-test--write-transaction-record (file status)
  "Write a generated transaction record fixture to FILE with STATUS."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; generated Nelix apply transaction record -*- lexical-binding: t; -*-\n\n")
    (prin1
     (list :schema nelix-transaction-schema-name
           :schema-version nelix-transaction-schema-version
           :id (file-name-base file)
           :status status
           :manifest "/tmp/manifest.el"
           :profile "/tmp/profile"
           :started-at "2026-06-19T18:00:00+0900"
           :updated-at "2026-06-19T18:00:01+0900"
           :plan '(:commands ((:operation install
                                :name "ripgrep"
                                :argv ("profile" "install" "ripgrep"))))
           :transaction '(:enabled t
                          :rollback-on-error t
                          :before-generation 7)
           :executed '((:operation install :name "ripgrep" :ok t))
           :rollback-plan '(:available t
                            :operation rollback
                            :generation 7)
           :rollback (and (eq status 'error)
                          '(:attempted t :ok t :generation 7))
           :error (and (eq status 'error) "install failed"))
     (current-buffer))
    (insert "\n")))

(ert-deftest nelix-cli-test-parse-strips-emacs-separator-and-json ()
  (should (equal (nelix-cli-parse-args
                  '("--" "--json" "audit" "manifest.el"))
                 '(:command "audit"
                   :args ("manifest.el")
                   :json t
                   :help nil
                   :version nil))))

(ert-deftest nelix-cli-test-dispatch-audit-is-read-only-api ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-audit)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok t :manifest manifest))))
      (should (equal (nelix-cli-dispatch
                      '(:command "audit" :args ("m.el")))
                     '(:ok t :manifest "m.el")))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-dispatch-validate-is-read-only-api ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-validate)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok t :manifest manifest :counts '(:emacs 1)))))
      (should (equal (nelix-cli-dispatch
                      '(:command "validate" :args ("m.el")))
                     '(:ok t :manifest "m.el" :counts (:emacs 1))))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-dispatch-validate-json-uses-nelisp-fast-dsl ()
  "Standalone NeLisp validate JSON avoids full manifest loading."
  (let ((dir (make-temp-file "nelix-cli-fast-validate-" t)))
    (unwind-protect
        (let ((manifest (expand-file-name "nelix-package.el" dir))
              (index (expand-file-name "packages.el" dir))
              (called nil))
          (with-temp-file index
            (insert "(defconst fixture-emacs-packages '(magit consult))\n")
            (insert "(defconst fixture-linux-core '(\"git\" \"curl\"))\n")
            (insert "(defconst fixture-linux-extra '(\"ripgrep\"))\n")
            (insert "(defconst fixture-linux-packages\n")
            (insert "  (append fixture-linux-core fixture-linux-extra))\n")
            (insert "(defconst fixture-bootstrap '(nix-bin elpa-nelix))\n"))
          (with-temp-file manifest
            (insert "(require 'nelix)\n")
            (insert "(load \"packages.el\" nil nil t)\n")
            (insert "(nelix-environment\n")
            (insert " (name \"fixture\")\n")
            (insert " (profile \"default\")\n")
            (insert " (nix-channel \"nixpkgs\")\n")
            (insert " (imports \"packages.el\")\n")
            (insert " (backend-policy (gnu/linux nix nelix-native))\n")
            (insert " (emacs-packages fixture-emacs-packages)\n")
            (insert " (linux-packages fixture-linux-packages)\n")
            (insert " (bootstrap-apt-packages fixture-bootstrap))\n"))
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'nelix-validate)
                     (lambda (_manifest)
                       (setq called t)
                       (ert-fail "fast validate should not call nelix-validate"))))
            (let* ((json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "validate"
                                 :args (list manifest)
                                 :json t))
                          t))
                   (parsed (json-parse-string json :object-type 'alist)))
              (should-not called)
              (should (equal "fixture" (alist-get 'name parsed)))
              (should (equal "nelisp-fast-validate"
                             (alist-get 'backend parsed)))
              (should (= 2 (alist-get
                            'emacs
                            (alist-get 'counts parsed))))
              (should (= 3 (alist-get
                            'linux
                            (alist-get 'counts parsed))))
              (should (= 2 (alist-get
                            'bootstrap-apt
                            (alist-get 'counts parsed)))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-validate-json-rejects-duplicate-dsl-forms ()
  "The NeLisp fast validator enforces the same DSL v1 shape as Emacs load."
  (let ((dir (make-temp-file "nelix-cli-fast-validate-duplicate-" t)))
    (unwind-protect
        (let ((manifest (expand-file-name "nelix-package.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix)\n")
            (insert "(nelix-environment\n")
            (insert " (name \"fixture\")\n")
            (insert " (name \"duplicate\")\n")
            (insert " (linux-packages \"ripgrep\"))\n"))
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t)))
            (let ((err (should-error
                        (nelix-cli-dispatch
                         (list :command "validate"
                               :args (list manifest)
                               :json t))
                        :type 'anvil-pkg-error)))
              (should (string-match-p "duplicate DSL form name"
                                      (cadr err))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-dispatch-sync-parses-prune ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-sync)
               (lambda (manifest &rest args)
                 (setq called (cons manifest args))
                 (list :status 'ok :manifest manifest :args args))))
      (should (equal (nelix-cli-dispatch
                      '(:command "sync" :args ("m.el" "--prune")))
                     (list :status 'ok
                           :manifest "m.el"
                           :args '(:prune t)
                           :profile-root anvil-pkg-profile-dir)))
      (should (equal called '("m.el" :prune t))))))

(ert-deftest nelix-cli-test-dispatch-apply-and-sync-parse-locked ()
  (let (apply-called sync-called)
    (cl-letf (((symbol-function 'nelix-apply)
               (lambda (manifest &rest args)
                 (setq apply-called (cons manifest args))
                 (list :status 'ok :manifest manifest :args args)))
              ((symbol-function 'nelix-sync)
               (lambda (manifest &rest args)
                 (setq sync-called (cons manifest args))
                 (list :status 'ok :manifest manifest :args args))))
      (let ((apply-result
             (nelix-cli-dispatch
              '(:command "apply"
                :args ("m.el" "--locked" "--allow-remove-count" "1"))))
            (sync-result
             (nelix-cli-dispatch
              '(:command "sync"
                :args ("m.el" "--locked" "--prune"
                       "--allow-remove-count" "2")))))
        (should (equal apply-called
                       '("m.el" :locked t :allow-remove-count 1)))
        (should (equal sync-called
                       '("m.el" :prune t :locked t
                         :allow-remove-count 2)))
        (should (equal (plist-get apply-result :profile-root)
                       anvil-pkg-profile-dir))
        (should (equal (plist-get sync-result :profile-root)
                       anvil-pkg-profile-dir))))))

(ert-deftest nelix-cli-test-dispatch-apply-parses-dry-run ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-apply)
               (lambda (manifest &rest args)
                 (setq called (cons manifest args))
                 (list :status 'dry-run :manifest manifest :args args))))
      (let ((result (nelix-cli-dispatch
                     '(:command "apply"
                       :args ("m.el" "--dry-run" "--locked"
                              "--allow-remove" "--no-rollback")))))
        (should (equal called
                       '("m.el" :dry-run t :locked t
                         :allow-remove t :rollback-on-error nil)))
        (should (equal (plist-get result :profile-root)
                       anvil-pkg-profile-dir))))))

(ert-deftest nelix-cli-test-dispatch-plan-is-read-only-api ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-plan)
               (lambda (manifest)
                 (setq called manifest)
                 (list :status 'planned :manifest manifest))))
      (should (equal (nelix-cli-dispatch
                      '(:command "plan" :args ("m.el")))
                     '(:status planned :manifest "m.el")))
      (should (equal (nelix-cli-dispatch
                      '(:command "plan" :args ("m.el" "--dry-run")))
                     '(:status planned :manifest "m.el")))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-mutating-command-adds-profile-root ()
  (let ((anvil-pkg-profile-dir "/tmp/nelix-profile"))
    (cl-letf (((symbol-function 'nelix-lock-write)
               (lambda (_manifest)
                 (list :status 'ok :lock "m.el.nelix-lock"))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock" :args ("m.el")))
                     '(:status ok
                       :lock "m.el.nelix-lock"
                       :profile-root "/tmp/nelix-profile"))))))

(ert-deftest nelix-cli-test-dispatch-lock-validate-is-read-only-api ()
  "lock validate does not inherit lockfile write mutation metadata."
  (let (called)
    (cl-letf (((symbol-function 'nelix-lock-validate)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok t :manifest manifest))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock" :args ("validate" "m.el")))
                     '(:ok t :manifest "m.el")))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-dispatch-lock-diff-is-read-only-api ()
  "lock diff exposes lock drift without profile mutation metadata."
  (let (called)
    (cl-letf (((symbol-function 'nelix-lock-diff)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok nil :status 'drift :manifest manifest))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock" :args ("diff" "m.el")))
                     '(:ok nil :status drift :manifest "m.el")))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-dispatch-lock-migrate-dry-run-is-read-only-api ()
  "lock migrate --dry-run reports migration status without mutation metadata."
  (let (called)
    (cl-letf (((symbol-function 'nelix-lock-migrate)
               (lambda (manifest &rest args)
                 (setq called (cons manifest args))
                 (list :ok t :needed t :dry-run (plist-get args :dry-run)))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock" :args ("migrate" "m.el" "--dry-run")))
                     '(:ok t :needed t :dry-run t)))
      (should (equal called '("m.el" :dry-run t))))))

(ert-deftest nelix-cli-test-dispatch-lock-migrate-adds-profile-root ()
  "lock migrate without --dry-run is a lockfile mutation command."
  (let ((anvil-pkg-profile-dir "/tmp/nelix-profile")
        called)
    (cl-letf (((symbol-function 'nelix-lock-migrate)
               (lambda (manifest &rest args)
                 (setq called (cons manifest args))
                 (list :ok t :status 'migrated
                       :written-lock "m.el.nelix-lock"))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock" :args ("migrate" "m.el")))
                     '(:ok t :status migrated
                       :written-lock "m.el.nelix-lock"
                       :profile-root "/tmp/nelix-profile")))
      (should (equal called '("m.el" :dry-run nil))))))

(ert-deftest nelix-cli-test-dispatch-lock-check-is-read-only-api ()
  "lock-check exposes the public lock checker without profile mutation metadata."
  (let (called)
    (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
               (lambda () nil))
              ((symbol-function 'nelix-lock-check)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok t :manifest manifest))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock-check" :args ("m.el")))
                     '(:ok t :manifest "m.el")))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-dispatch-lock-check-uses-nelisp-fast-reader ()
  "Standalone NeLisp lock-check uses the non-eval lock reader."
  (let (called)
    (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
               (lambda () t))
              ((symbol-function 'nelix-lock-check--nelisp)
               (lambda (manifest)
                 (setq called manifest)
                 (list :ok t :checked-by 'nelisp))))
      (should (equal (nelix-cli-dispatch
                      '(:command "lock-check" :args ("m.el")))
                     '(:ok t :checked-by nelisp)))
      (should (equal called "m.el")))))

(ert-deftest nelix-cli-test-lock-json-includes-versioned-schema ()
  "JSON lock output exposes stable schema metadata for other runtimes."
  (let ((anvil-pkg-profile-dir "/tmp/nelix-profile"))
    (cl-letf (((symbol-function 'nelix-lock-write)
               (lambda (_manifest)
                 (list :schema "nelix-lock"
                       :schema-version 2
                       :version 2
                       :format 'sexp
                       :lock "m.el.nelix-lock"))))
      (let ((json (nelix-cli-format-result
                   (nelix-cli-dispatch
                    '(:command "lock" :args ("m.el")))
                   t)))
        (should (string-match-p "\"schema\":\"nelix-lock\"" json))
        (should (string-match-p "\"schema-version\":2" json))
        (should (string-match-p "\"version\":2" json))
        (should (string-match-p
                 "\"profile-root\":\"/tmp/nelix-profile\""
                 json))))))

(ert-deftest nelix-cli-test-schema-json-exposes-dsl-and-lock-contracts ()
  "The CLI exposes stable schema metadata for manifest DSL and locks."
  (let* ((json (nelix-cli-format-result
                (nelix-cli-dispatch
                 '(:command "schema" :args nil :json t))
                t))
         (parsed (json-parse-string json :object-type 'alist))
         (schemas (alist-get 'schemas parsed))
         (manifest (cl-find "manifest-dsl-v1" schemas
                            :key (lambda (row) (alist-get 'name row))
                            :test #'equal))
         (lock (cl-find "lock-v2" schemas
                        :key (lambda (row) (alist-get 'name row))
                        :test #'equal)))
    (should (equal "ok" (alist-get 'status parsed)))
    (should manifest)
    (should lock)
    (should (= 1 (alist-get 'schema-version manifest)))
    (should (member "nelix-environment"
                    (list (alist-get 'schema manifest))))
    (should (member "emacs-packages"
                    (nelix-cli-test--json-array-list
                     (alist-get 'forms manifest))))
    (should (member "bootstrap-apt"
                    (nelix-cli-test--json-array-list
                     (alist-get 'manifest-keys manifest))))
    (should (member "dnf"
                    (nelix-cli-test--json-array-list
                     (alist-get 'backends manifest))))
    (should (member "nelix-native"
                    (nelix-cli-test--json-array-list
                     (alist-get 'backends manifest))))
    (should (equal "nelix-lock" (alist-get 'schema lock)))
    (should (= 2 (alist-get 'schema-version lock)))
    (should (member "manifest-files"
                    (nelix-cli-test--json-array-list
                     (alist-get 'required lock))))
    (should (member "source"
                    (nelix-cli-test--json-array-list
                     (alist-get 'package-required lock))))))

(ert-deftest nelix-cli-test-schema-selects-single-contract ()
  "nelix schema NAME returns the requested schema contract only."
  (let* ((json (nelix-cli-format-result
                (nelix-cli-dispatch
                 '(:command "schema" :args ("manifest-dsl-v1") :json t))
                t))
         (parsed (json-parse-string json :object-type 'alist)))
    (should (equal "ok" (alist-get 'status parsed)))
    (should (equal "manifest-dsl-v1" (alist-get 'name parsed)))
    (should (= 1 (alist-get 'schema-version parsed)))))

(ert-deftest nelix-cli-test-schema-lock-contract-matches-json-schema-file ()
  "The CLI lock schema contract matches the documented JSON schema."
  (let* ((schema-file (nelix-cli-test--schema
                       "nelix-lock-v2.schema.json"))
         (json (nelix-cli-format-result
                (nelix-cli-dispatch
                 '(:command "schema" :args ("lock-v2") :json t))
                t))
         (parsed (json-parse-string json :object-type 'alist))
         (properties (alist-get 'properties schema-file))
         (package-schema
          (alist-get
           'package
           (alist-get '$defs schema-file)))
         (required (alist-get 'required schema-file))
         (package-required (alist-get 'required package-schema)))
    (should (equal "ok" (alist-get 'status parsed)))
    (should (equal "lock-v2" (alist-get 'name parsed)))
    (should (equal (alist-get 'const (alist-get 'schema properties))
                   (alist-get 'schema parsed)))
    (should (= (alist-get 'const (alist-get 'schema-version properties))
               (alist-get 'schema-version parsed)))
    (should (= (alist-get 'const (alist-get 'version properties))
               (alist-get 'version parsed)))
    (should (equal (alist-get 'const (alist-get 'format properties))
                   (alist-get 'format parsed)))
    (should (equal required
                   (nelix-cli-test--json-array-list
                    (alist-get 'required parsed))))
    (should (equal package-required
                   (nelix-cli-test--json-array-list
                    (alist-get 'package-required parsed))))))

(ert-deftest nelix-cli-test-lock-json-round-trips-schema ()
  "Lock JSON can be parsed back by standard JSON consumers."
  (let ((anvil-pkg-profile-dir "/tmp/nelix-profile"))
    (cl-letf (((symbol-function 'nelix-lock-write)
               (lambda (_manifest)
                 (list :schema "nelix-lock"
                       :schema-version 2
                       :version 2
                       :format 'sexp
                       :lock "m.el.nelix-lock"
                       :packages '((:name "ripgrep"
                                    :target "ripgrep"))))))
      (let* ((json (nelix-cli-format-result
                    (nelix-cli-dispatch
                     '(:command "lock" :args ("m.el")))
                    t))
             (parsed (json-parse-string json :object-type 'alist
                                        :array-type 'list)))
        (should (equal "nelix-lock" (alist-get 'schema parsed)))
        (should (= 2 (alist-get 'schema-version parsed)))
        (should (= 2 (alist-get 'version parsed)))
        (should (equal "ripgrep"
                       (alist-get
                        'name
                        (car (alist-get 'packages parsed)))))))))

(ert-deftest nelix-cli-test-lock-json-round-trips-real-lock ()
  "Real lock output keeps schema/package rows stable through JSON."
  (let ((dir (make-temp-file "nelix-cli-real-lock-json-" t)))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :linux '(ripgrep))\n"))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7")))
            (let* ((json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "lock"
                                 :args (list manifest)))
                          t))
                   (parsed (json-parse-string json :object-type 'alist
                                              :array-type 'list))
                   (package (car (alist-get 'packages parsed))))
              (should (equal "nelix-lock" (alist-get 'schema parsed)))
              (should (= 2 (alist-get 'schema-version parsed)))
              (should (= 2 (alist-get 'version parsed)))
              (should (equal "sexp" (alist-get 'format parsed)))
              (should (equal "ripgrep" (alist-get 'name package)))
              (should (equal "ripgrep" (alist-get 'target package)))
              (should (equal "nix" (alist-get 'backend package))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-lock-json-satisfies-v2-schema-contract ()
  "The documented v2 schema required keys match real lock JSON output."
  (let ((dir (make-temp-file "nelix-cli-real-lock-schema-" t)))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :linux '(ripgrep))\n"))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7")))
            (let* ((schema (nelix-cli-test--schema
                            "nelix-lock-v2.schema.json"))
                   (json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "lock"
                                 :args (list manifest)))
                          t))
                   (parsed (json-parse-string json :object-type 'alist
                                              :array-type 'list))
                   (package (car (alist-get 'packages parsed)))
                   (properties (alist-get 'properties schema))
                   (package-schema
                    (alist-get
                     'package
                     (alist-get '$defs schema)))
                   (required (alist-get 'required schema))
                   (package-required (alist-get 'required package-schema)))
              (should (equal nelix-lock-schema-name
                             (alist-get 'const
                                        (alist-get 'schema properties))))
              (should (= nelix-lock-schema-version
                         (alist-get 'const
                                    (alist-get 'schema-version properties))))
              (should (= nelix-lock-schema-version
                         (alist-get 'const
                                    (alist-get 'version properties))))
              (dolist (key required)
                (should (nelix-cli-test--alist-has-json-key-p parsed key)))
              (dolist (key package-required)
                (should (nelix-cli-test--alist-has-json-key-p package key))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-lock-json-round-trips-native-dependencies ()
  "Native lock JSON preserves dependency closure rows for non-Elisp consumers."
  (let ((dir (make-temp-file "nelix-cli-native-lock-json-" t))
        (nelix-registry-root nil)
        (nelix-registry-roots nil)
        (nelix-registry-remotes nil)
        (nelix-registry--packages (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (registry-root (expand-file-name "registry" dir))
               (packages-dir (expand-file-name "packages/local" registry-root)))
          (make-directory packages-dir t)
          (setq nelix-registry-root registry-root)
          (with-temp-file (expand-file-name "fixture-dep.el" packages-dir)
            (insert "(require 'nelix-registry)\n"
                    "(nelix-package\n"
                    " :name \"fixture-dep\"\n"
                    " :version \"1.0.0\"\n"
                    " :class 'system-tool\n"
                    " :systems '((x86_64-linux\n"
                    "             :install (:type script-shim\n"
                    "                       :command \"fixture-dep\"\n"
                    "                       :target \"/usr/bin/fixture-dep\"))))\n"))
          (with-temp-file (expand-file-name "fixture-app.el" packages-dir)
            (insert "(require 'nelix-registry)\n"
                    "(nelix-package\n"
                    " :name \"fixture-app\"\n"
                    " :version \"1.0.0\"\n"
                    " :class 'system-tool\n"
                    " :systems '((x86_64-linux\n"
                    "             :dependencies (\"fixture-dep\")\n"
                    "             :install (:type script-shim\n"
                    "                       :command \"fixture-app\"\n"
                    "                       :target \"/usr/bin/fixture-app\"))))\n"))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :linux '(fixture-app)"
                    " :backend-policy '(nelix-native))\n"))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () nil)))
            (let* ((json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "lock"
                                 :args (list manifest)))
                          t))
                   (parsed (json-parse-string json :object-type 'alist
                                              :array-type 'list))
                   (packages (alist-get 'packages parsed))
                   (app (cl-find-if
                         (lambda (row)
                           (equal "fixture-app" (alist-get 'name row)))
                         packages))
                   (dep (cl-find-if
                         (lambda (row)
                           (equal "fixture-dep" (alist-get 'name row)))
                         packages)))
              (should (equal "nelix-lock" (alist-get 'schema parsed)))
              (should (= 2 (alist-get 'schema-version parsed)))
              (should (equal "nelix-native" (alist-get 'backend parsed)))
              (should (= 2 (length packages)))
              (should (equal '("fixture-dep")
                             (alist-get 'recipe-dependencies app)))
              (should (equal "script-shim"
                             (alist-get
                              'type
                              (alist-get 'recipe-install app))))
              (should (equal "script-shim"
                             (alist-get
                              'type
                              (alist-get 'recipe-install dep)))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-lock-json-round-trips-current-v2-fixture ()
  "Current v2 fixture lock rows remain stable through CLI JSON output."
  (let ((dir (make-temp-file "nelix-cli-lock-json-v2-fixture-" t)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (lock-file (expand-file-name "manifest.el.nelix-lock" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\")\n"))
          (copy-file (nelix-cli-test--fixture "nelix-lock-v2-current.el")
                     lock-file t)
          (cl-letf (((symbol-function 'nelix-lock-write)
                     (lambda (_manifest)
                       (nelix-lock-read manifest))))
            (let* ((json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "lock"
                                 :args (list manifest)))
                          t))
                   (parsed (json-parse-string json :object-type 'alist
                                              :array-type 'list))
                   (package (car (alist-get 'packages parsed))))
              (should (equal "nelix-lock" (alist-get 'schema parsed)))
              (should (= 2 (alist-get 'schema-version parsed)))
              (should (= 2 (alist-get 'version parsed)))
              (should (equal "sexp" (alist-get 'format parsed)))
              (should (equal "nix" (alist-get 'backend parsed)))
              (should (equal "ripgrep" (alist-get 'name package)))
              (should (equal "nix" (alist-get 'backend package)))
              (should (equal "legacyPackages.x86_64-linux.ripgrep"
                             (alist-get 'attr-path package))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-lock-json-round-trips-native-deps-fixture ()
  "Native dependency fixture remains stable through CLI JSON output."
  (let ((dir (make-temp-file "nelix-cli-lock-json-native-fixture-" t)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (lock-file (expand-file-name "manifest.el.nelix-lock" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\")\n"))
          (copy-file (nelix-cli-test--fixture "nelix-lock-v2-native-deps.el")
                     lock-file t)
          (cl-letf (((symbol-function 'nelix-lock-write)
                     (lambda (_manifest)
                       (nelix-lock-read manifest))))
            (let* ((json (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "lock"
                                 :args (list manifest)))
                          t))
                   (parsed (json-parse-string json :object-type 'alist
                                              :array-type 'list))
                   (packages (alist-get 'packages parsed))
                   (app (car packages))
                   (dep (cadr packages)))
              (should (equal "nelix-lock" (alist-get 'schema parsed)))
              (should (= 2 (alist-get 'schema-version parsed)))
              (should (equal "nelix-native" (alist-get 'backend parsed)))
              (should (equal '("fixture-app" "fixture-dep")
                             (mapcar (lambda (row)
                                       (alist-get 'name row))
                                     packages)))
              (should (equal '("fixture-dep")
                             (alist-get 'recipe-dependencies app)))
              (should (equal "script-shim"
                             (alist-get
                              'type
                              (alist-get 'recipe-install app))))
              (should (equal "script-shim"
                             (alist-get
                              'type
                              (alist-get 'recipe-install dep)))))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-upgrade-plan-allows-optional-target ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-upgrade-plan)
               (lambda (&optional target)
                 (setq called target)
                 (list :operation 'upgrade :name (or target :all)))))
      (should (equal (nelix-cli-dispatch
                      '(:command "upgrade-plan" :args ("ripgrep")))
                     '(:operation upgrade :name "ripgrep")))
      (should (equal called "ripgrep")))))

(ert-deftest nelix-cli-test-list-uses-nelisp-fast-path ()
  "Standalone NeLisp list dispatch returns name-only fast data."
  (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
             (lambda () t))
            ((symbol-function 'nelix-fast-list)
             (lambda () '("magit" "ripgrep")))
            ((symbol-function 'nelix-list)
             (lambda ()
               (ert-fail "standalone NeLisp list should not use row path"))))
    (should (equal (nelix-cli-dispatch '(:command "list" :args nil))
                   '("magit" "ripgrep")))))

(ert-deftest nelix-cli-test-dispatch-transaction-list-and-show ()
  "Transaction CLI lists generated records and shows record contents."
  (let* ((dir (make-temp-file "nelix-cli-transaction-" t))
         (nelix-transaction-log-root dir)
         (file (expand-file-name "apply-alpha.el" dir)))
    (unwind-protect
        (progn
          (nelix-cli-test--write-transaction-record file 'error)
          (let* ((list-result
                  (nelix-cli-dispatch
                   '(:command "transaction" :args ("list" "--limit" "10"))))
                 (row (car (plist-get list-result :transactions)))
                 (show-result
                  (nelix-cli-dispatch
                   '(:command "transaction" :args ("show" "apply-alpha"))))
                 (record (plist-get show-result :record))
                 (json (nelix-cli-format-result show-result t))
                 (parsed (json-parse-string json :object-type 'alist))
                 (parsed-record (alist-get 'record parsed)))
            (should (eq 'ok (plist-get list-result :status)))
            (should (equal 'transaction-list
                           (plist-get list-result :operation)))
            (should (= 1 (plist-get list-result :count)))
            (should (equal "apply-alpha" (plist-get row :id)))
            (should (eq 'error (plist-get row :status)))
            (should (= 1 (plist-get row :command-count)))
            (should (= 1 (plist-get row :executed-count)))
            (should (plist-get row :rollback-available))
            (should (equal "install failed" (plist-get row :error)))
            (should (eq 'ok (plist-get show-result :status)))
            (should (equal 'transaction-show
                           (plist-get show-result :operation)))
            (should (equal file (plist-get show-result :file)))
            (should (equal nelix-transaction-schema-name
                           (plist-get record :schema)))
            (should (eq 'error (plist-get record :status)))
            (should (equal "install failed" (plist-get record :error)))
            (should (equal "error" (alist-get 'status parsed-record)))
            (should (equal "nelix-apply-transaction"
                           (alist-get 'schema parsed-record)))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-formats-string-list-as-lines ()
  "Name-only CLI results stay useful without generic prin1 support."
  (should (equal (nelix-cli-format-result '("magit" "ripgrep") nil)
                 "magit\nripgrep")))

(ert-deftest nelix-cli-test-outdated-allows-target-and-backend ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-outdated)
               (lambda (&optional target backend)
                 (setq called (list target backend))
                 (list :operation 'outdated :target target :backend backend))))
      (should (equal (nelix-cli-dispatch
                      '(:command "outdated"
                        :args ("manifest.el" "--backend" "nelix-native")))
                     '(:operation outdated
                       :target "manifest.el"
                       :backend "nelix-native")))
      (should (equal called '("manifest.el" "nelix-native"))))))

(ert-deftest nelix-cli-test-outdated-rejects-missing-backend-value ()
  (should-error
   (nelix-cli-dispatch '(:command "outdated" :args ("--backend")))
   :type 'anvil-pkg-error))

(ert-deftest nelix-cli-test-upgrade-manifest-delegates-to-nelix-upgrade ()
  (let ((manifest (make-temp-file "nelix-cli-test-" nil ".el")))
    (unwind-protect
        (cl-letf (((symbol-function 'nelix-upgrade)
                   (lambda (target)
                     (list :status 'ok
                           :operation 'upgrade
                           :manifest target
                           :upgraded '("ripgrep")))))
          (let ((result (nelix-cli-dispatch
                         (list :command "upgrade"
                               :args (list manifest)))))
            (should (eq (plist-get result :status) 'ok))
            (should (equal '("ripgrep") (plist-get result :upgraded)))
            (should (equal (plist-get result :profile-root)
                           anvil-pkg-profile-dir))))
      (delete-file manifest))))

(ert-deftest nelix-cli-test-json-normalize-converts-plists-and-symbols ()
  (let* ((normalized (nelix-cli--json-normalize
                      '(:status ok :rows ((:name "ripgrep"
                                           :state installed)))))
         (rows (gethash "rows" normalized)))
    (should (hash-table-p normalized))
    (should (equal (gethash "status" normalized) "ok"))
    (should (vectorp rows))
    (should (equal (gethash "name" (aref rows 0)) "ripgrep"))
    (should (equal (gethash "state" (aref rows 0)) "installed"))))

(ert-deftest nelix-cli-test-json-normalize-converts-alists ()
  "Audit reports contain alists with dotted package metadata pairs."
  (let* ((normalized
          (nelix-cli--json-normalize
           '(:bootstrap
             (:native-missing-apt
              ((debhelper . "managed through wrapper")
               ("dh-elpa" . "managed through wrapper"))))))
         (bootstrap (gethash "bootstrap" normalized))
         (missing (gethash "native-missing-apt" bootstrap)))
    (should (hash-table-p missing))
    (should (equal "managed through wrapper"
                   (gethash "debhelper" missing)))
    (should (equal "managed through wrapper"
                   (gethash "dh-elpa" missing)))))

(ert-deftest nelix-cli-test-json-format-emits-null-for-nil ()
  (let ((json (nelix-cli-format-result '(:manifest nil :empty t) t)))
    (should (string-match-p "\"manifest\":null" json))
    (should (string-match-p "\"empty\":true" json))))

(ert-deftest nelix-cli-test-json-escape-slow-path-is-chunked-compatible ()
  "Escaped strings keep JSON semantics after avoiding loop concat."
  (should (equal (nelix-cli--json-escape-string "a\\b\"c\nd\te")
                 "a\\\\b\\\"c\\nd\\te"))
  (should (equal (nelix-aot--json-escape-string "a\\b\"c\nd\te")
                 "a\\\\b\\\"c\\nd\\te")))

(ert-deftest nelix-cli-test-format-result-passes-through-raw-json ()
  "Direct AOT JSON does not re-enter the generic JSON encoder."
  (should (equal (nelix-cli-format-result
                  (nelix-cli--raw-json "{\"ok\":true}")
                  t)
                 "{\"ok\":true}")))

(ert-deftest nelix-cli-test-fast-aot-input-is-line-protocol ()
  "Fast manifest data can be exported without plist-heavy native parsing."
  (let ((dir (make-temp-file "nelix-cli-aot-input-" t))
        (old-overrides-bound (boundp 'nelix-package-nixpkgs-overrides))
        (old-overrides-value (and (boundp 'nelix-package-nixpkgs-overrides)
                                  nelix-package-nixpkgs-overrides)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (nelix-fast--pname-cache nil))
          (setq nelix-package-nixpkgs-overrides
                '((magit . "legacyPackages.x86_64-linux.emacsPackages.magit"))
                nelix-fast--target-cache nil)
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (let ((payload (nelix-fast-aot-input
                          manifest
                          '("magit" "ripgrep" "fd"))))
            (should (string-prefix-p "NELIX-AOT-MANIFEST-V1\n" payload))
            (should (string-match-p
                     (regexp-quote
                      (concat "manifest\t" manifest "\n"))
                     payload))
            (should (string-match-p "profile\tdefault\n" payload))
            (should (string-match-p "system\tx86_64-linux\n" payload))
            (should (string-match-p
                     (regexp-quote
                      "target\tmagit\tmagit\tlegacyPackages.x86_64-linux.emacsPackages.magit\n")
                     payload))
            (should (string-match-p "target\tripgrep\tripgrep\n" payload))
            (should (string-match-p "pin\tripgrep\n" payload))
            (should (string-match-p "installed\tfd\n" payload))
            (should (string-suffix-p "end\n" payload))))
      (if old-overrides-bound
          (setq nelix-package-nixpkgs-overrides old-overrides-value)
        (makunbound 'nelix-package-nixpkgs-overrides))
      (setq nelix-fast--target-cache nil)
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-fast-aot-input-rejects-ambiguous-fields ()
  "The native/AOT line protocol keeps tab/newline escaping out of hot paths."
  (should-error
   (nelix-fast--aot-line "installed" "bad\tname")
   :type 'anvil-pkg-error)
  (should-error
   (nelix-fast--aot-line "installed" "bad\nname")
   :type 'anvil-pkg-error))

(ert-deftest nelix-cli-test-aot-engine-audit-uses-line-protocol ()
  "Portable AOT audit consumes `nelix-fast-aot-input' without manifest plists."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "target\tmagit\tmagit\temacsPackages.magit\n"
                  "target\tripgrep\tripgrep\n"
                  "target\tfd\tfd\n"
                  "pin\tripgrep\n"
                  "installed\tmagit\n"
                  "installed\tripgrep-1\n"
                  "installed\tbat\n"
                  "end\n")))
    (should (equal (nelix-aot-audit payload)
                   '(:ok nil
                     :manifest "/tmp/manifest.el"
                     :profile "default"
                     :system "x86_64-linux"
                     :present ("magit" "ripgrep-1")
                     :missing ("fd")
                     :extra ("bat")
                     :skipped (:state-pins :nelisp-aot
                               :lock-drift :nelisp-aot
                               :linux-command-audit :nelisp-aot))))))

(ert-deftest nelix-cli-test-aot-engine-audit-json-uses-direct-writer ()
  "AOT audit can emit JSON without constructing the CLI plist report."
  (let* ((payload (concat
                   "NELIX-AOT-MANIFEST-V1\n"
                   "manifest\t/tmp/manifest.el\n"
                   "profile\tdefault\n"
                   "system\tx86_64-linux\n"
                   "target\tmagit\tmagit\temacsPackages.magit\n"
                   "target\tripgrep\tripgrep\n"
                   "installed\tmagit\n"
                   "installed\tbat\n"
                   "end\n"))
         (json (nelix-aot-audit-json
                payload
                ":nelisp-aot-cache"
                "/tmp/manifest.el.nelix-aot-targets")))
    (should (string-prefix-p "{\"ok\":false" json))
    (should (string-match-p "\"present\":\\[\"magit\"\\]" json))
    (should (string-match-p "\"missing\":\\[\"ripgrep\"\\]" json))
    (should (string-match-p "\"extra\":\\[\"bat\"\\]" json))
    (should (string-match-p "\"fallback\":\":nelisp-aot-cache\"" json))
    (should (string-match-p "\"aot-cache\":\"/tmp/manifest.el.nelix-aot-targets\"" json))))

(ert-deftest nelix-cli-test-aot-engine-audit-lines-uses-direct-writer ()
  "AOT audit can emit compact lines without the CLI plist printer."
  (let* ((payload (concat
                   "NELIX-AOT-MANIFEST-V1\n"
                   "manifest\t/tmp/manifest.el\n"
                   "profile\tdefault\n"
                   "system\tx86_64-linux\n"
                   "target\tmagit\tmagit\temacsPackages.magit\n"
                   "target\tripgrep\tripgrep\n"
                   "installed\tmagit\n"
                   "installed\tbat\n"
                   "end\n"))
         (lines (nelix-aot-audit-lines
                 payload
                 ":nelisp-aot-cache"
                 "/tmp/manifest.el.nelix-aot-targets")))
    (should (string-match-p "^ok\tfalse$" lines))
    (should (string-match-p "^present\tmagit$" lines))
    (should (string-match-p "^missing\tripgrep$" lines))
    (should (string-match-p "^extra\tbat$" lines))
    (should (string-match-p "^fallback\t:nelisp-aot-cache$" lines))
    (should (string-match-p "^aot-cache\t/tmp/manifest.el.nelix-aot-targets$" lines))))

(ert-deftest nelix-cli-test-aot-engine-audit-prefers-id-records ()
  "AOT audit can compare numeric target/installed ID records."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "name-id\t1\tmagit\n"
                  "name-id\t2\tripgrep\n"
                  "name-id\t3\tfd\n"
                  "target-id\t1\t1\n"
                  "target-id\t2\t2\n"
                  "target-id\t3\t3\n"
                  "pin-id\t2\n"
                  "installed\tmagit\n"
                  "installed-id\t1\n"
                  "installed\tripgrep-1\n"
                  "installed-id\t2\n"
                  "installed\tbat\n"
                  "end\n")))
    (should (equal (nelix-aot-audit payload)
                   '(:ok nil
                     :manifest "/tmp/manifest.el"
                     :profile "default"
                     :system "x86_64-linux"
                     :present ("magit" "ripgrep-1")
                     :missing ("fd")
                     :extra ("bat")
                     :skipped (:state-pins :nelisp-aot
                               :lock-drift :nelisp-aot
                               :linux-command-audit :nelisp-aot))))))

(ert-deftest nelix-cli-test-aot-engine-upgrade-plan-uses-line-protocol ()
  "Portable AOT upgrade-plan preserves pin and missing semantics."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "target\tmagit\tmagit\temacsPackages.magit\n"
                  "target\tripgrep\tripgrep\n"
                  "target\tfd\tfd\n"
                  "pin\tripgrep\n"
                  "installed\tmagit\n"
                  "installed\tripgrep-1\n"
                  "installed\tbat\n"
                  "end\n")))
    (should (equal (nelix-aot-upgrade-plan payload)
                   '(:operation upgrade
                     :name :manifest
                     :count 1
                     :upgrade ("magit")
                     :pinned ("ripgrep-1")
                     :pinned-names ("ripgrep")
                     :blocked nil
                     :empty nil
                     :manifest "/tmp/manifest.el"
                     :profile "default"
                     :system "x86_64-linux"
                     :missing ("fd")
                     :extra nil
                     :lock-drift nil
                     :skipped (:extra-scan :nelisp-aot
                               :lock-drift :nelisp-aot
                               :state-pins :nelisp-aot))))))

(ert-deftest nelix-cli-test-aot-engine-prefers-exact-before-normalized-name ()
  "AOT target matching keeps exact profile names before -1 fallback aliases."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "target\tprescient\tprescient\temacsPackages.company-prescient\tcompany-prescient\n"
                  "target\tprescient-radian-software\tprescient-radian-software\temacsPackages.prescient\tprescient\n"
                  "target\tcompat\tcompat\temacsPackages.compat\n"
                  "target\tcompat-emacs-compat\tcompat-emacs-compat\temacsPackages.compat\tcompat\n"
                  "installed\tcompany-prescient\n"
                  "installed\tprescient-1\n"
                  "installed\tcompat-1\n"
                  "end\n")))
    (let ((plan (nelix-aot-upgrade-plan payload)))
      (should (equal (plist-get plan :upgrade)
                     '("company-prescient" "prescient-1" "compat-1")))
      (should (= 3 (plist-get plan :count)))
      (should-not (plist-get plan :missing)))))

(ert-deftest nelix-cli-test-aot-engine-upgrade-plan-json-uses-direct-writer ()
  "AOT upgrade-plan can emit JSON without constructing the CLI plist report."
  (let* ((payload (concat
                   "NELIX-AOT-MANIFEST-V1\n"
                   "manifest\t/tmp/manifest.el\n"
                   "profile\tdefault\n"
                   "system\tx86_64-linux\n"
                   "target\tmagit\tmagit\temacsPackages.magit\n"
                   "target\tripgrep\tripgrep\n"
                   "pin\tripgrep\n"
                   "installed\tmagit\n"
                   "installed\tripgrep-1\n"
                   "end\n"))
         (json (nelix-aot-upgrade-plan-json payload ":nelisp-aot" nil)))
    (should (string-prefix-p "{\"operation\":\"upgrade\"" json))
    (should (string-match-p "\"count\":1" json))
    (should (string-match-p "\"upgrade\":\\[\"magit\"\\]" json))
    (should (string-match-p "\"pinned\":\\[\"ripgrep-1\"\\]" json))
    (should (string-match-p "\"pinned-names\":\\[\"ripgrep\"\\]" json))
    (should (string-match-p "\"fallback\":\":nelisp-aot\"" json))))

(ert-deftest nelix-cli-test-aot-engine-upgrade-plan-lines-uses-direct-writer ()
  "AOT upgrade-plan can emit compact lines without the CLI plist printer."
  (let* ((payload (concat
                   "NELIX-AOT-MANIFEST-V1\n"
                   "manifest\t/tmp/manifest.el\n"
                   "profile\tdefault\n"
                   "system\tx86_64-linux\n"
                   "target\tmagit\tmagit\temacsPackages.magit\n"
                   "target\tripgrep\tripgrep\n"
                   "target\tfd\tfd\n"
                   "pin\tripgrep\n"
                   "installed\tmagit\n"
                   "installed\tripgrep-1\n"
                   "end\n"))
         (lines (nelix-aot-upgrade-plan-lines payload ":nelisp-aot" nil)))
    (should (string-match-p "^operation\tupgrade$" lines))
    (should (string-match-p "^count\t1$" lines))
    (should (string-match-p "^upgrade\tmagit$" lines))
    (should (string-match-p "^pinned\tripgrep-1$" lines))
    (should (string-match-p "^pinned-name\tripgrep$" lines))
    (should (string-match-p "^missing\tfd$" lines))
    (should (string-match-p "^fallback\t:nelisp-aot$" lines))))

(ert-deftest nelix-cli-test-aot-direct-writers-avoid-mapconcat ()
  "AOT output writers stream results without mapconcat-backed join lists."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "target\tmagit\tmagit\temacsPackages.magit\n"
                  "target\tripgrep\tripgrep\n"
                  "target\tfd\tfd\n"
                  "pin\tripgrep\n"
                  "installed\tmagit\n"
                  "installed\tripgrep-1\n"
                  "installed\tbat\n"
                  "end\n"))
        (list-payload "magit\nripgrep\nfd\n")
        (old-mapconcat (symbol-function 'mapconcat))
        (mapconcat-calls 0)
        audit-json
        upgrade-json
        audit-lines
        upgrade-lines
        list-lines
        list-json)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'mapconcat)
                     (lambda (&rest args)
                       (setq mapconcat-calls (1+ mapconcat-calls))
                       (apply old-mapconcat args))))
            (setq audit-json (nelix-aot-audit-json payload ":nelisp-aot" nil))
            (setq upgrade-json
                  (nelix-aot-upgrade-plan-json payload ":nelisp-aot" nil))
            (setq audit-lines (nelix-aot-audit-lines payload ":nelisp-aot" nil))
            (setq upgrade-lines
                  (nelix-aot-upgrade-plan-lines payload ":nelisp-aot" nil))
            (setq list-lines (nelix-aot-list-lines list-payload))
            (setq list-json (nelix-aot-list-json list-payload)))
          (should (string-match-p "\"present\":\\[\"magit\",\"ripgrep-1\"\\]"
                                  audit-json))
          (should (string-match-p "\"upgrade\":\\[\"magit\"\\]" upgrade-json))
          (should (string-match-p "^present\tmagit$" audit-lines))
          (should (string-match-p "^upgrade\tmagit$" upgrade-lines))
          (should (equal list-lines list-payload))
          (should (equal list-json "[\"magit\",\"ripgrep\",\"fd\"]"))
          (should (= mapconcat-calls 0)))
      (fset 'mapconcat old-mapconcat))))

(ert-deftest nelix-cli-test-aot-audit-upgrade-stream-input-lines ()
  "AOT audit/upgrade input parsing should not materialize all lines first."
  (let ((id-payload (concat
                     "NELIX-AOT-MANIFEST-V1\n"
                     "manifest\t/tmp/manifest.el\n"
                     "profile\tdefault\n"
                     "system\tx86_64-linux\n"
                     "name-id\t1\tmagit\n"
                     "name-id\t2\tripgrep\n"
                     "name-id\t3\tfd\n"
                     "target-id\t1\t1\n"
                     "target-id\t2\t2\n"
                     "target-id\t3\t3\n"
                     "pin-id\t2\n"
                     "installed\tmagit\n"
                     "installed-id\t1\n"
                     "installed\tripgrep-1\n"
                     "installed-id\t2\n"
                     "installed\tbat\n"
                     "end\n"))
        (string-payload (concat
                         "NELIX-AOT-MANIFEST-V1\n"
                         "manifest\t/tmp/manifest.el\n"
                         "profile\tdefault\n"
                         "system\tx86_64-linux\n"
                         "target\tmagit\tmagit\temacsPackages.magit\n"
                         "target\tripgrep\tripgrep\n"
                         "target\tfd\tfd\n"
                         "pin\tripgrep\n"
                         "installed\tmagit\n"
                         "installed\tripgrep-1\n"
                         "installed\tbat\n"
                         "end\n"))
        (old-parse-lines (symbol-function 'nelix-aot--parse-lines))
        (parse-lines-calls 0))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'nelix-aot--parse-lines)
                     (lambda (&rest args)
                       (setq parse-lines-calls (1+ parse-lines-calls))
                       (apply old-parse-lines args))))
            (should (equal (plist-get (nelix-aot-audit id-payload) :present)
                           '("magit" "ripgrep-1")))
            (should (equal (plist-get (nelix-aot-upgrade-plan id-payload)
                                      :upgrade)
                           '("magit")))
            (should (string-match-p "\"present\":\\[\"magit\",\"ripgrep-1\"\\]"
                                    (nelix-aot-audit-json id-payload)))
            (should (string-match-p "\"upgrade\":\\[\"magit\"\\]"
                                    (nelix-aot-upgrade-plan-json id-payload)))
            (should (string-match-p "^present\tmagit$"
                                    (nelix-aot-audit-lines id-payload)))
            (should (string-match-p "^upgrade\tmagit$"
                                    (nelix-aot-upgrade-plan-lines id-payload)))
            (should (equal (plist-get (nelix-aot-audit string-payload)
                                      :present)
                           '("magit" "ripgrep-1")))
            (should (equal (plist-get (nelix-aot-upgrade-plan string-payload)
                                      :upgrade)
                           '("magit"))))
          (should (= parse-lines-calls 0))
          (should-not (fboundp 'nelix-aot--split-tabs)))
      (fset 'nelix-aot--parse-lines old-parse-lines))))

(ert-deftest nelix-cli-test-aot-engine-upgrade-plan-prefers-id-records ()
  "AOT upgrade-plan can compare numeric target/installed ID records."
  (let ((payload (concat
                  "NELIX-AOT-MANIFEST-V1\n"
                  "manifest\t/tmp/manifest.el\n"
                  "profile\tdefault\n"
                  "system\tx86_64-linux\n"
                  "name-id\t1\tmagit\n"
                  "name-id\t2\tripgrep\n"
                  "name-id\t3\tfd\n"
                  "target-id\t1\t1\n"
                  "target-id\t2\t2\n"
                  "target-id\t3\t3\n"
                  "pin-id\t2\n"
                  "installed\tmagit\n"
                  "installed-id\t1\n"
                  "installed\tripgrep-1\n"
                  "installed-id\t2\n"
                  "installed\tbat\n"
                  "end\n")))
    (should (equal (nelix-aot-upgrade-plan payload)
                   '(:operation upgrade
                     :name :manifest
                     :count 1
                     :upgrade ("magit")
                     :pinned ("ripgrep-1")
                     :pinned-names ("ripgrep")
                     :blocked nil
                     :empty nil
                     :manifest "/tmp/manifest.el"
                     :profile "default"
                     :system "x86_64-linux"
                     :missing ("fd")
                     :extra nil
                     :lock-drift nil
                     :skipped (:extra-scan :nelisp-aot
                               :lock-drift :nelisp-aot
                               :state-pins :nelisp-aot))))))

(ert-deftest nelix-cli-test-aot-engine-list-direct-writers ()
  "AOT list can output lines or JSON without generic CLI formatting."
  (let ((payload "magit\nripgrep\nfd\n"))
    (should (equal (nelix-aot-list payload)
                   '("magit" "ripgrep" "fd")))
    (should (equal (nelix-aot-list-lines payload)
                   "magit\nripgrep\nfd\n"))
    (should (equal (nelix-aot-list-json payload)
                   "[\"magit\",\"ripgrep\",\"fd\"]"))))

(ert-deftest nelix-cli-test-dispatch-audit-uses-direct-json-when-available ()
  "JSON audit dispatch can bypass generic result encoding."
  (cl-letf (((symbol-function 'nelix-fast-audit-json)
             (lambda (_manifest) "{\"ok\":true}"))
            ((symbol-function 'nelix-audit)
             (lambda (_manifest)
               (ert-fail "direct JSON audit should not call nelix-audit"))))
    (should (equal (nelix-cli-format-result
                    (nelix-cli-dispatch
                     '(:command "audit" :args ("m.el") :json t))
                    t)
                   "{\"ok\":true}"))))

(ert-deftest nelix-cli-test-dispatch-upgrade-plan-uses-direct-json-when-available ()
  "JSON upgrade-plan dispatch can bypass generic result encoding."
  (let ((manifest (make-temp-file "nelix-cli-upgrade-json-" nil ".el")))
    (unwind-protect
        (cl-letf (((symbol-function 'nelix-fast-upgrade-plan-json)
                   (lambda (_manifest) "{\"operation\":\"upgrade\"}"))
                  ((symbol-function 'nelix-upgrade-plan)
                   (lambda (&optional _manifest)
                     (ert-fail "direct JSON upgrade-plan should not call nelix-upgrade-plan"))))
          (should (equal (nelix-cli-format-result
                          (nelix-cli-dispatch
                           (list :command "upgrade-plan"
                                 :args (list manifest)
                                 :json t))
                          t)
                         "{\"operation\":\"upgrade\"}")))
      (delete-file manifest))))

(ert-deftest nelix-cli-test-fast-json-default-is-standalone-scoped ()
  "Non-AOT fast JSON is used for standalone NeLisp, not normal Emacs."
  (let ((dir (make-temp-file "nelix-cli-fast-json-default-" t))
        (old-env (getenv "NELIX_NELISP_AOT"))
        (old-force nelix-fast-aot-force))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (setenv "NELIX_NELISP_AOT" nil)
          (setq nelix-fast-aot-force nil)
          (cl-letf (((symbol-function 'nelix-fast-profile-names)
                     (lambda (&optional _profile)
                       '("magit" "bat")))
                    ((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () nil)))
            (should-not (nelix-fast-audit-json manifest))
            (should-not (nelix-fast-upgrade-plan-json manifest)))
          (cl-letf (((symbol-function 'nelix-fast-profile-names)
                     (lambda (&optional _profile)
                       '("magit" "bat")))
                    ((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t)))
            (let ((audit (nelix-fast-audit-json manifest))
                  (plan (nelix-fast-upgrade-plan-json manifest)))
              (should (string-match-p "\"present\":\\[\"magit\"\\]" audit))
              (should (string-match-p "\"missing\":\\[\"ripgrep\"\\]" audit))
              (should (string-match-p "\"extra\":\\[\"bat\"\\]" audit))
              (should (string-match-p "\"fallback\":\":nelisp-fast\"" audit))
              (should (string-match-p "\"upgrade\":\\[\"magit\"\\]" plan))
              (should (string-match-p "\"missing\":\\[\"ripgrep\"\\]" plan))
              (should (string-match-p "\"fallback\":\":nelisp-fast\"" plan)))))
      (setq nelix-fast-aot-force old-force)
      (if old-env
          (setenv "NELIX_NELISP_AOT" old-env)
        (setenv "NELIX_NELISP_AOT" nil))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-opt-in-audit-uses-portable-engine ()
  "NELIX_NELISP_AOT=1 routes compact audit through the AOT engine."
  (let ((dir (make-temp-file "nelix-cli-aot-audit-" t))
        (old-env (getenv "NELIX_NELISP_AOT")))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (setenv "NELIX_NELISP_AOT" "1")
          (cl-letf (((symbol-function 'nelix-fast-profile-names)
                     (lambda (&optional _profile)
                       '("magit" "ripgrep-1" "bat"))))
            (let ((report (nelix-fast-audit manifest)))
              (should (equal (plist-get report :present)
                             '("magit" "ripgrep-1")))
              (should (equal (plist-get report :extra) '("bat")))
              (should (eq (plist-get
                           (plist-get report :backend-selection)
                           :fallback)
                          :nelisp-aot))
              (should (equal (plist-get report :skipped)
                             '(:state-pins :nelisp-aot
                               :lock-drift :nelisp-aot
                               :linux-command-audit :nelisp-aot))))))
      (if old-env
          (setenv "NELIX_NELISP_AOT" old-env)
        (setenv "NELIX_NELISP_AOT" nil))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-opt-in-upgrade-plan-uses-portable-engine ()
  "NELIX_NELISP_AOT=1 routes compact upgrade-plan through the AOT engine."
  (let ((dir (make-temp-file "nelix-cli-aot-upgrade-" t))
        (old-env (getenv "NELIX_NELISP_AOT")))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (setenv "NELIX_NELISP_AOT" "1")
          (cl-letf (((symbol-function 'nelix-fast-profile-names)
                     (lambda (&optional _profile)
                       '("magit" "ripgrep-1" "bat"))))
            (let ((plan (nelix-fast-upgrade-plan manifest)))
              (should (equal (plist-get plan :upgrade) '("magit")))
              (should (equal (plist-get plan :pinned) '("ripgrep-1")))
              (should (equal (plist-get plan :missing) nil))
              (should (eq (plist-get
                           (plist-get plan :backend-selection)
                           :fallback)
                          :nelisp-aot))
              (should (equal (plist-get plan :skipped)
                             '(:extra-scan :nelisp-aot
                               :lock-drift :nelisp-aot
                               :state-pins :nelisp-aot))))))
      (if old-env
          (setenv "NELIX_NELISP_AOT" old-env)
        (setenv "NELIX_NELISP_AOT" nil))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-target-cache-writes-manifest-records ()
  "The AOT target cache stores manifest records without installed rows."
  (let ((dir (make-temp-file "nelix-cli-aot-cache-" t)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (cache (expand-file-name "targets.cache" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (let ((result (nelix-fast-aot-target-cache-write manifest cache)))
            (should (equal (plist-get result :cache) cache))
            (should (equal (plist-get result :targets) 2))
            (should (file-exists-p cache))
            (let ((body (with-temp-buffer
                          (insert-file-contents cache)
                          (buffer-string))))
              (should (string-prefix-p "NELIX-AOT-MANIFEST-V1\n" body))
              (should (string-match-p "target\tmagit\tmagit\n" body))
              (should (string-match-p "target\tripgrep\tripgrep\n" body))
              (should (string-match-p "pin\tripgrep\n" body))
              (should (string-match-p "name-id\t1\tmagit\n" body))
              (should (string-match-p "name-id\t2\tripgrep\n" body))
              (should (string-match-p "target-id\t1\t1\n" body))
              (should (string-match-p "target-id\t2\t2\n" body))
              (should (string-match-p "pin-id\t2\n" body))
              (should-not (string-match-p "^installed\t" body))
              (should-not (string-match-p "^installed-id\t" body))
              (should-not (string-suffix-p "end\n" body)))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-target-cache-resolves-emacs-overrides ()
  "The AOT target cache stores resolved manifest targets for Emacs packages."
  (let ((dir (make-temp-file "nelix-cli-aot-cache-overrides-" t))
        (old-overrides-bound (boundp 'nelix-package-nixpkgs-overrides))
        (old-overrides-value (and (boundp 'nelix-package-nixpkgs-overrides)
                                  nelix-package-nixpkgs-overrides))
        (old-target-function (and (fboundp 'nelix-package-install-target)
                                  (symbol-function 'nelix-package-install-target))))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (cache (expand-file-name "targets.cache" dir)))
          (makunbound 'nelix-package-nixpkgs-overrides)
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(defun nelix-package-install-target (package)\n"
                    "  (or (cdr (assq package"
                    " '((compat . \"emacsPackages.compat\"))))"
                    " package))\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(compat))\n"))
          (let ((result (nelix-fast-aot-target-cache-write manifest cache)))
            (should (equal (plist-get result :cache) cache))
            (should (equal (plist-get result :targets) 1))
            (let ((body (with-temp-buffer
                          (insert-file-contents cache)
                          (buffer-string))))
              (should (string-match-p
                       "^target\temacsPackages\\.compat\temacsPackages\\.compat\tcompat$"
                       body))
              (should (string-match-p "^name-id\t1\temacsPackages\\.compat$" body))
              (should (string-match-p "^name-id\t2\tcompat$" body))
              (should (string-match-p "^target-id\t1\t1\t2$" body)))))
      (if old-overrides-bound
          (setq nelix-package-nixpkgs-overrides old-overrides-value)
        (makunbound 'nelix-package-nixpkgs-overrides))
      (if old-target-function
          (fset 'nelix-package-install-target old-target-function)
        (fmakunbound 'nelix-package-install-target))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-target-cache-builds-runtime-payload ()
  "A target cache can be completed with installed names at runtime."
  (let ((dir (make-temp-file "nelix-cli-aot-cache-payload-" t)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (cache (expand-file-name "targets.cache" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (nelix-fast-aot-target-cache-write manifest cache)
          (let* ((payload (nelix-fast-aot-input-from-target-cache
                           cache
                           '("magit" "ripgrep-1" "bat")))
                 (report (nelix-aot-audit payload))
                 (plan (nelix-aot-upgrade-plan payload))
                 (audit-json (nelix-aot-audit-json
                              payload
                              ":nelisp-aot-cache"
                              cache))
                 (plan-json (nelix-aot-upgrade-plan-json
                             payload
                             ":nelisp-aot-cache"
                             cache)))
            (should (string-match-p "installed\tbat\nend\n" payload))
            (should (string-match-p "installed-id\t1\n" payload))
            (should (string-match-p "installed-id\t2\n" payload))
            (should (string-match-p "^target\tmagit\tmagit$" payload))
            (should (string-match-p "^pin\tripgrep$" payload))
            (should (string-match-p "^target-id\t1\t1$" payload))
            (should (string-match-p "^pin-id\t2$" payload))
            (should (equal (plist-get report :present)
                           '("magit" "ripgrep-1")))
            (should (equal (plist-get report :extra) '("bat")))
            (should (equal (plist-get plan :upgrade) '("magit")))
            (should (equal (plist-get plan :pinned) '("ripgrep-1")))
            (should (equal (plist-get plan :missing) nil))
            (should (string-match-p "\"present\":\\[\"magit\",\"ripgrep-1\"\\]"
                                    audit-json))
            (should (string-match-p "\"extra\":\\[\"bat\"\\]" audit-json))
            (should (string-match-p "\"upgrade\":\\[\"magit\"\\]" plan-json))
            (should (string-match-p "\"pinned\":\\[\"ripgrep-1\"\\]"
                                    plan-json))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-aot-target-cache-shell-payload-adds-installed-ids ()
  "The shell payload path maps profile names to cached numeric IDs."
  (let ((dir (make-temp-file "nelix-cli-aot-cache-shell-payload-" t)))
    (unwind-protect
        (let* ((manifest (expand-file-name "manifest.el" dir))
               (cache (expand-file-name "targets.cache" dir))
               (fake-nix (expand-file-name "nix" dir))
               (anvil-pkg-nix-program fake-nix)
               (anvil-pkg-profile-dir (expand-file-name "profile" dir))
               (anvil-pkg-compat--nelisp-runtime-p nil))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit)"
                    " :linux '(\"ripgrep\")"
                    " :pins '(\"ripgrep\"))\n"))
          (with-temp-file fake-nix
            (insert "#!/bin/sh\n"
                    "printf 'Name: magit\\nName: ripgrep-1\\nName: bat\\n'\n"))
          (set-file-modes fake-nix #o755)
          (nelix-fast-aot-target-cache-write manifest cache)
          (let* ((payload (nelix-fast-aot-input-from-target-cache cache))
                 (report (nelix-aot-audit payload))
                 (plan (nelix-aot-upgrade-plan payload))
                 (audit-json (nelix-aot-audit-json
                              payload
                              ":nelisp-aot-cache"
                              cache))
                 (plan-json (nelix-aot-upgrade-plan-json
                             payload
                             ":nelisp-aot-cache"
                             cache)))
            (should (string-match-p "installed\tmagit\n" payload))
            (should (string-match-p "installed\tripgrep-1\n" payload))
            (should (string-match-p "installed-id\t1\n" payload))
            (should (string-match-p "installed-id\t2\n" payload))
            (should (string-match-p "^target\tmagit\tmagit$" payload))
            (should (string-match-p "^pin\tripgrep$" payload))
            (should (string-match-p "^target-id\t1\t1$" payload))
            (should (string-match-p "^pin-id\t2$" payload))
            (should (equal (plist-get report :present)
                           '("magit" "ripgrep-1")))
            (should (equal (plist-get report :extra) '("bat")))
            (should (equal (plist-get plan :upgrade) '("magit")))
            (should (equal (plist-get plan :pinned) '("ripgrep-1")))
            (should (equal (plist-get plan :missing) nil))
            (should (string-match-p "\"present\":\\[\"magit\",\"ripgrep-1\"\\]"
                                    audit-json))
            (should (string-match-p "\"extra\":\\[\"bat\"\\]" audit-json))
            (should (string-match-p "\"upgrade\":\\[\"magit\"\\]" plan-json))
            (should (string-match-p "\"pinned\":\\[\"ripgrep-1\"\\]"
                                    plan-json))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-dispatch-aot-cache-command ()
  "CLI dispatch exposes target cache generation."
  (let ((dir (make-temp-file "nelix-cli-dispatch-aot-cache-" t)))
    (unwind-protect
        (let ((manifest (expand-file-name "manifest.el" dir)))
          (with-temp-file manifest
            (insert "(require 'nelix-manifest)\n"
                    "(nelix-manifest :name \"default\""
                    " :emacs '(magit))\n"))
          (let ((result (nelix-cli-dispatch
                         (list :command "aot-cache"
                               :args (list manifest)))))
            (should (eq (plist-get result :status) 'ok))
            (should (file-exists-p (plist-get result :cache)))))
      (delete-directory dir t))))

(ert-deftest nelix-cli-test-dispatch-registry-update ()
  "CLI exposes registry cache refresh."
  (let (called)
    (cl-letf (((symbol-function 'nelix-registry-update)
               (lambda (&optional roots)
                 (setq called roots)
                 '(:status ok :loaded 2 :roots ("/tmp/registry")))))
      (let ((result (nelix-cli-dispatch
                     '(:command "registry" :args ("update")))))
        (should (eq (plist-get result :operation) 'registry-update))
        (should (eq (plist-get result :status) 'ok))
        (should (= (plist-get result :loaded) 2))
        (should (null called))))))

(ert-deftest nelix-cli-test-dispatch-registry-index ()
  "CLI writes a static registry index for a local root."
  (let (called)
    (cl-letf (((symbol-function 'nelix-registry-write-index)
               (lambda (root output)
                 (setq called (list root output))
                 (list :status 'ok
                       :operation 'registry-index
                       :root root
                       :output output
                       :count 2))))
      (let ((result (nelix-cli-dispatch
                     '(:command "registry"
                       :args ("index" "/tmp/registry" "/tmp/index.el")))))
        (should (eq (plist-get result :operation) 'registry-index))
        (should (= (plist-get result :count) 2))
        (should (equal called '("/tmp/registry" "/tmp/index.el")))))))

(ert-deftest nelix-cli-test-dispatch-registry-search ()
  "CLI registry search refreshes registry data before matching."
  (let (update-called search-called)
    (cl-letf (((symbol-function 'nelix-registry-update)
               (lambda (&optional roots)
                 (setq update-called roots)
                 '(:status ok :loaded 1)))
              ((symbol-function 'nelix-registry-search)
               (lambda (query &optional system)
                 (setq search-called (list query system))
                 '((:name "ripgrep" :version "14" :class binary
                    :systems ((x86_64-linux :source nil)))))))
      (let ((result (nelix-cli-dispatch
                     '(:command "registry"
                       :args ("search" "rip" "--system" "x86_64-linux")))))
        (should (eq (plist-get result :operation) 'registry-search))
        (should (equal (plist-get result :query) "rip"))
        (should (eq (plist-get result :system) 'x86_64-linux))
        (should (= (plist-get result :count) 1))
        (should (equal search-called '("rip" x86_64-linux)))
        (should (null update-called))))))

(ert-deftest nelix-cli-test-dispatch-registry-list ()
  "CLI registry list refreshes registry data and can filter by system."
  (let (update-called list-called)
    (cl-letf (((symbol-function 'nelix-registry-update)
               (lambda (&optional roots)
                 (setq update-called roots)
                 '(:status ok :loaded 2)))
              ((symbol-function 'nelix-registry-list)
               (lambda (&optional system)
                 (setq list-called system)
                 '((:name "magit" :version "4" :class emacs-package
                    :systems ((x86_64-linux :source nil)))
                   (:name "ripgrep" :version "14" :class binary
                    :systems ((x86_64-linux :source nil)))))))
      (let ((result (nelix-cli-dispatch
                     '(:command "registry"
                       :args ("list" "--system" "x86_64-linux")))))
        (should (eq (plist-get result :operation) 'registry-list))
        (should (eq (plist-get result :system) 'x86_64-linux))
        (should (= (plist-get result :count) 2))
        (should (eq list-called 'x86_64-linux))
        (should (null update-called))))))

(ert-deftest nelix-cli-test-dispatch-registry-show ()
  "CLI registry show refreshes registry data and returns one recipe."
  (let (updated shown)
    (cl-letf (((symbol-function 'nelix-registry-update)
               (lambda (&optional roots)
                 (setq updated roots)
                 '(:status ok :loaded 1)))
              ((symbol-function 'nelix-registry-get)
               (lambda (name)
                 (setq shown name)
                 '(:name "ripgrep" :version "14" :class binary
                   :systems ((x86_64-linux :source nil))))))
      (let ((result (nelix-cli-dispatch
                     '(:command "registry" :args ("show" "ripgrep")))))
        (should (eq (plist-get result :operation) 'registry-show))
        (should (equal (plist-get result :name) "ripgrep"))
        (should (equal (plist-get (plist-get result :recipe) :name)
                       "ripgrep"))
        (should (equal shown "ripgrep"))
        (should (null updated))))))

(ert-deftest nelix-cli-test-registry-json-normalizes-recipe ()
  "Registry CLI reports keep recipe data JSON-compatible."
  (cl-letf (((symbol-function 'nelix-registry-update)
             (lambda (&optional _roots) '(:status ok :loaded 1)))
            ((symbol-function 'nelix-registry-get)
             (lambda (_name)
               '(:name "ripgrep" :version "14" :class binary
                 :systems ((x86_64-linux :source nil))))))
    (let ((json (nelix-cli-format-result
                 (nelix-cli-dispatch
                  '(:command "registry" :args ("show" "ripgrep")))
                 t)))
      (should (string-match-p "\"operation\":\"registry-show\"" json))
      (should (string-match-p "\"name\":\"ripgrep\"" json))
      (should (string-match-p "\"class\":\"binary\"" json)))))

(ert-deftest nelix-cli-test-registry-rejects-missing-search-query ()
  (should-error
   (nelix-cli-dispatch '(:command "registry" :args ("search")))
   :type 'anvil-pkg-error))

(ert-deftest nelix-cli-test-dispatch-native-install ()
  "CLI native install refreshes registry and dispatches native backend install."
  (let (updated called)
    (cl-letf (((symbol-function 'nelix-registry-update)
               (lambda (&optional roots)
                 (setq updated roots)
                 '(:status ok :loaded 1)))
              ((symbol-function 'nelix-backend-install)
               (lambda (backend targets profile system)
                 (setq called (list backend targets profile system))
                 (list (list :status 'ok
                             :name "ripgrep"
                             :backend backend))))
              ((symbol-function 'nelix-current-system)
               (lambda () 'x86_64-linux))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("install" "ripgrep"
                       "--profile" "dev"
                       "--system" "x86_64-linux")))))
        (should (equal called
                       '(nelix-native ("ripgrep") "dev" x86_64-linux)))
        (should (null updated))
        (should (eq (plist-get result :operation) 'native-install))
        (should (= 1 (plist-get result :count)))
        (should (equal "/tmp/nelix/profiles"
                       (plist-get result :profile-root)))))))

(ert-deftest nelix-cli-test-dispatch-native-remove ()
  "CLI native remove prunes names from the selected profile generation."
  (let (called)
    (cl-letf (((symbol-function 'nelix-profile-prune)
               (lambda (profile names &optional system)
                 (setq called (list profile names system))
                 (list :changed t
                       :removed '((:name "ripgrep"))
                       :kept '((:name "magit"))
                       :profile '(:name "dev"
                                  :generation 4
                                  :system x86_64-linux
                                  :entries ((:name "magit"))))))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("remove" "ripgrep"
                       "--profile" "dev"
                       "--system" "x86_64-linux")))))
        (should (equal called '("dev" ("ripgrep") x86_64-linux)))
        (should (eq (plist-get result :operation) 'native-remove))
        (should (plist-get result :changed))
        (should (= 1 (plist-get result :count)))
        (should (= 4 (plist-get result :generation)))
        (should (equal "ripgrep"
                       (plist-get (car (plist-get result :removed))
                                  :name)))
        (should (equal "/tmp/nelix/profiles"
                       (plist-get result :profile-root)))))))

(ert-deftest nelix-cli-test-dispatch-native-list ()
  "CLI native list delegates to the native backend list API."
  (cl-letf (((symbol-function 'nelix-backend-list)
             (lambda (backend)
               (list :backend backend
                     :store '(:count 0)
                     :profiles-root "/tmp/nelix/profiles"))))
    (let ((result
           (nelix-cli-dispatch
            '(:command "native" :args ("list")))))
      (should (eq (plist-get result :operation) 'native-list))
      (should (eq (plist-get result :backend) 'nelix-native))
      (should (equal "/tmp/nelix/profiles"
                     (plist-get result :profiles-root))))))

(ert-deftest nelix-cli-test-dispatch-native-profile ()
  "CLI native profile reads a selected profile generation."
  (let (called)
    (cl-letf (((symbol-function 'nelix-profile-read)
               (lambda (profile generation)
                 (setq called (list profile generation))
                 (list :name profile
                       :generation generation
                       :entries nil)))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("profile" "--profile" "dev"
                       "--generation" "7")))))
        (should (equal called '("dev" 7)))
        (should (eq (plist-get result :operation) 'native-profile))
        (should (= 7 (plist-get result :generation)))))))

(ert-deftest nelix-cli-test-dispatch-native-activate ()
  "CLI native activate creates runtime activation and reports Emacs load paths."
  (let (runtime-called emacs-called)
    (cl-letf (((symbol-function 'nelix-profile-activate-runtime)
               (lambda (profile generation)
                 (setq runtime-called (list profile generation))
                 (list :status 'ok
                       :generation 3
                       :bin-dir "/tmp/nelix/profiles/dev/active/bin")))
              ((symbol-function 'nelix-profile-emacs-load-paths)
               (lambda (profile generation)
                 (setq emacs-called (list profile generation))
                 '("/tmp/nelix/store/pkg/lisp")))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("activate" "--profile" "dev"
                       "--generation" "3")))))
        (should (equal runtime-called '("dev" 3)))
        (should (equal emacs-called '("dev" 3)))
        (should (eq (plist-get result :operation) 'native-activate))
        (should (equal '("/tmp/nelix/store/pkg/lisp")
                       (plist-get result :emacs-load-paths)))))))

(ert-deftest nelix-cli-test-dispatch-native-rollback ()
  "CLI native rollback updates the current generation and reactivates it."
  (let (rollback-called runtime-called emacs-called)
    (cl-letf (((symbol-function 'nelix-profile-rollback)
               (lambda (profile generation)
                 (setq rollback-called (list profile generation))
                 (list :name profile
                       :generation generation
                       :entries '((:name "ripgrep")))))
              ((symbol-function 'nelix-profile-activate-runtime)
               (lambda (profile generation)
                 (setq runtime-called (list profile generation))
                 (list :status 'ok
                       :generation generation
                       :bin-dir "/tmp/nelix/profiles/dev/active/bin")))
              ((symbol-function 'nelix-profile-emacs-load-paths)
               (lambda (profile generation)
                 (setq emacs-called (list profile generation))
                 '("/tmp/nelix/store/pkg/lisp")))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("rollback" "--profile" "dev"
                       "--generation" "2")))))
        (should (equal rollback-called '("dev" 2)))
        (should (equal runtime-called '("dev" 2)))
        (should (equal emacs-called '("dev" 2)))
        (should (eq (plist-get result :operation) 'native-rollback))
        (should (= 2 (plist-get result :generation)))
        (should (equal '("/tmp/nelix/store/pkg/lisp")
                       (plist-get result :emacs-load-paths)))))))

(ert-deftest nelix-cli-test-dispatch-native-gc ()
  "CLI native gc parses dry-run/profile options."
  (let (called)
    (cl-letf (((symbol-function 'nelix-store-gc)
               (lambda (&rest args)
                 (setq called args)
                 '(:ok t :dry-run t :collected ("/tmp/dead"))))
              ((symbol-function 'nelix-profile-root)
               (lambda () "/tmp/nelix/profiles")))
      (let ((result
             (nelix-cli-dispatch
              '(:command "native"
                :args ("gc" "--dry-run" "--profile" "dev")))))
        (should (equal called '(:dry-run t :profile "dev")))
        (should (eq (plist-get result :operation) 'native-gc))
        (should (plist-get result :dry-run))))))

(ert-deftest nelix-cli-test-native-install-rejects-missing-name ()
  (should-error
   (nelix-cli-dispatch '(:command "native" :args ("install")))
   :type 'anvil-pkg-error))

(ert-deftest nelix-cli-test-rollback-generation-parses-integer ()
  (let (called)
    (cl-letf (((symbol-function 'nelix-rollback)
               (lambda (generation)
                 (setq called generation)
                 t)))
      (let ((result (nelix-cli-dispatch
                     '(:command "rollback" :args ("42")))))
        (should (eq (plist-get result :status) 'ok))
        (should (eq (plist-get result :generation) 42))
        (should (eq called 42))))))

(ert-deftest nelix-cli-test-unknown-command-errors ()
  (should-error
   (nelix-cli-dispatch '(:command "nope" :args nil))
   :type 'anvil-pkg-error))

(provide 'nelix-cli-test)
;;; nelix-cli-test.el ends here
