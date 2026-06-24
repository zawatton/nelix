;;; all-the-icons-completion.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "all-the-icons-completion"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/iyefrat/all-the-icons-completion/tar.gz/4c8bcad8033f5d0868ce82ea3807c6cd46c4a198" :sha256 "sha256-7a4126080410cad1518548ffeb993b184ab13f66f3c57ee9e539f6f545dfdcdc") :dependencies ("all-the-icons") :install (:type build :build-system emacs-package :pname "all-the-icons-completion" :load-paths (".") :features (all-the-icons-completion)))))

;;; all-the-icons-completion.el ends here
