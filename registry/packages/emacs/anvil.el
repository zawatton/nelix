;;; anvil.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "anvil"
 :version "1.2.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/anvil.el/tar.gz/2cc3a1ea7fa43ec3e2b70ee25fe0026fcd851dae" :sha256 "sha256-0a236defe42fb89728c9a47b52d67bc54aebb88b41580cabdc6ca815a61adc5d") :dependencies nil :install (:type build :build-system emacs-package :pname "anvil" :load-paths (".") :features (anvil)))))

;;; anvil.el ends here
