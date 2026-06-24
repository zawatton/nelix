;;; dashboard.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "dashboard"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-dashboard/emacs-dashboard/tar.gz/c9d2dda2cd75e9f6d05be0e52fb126f63e6e7430" :sha256 "sha256-161d8fb224e6ab9dd3ac2f9dd8649a3053ec1e8bd322afdd6dbdd13d982bbdb1") :dependencies nil :install (:type build :build-system emacs-package :pname "dashboard" :load-paths (".") :features (dashboard)))))

;;; dashboard.el ends here
