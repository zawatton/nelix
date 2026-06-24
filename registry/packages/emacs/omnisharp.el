;;; omnisharp.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "omnisharp"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/OmniSharp/omnisharp-emacs/tar.gz/c222e970998d796bdfd49e45ed789e2fd1a9da03" :sha256 "sha256-e93039e572230daeb5098a0471d5b2214a1417a9c58dba89f6036121db74e50e") :dependencies nil :install (:type build :build-system emacs-package :pname "omnisharp" :load-paths (".") :features (omnisharp)))))

;;; omnisharp.el ends here
