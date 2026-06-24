;;; ace-window.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ace-window"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/ace-window/tar.gz/77115afc1b0b9f633084cf7479c767988106c196" :sha256 "sha256-5c6620e838d39956fa0ba64514e2d945e0d05a94da3883f59e09dc851ef23e07") :dependencies ("avy") :install (:type build :build-system emacs-package :pname "ace-window" :load-paths (".") :features (ace-window)))))

;;; ace-window.el ends here
