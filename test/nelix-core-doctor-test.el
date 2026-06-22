;;; nelix-core-doctor-test.el --- ERT tests for pkg-doctor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Focused ERT coverage for the read-only `pkg-doctor' environment
;; health report.  All tests mock `nelix-core--call-nix-fn' so no nix
;; binary is required to run them.

;;; Code:

(require 'ert)
(require 'nelix-core)
(require 'nelix-state)

(defmacro nelix-core-doctor-test--with-mock (mock-fn &rest body)
  "Run BODY with `nelix-core--call-nix-fn' bound to MOCK-FN."
  (declare (indent 1))
  `(let* ((root (make-temp-file "nelix-core-doctor-test-" t))
          (mock ,mock-fn)
          (saved-profile-dir nelix-core-profile-dir)
          (saved-state-file nelix-state-file)
          (saved-state-cache nelix-state--cache)
          (saved-loaded-from nelix-state--loaded-from)
          (saved-call-nix-fn nelix-core--call-nix-fn))
     (unwind-protect
         (progn
           (setq nelix-core-profile-dir (expand-file-name "profile" root))
           (setq nelix-state-file (expand-file-name "state.json" root))
           (setq nelix-state--cache 'unloaded)
           (setq nelix-state--loaded-from nil)
           (setq nelix-core--call-nix-fn mock)
           ,@body)
       (setq nelix-core-profile-dir saved-profile-dir)
       (setq nelix-state-file saved-state-file)
       (setq nelix-state--cache saved-state-cache)
       (setq nelix-state--loaded-from saved-loaded-from)
       (setq nelix-core--call-nix-fn saved-call-nix-fn)
       (when (file-exists-p root)
         (delete-directory root t)))))

(defun nelix-core-doctor-test--find-check (checks check)
  "Return the CHECK row from CHECKS, or nil."
  (let (found)
    (dolist (row checks found)
      (when (and (null found)
                 (eq (plist-get row :check) check))
        (setq found row)))))

(defun nelix-core-doctor-test--mock-nix (version profile-json)
  "Return a mock nix caller for VERSION and PROFILE-JSON."
  (lambda (args)
    (cond
     ((equal args '("--version"))
      (list :exit 0
            :stdout (format "nix (Nix) %s\n" version)
            :stderr ""))
     ((and (member "profile" args)
           (member "list" args)
           (member "--json" args))
      (list :exit 0
            :stdout profile-json
            :stderr ""))
     (t
      (ert-fail (format "unexpected nix args: %S" args))))))

(ert-deftest nelix-core-doctor-test-report-shape ()
  "pkg-doctor returns one plist per check with the expected keys."
  (nelix-core-doctor-test--with-mock
      (nelix-core-doctor-test--mock-nix
       "2.18.0"
       "{\"version\":3,\"elements\":{}}")
    (let ((checks (pkg-doctor)))
      (should (= 5 (length checks)))
      (dolist (row checks)
        (should (plist-member row :check))
        (should (plist-member row :status))
        (should (plist-member row :detail))
        (should (symbolp (plist-get row :check)))
        (should (memq (plist-get row :status)
                      '(:ok :warn :error :info)))
        (should (stringp (plist-get row :detail)))))))

(ert-deftest nelix-core-doctor-test-nix-version-ok ()
  "nix-version reports :ok when the mocked version is >= 2.18."
  (nelix-core-doctor-test--with-mock
      (nelix-core-doctor-test--mock-nix
       "2.18.5"
       "{\"version\":3,\"elements\":{}}")
    (let* ((checks (pkg-doctor))
           (row (nelix-core-doctor-test--find-check checks 'nix-version)))
      (should row)
      (should (eq :ok (plist-get row :status)))
      (should (equal "Detected Nix 2.18.5 (meets >= 2.18)"
                     (plist-get row :detail))))))

(ert-deftest nelix-core-doctor-test-nix-version-old-warn ()
  "nix-version reports :warn when the mocked version is older than 2.18."
  (nelix-core-doctor-test--with-mock
      (nelix-core-doctor-test--mock-nix
       "2.17.9"
       "{\"version\":3,\"elements\":{}}")
    (let* ((checks (pkg-doctor))
           (row (nelix-core-doctor-test--find-check checks 'nix-version)))
      (should row)
      (should (eq :warn (plist-get row :status)))
      (should (equal "Detected Nix 2.17.9; nelix-core expects >= 2.18"
                     (plist-get row :detail))))))

(ert-deftest nelix-core-doctor-test-installed-count-detail ()
  "installed-count reflects the mocked `pkg-list' result."
  (nelix-core-doctor-test--with-mock
      (nelix-core-doctor-test--mock-nix
       "2.18.0"
       (concat
        "{\"version\":3,\"elements\":{"
        "\"ripgrep\":{\"active\":true,\"attrPath\":\"ripgrep\","
        "\"originalUrl\":\"flake:nixpkgs\","
        "\"storePaths\":[\"/nix/store/ripgrep\"]},"
        "\"fd\":{\"active\":true,\"attrPath\":\"fd\","
        "\"originalUrl\":\"flake:nixpkgs\","
        "\"storePaths\":[\"/nix/store/fd\"]}"
        "}}"))
    (let* ((checks (pkg-doctor))
           (row (nelix-core-doctor-test--find-check checks 'installed-count)))
      (should row)
      (should (eq :info (plist-get row :status)))
      (should (equal "2 package(s) installed in the nelix-core profile"
                     (plist-get row :detail))))))

(ert-deftest nelix-core-doctor-test-tool-wrapper-tallies ()
  "The MCP doctor wrapper returns the checks list plus status tallies."
  (nelix-core-doctor-test--with-mock
      (nelix-core-doctor-test--mock-nix
       "2.18.0"
       "{\"version\":3,\"elements\":{}}")
    (let ((old-features features))
      (unwind-protect
          (progn
            (setq features (cons 'anvil-server features))
            (with-temp-file nelix-state-file
              (insert "{}"))
            (let ((res (nelix-core--tool-doctor)))
              (should (= 5 (length (plist-get res :checks))))
              (should (= 2 (plist-get res :ok)))
              (should (= 0 (plist-get res :warn)))
              (should (= 0 (plist-get res :error)))
              (should (= 3 (plist-get res :info)))))
        (setq features old-features)))))

(provide 'nelix-core-doctor-test)
;;; nelix-core-doctor-test.el ends here
