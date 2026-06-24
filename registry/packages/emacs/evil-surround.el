;;; evil-surround.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil-surround"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-evil/evil-surround/tar.gz/14dc693ed971053feb9596d4bc1b1de0b0006584" :sha256 "sha256-7c378626fd5a1275e7bdd0d32d1ffdddee28f7aadece3ebd75bff2ac3c75555c") :dependencies ("evil") :install (:type build :build-system emacs-package :pname "evil-surround" :load-paths (".") :features (evil-surround)))))

;;; evil-surround.el ends here
