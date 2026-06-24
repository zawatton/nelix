;;; hydra.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "hydra"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/hydra/tar.gz/59a2a45a35027948476d1d7751b0f0215b1e61aa" :sha256 "sha256-ac1c2660ee311ea28d1ac9e7a1f2d2154ad7e607af4930f1c6b44f26fc89ced8") :dependencies nil :install (:type build :build-system emacs-package :pname "hydra" :load-paths (".") :features (hydra)))))

;;; hydra.el ends here
