;;; org-super-agenda.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-super-agenda"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/org-super-agenda/tar.gz/05a710065af5ee4b3982f9619f864f7af12ca1d3" :sha256 "sha256-5e146439a1037f08916d3521798193f91492d13fffd3bc502148d6d9c12a0778") :dependencies nil :install (:type build :build-system emacs-package :pname "org-super-agenda" :load-paths (".") :features (org-super-agenda)))))

;;; org-super-agenda.el ends here
