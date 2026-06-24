;;; visual-basic-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "visual-basic-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/visual-basic-mode/tar.gz/6474d32b04c34555c15fefcf713006e33e5076e8" :sha256 "sha256-a900a24ffe4961e18ad22d0f903ecd1825e18f21fd4dc866089f5de76f7e9e89") :dependencies nil :install (:type build :build-system emacs-package :pname "visual-basic-mode" :load-paths (".") :features (visual-basic-mode)))))

;;; visual-basic-mode.el ends here
