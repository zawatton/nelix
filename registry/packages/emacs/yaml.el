;;; yaml.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "yaml"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zkry/yaml.el/tar.gz/70c4fcead97e9bd6594e418c922ae769818f4245" :sha256 "sha256-f30ea647345a7aead0d0a4647b3046a2b7dfd228e7a99e4f5f98a0f37819dac1") :dependencies nil :install (:type build :build-system emacs-package :pname "yaml" :load-paths (".") :features (yaml)))))

;;; yaml.el ends here
