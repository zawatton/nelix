;;; org-msg.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-msg"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jeremy-compostella/org-msg/tar.gz/59e2042e5f23e25f31c6aef0db1e70c6f54f117d" :sha256 "sha256-b2a32a6398ef8cc57d6513b650c3215788f3a7dfa3281c92f198e7d0daea1bce") :dependencies nil :install (:type build :build-system emacs-package :pname "org-msg" :load-paths (".") :features (org-msg)))))

;;; org-msg.el ends here
