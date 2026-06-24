;;; flycheck-posframe.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "flycheck-posframe"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alexmurray/flycheck-posframe/tar.gz/19896b922c76a0f460bf3fe8d8ebc2f9ac9028d8" :sha256 "sha256-e7b488dcc315da537beded1d7e1d6de3d2d550102d8ef338abbf83e1ad842065") :dependencies nil :install (:type build :build-system emacs-package :pname "flycheck-posframe" :load-paths (".") :features (flycheck-posframe)))))

;;; flycheck-posframe.el ends here
