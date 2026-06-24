;;; evil-org.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil-org"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/somelauw/evil-org-mode/tar.gz/b1f309726b1326e1a103742524ec331789f2bf94" :sha256 "sha256-f6b434549722218f5f92f136001e4c1129941bdf7f27d0b266666c971ed86072") :dependencies ("evil" "org") :install (:type build :build-system emacs-package :pname "evil-org" :load-paths (".") :features (evil-org)))))

;;; evil-org.el ends here
