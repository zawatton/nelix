;;; flycheck.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "flycheck"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/flycheck/flycheck/tar.gz/7a6398ea3538a898eba0276f0f89b2f878325a89" :sha256 "sha256-e934f0db16a396147e62534ea390e6b21b4d4c891f212a689fb989ece1f2ee97") :dependencies nil :install (:type build :build-system emacs-package :pname "flycheck" :load-paths (".") :features (flycheck)))))

;;; flycheck.el ends here
