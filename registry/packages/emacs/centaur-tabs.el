;;; centaur-tabs.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "centaur-tabs"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/ema2159/centaur-tabs/tar.gz/ecee903518f1650421891f6c7bf521f200e22765" :sha256 "sha256-4ecdc82b56841ea39d71d1d0bf2b6f5e81dde818f092dd67abc249aca3b8d06c") :dependencies ("powerline") :install (:type build :build-system emacs-package :pname "centaur-tabs" :load-paths (".") :features (centaur-tabs)))))

;;; centaur-tabs.el ends here
