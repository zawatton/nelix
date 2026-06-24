;;; compat.el --- Nelix recipe (bumped to 31.0.0.1 for static-when) -*- lexical-binding: t; -*-

;; Bumped from 30.0.0.0 to 31.0.0.1: the recent transient / hl-todo pins both
;; declare `(compat "31.0")' and use the `static-when' macro, which Emacs 30.1
;; lacks (it has `static-if' only) and which only `compat-31.el' provides.
;; compat is a strictly additive compatibility shim, so the bump is safe for
;; every other package that requires an older compat.

(require 'nelix-registry)

(nelix-package
 :name "compat"
 :version "31.0.0.1"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-compat/compat/tar.gz/b5b48183689b536f72b1214106afeabc465da9d4" :sha256 "sha256-efd2feb2e093a0d9dc9325597a148a39508eb74290b15618df3893eaafc0e9f1") :dependencies nil :install (:type build :build-system emacs-package :pname "compat" :load-paths (".") :features (compat)))))

;;; compat.el ends here
