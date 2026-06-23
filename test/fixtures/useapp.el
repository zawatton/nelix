;;; useapp.el --- consumer fixture: reads libgreet input, builds binary -*- lexical-binding: t; -*-
;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; useapp: a source-build package that depends on libgreet.
;; Its build phases read the value from (nelix-input "libgreet")/value,
;; generate a C program that exits with that value, compile, and install.
;; The binary exits 42 only if (nelix-input "libgreet") resolved correctly
;; to libgreet's store path and the value file was readable.
;; Used by `make smoke-deps-inputs'.
;;; Code:
(require 'nelix-registry)
(nelix-package
 :name "useapp"
 :version "1.0.0"
 :class 'source-build
 :description "useapp: reads libgreet input, builds a binary that exits 42"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :dependencies ("libgreet")
    :install (:type build
              :build-system trivial
              :build-phases
              ((generate . (let* ((greet-dir (nelix-input "libgreet"))
                                  (val-file  (expand-file-name "value" greet-dir))
                                  (val-str   (with-temp-buffer
                                               (insert-file-contents val-file)
                                               (string-trim (buffer-string))))
                                  (n         (string-to-number val-str))
                                  (src       (format "int main(){return %d;}" n)))
                              (write-region src nil "useapp.c")))
               (build   . (nelix-invoke "cc" "-O2" "useapp.c" "-o" "useapp"))
               (install . (nelix-install-file "useapp" (concat (nelix-out) "/bin"))))
              :bin ("bin/useapp")))))
;;; useapp.el ends here
