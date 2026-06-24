;;; json-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "json-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/json-emacs/json-mode/tar.gz/77125b01c0ddce537085201098bea9b4b8ba6be3" :sha256 "sha256-b463eef5a692ec92016e2c378c7f3ffd057c450735e90b7d9074fdc44e2a8e0d") :dependencies nil :install (:type build :build-system emacs-package :pname "json-mode" :load-paths (".") :features (json-mode)))))

;;; json-mode.el ends here
