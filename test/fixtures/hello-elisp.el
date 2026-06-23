;;; hello-elisp.el --- Lisp-native build-phase fixture -*- lexical-binding: t; -*-
;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A source-build recipe whose :build-phases are ELISP FORMS (not shell
;; strings) using the nelix-build primitive vocabulary.  No shell drives the
;; orchestration: with-temp-file generates source, nelix-substitute* patches
;; it in pure Elisp (return 7 -> 42), nelix-invoke compiles, nelix-install-file
;; + (nelix-out) places it.  The binary exits 42 only if substitute* ran.
;; Used by `make smoke-native-build-elisp'.
;;; Code:
(require 'nelix-registry)
(nelix-package
 :name "hello-elisp"
 :version "1.0.0"
 :class 'source-build
 :description "Lisp-native phases (no shell strings) built via nelix-build primitives"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((unpack  . (with-temp-file "hello.c"
                            (insert "int main(){return 7;}")))
               (patch   . (nelix-substitute* "hello.c" '("return 7" . "return 42")))
               (build   . (nelix-invoke "cc" "-O2" "hello.c" "-o" "hello"))
               (install . (nelix-install-file "hello" (concat (nelix-out) "/bin"))))
              :bin ("bin/hello")))))
;;; hello-elisp.el ends here
