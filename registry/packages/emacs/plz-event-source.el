;;; plz-event-source.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "plz-event-source"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/r0man/plz-event-source/tar.gz/main" :sha256 "sha256-7205702b9db63046b6ed3a46bd026a6b5843524e16fa9027f8c74fb92311902c") :dependencies nil :install (:type build :build-system emacs-package :pname "plz-event-source" :load-paths (".") :features (plz-event-source)))))

;;; plz-event-source.el ends here
