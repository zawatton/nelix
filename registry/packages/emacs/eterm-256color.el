;;; eterm-256color.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "eterm-256color"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/dieggsy/eterm-256color/tar.gz/05fdbd336a888a0f4068578a6d385d8bf812a4e8" :sha256 "sha256-679b6c1474c670c98f07646928048094b06de8e7c1169e895845d2c98eb6267e") :dependencies ("xterm-color" "f") :install (:type build :build-system emacs-package :pname "eterm-256color" :load-paths (".") :features (eterm-256color)))))

;;; eterm-256color.el ends here
