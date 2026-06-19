;;; nelix-manifest-test.el --- ERT tests for Nelix manifests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Desired-state manifest tests.  Nix is not invoked; profile operations are
;; mocked at the Nelix public API boundary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-manifest)
(require 'nelix-dsl)
(require 'anvil-pkg-state)

(defvar nelix-manifest-test-import-loaded nil
  "Non-nil when a manifest import fixture has been loaded.")

(defconst nelix-manifest-test--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing nelix-manifest-test.el.")

(defmacro nelix-manifest-test--with-state (&rest body)
  "Run BODY with isolated persistent state."
  (declare (indent 0))
  `(let* ((tmp-state (make-temp-file "nelix-manifest-state-" nil ".json"))
          (anvil-pkg-state-file tmp-state)
          (anvil-pkg-state--cache 'unloaded)
          (anvil-pkg-state--loaded-from nil))
     (unwind-protect
         (progn
           (delete-file tmp-state)
           ,@body)
       (when (file-exists-p tmp-state)
         (delete-file tmp-state)))))

(defun nelix-manifest-test--write (dir name contents)
  "Write CONTENTS to DIR/NAME and return the file name."
  (let ((path (expand-file-name name dir)))
    (with-temp-file path
      (insert contents))
    path))

(defun nelix-manifest-test--fixture (name)
  "Return the test fixture path for NAME."
  (expand-file-name (concat "fixtures/" name)
                    nelix-manifest-test--directory))

(defun nelix-manifest-test--write-lock (file lock)
  "Write LOCK plist to FILE using the generated lock format."
  (with-temp-file file
    (insert ";;; generated test lock -*- lexical-binding: t; -*-\n\n"
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
            ")\n")))

(ert-deftest nelix-manifest-test-normalizes-minimal-form ()
  "nelix-manifest normalizes defaults and validates list fields."
  (let ((manifest (nelix-manifest
                   :name 'default
                   :emacs '(magit "org-roam")
                   :linux '(ripgrep "fd")
                   :pins '(ripgrep))))
    (should (equal "default" (plist-get manifest :name)))
    (should (equal "default" (plist-get manifest :profile)))
    (should (equal "nixpkgs" (plist-get manifest :nix-channel)))
    (should (equal '(magit "org-roam") (plist-get manifest :emacs)))
    (should (equal '("ripgrep" "fd") (plist-get manifest :linux)))
    (should (equal '("ripgrep") (plist-get manifest :pins)))))

(ert-deftest nelix-manifest-test-environment-dsl-v1-expands-to-manifest ()
  "nelix-environment is the stable Nix/Guix-style manifest DSL."
  (let ((emacs-list '(magit consult))
        (linux-list '("ripgrep" "fd")))
    (let ((manifest
           (nelix-environment
            (name "default")
            (profile "desktop")
            (nix-channel "nixpkgs")
            (imports "custom-lisp/nelix-linux.el"
                     "custom-lisp/nelix-package-index.el")
            (backend-policy (gnu/linux nix nelix-native)
                            (darwin nix nelix-native)
                            (windows-nt nix))
            (emacs-packages emacs-list)
            (linux-packages linux-list)
            (bootstrap-apt-packages build-essential devscripts)
            (pins ripgrep fd))))
      (should (equal "default" (plist-get manifest :name)))
      (should (equal "desktop" (plist-get manifest :profile)))
      (should (equal '(magit consult) (plist-get manifest :emacs)))
      (should (equal '("ripgrep" "fd") (plist-get manifest :linux)))
      (should (equal '(build-essential devscripts)
                     (plist-get manifest :bootstrap-apt)))
      (should (equal '("ripgrep" "fd") (plist-get manifest :pins)))
      (should (equal '("custom-lisp/nelix-linux.el"
                       "custom-lisp/nelix-package-index.el")
                     (plist-get manifest :imports)))
      (should (equal '(nix nelix-native)
                     (nelix-manifest-backend-policy
                      manifest 'gnu/linux))))))

(ert-deftest nelix-manifest-test-dsl-entrypoint-provides-environment-v1 ()
  "`nelix-dsl' is the public require boundary for the DSL v1 contract."
  (should (= 1 (nelix-dsl-version)))
  (should (fboundp 'nelix-environment))
  (should (memq 'emacs-packages nelix-environment-dsl-forms))
  (let ((manifest
         (nelix-environment
          (name "entrypoint")
          (emacs-packages magit consult)
          (linux-packages "ripgrep" "fd"))))
    (should (equal "entrypoint" (plist-get manifest :name)))
    (should (equal '(magit consult) (plist-get manifest :emacs)))
    (should (equal '("ripgrep" "fd") (plist-get manifest :linux)))))

(ert-deftest nelix-manifest-test-environment-dsl-v1-rejects-duplicate-forms ()
  "DSL v1 subforms are single-assignment."
  (let ((err (should-error
              (eval '(nelix-environment
                      (name "first")
                      (name "second")))
              :type 'anvil-pkg-error)))
    (should (string-match-p "duplicate form name" (cadr err)))))

(ert-deftest nelix-manifest-test-validate-is-process-free ()
  "nelix-validate loads manifests and reports counts without profile IO."
  (let ((dir (make-temp-file "nelix-manifest-validate-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "packages.el"
           "(setq nelix-manifest-test-import-loaded 'validate)\n")
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :imports '(\"packages.el\") :emacs '(magit consult) :linux '(\"ripgrep\") :bootstrap-apt '(nix-bin))\n")
          (cl-letf (((symbol-function 'pkg-list)
                     (lambda ()
                       (error "pkg-list must not be called"))))
            (let* ((report (nelix-validate
                            (expand-file-name "manifest.el" dir)))
                   (counts (plist-get report :counts)))
              (should (plist-get report :ok))
              (should (equal 2 (plist-get counts :emacs)))
              (should (equal 1 (plist-get counts :linux)))
              (should (equal 1 (plist-get counts :bootstrap-apt)))
              (should (equal 1 (plist-get counts :imports)))
              (should (equal "default" (plist-get report :profile))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-rejects-unknown-keyword ()
  "Unknown manifest keywords fail before profile mutation."
  (let ((err (should-error
              (nelix-manifest :name "default" :unknown t)
              :type 'anvil-pkg-error)))
    (should (string-match-p "unknown keyword" (cadr err)))))

(ert-deftest nelix-manifest-test-loads-imports-relative-to-manifest ()
  "nelix-manifest-load loads declared import files relative to the manifest."
  (let ((dir (make-temp-file "nelix-manifest-load-" t)))
    (unwind-protect
        (let ((import (nelix-manifest-test--write
                       dir "packages.el"
                       "(setq nelix-manifest-test-import-loaded t)\n")))
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :imports '(\"packages.el\"))\n")
          (setq nelix-manifest-test-import-loaded nil)
          (let ((manifest (nelix-manifest-load
                           (expand-file-name "manifest.el" dir))))
            (should (equal (list import) (plist-get manifest :imports)))
            (should nelix-manifest-test-import-loaded)))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-installs-removes-and-pins ()
  "nelix-apply converges missing and extra Nix profile entries."
  (let ((dir (make-temp-file "nelix-manifest-apply-" t))
        nix-calls
        pinned-targets)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :emacs '(magit) :linux '(ripgrep) :pins '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-package-install-target)
                     (lambda (package)
                       (if (eq package 'magit) "emacsPackages.magit" package)))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "magit"
                                   :attr-path "legacyPackages.x86_64-linux.emacsPackages.magit")
                             (list :name "bat"
                                   :attr-path "legacyPackages.x86_64-linux.bat"))))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (args)
                       (push args nix-calls)
                       (list :exit 0 :stdout "" :stderr "")))
                    ((symbol-function 'pkg-list-generations)
                     (lambda ()
                       '((:id 7 :date "before" :packages nil :active t))))
                    ((symbol-function 'nelix-pin)
                     (lambda (name)
                       (push name pinned-targets)
                       t)))
            (let ((err (should-error
                        (nelix-apply (expand-file-name "manifest.el" dir))
                        :type 'anvil-pkg-error)))
              (should (string-match-p "refusing to remove 1 package"
                                      (cadr err))))
            (should-not nix-calls)
            (let ((report (nelix-apply (expand-file-name "manifest.el" dir)
                                       :allow-remove-count 1)))
              (should (eq 'ok (plist-get report :status)))
              (should (eq 'nix (plist-get report :backend)))
              (should (equal '("ripgrep")
                             (plist-get report :installed)))
              (should (equal '("bat")
                             (plist-get report :removed)))
              (should (equal '(("profile" "install" "--profile")
                              ("profile" "remove" "bat"))
                             (mapcar (lambda (argv) (cl-subseq argv 0 3))
                                     (nreverse nix-calls))))
              (should (equal 7 (plist-get (plist-get report :transaction)
                                          :before-generation)))
              (should (equal '("ripgrep") (nreverse pinned-targets))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-rolls-back-on-command-failure ()
  "nelix-apply rolls the Nix profile back to the pre-apply generation."
  (let ((dir (make-temp-file "nelix-manifest-apply-rollback-" t))
        nix-calls
        rollback-generation)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep fd))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'pkg-list-generations)
                     (lambda ()
                       '((:id 7 :date "before" :packages nil :active t))))
                    ((symbol-function 'nelix-rollback)
                     (lambda (generation)
                       (setq rollback-generation generation)
                       t))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (args)
                       (push args nix-calls)
                       (if (equal (car (last args)) "nixpkgs#fd")
                           (list :exit 1 :stdout "" :stderr "install failed")
                         (list :exit 0 :stdout "" :stderr "")))))
            (let ((err (should-error
                        (nelix-apply (expand-file-name "manifest.el" dir))
                        :type 'anvil-pkg-error)))
              (should (string-match-p "rollback=ok" (cadr err)))
              (should (equal 7 rollback-generation))
              (should (= 2 (length nix-calls))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-nelisp-installs-missing-via-nix ()
  "NeLisp runtime apply can dry-run the Nix convergence plan."
  (let ((dir (make-temp-file "nelix-manifest-nelisp-apply-" t))
        nix-called)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :emacs '(magit) :linux '(ripgrep) :pins '(ripgrep))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'nelix-package-install-target)
                     (lambda (package)
                       (if (eq package 'magit) "emacsPackages.magit" package)))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "magit"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (_args)
                       (setq nix-called t)
                       (list :exit 0 :stdout "" :stderr ""))))
            (let ((report (nelix-apply (expand-file-name "manifest.el" dir)
                                       :dry-run t)))
              (should (eq 'dry-run (plist-get report :status)))
              (should (eq 'nix (plist-get report :backend)))
              (should (equal '("ripgrep")
                             (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get report :install))))
              (should-not nix-called))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-prune-plan-nelisp-uses-name-only-profile ()
  "NeLisp prune-plan uses the name-only profile fast path and protects pins."
  (let ((dir (make-temp-file "nelix-manifest-nelisp-prune-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep) :pins '(fd))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)
                             (list :name "fd"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)
                             (list :name "bat"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)))))
            (let ((plan (nelix-prune-plan
                         (expand-file-name "manifest.el" dir))))
              (should (eq 'nix (plist-get plan :backend)))
              (should (equal '("bat")
                             (mapcar (lambda (entry)
                                       (plist-get entry :name))
                                     (plist-get plan :remove))))
              (should (equal '("fd")
                             (mapcar (lambda (entry)
                                       (plist-get entry :name))
                                     (plist-get plan :protected))))
              (should (equal '(:pinned) (plist-get plan :reason))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-sync-nelisp-prunes-via-nix-uninstall ()
  "NeLisp sync --prune removes unmanaged Nix profile names."
  (let ((dir (make-temp-file "nelix-manifest-nelisp-sync-prune-" t))
        removed)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)
                             (list :name "fd"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'pkg-list-generations)
                     (lambda ()
                       '((:id 7 :date "before" :packages nil :active t))))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (_args)
                       (list :exit 0 :stdout "" :stderr "")))
                    ((symbol-function 'nelix-install)
                     (lambda (_targets)
                       (ert-fail "sync prune fixture should not install")))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t))
                    ((symbol-function 'nelix-uninstall)
                     (lambda (name)
                       (push name removed)
                       t)))
            (let ((report (nelix-sync (expand-file-name "manifest.el" dir)
                                      :prune t
                                      :allow-remove-count 1)))
              (should (eq 'ok (plist-get report :status)))
              (should (equal '("fd") (nreverse removed)))
              (should (equal '("fd")
                             (mapcar (lambda (entry)
                                       (plist-get entry :name))
                                     (plist-get report :pruned)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-plan-supports-native-without-nix ()
  "Native backend planning is read-only and does not require Nix."
  (let ((dir (make-temp-file "nelix-manifest-native-apply-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :profile \"dev\" :linux '(fixture-tool))\n")
          (let* ((root (make-temp-file "nelix-manifest-native-plan-" t))
                 (nelix-store-root (expand-file-name "store" root))
                 (nelix-profile-root (expand-file-name "profiles" root))
                 (nelix-registry--packages (make-hash-table :test 'equal)))
            (unwind-protect
                (progn
                  (let (registry-updated)
                    (cl-letf (((symbol-function 'nelix-registry-update)
                               (lambda (&optional _roots)
                                 (setq registry-updated t)
                                 (nelix-registry-add
                                  '(:name "fixture-tool"
                                    :version "1.0.0"
                                    :class system-tool
                                    :systems
                                    ((x86_64-linux
                                      :install (:type script-shim
                                                :command "fixture-tool"
                                                :target "/usr/bin/fixture-tool")))))
                                 (list :status 'ok :loaded 1)))
                              ((symbol-function 'anvil-pkg-compat-executable-find)
                             (lambda (_program) nil)))
                      (let ((plan (nelix-plan
                                   (expand-file-name "manifest.el" dir))))
                        (should registry-updated)
                        (should (eq 'nelix-native (plist-get plan :backend)))
                        (should (= 1 (plist-get plan :count)))
                        (should-not (plist-get plan :commands))
                        (should (equal '("fixture-tool")
                                       (mapcar
                                        (lambda (row) (plist-get row :name))
                                        (plist-get plan :install))))
                        (should (eq 'registry
                                    (plist-get (car (plist-get plan :install))
                                               :source)))
                        (should (equal "1.0.0"
                                       (plist-get
                                        (car (plist-get plan :install))
                                        :recipe-version)))))))
              (delete-directory root t))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-dry-run-supports-native-without-mutation ()
  "Native apply --dry-run returns the plan without installing recipes."
  (let ((dir (make-temp-file "nelix-manifest-native-dry-run-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :profile \"dev\" :linux '(fixture-tool) :backend-policy '(nelix-native))\n")
          (let* ((root (make-temp-file "nelix-manifest-native-dry-run-root-" t))
                 (nelix-store-root (expand-file-name "store" root))
                 (nelix-profile-root (expand-file-name "profiles" root))
                 (nelix-registry--packages (make-hash-table :test 'equal)))
            (unwind-protect
                (progn
                  (let (registry-updated)
                    (cl-letf (((symbol-function 'nelix-registry-update)
                               (lambda (&optional _roots)
                                 (setq registry-updated t)
                                 (nelix-registry-add
                                  '(:name "fixture-tool"
                                    :version "1.0.0"
                                    :class system-tool
                                    :systems
                                    ((x86_64-linux
                                      :install (:type script-shim
                                                :command "fixture-tool"
                                                :target "/usr/bin/fixture-tool")))))
                                 (list :status 'ok :loaded 1)))
                              ((symbol-function 'anvil-pkg-compat-executable-find)
                             (lambda (_program) nil))
                            ((symbol-function 'nelix-native-install)
                             (lambda (&rest _args)
                               (ert-fail "native dry-run must not install"))))
                      (let ((report (nelix-apply
                                     (expand-file-name "manifest.el" dir)
                                     :dry-run t)))
                        (should registry-updated)
                        (should (eq 'dry-run (plist-get report :status)))
                        (should (eq 'nelix-native (plist-get report :backend)))
                        (should (plist-get report :dry-run))
                        (should (= 1 (plist-get report :count)))
                        (should (equal '("fixture-tool")
                                       (mapcar
                                        (lambda (row) (plist-get row :name))
                                        (plist-get report :install))))
                        (should (plist-get (plist-get report :transaction)
                                           :dry-run))))))
              (delete-directory root t))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-audit-reports-missing-extra-and-pin-drift ()
  "nelix-audit is read-only and reports desired-state drift."
  (let ((dir (make-temp-file "nelix-manifest-audit-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep fd) :pins '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep")
                             (list :name "jq"
                                   :attr-path "legacyPackages.x86_64-linux.jq"))))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () '("jq"))))
            (let ((audit (nelix-audit (expand-file-name "manifest.el" dir))))
              (should-not (plist-get audit :ok))
              (should (equal '("fd")
                             (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get audit :missing))))
              (should (equal '("jq")
                             (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get audit :extra))))
              (should (equal '("ripgrep")
                             (plist-get (plist-get audit :pins) :missing)))
              (should (equal '("jq")
                             (plist-get (plist-get audit :pins) :extra))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-audit-includes-native-report ()
  "nelix-audit includes native store/profile state for nelix-native."
  (let ((dir (make-temp-file "nelix-manifest-native-audit-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-tool) :backend-policy '(nelix-native nix))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (_program) nil))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () nil))
                    ((symbol-function 'nelix-native-audit)
                     (lambda (targets)
                       (should (equal '("fixture-tool") targets))
                       (list :ok t
                             :backend 'nelix-native
                             :store (list :ok t :count 0)))))
            (let ((audit (nelix-audit (expand-file-name "manifest.el" dir))))
              (should (eq 'nelix-native (plist-get audit :backend)))
              (should (equal "fixture-tool"
                             (plist-get (car (plist-get audit :missing))
                                        :name)))
              (should (plist-get (plist-get audit :native) :ok)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-audit-fails-on-native-unsupported-target-system ()
  "nelix-audit fails when a requested native recipe lacks current-system data."
  (let ((dir (make-temp-file "nelix-manifest-native-unsupported-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(darwin-only) :backend-policy '(nelix-native))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (_program) nil))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () nil))
                    ((symbol-function 'nelix-native-audit)
                     (lambda (targets)
                       (should (equal '("darwin-only") targets))
                       (list :ok nil
                             :backend 'nelix-native
                             :unsupported-systems
                             (list (list :name "darwin-only"
                                         :reason :unsupported-system))))))
            (let ((audit (nelix-audit (expand-file-name "manifest.el" dir))))
              (should-not (plist-get audit :ok))
              (should (equal "darwin-only"
                             (plist-get
                              (car (plist-get (plist-get audit :native)
                                              :unsupported-systems))
                              :name))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-sync-prunes-native-profile-generation ()
  "nelix-sync prunes native profile entries through a new generation."
  (let ((dir (make-temp-file "nelix-manifest-native-sync-" t)))
    (unwind-protect
        (let* ((root (make-temp-file "nelix-manifest-native-roots-" t))
               (nelix-store-root (expand-file-name "store" root))
               (nelix-profile-root (expand-file-name "profiles" root))
               (entry-a (list :name "fixture-tool"
                              :version "1.0.0"
                              :system 'x86_64-linux
                              :hash "sha256-fixture-tool"))
               (entry-b (list :name "extra-tool"
                              :version "1.0.0"
                              :system 'x86_64-linux
                              :hash "sha256-extra-tool"))
               (entry-orphan (list :name "orphan-tool"
                                   :version "1.0.0"
                                   :system 'x86_64-linux
                                   :hash "sha256-orphan-tool"))
               (store-a (nelix-store-write-entry entry-a))
               (store-b (nelix-store-write-entry entry-b))
               (store-orphan (nelix-store-write-entry entry-orphan)))
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-tool) :backend-policy '(nelix-native nix))\n")
          (nelix-profile-create-generation
           "default" 'x86_64-linux
           (list (list :name "fixture-tool" :store-path store-a)
                 (list :name "extra-tool" :store-path store-b)))
          (cl-letf (((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (_program) nil))
                    ((symbol-function 'nelix-native-install)
                     (lambda (target _profile _system)
                       (list :status 'ok
                             :backend 'nelix-native
                             :name (if (symbolp target)
                                       (symbol-name target)
                                     target))))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () nil))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let ((report (nelix-sync (expand-file-name "manifest.el" dir)
                                      :prune t)))
              (should (eq 'nelix-native (plist-get report :backend)))
              (should-not (plist-get report :prune-blocked))
              (should (equal '("extra-tool")
                             (mapcar (lambda (entry)
                                       (plist-get entry :name))
                                     (plist-get report :pruned))))
              (should (equal '("fixture-tool")
                             (mapcar (lambda (entry)
                                       (plist-get entry :name))
                                     (plist-get (nelix-profile-read "default")
                                                :entries))))
              (should (file-exists-p store-b))
              (should-not (file-exists-p store-orphan))
              (should (equal (list store-orphan)
                             (plist-get (plist-get report :gc)
                                        :removed))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-prune-plan-protects-pins ()
  "nelix-prune-plan separates removable extras from manifest-pinned extras."
  (let ((dir (make-temp-file "nelix-manifest-prune-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep) :pins '(jq))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep")
                             (list :name "fd"
                                   :attr-path "legacyPackages.x86_64-linux.fd")
                             (list :name "jq"
                                   :attr-path "legacyPackages.x86_64-linux.jq")))))
            (let ((plan (nelix-prune-plan (expand-file-name "manifest.el" dir))))
              (should (equal '("fd")
                             (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get plan :remove))))
              (should (equal '("jq")
                             (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get plan :protected)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-write-read-and-check ()
  "nelix-lock-write emits a readable lock whose digest matches the manifest."
  (let ((dir (make-temp-file "nelix-manifest-lock-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7")))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (nelix-lock-write manifest-file))
                   (read-lock (nelix-lock-read manifest-file))
                   (check (nelix-lock-check manifest-file)))
              (should (equal (plist-get lock :manifest-digest)
                             (plist-get read-lock :manifest-digest)))
              (should (= 2 (plist-get read-lock :version)))
              (should (equal "nelix-lock" (plist-get read-lock :schema)))
              (should (= 2 (plist-get read-lock :schema-version)))
              (should (eq 'sexp (plist-get read-lock :format)))
              (should (plist-get (nelix-lock-schema-check read-lock) :ok))
              (should (eq 'nix (plist-get read-lock :backend)))
              (should (eq (nelix-current-system) (plist-get read-lock :system)))
              (should (equal "nixpkgs" (plist-get read-lock :nix-channel)))
              (should (equal '("ripgrep")
                             (mapcar (lambda (row)
                                       (plist-get row :name))
                                     (plist-get read-lock :packages))))
              (should (plist-get check :ok)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-schema-check-accepts-legacy-v2 ()
  "Lock schema v2 remains readable without explicit schema metadata."
  (let ((dir (make-temp-file "nelix-manifest-lock-legacy-" t)))
    (unwind-protect
        (let* ((manifest-file
                (nelix-manifest-test--write
                 dir "manifest.el"
                 "(require 'nelix-manifest)\n(nelix-manifest :name \"default\")\n"))
               (legacy-lock (expand-file-name "manifest.lock.el" dir)))
          (copy-file (nelix-manifest-test--fixture
                      "nelix-lock-v2-legacy.el")
                     legacy-lock t)
          (let* ((lock (nelix-lock-read manifest-file))
                 (schema (nelix-lock-schema-check lock)))
            (should (plist-get schema :ok))
            (should (equal "nelix-lock" (plist-get schema :schema)))
            (should (= 2 (plist-get schema :schema-version)))
            (should (= 2 (plist-get schema :version)))
            (should (eq 'nix (plist-get lock :backend)))
            (should (null (plist-get lock :packages)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-schema-check-accepts-current-v2-fixture ()
  "Current schema v2 fixtures preserve explicit schema metadata and rows."
  (let ((dir (make-temp-file "nelix-manifest-lock-v2-current-" t)))
    (unwind-protect
        (let* ((manifest-file
                (nelix-manifest-test--write
                 dir "manifest.el"
                 "(require 'nelix-manifest)\n(nelix-manifest :name \"default\")\n"))
               (lock-file (expand-file-name "manifest.el.nelix-lock" dir)))
          (copy-file (nelix-manifest-test--fixture
                      "nelix-lock-v2-current.el")
                     lock-file t)
          (let* ((lock (nelix-lock-read manifest-file))
                 (schema (nelix-lock-schema-check lock))
                 (package (car (plist-get lock :packages))))
            (should (plist-get schema :ok))
            (should (equal "nelix-lock" (plist-get schema :schema)))
            (should (= 2 (plist-get schema :schema-version)))
            (should (= 2 (plist-get schema :version)))
            (should (equal "ripgrep" (plist-get package :name)))
            (should (eq 'nix (plist-get package :backend)))
            (should (equal "legacyPackages.x86_64-linux.ripgrep"
                           (plist-get package :attr-path)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-schema-check-accepts-native-deps-fixture ()
  "Current schema v2 fixtures can include native dependency closure rows."
  (let ((dir (make-temp-file "nelix-manifest-lock-v2-native-deps-" t)))
    (unwind-protect
        (let* ((manifest-file
                (nelix-manifest-test--write
                 dir "manifest.el"
                 "(require 'nelix-manifest)\n(nelix-manifest :name \"default\")\n"))
               (lock-file (expand-file-name "manifest.el.nelix-lock" dir)))
          (copy-file (nelix-manifest-test--fixture
                      "nelix-lock-v2-native-deps.el")
                     lock-file t)
          (let* ((lock (nelix-lock-read manifest-file))
                 (schema (nelix-lock-schema-check lock))
                 (packages (plist-get lock :packages))
                 (app (car packages))
                 (dep (cadr packages)))
            (should (plist-get schema :ok))
            (should (equal "nelix-lock" (plist-get schema :schema)))
            (should (= 2 (plist-get schema :schema-version)))
            (should (eq 'nelix-native (plist-get lock :backend)))
            (should (equal '("fixture-app" "fixture-dep")
                           (mapcar (lambda (row)
                                     (plist-get row :name))
                                   packages)))
            (should (equal '("fixture-dep")
                           (plist-get app :recipe-dependencies)))
            (should (eq 'script-shim
                        (plist-get (plist-get app :recipe-install)
                                   :type)))
            (should-not (plist-get dep :recipe-dependencies))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-schema-check-accepts-legacy-v1 ()
  "Lock schema v1 remains readable for drift checks without row enforcement."
  (let ((dir (make-temp-file "nelix-manifest-lock-v1-legacy-" t)))
    (unwind-protect
        (let* ((manifest-file
                (nelix-manifest-test--write
                 dir "manifest.el"
                 "(require 'nelix-manifest)\n(nelix-manifest :name \"default\")\n"))
               (legacy-lock (expand-file-name "manifest.lock.el" dir)))
          (copy-file (nelix-manifest-test--fixture
                      "nelix-lock-v1-legacy.el")
                     legacy-lock t)
          (let* ((lock (nelix-lock-read manifest-file))
                 (schema (nelix-lock-schema-check lock)))
            (should (plist-get schema :ok))
            (should (equal "nelix-lock" (plist-get schema :schema)))
            (should (= 1 (plist-get schema :schema-version)))
            (should (= 1 (plist-get schema :version)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-schema-check-rejects-future-version ()
  "Future lock schema versions are rejected until explicitly supported."
  (let ((schema (nelix-lock-schema-check
                 '(:schema "nelix-lock"
                   :schema-version 999
                   :version 999))))
    (should-not (plist-get schema :ok))
    (should (= 999 (plist-get schema :schema-version)))
    (should (= 2 (plist-get schema :current-schema-version)))))

(ert-deftest nelix-manifest-test-lock-schema-check-rejects-wrong-schema ()
  "Lock schemas with another name are not compatible Nelix locks."
  (let ((schema (nelix-lock-schema-check
                 '(:schema "other-lock"
                   :schema-version 2
                   :version 2))))
    (should-not (plist-get schema :ok))
    (should (equal "other-lock" (plist-get schema :schema)))
    (should (equal "nelix-lock" (plist-get schema :current-schema)))))

(ert-deftest nelix-manifest-test-lock-schema-check-rejects-missing-version ()
  "Lock schema compatibility requires an integer :version."
  (let ((schema (nelix-lock-schema-check
                 '(:schema "nelix-lock"
                   :schema-version 2))))
    (should-not (plist-get schema :ok))
    (should (= 2 (plist-get schema :schema-version)))
    (should (null (plist-get schema :version)))))

(ert-deftest nelix-manifest-test-lock-check-rejects-future-schema ()
  "Digest-clean future schema locks are still rejected by lock-check."
  (let ((dir (make-temp-file "nelix-manifest-lock-future-schema-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7")))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (nelix-lock-write manifest-file))
                   (future-lock (copy-sequence lock)))
              (setq future-lock (plist-put future-lock :schema-version 999))
              (setq future-lock (plist-put future-lock :version 999))
              (nelix-manifest-test--write-lock
               (nelix-manifest-lock-file-name manifest-file)
               future-lock)
              (let ((check (nelix-lock-check manifest-file)))
                (should-not (plist-get check :ok))
                (should-not (plist-get
                             (plist-get check :schema-check)
                             :ok))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-check-detects-import-drift ()
  "nelix-lock-check detects changes in manifest import files."
  (let ((dir (make-temp-file "nelix-manifest-lock-import-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "packages.el"
           "(setq nelix-manifest-test-import-loaded 'v1)\n")
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :imports '(\"packages.el\") :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7")))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (_lock (nelix-lock-write manifest-file))
                   (clean (nelix-lock-check manifest-file)))
              (should (plist-get clean :ok))
              (nelix-manifest-test--write
               dir "packages.el"
               "(setq nelix-manifest-test-import-loaded 'v2)\n")
              (let ((drift (nelix-lock-check manifest-file)))
                (should-not (plist-get drift :ok))
                (should-not (equal (plist-get drift :expected-files)
                                   (plist-get drift :actual-files)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-refuses-import-drift ()
  "nelix-apply :locked t refuses mutation when imported files drift."
  (let ((dir (make-temp-file "nelix-manifest-locked-drift-" t))
        installed-targets)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "packages.el"
           "(setq nelix-manifest-test-import-loaded 'v1)\n")
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :imports '(\"packages.el\") :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7"))
                    ((symbol-function 'nelix-install)
                     (lambda (targets)
                       (setq installed-targets targets)
                       t))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let ((manifest-file (expand-file-name "manifest.el" dir)))
              (nelix-lock-write manifest-file)
              (nelix-manifest-test--write
               dir "packages.el"
               "(setq nelix-manifest-test-import-loaded 'v2)\n")
              (should-error (nelix-apply manifest-file :locked t)
                            :type 'anvil-pkg-error)
              (should-not installed-targets))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-enforces-package-rows ()
  "nelix-apply :locked t records and uses lock package rows."
  (let ((dir (make-temp-file "nelix-manifest-locked-apply-" t))
        nix-calls)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7"))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (args)
                       (push args nix-calls)
                       (list :exit 0 :stdout "" :stderr "")))
                    ((symbol-function 'pkg-list-generations)
                     (lambda ()
                       '((:id 7 :date "before" :packages nil :active t))))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (_lock (nelix-lock-write manifest-file))
                   (report (nelix-apply manifest-file :locked t)))
              (should (plist-get report :locked))
              (should (plist-get report :lock-enforced))
              (should (equal '("ripgrep") (plist-get report :installed)))
              (should (equal '(("profile" "install" "--profile"))
                             (mapcar (lambda (argv) (cl-subseq argv 0 3))
                                     (nreverse nix-calls))))
              (should (equal '("ripgrep")
                             (mapcar (lambda (row)
                                       (plist-get row :target))
                                     (plist-get report
                                                :locked-installed)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-refuses-legacy-v1-lock ()
  "nelix-apply :locked t refuses legacy v1 locks without package rows."
  (let ((dir (make-temp-file "nelix-manifest-locked-v1-" t))
        installed-targets)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'nelix-install)
                     (lambda (targets)
                       (setq installed-targets targets)
                       t))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (list :version 1
                               :manifest-digest
                               (plist-get (nelix-lock-write manifest-file)
                                          :manifest-digest)
                               :manifest-files
                               (plist-get (nelix-lock-read manifest-file)
                                          :manifest-files)
                               :profile "default"
                               :backend 'nix
                               :system (nelix-current-system)
                               :packages nil)))
              (cl-letf (((symbol-function 'nelix-lock-read)
                         (lambda (_manifest) lock)))
                (let ((err (should-error
                            (nelix-apply manifest-file :locked t)
                            :type 'anvil-pkg-error)))
                  (should (string-match-p "lock version 1 cannot enforce"
                                          (cadr err))))
                (should-not installed-targets)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-refuses-future-lock-schema ()
  "nelix-apply :locked t refuses future lock schema versions."
  (let ((dir (make-temp-file "nelix-manifest-locked-future-schema-" t))
        nix-calls)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path "legacyPackages.x86_64-linux.ripgrep"))))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7"))
                    ((symbol-function 'anvil-pkg--call-nix)
                     (lambda (args)
                       (push args nix-calls)
                       (list :exit 0 :stdout "" :stderr "")))
                    ((symbol-function 'pkg-list-generations)
                     (lambda ()
                       '((:id 7 :date "before" :packages nil :active t))))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (nelix-lock-write manifest-file))
                   (future-lock (copy-sequence lock)))
              (setq future-lock (plist-put future-lock :schema-version 999))
              (setq future-lock (plist-put future-lock :version 999))
              (nelix-manifest-test--write-lock
               (nelix-manifest-lock-file-name manifest-file)
               future-lock)
              (let ((err (should-error
                          (nelix-apply manifest-file :locked t)
                          :type 'anvil-pkg-error)))
                (should (string-match-p "lock schema incompatible"
                                        (cadr err))))
              (should-not nix-calls))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-refuses-package-target-drift ()
  "nelix-apply :locked t refuses mutation when package rows drift."
  (let ((dir (make-temp-file "nelix-manifest-locked-package-drift-" t))
        installed-targets)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'anvil-pkg-compat-executable-find)
                     (lambda (program)
                       (and (equal program "nix") "/usr/bin/nix")))
                    ((symbol-function 'anvil-pkg--detect-nix-version)
                     (lambda () "2.34.7"))
                    ((symbol-function 'nelix-install)
                     (lambda (targets)
                       (setq installed-targets targets)
                       t))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (nelix-lock-write manifest-file))
                   (package (copy-sequence
                             (car (plist-get lock :packages))))
                   (drift-lock
                    (plist-put (copy-sequence lock)
                               :packages
                               (list (plist-put package
                                                :target "fd")))))
              (cl-letf (((symbol-function 'nelix-lock-read)
                         (lambda (_manifest) drift-lock)))
                (should-error (nelix-apply manifest-file :locked t)
                              :type 'anvil-pkg-error)
                (should-not installed-targets)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-replays-native-lock-despite-registry-drift ()
  "nelix-apply :locked t uses native lock rows instead of registry state."
  (let ((dir (make-temp-file "nelix-manifest-native-lock-drift-" t))
        (nelix-registry--packages (make-hash-table :test 'equal))
        installed-lock-package
        installed-lock-packages)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-tool) :backend-policy '(nelix-native))\n")
          (nelix-registry-add
           (list :name "fixture-tool"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :source (:type url
                             :url "file:///tmp/fixture-v1.tar"
                             :sha256 "sha256-fixture-v1")
                    :install (:type unpack :bin ("bin/fixture-tool"))))))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'nelix-registry-update)
                     (lambda (&optional _roots)
                       (list :status 'ok :loaded 0)))
                    ((symbol-function 'nelix-native-install-lock-package)
                     (lambda (package _profile _system all-packages)
                       (setq installed-lock-package package)
                       (setq installed-lock-packages all-packages)
                       (list :status 'ok
                             :name (plist-get package :name))))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let ((manifest-file (expand-file-name "manifest.el" dir)))
              (nelix-lock-write manifest-file)
              (nelix-registry-add
               (list :name "fixture-tool"
                     :version "1.0.0"
                     :class 'system-tool
                     :systems
                     '((x86_64-linux
                        :source (:type url
                                 :url "file:///tmp/fixture-v2.tar"
                                 :sha256 "sha256-fixture-v2")
                        :install (:type unpack
                                  :bin ("bin/fixture-tool"))))))
              (let ((report (nelix-apply manifest-file :locked t)))
                (should (plist-get report :lock-enforced))
                (should (equal "fixture-tool"
                               (plist-get installed-lock-package :name)))
                (should (equal "file:///tmp/fixture-v1.tar"
                               (plist-get (plist-get installed-lock-package
                                                     :recipe-source)
                                          :url)))
                (should (= 1 (length installed-lock-packages)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-replays-native-script-shim-lock ()
  "nelix-apply :locked t replays source-free native script-shim rows."
  (let ((dir (make-temp-file "nelix-manifest-native-lock-shim-" t))
        (nelix-registry--packages (make-hash-table :test 'equal))
        installed-lock-package
        installed-lock-packages)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-shim) :backend-policy '(nelix-native))\n")
          (nelix-registry-add
           (list :name "fixture-shim"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :install (:type script-shim
                              :command "fixture-shim"
                              :target "/usr/bin/fixture-real")))))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'nelix-registry-update)
                     (lambda (&optional _roots)
                       (list :status 'ok :loaded 0)))
                    ((symbol-function 'nelix-native-install-lock-package)
                     (lambda (package _profile _system all-packages)
                       (setq installed-lock-package package)
                       (setq installed-lock-packages all-packages)
                       (list :status 'ok
                             :name (plist-get package :name))))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let ((manifest-file (expand-file-name "manifest.el" dir)))
              (nelix-lock-write manifest-file)
              (nelix-registry-add
               (list :name "fixture-shim"
                     :version "2.0.0"
                     :class 'system-tool
                     :systems
                     '((x86_64-linux
                        :install (:type script-shim
                                  :command "fixture-shim"
                                  :target "/usr/bin/fixture-drift")))))
              (let ((report (nelix-apply manifest-file :locked t)))
                (should (plist-get report :lock-enforced))
                (should (equal "fixture-shim"
                               (plist-get installed-lock-package :name)))
                (should-not (plist-get installed-lock-package
                                       :recipe-source))
                (should (equal 'script-shim
                               (plist-get
                                (plist-get installed-lock-package
                                           :recipe-install)
                                :type)))
                (should (equal "/usr/bin/fixture-real"
                               (plist-get
                                (plist-get installed-lock-package
                                           :recipe-install)
                                :target)))
                (should (= 1 (length installed-lock-packages)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-lock-writes-native-dependency-closure ()
  "Native lockfiles include dependency rows needed for locked replay."
  (let ((dir (make-temp-file "nelix-manifest-native-lock-deps-" t))
        (nelix-registry--packages (make-hash-table :test 'equal))
        installed-lock-package
        installed-lock-packages)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-app) :backend-policy '(nelix-native))\n")
          (nelix-registry-add
           (list :name "fixture-dep"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :install (:type script-shim
                              :command "fixture-dep"
                              :target "/usr/bin/fixture-dep")))))
          (nelix-registry-add
           (list :name "fixture-app"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :dependencies ("fixture-dep")
                    :install (:type script-shim
                              :command "fixture-app"
                              :target "/usr/bin/fixture-app")))))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'nelix-registry-update)
                     (lambda (&optional _roots)
                       (list :status 'ok :loaded 0)))
                    ((symbol-function 'nelix-native-install-lock-package)
                     (lambda (package _profile _system all-packages)
                       (setq installed-lock-package package)
                       (setq installed-lock-packages all-packages)
                       (list :status 'ok
                             :name (plist-get package :name))))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (lock (nelix-lock-write manifest-file))
                   (names (mapcar (lambda (row)
                                    (plist-get row :name))
                                  (plist-get lock :packages))))
              (should (equal '("fixture-app" "fixture-dep") names))
              (should (equal '("fixture-dep")
                             (plist-get
                              (car (plist-get lock :packages))
                              :recipe-dependencies)))
              (nelix-registry-add
               (list :name "fixture-dep"
                     :version "9.9.9"
                     :class 'system-tool
                     :systems
                     '((x86_64-linux
                        :install (:type script-shim
                                  :command "fixture-dep"
                                  :target "/usr/bin/drift")))))
              (let ((report (nelix-apply manifest-file :locked t)))
                (should (plist-get report :lock-enforced))
                (should (equal "fixture-app"
                               (plist-get installed-lock-package :name)))
                (should (= 2 (length installed-lock-packages)))
                (should (equal "fixture-dep"
                               (plist-get
                                (cadr installed-lock-packages)
                                :name)))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-apply-locked-native-dry-run-exposes-dependency-closure ()
  "Locked native dry-run reports the full lock dependency closure."
  (let ((dir (make-temp-file "nelix-manifest-native-lock-dry-run-deps-" t))
        (nelix-registry--packages (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-app) :backend-policy '(nelix-native))\n")
          (nelix-registry-add
           (list :name "fixture-dep"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :install (:type script-shim
                              :command "fixture-dep"
                              :target "/usr/bin/fixture-dep")))))
          (nelix-registry-add
           (list :name "fixture-app"
                 :version "1.0.0"
                 :class 'system-tool
                 :systems
                 '((x86_64-linux
                    :dependencies ("fixture-dep")
                    :install (:type script-shim
                              :command "fixture-app"
                              :target "/usr/bin/fixture-app")))))
          (cl-letf (((symbol-function 'nelix-list)
                     (lambda () nil))
                    ((symbol-function 'nelix-registry-update)
                     (lambda (&optional _roots)
                       (list :status 'ok :loaded 0)))
                    ((symbol-function 'nelix-native-install-lock-package)
                     (lambda (&rest _args)
                       (ert-fail
                        "locked native dry-run must not install lock rows")))
                    ((symbol-function 'nelix-pin)
                     (lambda (_name) t)))
            (let* ((manifest-file (expand-file-name "manifest.el" dir))
                   (_lock (nelix-lock-write manifest-file))
                   (report (nelix-apply manifest-file :dry-run t :locked t))
                   (names (mapcar (lambda (row)
                                    (plist-get row :name))
                                  (plist-get report :lock-all-packages))))
              (should (eq 'dry-run (plist-get report :status)))
              (should (plist-get report :lock-enforced))
              (should (equal '("fixture-app" "fixture-dep") names)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-upgrade-plan-adds-manifest-context ()
  "Manifest-aware nelix-upgrade-plan keeps profile plan data and adds drift."
  (let ((dir (make-temp-file "nelix-manifest-upgrade-" t)))
    (unwind-protect
        (nelix-manifest-test--with-state
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (let ((anvil-pkg--call-nix-fn
                 (lambda (_args)
                   (ert-fail "nelix-upgrade-plan must not invoke nix in this test"))))
            (cl-letf (((symbol-function 'pkg-list)
                       (lambda ()
                         (list (list :name "ripgrep"
                                     :attr-path "legacyPackages.x86_64-linux.ripgrep")
                               (list :name "fd"
                                     :attr-path "legacyPackages.x86_64-linux.fd"))))
                      ((symbol-function 'nelix-list)
                       (lambda ()
                         (list (list :name "ripgrep"
                                     :attr-path "legacyPackages.x86_64-linux.ripgrep")
                               (list :name "fd"
                                     :attr-path "legacyPackages.x86_64-linux.fd")))))
              (let ((plan (nelix-upgrade-plan
                           (expand-file-name "manifest.el" dir))))
                (should (eq 'upgrade (plist-get plan :operation)))
                (should (= 2 (plist-get plan :count)))
                (should (equal '("fd")
                               (mapcar (lambda (row) (plist-get row :name))
                                       (plist-get plan :extra))))
	                (should-not (plist-get plan :missing))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-upgrade-plan-nelisp-uses-name-only-profile ()
  "NeLisp manifest upgrade-plan reports declared upgrade candidates."
  (let ((dir (make-temp-file "nelix-manifest-nelisp-upgrade-plan-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep) :pins '(fd))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'pkg-upgrade-plan)
                     (lambda (&optional _name)
                       (ert-fail "NeLisp manifest upgrade-plan should use its manifest path")))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () '("fd")))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)
                             (list :name "fd"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)))))
            (let ((plan (nelix-upgrade-plan
                         (expand-file-name "manifest.el" dir))))
              (should (eq 'upgrade (plist-get plan :operation)))
              (should (eq 'nix (plist-get plan :backend)))
              (should (= 1 (plist-get plan :count)))
              (should (equal '("ripgrep") (plist-get plan :upgrade)))
              (should-not (plist-get plan :pinned))
              (should (equal '(:extra-scan :nelisp
                               :lock-drift :nelisp
                               :state-pins :nelisp)
                             (plist-get plan :skipped)))
              (should-not (plist-get plan :missing))
              (should-not (plist-get plan :extra)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-outdated-aggregates-available-backends ()
  "nelix-outdated returns one read-only report across available backends."
  (cl-letf (((symbol-function 'nelix-backend-policy-for-os)
             (lambda (&optional _os) '(nix nelix-native apt)))
            ((symbol-function 'nelix-backend-available-p)
             (lambda (backend &optional _system)
               (memq backend '(nix nelix-native))))
            ((symbol-function 'nelix-backend-upgrade-plan)
             (lambda (backend &optional _targets)
               (pcase backend
                 ('nix
                  (list :operation 'upgrade
                        :upgrade (list (list :name "ripgrep"
                                             :from "1.0"
                                             :to "1.1"))))
                 ('nelix-native
                  (list :operation 'upgrade
                        :upgrade (list (list :name "fd"
                                             :from "8.0"
                                             :to "9.0"))))
                 (_ (ert-fail "unexpected backend"))))))
    (let ((report (nelix-outdated)))
      (should (eq 'outdated (plist-get report :operation)))
      (should (= 2 (plist-get report :count)))
      (should (equal '(nix nelix-native)
                     (mapcar (lambda (row) (plist-get row :backend))
                             (plist-get report :outdated))))
      (should (equal '(apt)
                     (mapcar (lambda (row) (plist-get row :backend))
                             (plist-get report :skipped)))))))

(ert-deftest nelix-manifest-test-outdated-manifest-uses-backend-targets ()
  "nelix-outdated resolves manifest targets for the selected backend."
  (let ((dir (make-temp-file "nelix-manifest-outdated-" t))
        observed-targets)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :emacs '(magit) :linux '(ripgrep) :backend-policy '(nelix-native))\n")
          (cl-letf (((symbol-function 'nelix-backend-available-p)
                     (lambda (_backend &optional _system) t))
                    ((symbol-function 'nelix-backend-upgrade-plan)
                     (lambda (backend &optional targets)
                       (setq observed-targets (list backend targets))
                       (list :operation 'upgrade
                             :upgrade (list (list :name "magit"
                                                  :from "1"
                                                  :to "2"))))))
            (let ((report (nelix-outdated
                           (expand-file-name "manifest.el" dir))))
              (should (= 1 (plist-get report :count)))
              (should (equal (list 'nelix-native '(magit "ripgrep"))
                             observed-targets)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-outdated-direct-target-can-restrict-backend ()
  "nelix-outdated accepts a target and an explicit backend."
  (let (observed)
    (cl-letf (((symbol-function 'nelix-backend-available-p)
               (lambda (backend &optional _system)
                 (eq backend 'nelix-native)))
              ((symbol-function 'nelix-backend-upgrade-plan)
               (lambda (backend &optional targets)
                 (setq observed (list backend targets))
                 (list :operation 'upgrade
                       :upgrade (list (list :name targets
                                            :from "1"
                                            :to "2"))))))
      (let ((report (nelix-outdated "fixture-tool" "nelix-native")))
        (should (= 1 (plist-get report :count)))
        (should (equal '(nelix-native "fixture-tool") observed))
        (should (eq 'nelix-native (plist-get report :backend)))))))

(ert-deftest nelix-manifest-test-outdated-skips-unsupported-backend-plan ()
  "Available backends without upgrade-plan support are reported as skipped."
  (cl-letf (((symbol-function 'nelix-backend-policy-for-os)
             (lambda (&optional _os) '(apt)))
            ((symbol-function 'nelix-backend-available-p)
             (lambda (_backend &optional _system) t))
            ((symbol-function 'nelix-backend-upgrade-plan)
             (lambda (backend &optional _targets)
               (signal 'anvil-pkg-error
                       (list (format "unsupported backend %S" backend))))))
    (let ((report (nelix-outdated)))
      (should (plist-get report :empty))
      (should (equal '(apt)
                     (mapcar (lambda (row) (plist-get row :backend))
                             (plist-get report :skipped))))
      (should (eq :unsupported-upgrade-plan
                  (plist-get (car (plist-get report :skipped)) :reason))))))

(ert-deftest nelix-manifest-test-upgrade-direct-target-preserves-profile-api ()
  "nelix-upgrade without a manifest delegates to the historical profile API."
  (let (called)
    (cl-letf (((symbol-function 'pkg-upgrade)
               (lambda (&optional name)
                 (setq called name)
                 t)))
      (should (eq t (nelix-upgrade "ripgrep")))
      (should (equal "ripgrep" called)))))

(ert-deftest nelix-manifest-test-upgrade-manifest-native-installs-outdated ()
  "Manifest upgrade mutates native backend entries reported as outdated."
  (let ((dir (make-temp-file "nelix-manifest-upgrade-native-" t))
        observed-install)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(fixture-tool) :backend-policy '(nelix-native))\n")
          (cl-letf (((symbol-function 'nelix-backend-available-p)
                     (lambda (_backend &optional _system) t))
                    ((symbol-function 'nelix-outdated)
                     (lambda (manifest backend)
                       (list :operation 'outdated
                             :manifest manifest
                             :backend backend
                             :outdated (list (list :name "fixture-tool"
                                                   :from "1.0"
                                                   :to "2.0"
                                                   :backend backend)))))
                    ((symbol-function 'nelix-backend-install)
                     (lambda (backend names profile system)
                       (setq observed-install
                             (list backend names profile system))
                       (list (list :status 'ok
                                   :name "fixture-tool"
                                   :version "2.0")))))
            (let ((report (nelix-upgrade
                           (expand-file-name "manifest.el" dir))))
              (should (eq 'ok (plist-get report :status)))
              (should (eq 'nelix-native (plist-get report :backend)))
              (should (equal '("fixture-tool") (plist-get report :upgraded)))
              (should (equal '(nelix-native ("fixture-tool")
                                            "default" x86_64-linux)
                             observed-install)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-upgrade-manifest-nix-upgrades-outdated-names ()
  "Manifest upgrade mutates Nix profile entries reported as outdated."
  (let ((dir (make-temp-file "nelix-manifest-upgrade-nix-" t))
        upgraded)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep) :backend-policy '(nix))\n")
          (cl-letf (((symbol-function 'nelix-backend-available-p)
                     (lambda (_backend &optional _system) t))
                    ((symbol-function 'nelix-outdated)
                     (lambda (manifest backend)
                       (list :operation 'outdated
                             :manifest manifest
                             :backend backend
                             :outdated (list (list :name "ripgrep"
                                                   :from "1.0"
                                                   :to "1.1"
                                                   :backend backend)))))
                    ((symbol-function 'pkg-upgrade)
                     (lambda (&optional name)
                       (push name upgraded)
                       t)))
            (let ((report (nelix-upgrade
                           (expand-file-name "manifest.el" dir))))
              (should (eq 'nix (plist-get report :backend)))
              (should (equal '("ripgrep") (plist-get report :upgraded)))
              (should (equal '("ripgrep") (nreverse upgraded))))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-upgrade-manifest-empty-plan-does-not-mutate ()
  "Manifest upgrade does not mutate profiles when no outdated rows exist."
  (let ((dir (make-temp-file "nelix-manifest-upgrade-empty-" t)))
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep) :backend-policy '(nelix-native))\n")
          (cl-letf (((symbol-function 'nelix-backend-available-p)
                     (lambda (_backend &optional _system) t))
                    ((symbol-function 'nelix-outdated)
                     (lambda (manifest backend)
                       (list :operation 'outdated
                             :manifest manifest
                             :backend backend
                             :outdated nil
                             :empty t)))
                    ((symbol-function 'nelix-backend-install)
                     (lambda (&rest _args)
                       (ert-fail "empty manifest upgrade must not install")))
                    ((symbol-function 'pkg-upgrade)
                     (lambda (&rest _args)
                       (ert-fail "empty manifest upgrade must not call nix"))))
            (let ((report (nelix-upgrade
                           (expand-file-name "manifest.el" dir))))
              (should (plist-get report :empty))
              (should (= 0 (plist-get report :count)))
	              (should-not (plist-get report :reports)))))
      (delete-directory dir t))))

(ert-deftest nelix-manifest-test-upgrade-nelisp-mutates-declared-profile-names ()
  "NeLisp manifest upgrade mutates declared profile names from its plan."
  (let ((dir (make-temp-file "nelix-manifest-nelisp-upgrade-" t))
        upgraded)
    (unwind-protect
        (progn
          (nelix-manifest-test--write
           dir "manifest.el"
           "(require 'nelix-manifest)\n(nelix-manifest :name \"default\" :linux '(ripgrep))\n")
          (cl-letf (((symbol-function 'anvil-pkg-compat--standalone-nelisp-p)
                     (lambda () t))
                    ((symbol-function 'nelix-list)
                     (lambda ()
                       (list (list :name "ripgrep"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil)
                             (list :name "fd"
                                   :attr-path nil
                                   :original-url nil
                                   :store-paths nil))))
                    ((symbol-function 'nelix-list-pins)
                     (lambda () nil))
                    ((symbol-function 'pkg-upgrade)
                     (lambda (&optional name)
                       (push name upgraded)
                       t)))
            (let ((report (nelix-upgrade
                           (expand-file-name "manifest.el" dir))))
              (should (eq 'ok (plist-get report :status)))
              (should (eq 'upgrade (plist-get report :operation)))
              (should-not (plist-get report :empty))
              (should (= 1 (plist-get report :count)))
              (should (equal '("ripgrep") (plist-get report :upgraded)))
              (should (equal '("ripgrep") (nreverse upgraded)))
              (should (equal '(:extra-scan :nelisp
                               :lock-drift :nelisp
                               :state-pins :nelisp)
                             (plist-get report :skipped))))))
      (delete-directory dir t))))

(provide 'nelix-manifest-test)
;;; nelix-manifest-test.el ends here
