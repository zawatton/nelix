;;; multi-vterm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "multi-vterm"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/suonlight/multi-vterm/tar.gz/36746d85870dac5aaee6b9af4aa1c3c0ef21a905" :sha256 "sha256-c63ff6a4700e7609f2ff38ad13d6837817aceeb2e46ca11d3f363ae51ae02f95") :dependencies nil :install (:type build :build-system emacs-package :pname "multi-vterm" :load-paths (".") :features (multi-vterm)))))

;;; multi-vterm.el ends here
