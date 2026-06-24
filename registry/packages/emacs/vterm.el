;;; vterm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "vterm"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/akermu/emacs-libvterm/tar.gz/988279316fc89e6d78947b48513f248597ba969a" :sha256 "sha256-fb44457c8197a30f08b7ae3799b87f08970b9007090d0dc5d6cd628db8831028") :dependencies nil :install (:type build :build-system emacs-package :pname "vterm" :load-paths (".") :features (vterm)))))

;;; vterm.el ends here
