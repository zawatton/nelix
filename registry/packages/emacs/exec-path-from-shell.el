;;; exec-path-from-shell.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "exec-path-from-shell"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/purcell/exec-path-from-shell/tar.gz/72ede29a0e0467b3b433e8edbee3c79bab005884" :sha256 "sha256-7e62eba6537b44db2b9cb6ca0a3f847068ec3817981500109b7cca298f041867") :dependencies nil :install (:type build :build-system emacs-package :pname "exec-path-from-shell" :load-paths (".") :features (exec-path-from-shell)))))

;;; exec-path-from-shell.el ends here
