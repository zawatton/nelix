;;; nelix-import-test.el --- ERT tests for nelix-import -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-B sub-task D ERT coverage for the
;; `nelix-import-async-installer' read-only converter.
;;
;; No nix binary or disk fixtures required; the tests work on a
;; literal in-memory list and a temp file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-import)

(defvar async-installer-test-list nil
  "Synthetic fixture so the converter has a `boundp' source variable.")

(ert-deftest nelix-import-test-emits-pkg-define-forms ()
  "Converter emits one `pkg-define' form per input entry."
  (let ((async-installer-test-list
         '(("magnars/dash.el" :tag "2.20.0")
           ("magit/transient" :commit "abc1234567890" :native-compile t))))
    (let ((tmpfile (make-temp-file "nelix-import-test-" nil ".el")))
      (unwind-protect
          (progn
            (nelix-import-async-installer
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

(ert-deftest nelix-import-test-idempotent ()
  "Two runs over the same input produce byte-identical output.

Uses a single fixed-name temp path so the basename (which appears
in the file header and the `provide' form) is identical across both
runs — the basename is part of the deterministic content, but it
must match between the two runs to make the comparison meaningful."
  (let ((async-installer-test-list
         '(("magnars/dash.el" :tag "2.20.0")
           ("magit/transient" :commit "abc1234567890" :native-compile t)
           ("foo/bar" :require t)))
        (tmpdir (make-temp-file "nelix-import-test-dir-" t)))
    (unwind-protect
        (let ((tmpfile-a (expand-file-name "out-a.el" tmpdir))
              (tmpfile-b (expand-file-name "out-b.el" tmpdir)))
          ;; Freeze date so the header line is stable.  Both files
          ;; share the same fixed extension/name pattern so basename
          ;; difference is the ONLY remaining variable; we strip it
          ;; below before comparing.
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (&rest _) "1970-01-01")))
            (nelix-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile-a)
            (nelix-import-async-installer
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
            (should (string-match-p "Generated by nelix-import on 1970-01-01"
                                    content-a))))
      (when (file-directory-p tmpdir)
        (delete-directory tmpdir t)))))

;;;; --- Phase 4-C L21: :scrape-deps from local clone ------------------------

(ert-deftest nelix-import-test-scrape-deps-from-local-clone ()
  "L21: when a local clone has <pname>-pkg.el, deps are emitted.

Fixture: writes /tmp/.../foo/foo-pkg.el carrying a `define-package'
sexp with deps `(dash s)'.  The importer is called with
`:scrape-deps t' and a `:clone-dir-fn' pointing at the fixture
directory.  HTTP mock raises if invoked — we expect the local
clone to win."
  (let* ((tmpdir (make-temp-file "nelix-import-clone-test-" t))
         (foo-dir (expand-file-name "foo" tmpdir))
         (foo-pkg-el (expand-file-name "foo-pkg.el" foo-dir))
         (tmpfile (expand-file-name "out.el" tmpdir))
         (async-installer-test-list
          '(("owner/foo" :tag "1.0.0"))))
    (unwind-protect
        (progn
          (make-directory foo-dir t)
          (with-temp-file foo-pkg-el
            (insert
             "(define-package \"foo\" \"1.0\" \"d\" "
             "'((dash \"2.0\") (s \"1.0\")))\n"))
          ;; HTTP mock that raises if called — proves local clone won.
          (cl-letf (((symbol-function 'nelix-compat-http-get)
                     (lambda (&rest _)
                       (ert-fail "HTTP fetch must NOT happen — local clone exists")
                       (list :status 0 :body ""))))
            (nelix-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile
             :scrape-deps t
             :clone-dir-fn
             (lambda (entry-info)
               (when (equal (plist-get entry-info :name) "foo")
                 foo-dir))))
          (let ((content (with-temp-buffer
                           (insert-file-contents tmpfile)
                           (buffer-string))))
            (should (string-match-p
                     "(depends-on (list dash s))"
                     content))))
      (when (file-directory-p tmpdir)
        (delete-directory tmpdir t)))))

(ert-deftest nelix-import-test-default-clone-dir-uses-emacs-directory ()
  "Default clone lookup uses ~/.emacs.d/external-packages/<pkg>."
  (let ((tmp-home (make-temp-file "nelix-import-home-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'nelix-compat-getenv)
                   (lambda (name)
                     (and (equal name "HOME") tmp-home))))
          (should
           (equal (nelix-import-default-clone-dir '(:name "foo"))
                  (expand-file-name ".emacs.d/external-packages/foo"
                                    tmp-home))))
      (when (file-directory-p tmp-home)
        (delete-directory tmp-home t)))))

(ert-deftest nelix-import-test-scrape-deps-from-default-clone-dir ()
  "Importer reads deps from the documented default clone directory."
  (let* ((tmp-home (make-temp-file "nelix-import-home-" t))
         (foo-dir (expand-file-name ".emacs.d/external-packages/foo" tmp-home))
         (foo-pkg-el (expand-file-name "foo-pkg.el" foo-dir))
         (tmpfile (expand-file-name "imported.el" tmp-home))
         (async-installer-test-list
          '(("owner/foo" :tag "1.0.0"))))
    (unwind-protect
        (progn
          (make-directory foo-dir t)
          (with-temp-file foo-pkg-el
            (insert
             "(define-package \"foo\" \"1.0\" \"d\" "
             "'((dash \"2.0\") (s \"1.0\")))\n"))
          (cl-letf (((symbol-function 'nelix-compat-getenv)
                     (lambda (name)
                       (and (equal name "HOME") tmp-home)))
                    ((symbol-function 'nelix-compat-http-get)
                     (lambda (&rest _)
                       (ert-fail "HTTP fetch must NOT happen when default clone exists")
                       (list :status 0 :body ""))))
            (nelix-import-async-installer
             :var 'async-installer-test-list
             :emit tmpfile
             :scrape-deps t))
          (let ((content (with-temp-buffer
                           (insert-file-contents tmpfile)
                           (buffer-string))))
            (should (string-match-p
                     "(depends-on (list dash s))"
                     content))))
      (when (file-directory-p tmp-home)
        (delete-directory tmp-home t)))))

(provide 'nelix-import-test)
;;; nelix-import-test.el ends here
