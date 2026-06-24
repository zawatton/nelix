;;; evil-commentary.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil-commentary"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/linktohack/evil-commentary/tar.gz/c5945f28ce47644c828aac1f5f6ec335478d17fb" :sha256 "sha256-1a4297fee0a1b54f00eb07cbe64f4ca7b81b248b864558c6ee3e515ddfcec6ce") :dependencies ("evil") :install (:type build :build-system emacs-package :pname "evil-commentary" :load-paths (".") :features (evil-commentary)))))

;;; evil-commentary.el ends here
