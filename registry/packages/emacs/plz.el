;;; plz.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "plz"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/plz.el/tar.gz/master" :sha256 "sha256-b90e4c54a0ca462cb155397209d2368716969a08fc6c2a16a9ebd28c34241fd8") :dependencies nil :install (:type build :build-system emacs-package :pname "plz" :load-paths (".") :features (plz)))))

;;; plz.el ends here
