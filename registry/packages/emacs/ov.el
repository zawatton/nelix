;;; ov.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ov"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsorphanage/ov/tar.gz/e2971ad986b6ac441e9849031d34c56c980cf40b" :sha256 "sha256-4369dbb5e62cf2c092b77e9f4d40ee4dffda32560c3d62adee35bb6813d598cf") :dependencies nil :install (:type build :build-system emacs-package :pname "ov" :load-paths (".") :features (ov)))))

;;; ov.el ends here
