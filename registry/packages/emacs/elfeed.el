;;; elfeed.el --- Nelix recipe (manual pin; flake.nix import 404 fallback) -*- lexical-binding: t; -*-

;; The flake.nix block pinned `rev = "master"', but skeeto/elfeed renamed its
;; default branch to `main', so the codeload tarball 404'd during bulk import
;; and no recipe was emitted.  Pinned here by full commit on `main' with the
;; real tarball sha256.  elfeed has no external Package-Requires (Emacs only).

(require 'nelix-registry)

(nelix-package
 :name "elfeed"
 :version "3.4.2"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/skeeto/elfeed/tar.gz/2c4f03158a3bf410d95c57851de284a1f88537ca" :sha256 "sha256-d4b5bfb123a5d34381f3b0278dcac12559010958408bfc2059b846b593879686") :dependencies nil :install (:type build :build-system emacs-package :pname "elfeed" :load-paths (".") :features (elfeed)))))

;;; elfeed.el ends here
