;;; julia-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "julia-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/JuliaEditorSupport/julia-emacs/tar.gz/7fc071eb2c383d44be6d61ea6cef73b0cc8ef9b7" :sha256 "sha256-2b85d30d2e667749f13524caebd0e548c7acbc6419dd200aacc8a2e11a8701d9") :dependencies nil :install (:type build :build-system emacs-package :pname "julia-mode" :load-paths (".") :features (julia-mode)))))

;;; julia-mode.el ends here
