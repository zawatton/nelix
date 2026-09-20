;;; emacs-webkit.el --- Nelix recipe (akirakyle/emacs-webkit, GitHub) -*- lexical-binding: t; -*-

;; NOTE: this package builds a WebKitGTK dynamic module (webkit-module.so)
;; via its Makefile.  The nelix-native emacs-package build-system used here
;; only unpacks and adds the source to load-path; it does not run the
;; module's native build step, so `(require 'webkit)` will likely fail
;; until that native build integration exists. Recipe is registered for
;; name resolution / tracking purposes.

(require 'nelix-registry)

(nelix-package :name "emacs-webkit" :version "0.1" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/akirakyle/emacs-webkit/tar.gz/4c5caa8e2c2baa09400d3c4a467d4799d735d388" :sha256 "sha256-43347ebeeb1ce084e18d4c8cd76ee9d936b8bafdd463ba9691d7a9444d62fb32") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-webkit" :load-paths (".") :features (webkit))) (x86_64-windows :source (:type url :url "https://codeload.github.com/akirakyle/emacs-webkit/tar.gz/4c5caa8e2c2baa09400d3c4a467d4799d735d388" :sha256 "sha256-43347ebeeb1ce084e18d4c8cd76ee9d936b8bafdd463ba9691d7a9444d62fb32") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-webkit" :load-paths (".") :features (webkit)))))

;;; emacs-webkit.el ends here
