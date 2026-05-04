;;; anvil-pkg-import-test.el --- ERT tests for anvil-pkg-import -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-B sub-task D ERT coverage for the
;; `anvil-pkg-import-async-installer' read-only converter.
;;
;; No nix binary or disk fixtures required; the tests work on a
;; literal in-memory list and a temp file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-import)

(defvar async-installer-test-list nil
  "Synthetic fixture so the converter has a `boundp' source variable.")

(ert-deftest anvil-pkg-import-test-emits-pkg-define-forms ()
  "Converter emits one `pkg-define' form per input entry."
  (let ((async-installer-test-list
         '(("magnars/dash.el" :tag "2.20.0")
           ("magit/transient" :commit "abc1234567890" :native-compile t))))
    (let ((tmpfile (make-temp-file "anvil-pkg-import-test-" nil ".el")))
      (unwind-protect
          (progn
            (anvil-pkg-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile)
            (with-temp-buffer
              (insert-file-contents tmpfile)
              (goto-char (point-min))
              (let ((forms
                     (cl-loop for f = (condition-case nil
                                          (read (current-buffer))
                                        (end-of-file nil)
                                        (error nil))
                              while f
                              collect f)))
                (let ((pkg-defines
                       (cl-remove-if-not
                        (lambda (f)
                          (and (consp f) (eq (car f) 'pkg-define)))
                        forms)))
                  (should (= 2 (length pkg-defines)))
                  (should (member 'dash.el (mapcar #'cadr pkg-defines)))
                  (should (member 'transient (mapcar #'cadr pkg-defines)))
                  ;; transient entry has :native-compile t so its
                  ;; build-system should be (emacs-package :native-comp t).
                  (let* ((transient-form
                          (cl-find 'transient pkg-defines :key #'cadr))
                         (bs-form (cl-find-if
                                   (lambda (sub)
                                     (and (consp sub)
                                          (eq (car sub) 'build-system)))
                                   (cddr transient-form))))
                    (should (equal bs-form
                                   '(build-system (emacs-package :native-comp t)))))
                  ;; dash.el entry has :tag "2.20.0" which should
                  ;; flow into (version "2.20.0").
                  (let* ((dash-form
                          (cl-find 'dash.el pkg-defines :key #'cadr))
                         (ver-form (cl-find-if
                                    (lambda (sub)
                                      (and (consp sub)
                                           (eq (car sub) 'version)))
                                    (cddr dash-form))))
                    (should (equal ver-form '(version "2.20.0"))))))))
        (when (file-exists-p tmpfile) (delete-file tmpfile))))))

(ert-deftest anvil-pkg-import-test-idempotent ()
  "Two runs over the same input produce byte-identical output.

Uses a single fixed-name temp path so the basename (which appears
in the file header and the `provide' form) is identical across both
runs — the basename is part of the deterministic content, but it
must match between the two runs to make the comparison meaningful."
  (let ((async-installer-test-list
         '(("magnars/dash.el" :tag "2.20.0")
           ("magit/transient" :commit "abc1234567890" :native-compile t)
           ("foo/bar" :require t)))
        (tmpdir (make-temp-file "anvil-pkg-import-test-dir-" t)))
    (unwind-protect
        (let ((tmpfile-a (expand-file-name "out-a.el" tmpdir))
              (tmpfile-b (expand-file-name "out-b.el" tmpdir)))
          ;; Freeze date so the header line is stable.  Both files
          ;; share the same fixed extension/name pattern so basename
          ;; difference is the ONLY remaining variable; we strip it
          ;; below before comparing.
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (&rest _) "1970-01-01")))
            (anvil-pkg-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile-a)
            (anvil-pkg-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile-b))
          (let* ((content-a (with-temp-buffer
                              (insert-file-contents tmpfile-a)
                              (buffer-string)))
                 (content-b (with-temp-buffer
                              (insert-file-contents tmpfile-b)
                              (buffer-string)))
                 ;; Strip the basename so identical-content with
                 ;; different filenames compares equal.  The basename
                 ;; appears 3 times: header line, provide form, "ends
                 ;; here" trailer.
                 (norm (lambda (s base)
                         (replace-regexp-in-string
                          (regexp-quote base) "OUT" s))))
            (should (string= (funcall norm content-a "out-a")
                             (funcall norm content-b "out-b")))
            (should (string-match-p "Generated by anvil-pkg-import on 1970-01-01"
                                    content-a))))
      (when (file-directory-p tmpdir)
        (delete-directory tmpdir t)))))

(provide 'anvil-pkg-import-test)
;;; anvil-pkg-import-test.el ends here
