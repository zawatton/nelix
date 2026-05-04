;;; anvil-pkg-emacs-test.el --- ERT tests for anvil-pkg-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task A (L18) ERT coverage for the
;; `anvil-pkg-emacs-derive-deps' Package-Requires scraper.
;;
;; Mocks `anvil-pkg-compat-http-get' via `cl-letf'; no network access
;; or nix binary required.  Each test resets the in-process cache
;; with `clrhash anvil-pkg-emacs--deps-cache' under `unwind-protect'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-emacs)

(defmacro anvil-pkg-emacs-test--with-http-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg-compat-http-get' bound to MOCK-FN.

Cache is cleared before BODY and again on exit so tests do not
interfere with each other."
  (declare (indent 1))
  `(unwind-protect
       (progn
         (clrhash anvil-pkg-emacs--deps-cache)
         (cl-letf (((symbol-function 'anvil-pkg-compat-http-get)
                    ,mock-fn))
           ,@body))
     (clrhash anvil-pkg-emacs--deps-cache)))

(defun anvil-pkg-emacs-test--ir (owner repo rev pname &optional extra)
  "Build a synthetic IR plist for OWNER/REPO@REV with package PNAME.
EXTRA is merged on top via plist-put."
  (let ((ir (list :name (intern pname)
                  :version "1.0.0"
                  :source (list :type 'github-fetch
                                :owner owner
                                :repo repo
                                :rev rev
                                :sha256 "sha256-fake")
                  :build-system (list :type 'emacs-package))))
    (when extra
      (let ((rest extra))
        (while rest
          (setq ir (plist-put ir (car rest) (cadr rest))
                rest (cddr rest)))))
    ir))

;;;; --- L18 happy paths ------------------------------------------------------

(ert-deftest anvil-pkg-emacs-test-derive-deps-from-github-pkg-el ()
  "Lookup #1: <pname>-pkg.el on raw.githubusercontent.com.

Mock returns 200 with a `define-package' sexp body for the
`-pkg.el' URL; expect `(dash s)' parsed out of the deps argument."
  (anvil-pkg-emacs-test--with-http-mock
      (lambda (url &optional _timeout)
        (cond
         ((string-suffix-p "/foo-pkg.el" url)
          (list :status 200
                :body (concat
                       "(define-package \"foo\" \"1.0\" \"d\" "
                       "'((dash \"2.0\") (s \"1.0\")))")))
         (t (list :status 404 :body ""))))
    (let ((ir (anvil-pkg-emacs-test--ir "owner" "repo" "v1" "foo")))
      (should (equal '(dash s) (anvil-pkg-emacs-derive-deps ir))))))

(ert-deftest anvil-pkg-emacs-test-derive-deps-from-package-requires-header ()
  "Lookup #2: Package-Requires header on <pname>.el (when -pkg.el 404)."
  (anvil-pkg-emacs-test--with-http-mock
      (lambda (url &optional _timeout)
        (cond
         ((string-suffix-p "/foo-pkg.el" url)
          (list :status 404 :body ""))
         ((string-suffix-p "/foo.el" url)
          (list :status 200
                :body (concat
                       ";;; foo.el --- a thing -*- lexical-binding: t; -*-\n"
                       ";; Package-Requires: ((dash \"2.0\") (s \"1.0\"))\n"
                       ";;; Code:\n"
                       "(provide 'foo)\n")))
         (t (list :status 404 :body ""))))
    (let ((ir (anvil-pkg-emacs-test--ir "owner" "repo" "v1" "foo")))
      (should (equal '(dash s) (anvil-pkg-emacs-derive-deps ir))))))

;;;; --- L8 invariant + non-github-fetch skip --------------------------------

(ert-deftest anvil-pkg-emacs-test-derive-deps-explicit-wins ()
  "Explicit `:depends-on' on IR causes immediate nil return without HTTP."
  (let ((http-calls 0))
    (anvil-pkg-emacs-test--with-http-mock
        (lambda (_url &optional _timeout)
          (cl-incf http-calls)
          (list :status 200 :body "(define-package \"foo\" \"1.0\" \"d\" '((q \"1\")))"))
      (let ((ir (anvil-pkg-emacs-test--ir
                 "owner" "repo" "v1" "foo"
                 (list :depends-on '(a b)))))
        (should (null (anvil-pkg-emacs-derive-deps ir)))
        (should (= 0 http-calls))))))

(ert-deftest anvil-pkg-emacs-test-derive-deps-non-github-skips ()
  "Non-`github-fetch' source returns nil without consulting HTTP."
  (let ((http-calls 0))
    (anvil-pkg-emacs-test--with-http-mock
        (lambda (_url &optional _timeout)
          (cl-incf http-calls)
          (list :status 200 :body ""))
      (let ((ir (list :name 'foo
                      :version "1.0.0"
                      :source (list :type 'url-fetch
                                    :url "https://example/foo.tar.gz"
                                    :sha256 "sha256-x")
                      :build-system (list :type 'emacs-package))))
        (should (null (anvil-pkg-emacs-derive-deps ir)))
        (should (= 0 http-calls))))))

;;;; --- caching -------------------------------------------------------------

(ert-deftest anvil-pkg-emacs-test-derive-deps-cache-hit ()
  "Second call within TTL is fully served by the cache."
  (let ((http-calls 0))
    (anvil-pkg-emacs-test--with-http-mock
        (lambda (url &optional _timeout)
          (cl-incf http-calls)
          (cond
           ((string-suffix-p "/foo-pkg.el" url)
            (list :status 200
                  :body "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))"))
           (t (list :status 404 :body ""))))
      (let ((ir (anvil-pkg-emacs-test--ir "owner" "repo" "v1" "foo")))
        (should (equal '(dash) (anvil-pkg-emacs-derive-deps ir)))
        (should (= 1 http-calls))
        ;; Second call: cache hit, no HTTP.
        (should (equal '(dash) (anvil-pkg-emacs-derive-deps ir)))
        (should (= 1 http-calls))))))

(ert-deftest anvil-pkg-emacs-test-derive-deps-cache-expired ()
  "After TTL, second call refetches from HTTP."
  (let ((http-calls 0))
    (anvil-pkg-emacs-test--with-http-mock
        (lambda (url &optional _timeout)
          (cl-incf http-calls)
          (cond
           ((string-suffix-p "/foo-pkg.el" url)
            (list :status 200
                  :body "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))"))
           (t (list :status 404 :body ""))))
      (let ((ir (anvil-pkg-emacs-test--ir "owner" "repo" "v1" "foo")))
        (should (equal '(dash) (anvil-pkg-emacs-derive-deps ir)))
        (should (= 1 http-calls))
        ;; Mutate the cached entry's :cached-at to 31 days ago.
        (let* ((key "owner/repo@v1")
               (entry (gethash key anvil-pkg-emacs--deps-cache))
               (stale-time (time-subtract (current-time)
                                          (* 31 24 60 60))))
          (puthash key
                   (plist-put (copy-sequence entry) :cached-at stale-time)
                   anvil-pkg-emacs--deps-cache))
        (should (equal '(dash) (anvil-pkg-emacs-derive-deps ir)))
        (should (= 2 http-calls))))))

;;;; --- error degradation ---------------------------------------------------

(ert-deftest anvil-pkg-emacs-test-derive-deps-network-error-degrades ()
  "Network failure (status 0) returns nil + caches `:miss' (no signal)."
  (anvil-pkg-emacs-test--with-http-mock
      (lambda (_url &optional _timeout)
        (list :status 0 :body ""))
    (let ((ir (anvil-pkg-emacs-test--ir "owner" "repo" "v1" "foo")))
      ;; Must not signal — failure mode is silent nil + lwarn at most.
      (should (null (anvil-pkg-emacs-derive-deps ir)))
      ;; Cache entry should exist (so we do not retry every install).
      (let ((cached (gethash "owner/repo@v1"
                             anvil-pkg-emacs--deps-cache)))
        (should cached)
        (should (memq (plist-get cached :status) '(:miss :error)))))))

(provide 'anvil-pkg-emacs-test)
;;; anvil-pkg-emacs-test.el ends here
