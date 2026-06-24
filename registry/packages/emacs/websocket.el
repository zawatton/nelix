;;; websocket.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "websocket"
 :version "1.16"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/ahyatt/emacs-websocket/tar.gz/1.16" :sha256 "sha256-35a243c5e1128cdddec0f09cecddf154881d1edbbef522275a710349ef622301") :dependencies nil :install (:type build :build-system emacs-package :pname "websocket" :load-paths (".") :features (websocket)))))

;;; websocket.el ends here
