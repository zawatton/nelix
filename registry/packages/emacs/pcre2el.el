;;; pcre2el.el --- Nelix recipe (manual pin; missing transitive dep) -*- lexical-binding: t; -*-

;; magit-todos requires pcre2el, which nixpkgs supplied as a propagated
;; dependency and which was therefore never a top-level flake.nix block.  Pinned
;; here by full commit with the real tarball sha256.  pcre2el needs only
;; Emacs 25.1 (cl-lib is built in), so it has no external dependencies.

(require 'nelix-registry)

(nelix-package
 :name "pcre2el"
 :version "1.12"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/joddie/pcre2el/tar.gz/b4d846d80dddb313042131cf2b8fbf647567e000" :sha256 "sha256-6141625d10ae2ed5342d22da8bd43e57dc0d4f58a5c07d7bb408665bb3f0f839") :dependencies nil :install (:type build :build-system emacs-package :pname "pcre2el" :load-paths (".") :features (pcre2el)))))

;;; pcre2el.el ends here
