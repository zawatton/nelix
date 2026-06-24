;;; llama.el --- Nelix recipe (manual pin; flake.nix import 404 fallback) -*- lexical-binding: t; -*-

;; The flake.nix block pinned `rev = "1.0.4"', but the upstream tag is
;; `v1.0.4' (with the `v' prefix), so the codeload tarball 404'd during
;; bulk import and no recipe was emitted.  llama is a hard dependency of
;; recent magit / with-editor / git-commit, so it is pinned here by full
;; commit (v1.0.5) with the real tarball sha256.

(require 'nelix-registry)

(nelix-package
 :name "llama"
 :version "1.0.5"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tarsius/llama/tar.gz/4d4024048053b898a01521046e0f063ee47615b0" :sha256 "sha256-fdc7a04ac166062911ed670a1d59076fa706b84af47e4ad89af2cea0713fb308") :dependencies ("compat") :install (:type build :build-system emacs-package :pname "llama" :load-paths (".") :features (llama)))))

;;; llama.el ends here
