;;; dash.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "dash"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magnars/dash.el/tar.gz/1de9dcb83eacfb162b6d9a118a4770b1281bcd84" :sha256 "sha256-4d528df35412d4df346f1ab51f8ee0bee00eb1c6bc3ffe9958e6f15f6ebefd0a") :dependencies nil :install (:type build :build-system emacs-package :pname "dash" :load-paths (".") :features (dash)))))

;;; dash.el ends here
