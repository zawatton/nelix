;;; latex-math-preview.el --- Nelix recipe -*- lexical-binding: t; -*-

;; Hand-written, not generated from flake.nix: this package never had a
;; resolved Nix hash (the nelix-package.el DSL entry still carries
;; "sha256-PLACEHOLDER-fill-in-from-nix").  The archive below was fetched
;; twice with identical bytes and its contents verified file-by-file against
;; a git checkout of the pinned commit.  test.el is excluded because it is
;; the upstream ERT file, not part of the package.

(require 'nelix-registry)

(nelix-package :name "latex-math-preview" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/latex-math-preview/latex-math-preview/-/archive/1c082179493eed3ce8bc255f87791eb4acb1fbdb/latex-math-preview-1c082179493eed3ce8bc255f87791eb4acb1fbdb.tar.gz" :sha256 "sha256-5922997802c6a49a3b0d48dbe74357acfbc758b32426349d9e8dc3694408812c") :install (:type build :build-system emacs-package :pname "latex-math-preview" :load-paths (".") :el-exclude ("test.el") :features (latex-math-preview))) (x86_64-windows :source (:type url :url "https://gitlab.com/latex-math-preview/latex-math-preview/-/archive/1c082179493eed3ce8bc255f87791eb4acb1fbdb/latex-math-preview-1c082179493eed3ce8bc255f87791eb4acb1fbdb.tar.gz" :sha256 "sha256-5922997802c6a49a3b0d48dbe74357acfbc758b32426349d9e8dc3694408812c") :install (:type build :build-system emacs-package :pname "latex-math-preview" :load-paths (".") :el-exclude ("test.el") :features (latex-math-preview)))))

;;; latex-math-preview.el ends here
