;;; evil-collection.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil-collection"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-evil/evil-collection/tar.gz/6365e7c8ae728f7a26294db261b6778d089a6263" :sha256 "sha256-9a056eba2ae1c7b73eeb9bc784b5747c8360677b9e01fb755b0ab4e4f1fd8849") :dependencies ("evil" "annalist") :install (:type build :build-system emacs-package :pname "evil-collection" :load-paths (".") :features (evil-collection)))))

;;; evil-collection.el ends here
