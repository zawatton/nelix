;;; emacsql.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "emacsql"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magit/emacsql/tar.gz/fb05d0f72729a4b4452a3b1168a9b7b35a851a53" :sha256 "sha256-c09368f22107de3b10978750d323027661b0b5b807181ef52da7efea519274ea") :dependencies nil :install (:type build :build-system emacs-package :pname "emacsql" :load-paths (".") :features (emacsql)))))

;;; emacsql.el ends here
