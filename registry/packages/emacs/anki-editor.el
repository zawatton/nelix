;;; anki-editor.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "anki-editor"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/anki-editor/anki-editor/tar.gz/ba7c7bf3269f7630ef8c06f342ab04bdd8efea53" :sha256 "sha256-da7eff117857432421f85bdf0092fb51180569e58ec2d9d883561c5df119086a") :dependencies nil :install (:type build :build-system emacs-package :pname "anki-editor" :load-paths (".") :features (anki-editor)))))

;;; anki-editor.el ends here
