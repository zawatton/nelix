;;; nelix-builder-input-test.el --- nelix-input across runs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `nelix-input' resolves a dependency's store path inside a build phase --
;; how a C module finds the headers and libraries of a library package it
;; was built against.  The alist behind it is assembled from the reports
;; `nelix-builder--install-dependencies' returns.
;;
;; A dependency already present in the profile is not rebuilt, and used to
;; return no report at all.  That made the alist depend on history rather
;; than on the recipe: the very first run installed the dependency and saw
;; it, every later run saw nothing and the phase failed.  So what is
;; asserted here is that the report is the same either way.

;;; Code:

(require 'ert)
(require 'nelix-builder)
(require 'nelix-store)
(require 'nelix-build)

(defmacro nelix-builder-input-test--with-profile (entries &rest body)
  "Run BODY with a profile whose :entries are ENTRIES."
  (declare (indent 1))
  `(let* ((root (make-temp-file "nelix-input-" t))
          (nelix-profile-root (expand-file-name "profiles" root))
          (nelix-store-root (expand-file-name "store" root))
          (nelix-builder--profile-entries-cache nil))
     (unwind-protect
         (progn
           (nelix-profile-write-generation
            (list :name "default" :generation 1
                  :system 'x86_64-linux :entries ,entries))
           ,@body)
       (delete-directory root t))))

(ert-deftest nelix-builder-input-test-installed-dependency-is-reported ()
  "An already-installed dependency still yields a report with its store path."
  (nelix-builder-input-test--with-profile
      (list (list :name "libtool" :version "2.5.4"
                  :store-path "/store/sha256-libtool-2.5.4"
                  :backend 'nelix-native))
    (let ((reports (nelix-builder--install-dependencies
                    '("libtool") "default" 'x86_64-linux)))
      (should (= 1 (length reports)))
      (should (equal "libtool" (plist-get (car reports) :name)))
      (should (equal "/store/sha256-libtool-2.5.4"
                     (plist-get (car reports) :store-path)))
      (should (plist-get (car reports) :already-installed)))))

(ert-deftest nelix-builder-input-test-report-feeds-nelix-input ()
  "The report carries what the caller needs to build the `nelix-input' alist.

The alist is (NAME . STORE-PATH) pairs taken from the reports, so a
report missing either key silently drops the dependency."
  (nelix-builder-input-test--with-profile
      (list (list :name "libtool" :version "2.5.4"
                  :store-path "/store/sha256-libtool-2.5.4"
                  :backend 'nelix-native))
    (let* ((reports (nelix-builder--install-dependencies
                     '("libtool") "default" 'x86_64-linux))
           (inputs (delq nil
                         (mapcar (lambda (r)
                                   (let ((n (plist-get r :name))
                                         (sp (plist-get r :store-path)))
                                     (and n sp (cons n sp))))
                                 reports)))
           (nelix-build--inputs inputs))
      (should (equal "/store/sha256-libtool-2.5.4" (nelix-input "libtool"))))))

(ert-deftest nelix-builder-input-test-built-in-reports-nothing ()
  "A host-provided dependency yields no report -- it has no store path.

Distinct from the case above: `org' is satisfied, but there is nothing
for `nelix-input' to point at, and inventing an entry for it would put a
bogus path in the alist."
  (nelix-builder-input-test--with-profile nil
    (should (null (nelix-builder--install-dependencies
                   '("org") "default" 'x86_64-linux)))))

(provide 'nelix-builder-input-test)
;;; nelix-builder-input-test.el ends here
