;;; anvil-pkg-emacs-test.el --- ERT tests for anvil-pkg-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task A (L18) ERT coverage for the
;; `anvil-pkg-emacs-derive-deps' Package-Requires scraper.
;;
;; Mocks `anvil-pkg-compat-http-get' via `cl-letf'; no network access
;; or nix binary required.  The deps cache is the persistent
;; `anvil-pkg-state' KV under namespace
;; `anvil-pkg:emacs-deps' (Phase 4-D L26 promotion); each test
;; binds `anvil-pkg-state-file' to a tmp path so the real
;; ~/.local/state/anvil-pkg/state.json is never touched and the
;; in-process cache is reset between tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-emacs)
(require 'anvil-pkg-state)

(defmacro anvil-pkg-emacs-test--with-http-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg-compat-http-get' bound to MOCK-FN.

Also binds `anvil-pkg-state-file' to a tmp file (cleaned on exit)
and resets the in-process state cache so the deps lookup namespace
starts empty.  Tests do not interfere with each other."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "anvil-pkg-emacs-test-" nil ".json"))
          (anvil-pkg-state-file tmp)
          (anvil-pkg-state--cache 'unloaded)
          (anvil-pkg-state--loaded-from nil))
     (unwind-protect
         (progn
           (delete-file tmp)
           (cl-letf (((symbol-function 'anvil-pkg-compat-http-get)
                      ,mock-fn))
             ,@body))
       (when (file-exists-p tmp) (delete-file tmp)))))

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
  "After TTL, second call refetches from HTTP.

Drives expiry by directly mutating the cached entry's
`:expires-at' to 1 second in the past — same effect as letting
real wall-clock time elapse, without sleeping in the test."
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
        ;; Force-expire the cached entry by overwriting its expires-at.
        ;; Reach into the in-process cache directly because the public
        ;; API hides expiry; this is test-internal manipulation.
        (let* ((ns-pair (assoc anvil-pkg-emacs--deps-namespace
                               anvil-pkg-state--cache))
               (entry-pair (assoc "owner/repo@v1" (cdr ns-pair))))
          (should entry-pair)
          (setcdr entry-pair
                  (plist-put (cdr entry-pair) :expires-at
                             (- (float-time) 1))))
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
      (let ((cached (anvil-pkg-state-get
                     anvil-pkg-emacs--deps-namespace
                     "owner/repo@v1")))
        (should cached)
        (should (memq (plist-get cached :status) '(:miss :error)))))))

(provide 'anvil-pkg-emacs-test)
;;; anvil-pkg-emacs-test.el ends here
