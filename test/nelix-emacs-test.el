;;; nelix-emacs-test.el --- ERT tests for nelix-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task A (L18) ERT coverage for the
;; `nelix-emacs-derive-deps' Package-Requires scraper.
;;
;; Mocks `nelix-compat-http-get' via `cl-letf'; no network access
;; or nix binary required.  The deps cache is the persistent
;; `nelix-state' KV under namespace
;; `nelix-core:emacs-deps' (Phase 4-D L26 promotion); each test
;; binds `nelix-state-file' to a tmp path so the real
;; ~/.local/state/nelix/state.json is never touched and the
;; in-process cache is reset between tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-emacs)
(require 'nelix-state)

(defmacro nelix-emacs-test--with-http-mock (mock-fn &rest body)
  "Run BODY with `nelix-compat-http-get' bound to MOCK-FN.

Also binds `nelix-state-file' to a tmp file (cleaned on exit)
and resets the in-process state cache so the deps lookup namespace
starts empty.  Tests do not interfere with each other."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "nelix-emacs-test-" nil ".json"))
          (nelix-state-file tmp)
          (nelix-state--cache 'unloaded)
          (nelix-state--loaded-from nil)
          ;; Force the Emacs runtime branch: derive-deps' tar extraction
          ;; goes through `nelix-compat-call-process', which routes to the
          ;; NeLisp hook when the sticky `nelix-compat--nelisp-runtime-p'
          ;; cache leaked t from an earlier test (ERT runs in name order).
          (nelix-compat--nelisp-runtime-p nil))
     (unwind-protect
         (progn
           (delete-file tmp)
           (cl-letf (((symbol-function 'nelix-compat-http-get)
                      ,mock-fn))
             ,@body))
       (when (file-exists-p tmp) (delete-file tmp)))))

(defun nelix-emacs-test--ir (owner repo rev pname &optional extra)
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

(ert-deftest nelix-emacs-test-derive-deps-from-github-pkg-el ()
  "Lookup #1: <pname>-pkg.el on raw.githubusercontent.com.

Mock returns 200 with a `define-package' sexp body for the
`-pkg.el' URL; expect `(dash s)' parsed out of the deps argument."
  (nelix-emacs-test--with-http-mock
      (lambda (url &optional _timeout)
        (cond
         ((string-suffix-p "/foo-pkg.el" url)
          (list :status 200
                :body (concat
                       "(define-package \"foo\" \"1.0\" \"d\" "
                       "'((dash \"2.0\") (s \"1.0\")))")))
         (t (list :status 404 :body ""))))
    (let ((ir (nelix-emacs-test--ir "owner" "repo" "v1" "foo")))
      (should (equal '(dash s) (nelix-emacs-derive-deps ir))))))

(ert-deftest nelix-emacs-test-derive-deps-from-package-requires-header ()
  "Lookup #2: Package-Requires header on <pname>.el (when -pkg.el 404)."
  (nelix-emacs-test--with-http-mock
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
    (let ((ir (nelix-emacs-test--ir "owner" "repo" "v1" "foo")))
      (should (equal '(dash s) (nelix-emacs-derive-deps ir))))))

;;;; --- L8 invariant + non-github-fetch skip --------------------------------

(ert-deftest nelix-emacs-test-derive-deps-explicit-wins ()
  "Explicit `:depends-on' on IR causes immediate nil return without HTTP."
  (let ((http-calls 0))
    (nelix-emacs-test--with-http-mock
        (lambda (_url &optional _timeout)
          (cl-incf http-calls)
          (list :status 200 :body "(define-package \"foo\" \"1.0\" \"d\" '((q \"1\")))"))
      (let ((ir (nelix-emacs-test--ir
                 "owner" "repo" "v1" "foo"
                 (list :depends-on '(a b)))))
        (should (null (nelix-emacs-derive-deps ir)))
        (should (= 0 http-calls))))))

(ert-deftest nelix-emacs-test-derive-deps-non-github-skips ()
  "Non-`github-fetch' source returns nil without consulting HTTP."
  (let ((http-calls 0))
    (nelix-emacs-test--with-http-mock
        (lambda (_url &optional _timeout)
          (cl-incf http-calls)
          (list :status 200 :body ""))
      (let ((ir (list :name 'foo
                      :version "1.0.0"
                      :source (list :type 'url-fetch
                                    :url "https://example/foo.tar.gz"
                                    :sha256 "sha256-x")
                      :build-system (list :type 'emacs-package))))
        (should (null (nelix-emacs-derive-deps ir)))
        (should (= 0 http-calls))))))

;;;; --- caching -------------------------------------------------------------

(ert-deftest nelix-emacs-test-derive-deps-cache-hit ()
  "Second call within TTL is fully served by the cache."
  (let ((http-calls 0))
    (nelix-emacs-test--with-http-mock
        (lambda (url &optional _timeout)
          (cl-incf http-calls)
          (cond
           ((string-suffix-p "/foo-pkg.el" url)
            (list :status 200
                  :body "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))"))
           (t (list :status 404 :body ""))))
      (let ((ir (nelix-emacs-test--ir "owner" "repo" "v1" "foo")))
        (should (equal '(dash) (nelix-emacs-derive-deps ir)))
        (should (= 1 http-calls))
        ;; Second call: cache hit, no HTTP.
        (should (equal '(dash) (nelix-emacs-derive-deps ir)))
        (should (= 1 http-calls))))))

(ert-deftest nelix-emacs-test-derive-deps-cache-expired ()
  "After TTL, second call refetches from HTTP.

Drives expiry by directly mutating the cached entry's
`:expires-at' to 1 second in the past — same effect as letting
real wall-clock time elapse, without sleeping in the test."
  (let ((http-calls 0))
    (nelix-emacs-test--with-http-mock
        (lambda (url &optional _timeout)
          (cl-incf http-calls)
          (cond
           ((string-suffix-p "/foo-pkg.el" url)
            (list :status 200
                  :body "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))"))
           (t (list :status 404 :body ""))))
      (let ((ir (nelix-emacs-test--ir "owner" "repo" "v1" "foo")))
        (should (equal '(dash) (nelix-emacs-derive-deps ir)))
        (should (= 1 http-calls))
        ;; Force-expire the cached entry by overwriting its expires-at.
        ;; Reach into the in-process cache directly because the public
        ;; API hides expiry; this is test-internal manipulation.
        (let* ((ns-pair (assoc nelix-emacs--deps-namespace
                               nelix-state--cache))
               (entry-pair (assoc "owner/repo@v1" (cdr ns-pair))))
          (should entry-pair)
          (setcdr entry-pair
                  (plist-put (cdr entry-pair) :expires-at
                             (- (float-time) 1))))
        (should (equal '(dash) (nelix-emacs-derive-deps ir)))
        (should (= 2 http-calls))))))

;;;; --- error degradation ---------------------------------------------------

(ert-deftest nelix-emacs-test-derive-deps-network-error-degrades ()
  "Network failure (status 0) returns nil + caches `:miss' (no signal)."
  (nelix-emacs-test--with-http-mock
      (lambda (_url &optional _timeout)
        (list :status 0 :body ""))
    (let ((ir (nelix-emacs-test--ir "owner" "repo" "v1" "foo")))
      ;; Must not signal — failure mode is silent nil + lwarn at most.
      (should (null (nelix-emacs-derive-deps ir)))
      ;; Cache entry should exist (so we do not retry every install).
      (let ((cached (nelix-state-get
                     nelix-emacs--deps-namespace
                     "owner/repo@v1")))
        (should cached)
        (should (memq (plist-get cached :status) '(:miss :error)))))))

;;;; --- L24a tarball / L24b git mock helpers --------------------------------

(defmacro nelix-emacs-test--with-state (&rest body)
  "Run BODY with `nelix-state-file' bound to a fresh tmp file.

Resets the in-process state cache so namespaces start empty.  No
HTTP / call-process mocking — callers wrap as needed."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "nelix-emacs-test-" nil ".json"))
          (nelix-state-file tmp)
          (nelix-state--cache 'unloaded)
          (nelix-state--loaded-from nil)
          ;; Force the Emacs runtime branch: derive-deps' tar extraction
          ;; goes through `nelix-compat-call-process', which routes to the
          ;; NeLisp hook when the sticky `nelix-compat--nelisp-runtime-p'
          ;; cache leaked t from an earlier test (ERT runs in name order).
          (nelix-compat--nelisp-runtime-p nil))
     (unwind-protect
         (progn
           (delete-file tmp)
           ,@body)
       (when (file-exists-p tmp) (delete-file tmp)))))

(defun nelix-emacs-test--ir-url-fetch (sha256 pname)
  "Build a synthetic url-fetch IR plist for PNAME with tarball SHA256."
  (list :name (intern pname)
        :version "1.0.0"
        :source (list :type 'url-fetch
                      :url "https://example.com/foo-1.0.tar.gz"
                      :sha256 sha256)
        :build-system (list :type 'emacs-package)))

(defun nelix-emacs-test--ir-git-fetch (url rev pname)
  "Build a synthetic git-fetch IR plist for PNAME at URL REV."
  (list :name (intern pname)
        :version "1.0.0"
        :source (list :type 'git-fetch
                      :url url
                      :rev rev
                      :sha256 "sha256-fake")
        :build-system (list :type 'emacs-package)))

(defun nelix-emacs-test--build-tarball (top-dir files)
  "Build a tar.gz at a temp path.

TOP-DIR is the single top-level directory inside the tarball.
FILES is an alist of (RELATIVE-PATH . CONTENT-STRING).  Returns
the raw bytes of the tarball as a unibyte string.  Skips with
`ert-skip' when `tar' / `gzip' is unavailable."
  (unless (executable-find "tar")
    (ert-skip "tar binary not available"))
  (let* ((staging (make-temp-file "nelix-core-tar-stage-" t))
         (tarfile (make-temp-file "nelix-core-tar-" nil ".tar.gz"))
         (root (expand-file-name top-dir staging)))
    (unwind-protect
        (progn
          (make-directory root t)
          (dolist (f files)
            (let* ((rel (car f))
                   (content (cdr f))
                   (path (expand-file-name rel root)))
              (make-directory (file-name-directory path) t)
              (with-temp-file path (insert content))))
          (let ((default-directory staging))
            (let ((exit (call-process "tar" nil nil nil
                                      "-czf" tarfile top-dir)))
              (unless (eq 0 exit)
                (error "tar -czf failed: %S" exit))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (let ((coding-system-for-read 'binary))
              (insert-file-contents-literally tarfile))
            (buffer-string)))
      (delete-directory staging t)
      (when (file-exists-p tarfile) (delete-file tarfile)))))

;;;; --- L24a tarball happy + miss ------------------------------------------

(ert-deftest nelix-emacs-test-derive-deps-tarball-pkg-el-happy ()
  "L24a: tarball with FOO-pkg.el → parsed deps, cached by sha256."
  (let* ((bytes (nelix-emacs-test--build-tarball
                 "foo-1.0"
                 '(("foo-pkg.el"
                    . "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\") (s \"1.0\")))\n"))))
         (http-calls 0))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-http-get-binary)
                 (lambda (_url &optional _timeout)
                   (cl-incf http-calls)
                   (list :status 200 :body bytes
                         :content-length (length bytes)))))
        (let ((ir (nelix-emacs-test--ir-url-fetch "sha256-aaa" "foo")))
          (should (equal '(dash s) (nelix-emacs-derive-deps ir)))
          (should (= 1 http-calls)))))))

(ert-deftest nelix-emacs-test-derive-deps-tarball-package-requires-header ()
  "L24a: tarball with no -pkg.el but FOO.el header → parsed deps."
  (let* ((bytes (nelix-emacs-test--build-tarball
                 "foo-1.0"
                 '(("foo.el"
                    . ";;; foo.el --- a thing -*- lexical-binding: t; -*-\n;; Package-Requires: ((dash \"2.0\") (s \"1.0\"))\n;;; Code:\n(provide 'foo)\n")))))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-http-get-binary)
                 (lambda (_url &optional _timeout)
                   (list :status 200 :body bytes
                         :content-length (length bytes)))))
        (let ((ir (nelix-emacs-test--ir-url-fetch "sha256-bbb" "foo")))
          (should (equal '(dash s) (nelix-emacs-derive-deps ir))))))))

(ert-deftest nelix-emacs-test-derive-deps-tarball-too-large-refuses ()
  "L24a: Content-Length > 50 MiB → warn + nil + no extraction.

Mock returns a tiny body but advertises a content-length far in
excess of the cap so we exercise the refuse branch deterministically.
The :body slot is irrelevant because the size check happens before
extraction; we nevertheless verify `tar' is never invoked."
  (let ((tar-calls 0))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-http-get-binary)
                 (lambda (_url &optional _timeout)
                   (list :status 200
                         :body ""
                         :content-length (* 100 1024 1024))))
                ((symbol-function 'nelix-compat-call-process)
                 (lambda (_program _args)
                   (cl-incf tar-calls)
                   (list :exit 0 :stdout "" :stderr ""))))
        (let ((ir (nelix-emacs-test--ir-url-fetch "sha256-big" "foo")))
          (should (null (nelix-emacs-derive-deps ir)))
          (should (= 0 tar-calls))
          ;; Refusal cached as :error so subsequent installs don't retry.
          (let ((cached (nelix-state-get
                         nelix-emacs--deps-namespace
                         "sha256:sha256-big")))
            (should cached)
            (should (eq :error (plist-get cached :status)))))))))

(ert-deftest nelix-emacs-test-derive-deps-tarball-cache-hit-by-sha256 ()
  "L24a: second call with same sha256 → no http-get-binary call."
  (let* ((bytes (nelix-emacs-test--build-tarball
                 "foo-1.0"
                 '(("foo-pkg.el"
                    . "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))\n"))))
         (http-calls 0))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-http-get-binary)
                 (lambda (_url &optional _timeout)
                   (cl-incf http-calls)
                   (list :status 200 :body bytes
                         :content-length (length bytes)))))
        (let ((ir (nelix-emacs-test--ir-url-fetch "sha256-cache" "foo")))
          (should (equal '(dash) (nelix-emacs-derive-deps ir)))
          (should (= 1 http-calls))
          ;; Same sha256 → cache hit.
          (should (equal '(dash) (nelix-emacs-derive-deps ir)))
          (should (= 1 http-calls)))))))

;;;; --- L24b git-fetch happy + failure + cache ------------------------------

(defun nelix-emacs-test--git-clone-mock (writer)
  "Return a `call-process' mock that writes a fixture into the clone tmpdir.

WRITER is called with the tmpdir path on a `git clone' invocation;
it should populate the directory with the files the scrape will
read.  Non-clone shell-outs (e.g. `tar' if reused) return success
+ empty stdout."
  (lambda (program args)
    (cond
     ((and (string= program "git")
           (>= (length args) 1)
           (string= (car args) "clone"))
      ;; Last arg is the destination tmpdir.
      (let ((dest (car (last args))))
        (make-directory dest t)
        (funcall writer dest)
        (list :exit 0 :stdout "" :stderr "")))
     (t
      (list :exit 0 :stdout "" :stderr "")))))

(ert-deftest nelix-emacs-test-derive-deps-git-clone-happy ()
  "L24b: git clone success + foo-pkg.el in tmpdir → parsed deps + cleanup."
  (let ((seen-tmpdir nil))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-call-process)
                 (nelix-emacs-test--git-clone-mock
                  (lambda (dest)
                    (setq seen-tmpdir dest)
                    (with-temp-file (expand-file-name "foo-pkg.el" dest)
                      (insert "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\") (s \"1.0\")))\n"))))))
        (let* ((ir (nelix-emacs-test--ir-git-fetch
                    "https://git.example.com/foo.git" "v1.0" "foo"))
               (deps (nelix-emacs-derive-deps ir)))
          (should (equal '(dash s) deps))
          ;; tmpdir created by the impl, not by the mock — but the
          ;; mock recorded the path, so post-call it must be gone.
          (should seen-tmpdir)
          (should-not (file-exists-p seen-tmpdir)))))))

(ert-deftest nelix-emacs-test-derive-deps-git-clone-failure-degrades ()
  "L24b: git clone nonzero exit on every variant → warn + nil + cleanup."
  (let ((seen-tmpdir nil))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-call-process)
                 (lambda (program args)
                   (cond
                    ((and (string= program "git")
                          (string= (car args) "clone"))
                     (setq seen-tmpdir (car (last args)))
                     (list :exit 128 :stdout ""
                           :stderr "fatal: ref not found"))
                    (t (list :exit 1 :stdout "" :stderr ""))))))
        (let* ((ir (nelix-emacs-test--ir-git-fetch
                    "https://git.example.com/foo.git" "deadbeef" "foo"))
               (deps (nelix-emacs-derive-deps ir)))
          (should (null deps))
          (when seen-tmpdir
            (should-not (file-exists-p seen-tmpdir)))
          ;; Failure cached as :error.
          (let ((cached (nelix-state-get
                         nelix-emacs--deps-namespace
                         "git:https://git.example.com/foo.git@deadbeef")))
            (should cached)
            (should (eq :error (plist-get cached :status)))))))))

(ert-deftest nelix-emacs-test-derive-deps-git-cache-hit-by-rev ()
  "L24b: second call with same url@rev → no shell-out."
  (let ((proc-calls 0))
    (nelix-emacs-test--with-state
      (cl-letf (((symbol-function 'nelix-compat-call-process)
                 (let ((git-mock
                        (nelix-emacs-test--git-clone-mock
                         (lambda (dest)
                           (with-temp-file (expand-file-name "foo-pkg.el" dest)
                             (insert "(define-package \"foo\" \"1.0\" \"d\" '((dash \"2.0\")))\n"))))))
                   (lambda (program args)
                     (cl-incf proc-calls)
                     (funcall git-mock program args)))))
        (let ((ir (nelix-emacs-test--ir-git-fetch
                   "https://git.example.com/foo.git" "v1.0" "foo")))
          (should (equal '(dash) (nelix-emacs-derive-deps ir)))
          (let ((first-calls proc-calls))
            (should (> first-calls 0))
            ;; Second call: cached, no further call-process invocations.
            (should (equal '(dash) (nelix-emacs-derive-deps ir)))
            (should (= first-calls proc-calls))))))))

;;;; --- Phase 4-E L27: MELPA upstream recipe fetch + cache -----------------

(defmacro nelix-emacs-test--with-melpa-mock (mock-fn &rest body)
  "Mock `nelix-emacs--http-fetch' (the inner http call used by
`nelix-emacs-fetch-melpa-recipe') with MOCK-FN (1-arg URL → resp
plist).  Also resets the recipe cache namespace by binding a tmp
state file."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "nelix-core-melpa-test-" nil ".json"))
          (nelix-state-file tmp)
          (nelix-state--cache 'unloaded)
          (nelix-state--loaded-from nil))
     (unwind-protect
         (progn
           (delete-file tmp)
           (cl-letf (((symbol-function 'nelix-emacs--http-fetch)
                      ,mock-fn))
             ,@body))
       (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest nelix-emacs-test-fetch-melpa-recipe-hit-caches ()
  "200 from raw.githubusercontent.com → trimmed body, cache `:hit'."
  (nelix-emacs-test--with-melpa-mock
      (lambda (url)
        (should (string-prefix-p
                 "https://raw.githubusercontent.com/melpa/melpa/master/recipes/helm"
                 url))
        (list :status 200
              :body "  (helm :fetcher git :url \"https://github.com/emacs-helm/helm\")\n  "))
    (let ((recipe (nelix-emacs-fetch-melpa-recipe "helm")))
      (should (equal recipe
                     "(helm :fetcher git :url \"https://github.com/emacs-helm/helm\")"))
      ;; Cache stores the trimmed body + :hit status.
      (let ((cached (nelix-state-get
                     nelix-emacs--melpa-recipe-namespace "helm")))
        (should (equal :hit (plist-get cached :status)))
        (should (equal recipe (plist-get cached :recipe)))))))

(ert-deftest nelix-emacs-test-fetch-melpa-recipe-miss-caches ()
  "404 → returns nil, cache stores `:miss' (negative cache)."
  (nelix-emacs-test--with-melpa-mock
      (lambda (_url) (list :status 404 :body ""))
    (should (null (nelix-emacs-fetch-melpa-recipe "no-such-pkg")))
    (let ((cached (nelix-state-get
                   nelix-emacs--melpa-recipe-namespace "no-such-pkg")))
      (should (equal :miss (plist-get cached :status)))
      (should (null (plist-get cached :recipe))))))

(ert-deftest nelix-emacs-test-fetch-melpa-recipe-error-caches ()
  "Network error → returns nil, cache stores `:error'."
  (nelix-emacs-test--with-melpa-mock
      (lambda (_url) (list :status 500 :body "internal"))
    (should (null (nelix-emacs-fetch-melpa-recipe "transient")))
    (let ((cached (nelix-state-get
                   nelix-emacs--melpa-recipe-namespace "transient")))
      (should (equal :error (plist-get cached :status))))))

(ert-deftest nelix-emacs-test-fetch-melpa-recipe-cache-hit-skips-http ()
  "Second call within TTL → no HTTP round-trip."
  (let ((http-calls 0))
    (nelix-emacs-test--with-melpa-mock
        (lambda (_url)
          (cl-incf http-calls)
          (list :status 200 :body "(magit :fetcher github :repo \"magit/magit\")"))
      (let ((first (nelix-emacs-fetch-melpa-recipe "magit")))
        (should (equal first "(magit :fetcher github :repo \"magit/magit\")"))
        (should (= 1 http-calls))
        (let ((second (nelix-emacs-fetch-melpa-recipe "magit")))
          (should (equal first second))
          ;; No additional HTTP call.
          (should (= 1 http-calls)))))))

(ert-deftest nelix-emacs-test-render-fetch-fn-respects-defcustom ()
  "Default `nelix-emacs--render-fetch-fn' returns nil when the
upstream-fetch defcustom is off (Phase 4-D parity)."
  (let ((nelix-emacs-melpa-upstream-fetch nil))
    ;; Even if cache happens to have a value, the lambda short-circuits.
    (should (null (funcall nelix-emacs--render-fetch-fn "anything")))))

;;;; --- Phase 4-G: git-clone credential injection ---------------------------

(defmacro nelix-emacs-test--with-env (bindings &rest body)
  "Set BINDINGS env vars for BODY; restore on exit."
  (declare (indent 1))
  `(let ((nelix-emacs-test--saved
          (mapcar (lambda (b) (cons (car b) (getenv (car b))))
                  ',bindings)))
     (unwind-protect
         (progn
           ,@(mapcar (lambda (b) `(setenv ,(car b) ,(cadr b)))
                     bindings)
           ,@body)
       (dolist (s nelix-emacs-test--saved)
         (setenv (car s) (cdr s))))))

(ert-deftest nelix-emacs-test-git-credential-args-https-with-env ()
  "HTTPS URL + GITHUB_TOKEN → -c http.<host>/.extraheader=Authorization."
  (nelix-emacs-test--with-env (("GITHUB_TOKEN" "ghp_xxx"))
    (let ((args (nelix-emacs--git-credential-args
                 "https://github.com/owner/repo.git")))
      (should (equal "-c" (car args)))
      (should (string-match-p
               "\\`http\\.https://github\\.com/\\.extraheader=Authorization: Bearer ghp_xxx\\'"
               (cadr args))))))

(ert-deftest nelix-emacs-test-git-credential-args-ssh-passthrough ()
  "SSH URL → no -c injection (SSH agent handles auth)."
  (nelix-emacs-test--with-env (("GITHUB_TOKEN" "ghp_xxx"))
    (should-not (nelix-emacs--git-credential-args
                 "git@github.com:owner/repo.git"))))

(ert-deftest nelix-emacs-test-git-credential-args-https-no-env ()
  "HTTPS URL + no env → no -c injection."
  (nelix-emacs-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil))
    (should-not (nelix-emacs--git-credential-args
                 "https://github.com/owner/repo.git"))))

(ert-deftest nelix-emacs-test-git-credential-args-unknown-host ()
  "HTTPS URL on a host not in the alist → no injection even with token set."
  (nelix-emacs-test--with-env (("GITHUB_TOKEN" "ghp_xxx"))
    (should-not (nelix-emacs--git-credential-args
                 "https://example.com/foo.git"))))

(provide 'nelix-emacs-test)
;;; nelix-emacs-test.el ends here
