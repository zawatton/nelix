;;; hl-todo.el --- Nelix recipe (manual pin; missing transitive dep) -*- lexical-binding: t; -*-

;; magit-todos requires hl-todo, which nixpkgs supplied as a propagated
;; dependency and which was therefore never a top-level flake.nix block.  Pinned
;; here by full commit with the real tarball sha256.  hl-todo itself requires
;; compat 31 and cond-let, both present in the registry.

(require 'nelix-registry)

(nelix-package
 :name "hl-todo"
 :version "3.8.1"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tarsius/hl-todo/tar.gz/527d545b8c2f36243194cbe4a8d0e6ac9d50e6a7" :sha256 "sha256-ff2d96cd94715196490bf8539c379f38388528579dcf7a87e3136441fec9041f") :dependencies ("compat" "cond-let") :install (:type build :build-system emacs-package :pname "hl-todo" :load-paths (".") :features (hl-todo)))))

;;; hl-todo.el ends here
