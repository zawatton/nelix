;;; ob-yaml.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ob-yaml"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/ob-yaml/tar.gz/3417a224be328914074578df11ebd50a2e0bba79" :sha256 "sha256-cd0bdaf68743be94f32329ab2a171ff7c4a2cf9270519bd7a1a77c61d40108bb") :dependencies ("yaml-mode") :install (:type build :build-system emacs-package :pname "ob-yaml" :load-paths (".") :features (ob-yaml)))))

;;; ob-yaml.el ends here
