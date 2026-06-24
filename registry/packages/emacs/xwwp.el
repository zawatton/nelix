;;; xwwp.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "xwwp"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/canatella/xwwp/tar.gz/0c875e460d1c0637766204dc289ffbd0f2284194" :sha256 "sha256-b245c13a8269208826fef98a493b70e62d9c6ec435586741d043c545403f6dc7") :dependencies nil :install (:type build :build-system emacs-package :pname "xwwp" :load-paths (".") :features (xwwp)))))

;;; xwwp.el ends here
