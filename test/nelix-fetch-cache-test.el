;;; nelix-fetch-cache-test.el --- source cache and prefetch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Installing a package set is network-bound -- measured over 20 packages
;; into an empty store, 91% of wall clock was `nelix-fetch-source' against
;; 4% for the build phases -- so the cache these tests cover is where the
;; time goes.
;;
;; The cache is keyed by the SHA-256 the recipe declares, which is what
;; makes it safe to consult: an entry is only used when it hashes to the
;; name it is filed under.  These use file:// and local paths so nothing
;; here touches the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-fetch)

(defmacro nelix-fetch-cache-test--with-cache (&rest body)
  "Run BODY with a throwaway cache directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "nelix-fetch-cache-" t))
          (nelix-fetch-cache-directory dir))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun nelix-fetch-cache-test--file (dir name content)
  "Write CONTENT to NAME under DIR and return the path."
  (let ((path (expand-file-name name dir)))
    (write-region content nil path)
    path))

(ert-deftest nelix-fetch-cache-test-miss-then-hit ()
  "A fetch populates the cache; the next one is served from it."
  (nelix-fetch-cache-test--with-cache
    (let* ((src-dir (make-temp-file "nelix-fetch-src-" t))
           (src (nelix-fetch-cache-test--file src-dir "pkg.tar" "payload"))
           (sha (nelix-fetch-sha256-file src))
           (dest1 (expand-file-name "out1" src-dir))
           (dest2 (expand-file-name "out2" src-dir)))
      (unwind-protect
          (progn
            (should-not (nelix-fetch-cached-p sha))
            (let ((r (nelix-fetch-source (list :type 'url :url src :sha256 sha) dest1)))
              (should (plist-get r :ok))
              (should-not (plist-get r :cached)))
            (should (nelix-fetch-cached-p sha))
            ;; Remove the origin: only a cache hit can satisfy this one.
            (delete-file src)
            (let ((r (nelix-fetch-source (list :type 'url :url src :sha256 sha) dest2)))
              (should (plist-get r :ok))
              (should (plist-get r :cached)))
            (should (equal "payload"
                           (with-temp-buffer (insert-file-contents dest2)
                                             (buffer-string)))))
        (delete-directory src-dir t)))))

(ert-deftest nelix-fetch-cache-test-wrong-content-is-not-a-hit ()
  "An entry that does not hash to its own name is ignored.

This is the property the whole design rests on: the cache is consulted
before the download, so if a mismatched file could be served the fetcher
would hand back content the recipe never asked for."
  (nelix-fetch-cache-test--with-cache
    (let* ((src-dir (make-temp-file "nelix-fetch-src-" t))
           (real (nelix-fetch-cache-test--file src-dir "pkg.tar" "payload"))
           (sha (nelix-fetch-sha256-file real))
           (dest (expand-file-name "out" src-dir)))
      (unwind-protect
          (progn
            ;; File something else under the right name.
            (make-directory nelix-fetch-cache-directory t)
            (write-region "tampered" nil
                          (expand-file-name sha nelix-fetch-cache-directory))
            (should-not (nelix-fetch-cached-p sha))
            ;; The fetch still succeeds, from the origin, with real content.
            (nelix-fetch-source (list :type 'url :url real :sha256 sha) dest)
            (should (equal "payload"
                           (with-temp-buffer (insert-file-contents dest)
                                             (buffer-string)))))
        (delete-directory src-dir t)))))

(ert-deftest nelix-fetch-cache-test-key-rejects-path-separators ()
  "A hash carrying a path separator is refused as a cache key.
The hash becomes a file name, so a value containing / must not be able
to write outside the cache directory."
  (nelix-fetch-cache-test--with-cache
    (should-not (nelix-fetch--cache-file "sha256-../../escape"))
    (should-not (nelix-fetch--cache-file ""))
    (should (nelix-fetch--cache-file "sha256-abc123"))))

(ert-deftest nelix-fetch-cache-test-prefetch-counts-cached ()
  "Prefetch reports an already-cached source without downloading it."
  (nelix-fetch-cache-test--with-cache
    (let* ((src-dir (make-temp-file "nelix-fetch-src-" t))
           (src (nelix-fetch-cache-test--file src-dir "pkg.tar" "payload"))
           (sha (nelix-fetch-sha256-file src)))
      (unwind-protect
          (progn
            (nelix-fetch--cache-put src sha)
            (let ((r (nelix-fetch-prefetch
                      (list (list :type 'url :url "https://example.invalid/x"
                                  :sha256 sha)))))
              (should (= 1 (plist-get r :cached)))
              (should (= 0 (plist-get r :fetched)))
              (should (null (plist-get r :failed)))))
        (delete-directory src-dir t)))))

(ert-deftest nelix-fetch-cache-test-prefetch-skips-git-sources ()
  "A git source is left to the serial path -- it needs a checkout, not a GET."
  (nelix-fetch-cache-test--with-cache
    (let ((r (nelix-fetch-prefetch
              (list (list :type 'git :url "https://example.invalid/r.git"
                          :rev "deadbeef" :sha256 "sha256-abc")))))
      (should (= 0 (plist-get r :cached)))
      (should (= 0 (plist-get r :fetched)))
      (should (null (plist-get r :failed))))))

(require 'nelix-builder)

(ert-deftest nelix-fetch-cache-test-prefetch-follows-dependencies ()
  "Prefetch covers what a package depends on, not just the package.

The install loop installs dependencies too, so prefetching only the
names asked for leaves each dependency to be downloaded serially.
Measured over 60 packages that was 79 fetches against 60 prefetched,
and 19.6s of the 30.1s that remained."
  (let ((registry (make-hash-table :test 'equal)))
    (puthash "leaf"
             (list :name "leaf"
                   :systems '((x86_64-linux
                               :source (:type url :url "https://e.invalid/leaf"
                                        :sha256 "sha256-leaf"))))
             registry)
    (puthash "mid"
             (list :name "mid"
                   :systems '((x86_64-linux
                               :source (:type url :url "https://e.invalid/mid"
                                        :sha256 "sha256-mid")
                               :dependencies ("leaf"))))
             registry)
    (puthash "top"
             (list :name "top"
                   :systems '((x86_64-linux
                               :source (:type url :url "https://e.invalid/top"
                                        :sha256 "sha256-top")
                               :dependencies ("mid" "org"))))
             registry)
    (cl-letf (((symbol-function 'nelix-registry-get)
               (lambda (name) (gethash name registry))))
      (let ((hashes (mapcar (lambda (s) (plist-get s :sha256))
                            (nelix-builder--prefetch-sources
                             '("top") 'x86_64-linux))))
        ;; The whole closure, and "org" -- which has no recipe -- dropped.
        (should (equal '("sha256-top" "sha256-mid" "sha256-leaf") hashes))))))

(ert-deftest nelix-fetch-cache-test-prefetch-survives-a-dependency-cycle ()
  "A cycle in the dependency graph terminates instead of looping.

Recipes are data and can name each other; the walk has to be able to
survive that, because the alternative is a hang with no output."
  (let ((registry (make-hash-table :test 'equal)))
    (puthash "a" (list :name "a"
                       :systems '((x86_64-linux
                                   :source (:type url :url "https://e.invalid/a"
                                            :sha256 "sha256-a")
                                   :dependencies ("b"))))
             registry)
    (puthash "b" (list :name "b"
                       :systems '((x86_64-linux
                                   :source (:type url :url "https://e.invalid/b"
                                            :sha256 "sha256-b")
                                   :dependencies ("a"))))
             registry)
    (cl-letf (((symbol-function 'nelix-registry-get)
               (lambda (name) (gethash name registry))))
      (let ((hashes (mapcar (lambda (s) (plist-get s :sha256))
                            (nelix-builder--prefetch-sources
                             '("a") 'x86_64-linux))))
        (should (equal '("sha256-a" "sha256-b") hashes))))))

(provide 'nelix-fetch-cache-test)
;;; nelix-fetch-cache-test.el ends here
