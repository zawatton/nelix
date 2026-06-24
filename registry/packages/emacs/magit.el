;;; magit.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "magit"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magit/magit/tar.gz/61c051ea1cda5fe6c9404cb5ae228088d2e254f0" :sha256 "sha256-5f9b6b130e59af591934e300736711813dca59cb10c7745df95e573c48ecdfc2") :dependencies nil :install (:type build :build-system emacs-package :pname "magit" :load-paths (".") :features (magit)))))

;;; magit.el ends here
