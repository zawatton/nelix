;;; powerline.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "powerline"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/milkypostman/powerline/tar.gz/c35c35bdf5ce2d992882c1f06f0f078058870d4a" :sha256 "sha256-b590abe9804eb2edb030b61f41549e44ddb56ccf7c0117c32593a4d9dbf2e2ce") :dependencies nil :install (:type build :build-system emacs-package :pname "powerline" :load-paths (".") :features (powerline)))))

;;; powerline.el ends here
